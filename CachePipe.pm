# Matt Post <post@jhu.edu>

package CachePipe;

use strict;
use Exporter;
use vars qw|$VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS|;

# our($lexicon,%rules,%deps,%PARAMS,$base_measure);

@ISA = qw|Exporter|;
@EXPORT = qw|signature cache cache_from_file sha1hash|;
@EXPORT_OK = ();

use strict;
use Carp qw|croak|;
use warnings;
use threads;
use threads::shared;
use POSIX qw|strftime|;
use List::Util qw|reduce min shuffle sum|;
use IO::Handle;
# use Digest::SHA1;
# use Memoize;

# my $basedir;
# BEGIN {
#   $basedir = $ENV{CACHEPIPE};
#   unshift @INC, $basedir;
# }

# constructor
sub new {
  my $class = shift;
  my %params = @_;
  # default values
  my $self = { 
	dir     => ".cachepipe",
	basedir => $ENV{PWD},
	retval  => 0,  # expected return value
	email   => undef,
  };

  map { $self->{$_} = $params{$_} } keys %params;
  bless($self,$class);

  STDERR->autoflush(1);

  return $self;
}

# static version of cmd()
sub cache {
  my @args = @_;
  my $pipe = new CachePipe();
  $pipe->cmd(@args);
}

# static version that reads args from file
sub cache_from_file {
  my ($file) = @_;

  my @args;
  open READ, $file or die;
  while (my $line = <READ>) {
	chomp($line);
	push(@args,$line);
  }
  close(READ);

  # print join("\n",@args) . $/;

  my $pipe = new CachePipe();
  $pipe->cmd(@args);
}

sub build_signatures {
  my ($cmd,@deps) = @_;

  # print STDERR "CMD: $cmd\n";
  # map { print STDERR "DEP: $_\n" } @deps;

  # generate git-style signatures for input and output files
  my @sigs = map { sha1hash($_) } @deps;

  # walk through the command line and substitute signatures for file names
  my %filehash;
  for my $i (0..$#deps) {
	my $file = $deps[$i];
	$filehash{$file} = $sigs[$i];
  }
  my @tokens = split(' ',$cmd);
  for my $i (0..$#tokens) {
	my $token = $tokens[$i];
	if (exists $filehash{$token}) {
	  $tokens[$i] = $filehash{$token};
	}
  }
  # print STDERR "CMDSIG($cmd) = " . join(" ",@tokens) . $/;
  my $cmdsig = join(" ",@tokens);

  # generate a signature of the concatenation of the command and the
  # dependency signatures
  # TODO: 
  my $new_signature = signature(join(" ", $cmdsig, @sigs));
  
  return ($new_signature,$cmdsig,@sigs);
}

# Runs a command (if required)
# name: the (unique) name assigned to this command
# input_deps: an array ref of input file dependencies
# cmd: the complete command to run
# output_deps: an array ref of output file dependencies
#
# return code 1: command was re-run
# return code 0: command was cached
sub cmd {
  my ($self,$name,@args) = @_;

  die "no name provided" unless $name ne "";

  my ($cmd,@deps);
  my ($cache_only) = 0;
  while (my $arg = shift @args) {
	if ($arg =~ /^--/) {
	  $arg =~ s/^--//;
	  if ($arg eq "cache-only") {
		# print STDERR "* argument: --$arg\n";
		$cache_only = 1;
	  } else {
		print STDERR "* FATAL: CachePipe: unknown argument: --$arg\n";
		exit 1;
	  }
	} else {
	  $cmd = $arg;
	  @deps = @args;
	  last;
	}
  }

  # the directory where cache information is written
  my $dir = $self->{dir};
  my $namedir = "$dir/$name";

  my ($new_signature,$cmdsig,@sigs) = build_signatures($cmd,@deps);
  my $old_signature = "";
  my @old_sigs = ("") x @sigs;

  if (! -d $dir) {
	# if no caching has ever been done

	mkdir($dir);
	mkdir($namedir);

  } elsif (! -d $namedir)  {
	# otherwise, if this command hasn't yet been cached...

	mkdir($namedir);

  } elsif (! -e "$namedir/signature") { 
	# otherwise if the signature file doesn't exist...

  } else {
	# everything exists, but we need to check whether anything has changed

	open(READ, "$namedir/signature") 
		or die "no such file '$namedir/signature'";
	chomp($old_signature = <READ>);

	# throw away command signature line
	<READ>;

	# read in file dependency signatures
	while (my $line = <READ>) {
	  my @tokens = split(' ',$line);
	  push(@old_sigs, $tokens[0]);
	}
	close (READ);
  }

  if ($old_signature ne $new_signature) {
	$self->mylog("[$name] rebuilding...");
	for my $i (0..$#deps) {
	  my $dep = $deps[$i];

	  my $diff = ($sigs[$i] eq $old_sigs[$i]) ? "" : "[CHANGED]";
	  if (-e $dep) {
		$self->mylog("  dep=$dep $diff");
	  } else {
		$self->mylog("  dep=$dep [NOT FOUND] $diff");
	  }
        }
	$self->mylog("  cmd=$cmd");

	if ($cache_only) {

	  write_signature($namedir,$cmd,@deps);

	  return 0;

	} else {
	  # run the command
	  # redirect stdout and stderr

	  open OLDOUT, ">&", \*STDOUT or die;
	  open OLDERR, ">&", \*STDERR or die;

	  open(STDOUT,">$namedir/out") or die;
	  open(STDERR,">$namedir/err") or die;

	  system($cmd);

	  close(STDOUT);
	  close(STDERR);

	  open(STDOUT,">&", \*OLDOUT);
	  open(STDERR,">&", \*OLDERR);

	  my $retval = $? >> 8;

	  if ($retval == $self->{retval}) {
		write_signature($namedir,$cmd,@deps);

		return 1;

	  } else {
		$self->mylog("  JOB FAILED (return code $retval)");
		system("cat $namedir/err");
		exit(-1);
	  }
	}

  } else {
	$self->mylog("[$name] cached, skipping...");

	return 0;
  }
}

sub write_signature {
  my ($namedir,$cmd,@deps) = @_;

  my ($new_signature,$cmdsig,@sigs) = build_signatures($cmd,@deps);

  # regenerate signature
  open(WRITE, ">$namedir/signature");
  print WRITE $new_signature . $/;
  
  print WRITE "$cmdsig CMD $cmd\n";
  map {
	print WRITE "$sigs[$_] DEPENDENCY $deps[$_]\n";
  } (0..$#sigs);
  close(WRITE);

  # generate timestamp
  open(WRITE, ">$namedir/timestamp");
  print WRITE time() . $/;
  close(WRITE);
}


# Generates a GIT-style signature of a file.  Thanks to
# http://stackoverflow.com/questions/552659/assigning-git-sha1s-without-git
sub sha1hash {
  my ($arg) = @_;

  my $content = time();
  if ($arg =~ /^ENV:/) {
	my (undef,$env) = split(':',$arg);
	$content = $ENV{$env} || "";
	# print STDERR "ENV '$env' $content\n";
  } else {
	if (-e $arg) {
	  return file_signature($arg);
	}
  }

  return signature($content);
}

# Generates a GIT-style signature of a string *without* loading the whole file into memory 
sub file_signature {
  my ($file) = @_;

  my $size = (stat($file))[7];
  chomp(my $sha1 = `(echo -ne "blob $size\\0"; cat $file) | sha1sum -b | awk '{print \$1}'`);

  return $sha1;
}


# Generates a GIT-style signature of a string
sub signature {
  my ($content) = @_;

  my $length;
  {
	use bytes;
	$length = length($content);
  }

  my $git_blob = 'blob' . ' ' . length($content) . "\0" . $content;
  my $tmpfile = ".tmp.$$";
  open OUT, ">$tmpfile" or die;
  print OUT $git_blob;
  close(OUT);
  chomp(my $sha1 = `cat $tmpfile | sha1sum -b | awk '{ print \$1 }'`);
  unlink($tmpfile);
  return $sha1;

  # my $git_blob = 'blob' . ' ' . length($content) . "\0" . $content;
  # my $sha = new Digest::SHA1();
  # $sha->add($git_blob);
  # return $sha->hexdigest() . $/;
}

sub mylog {
	my ($self,$msg) = @_;

	print STDERR $msg . $/;
        
}

1;

