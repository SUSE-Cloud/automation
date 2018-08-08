#!/usr/bin/perl -w

#
# track an upstream source service in an OBS package
#
# 2012 J. Daniel Schmidt <jdsn@suse.de>, Bernhard M. Wiedemann <bwiedemann@suse.de>
#


# Prepare packages: for i in python-keystoneclient python-novaclient ; do ibs copypac Devel:Cloud $i Devel:Cloud:Head ; ibs co $i ; done

# prepare node:
#   zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools/SLE_11_SP1 openSUSE_Tools-SLE_11_SP1
#   zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools/SLE_11_SP2 openSUSE_Tools
#   zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools:/Unstable/SLE_11_SP2/ openSUSE_Tools_Unstable
#   zypper ar http://download.opensuse.org/repositories/devel:/tools:/scm/SLE_11_SP1/ devel_tools_scm
#   zypper in osc=VERSION_from_openSUSE_Tools_Unstable
#   zypper in build obs-service-tar_scm obs-service-source_validator obs-service-set_version obs-service-recompress obs-service-verify_file obs-service-format_spec_file obs-service-refresh_patches
#
# cd $IBS_CHECKOUT; osc co Devel:Cloud:Head
# cd $choose_one_package; osc build (and select to trust the required repos)
#
#


use strict;
use Digest::SHA qw(sha256_hex);
use File::Basename;
use POSIX;
use XML::LibXML;
#use Data::Dumper;

# global
our $xmldom;
our $gitremote;
our $gitrepo;
our $project;
our $SDIR = $ENV{PWD};
our $xmlfile = '_service';
my $OSCAPI = $ENV{OSCAPI} || '';
my $OSCRC  = $ENV{OSCRC} || '';
our @OSCBASE=('osc');
push @OSCBASE, "-c", $OSCRC  if $OSCRC;
push @OSCBASE, "-A", $OSCAPI if $OSCAPI;
our $OSC_BUILD_ARCH = $ENV{OSC_BUILD_ARCH} || '';
our $OSC_BUILD_LOG;
our $OSC_BUILD_LOG_OLD;
our @tarballfiles;
our $gitrev;
our @oldtarballfiles;
our $oldgitrev;


sub servicefile_read_xml($)
{
  my $file = shift || die "Error: no input file to read the service xml data from.";
  open (my $FH, '<', $file) or die $!;
  binmode $FH;
  #my $xml = XML::LibXML->load_xml(IO => $FH);
  my $parser=XML::LibXML->new();
  my $xml = $parser->parse_fh($FH);
  close $FH;
  return $xml;
}


sub xml_get_text($$;$)
{
  my ($node, $path, $attribute) = @_;
  die "Error: node or path undefined." unless ($node && $path);
  my $nodeL = $node->find($path);
  my $onenode;
  $onenode = $nodeL->pop() if $nodeL->size() > 0;
  die "Error: Could not find an xml element with the statement $path, exiting." unless $onenode;
  return $attribute ? $onenode->getAttribute($attribute) : $onenode->textContent();
}


sub pack_servicerun()
{
  my @cmd = (@OSCBASE, qw(service disabledrun));
  my $output = readpipe(join " ", @cmd);
  my $exitcode = $?;
  print $output;
  if((($exitcode>>8) == 0) && $output eq "There are no new changes.\n") {
    exit 0
  }
  return $exitcode >> 8;
}


sub osc_build()
{
  local $| = 1;
  my $OSC_BUILD_DIST = $ENV{OSC_BUILD_DIST};
  unless($OSC_BUILD_DIST) {
    my $prj = `cat .osc/_project`;
    if ($prj =~ /Devel:Cloud:7/) {
      $OSC_BUILD_DIST = "SLE_12_SP2";
    }
    elsif ($prj =~ /Devel:Cloud:8/) {
      $OSC_BUILD_DIST = "SLE_12_SP3";
    }
    else {
      $OSC_BUILD_DIST = "SLE_12_SP4";
    }
  }

  my $cmd = "yes '1' | ".join(' ',@OSCBASE)." build --clean --no-verify $OSC_BUILD_DIST $OSC_BUILD_ARCH 2>&1 | ";
  open (my $FH, $cmd) or die $!;
  open (my $LOGFH, '>', $OSC_BUILD_LOG) or die $!;
  while (<$FH>)
  {
    print;
    print $LOGFH $_;
  }
  close $LOGFH;
  close $FH;
  #my $exitcode = system($cmd);
  my $exitcode = $?;
  return $exitcode >> 8;
}

sub osc_st($)
{
  my $FLAGS = shift || 'ADMR';
  my $cmd = join(' ', @OSCBASE). ' st | grep -e "^['.$FLAGS.']" | sed -e "s/^.\s\+//" ';
  my @lines;
  push @lines, `$cmd`;
  return @lines;
}


sub die_on_error($$)
{
  my $mode = shift || '--unknown--';
  my $exitcode = shift;
  die "Error: non-numeric exitcode" unless (defined $exitcode && $exitcode =~ /^\d+$/);
  print "\n-->\n--> Checking last exitcode: ";

  if ($exitcode == 0)
  {
    print "0 - Good!\n\n";
  }
  else
  {
    print "$exitcode - Error detected in $mode. Exiting.\n";

    if ($mode eq 'build')
    {
      #TODO fetch the last lines of the log
      print "\nTODO: display the last lines of the build log here\n\n";
    }

    exit $exitcode;
  }
}


sub add_changes_entry() {
  return 1 if $oldgitrev eq $gitrev;

  die "gitrev or oldgitrev is not set" if ($oldgitrev eq '' || $gitrev eq '');
  die "cannot find $ENV{'HOME'}/.obs/tar_scm" if (! -e $ENV{'HOME'}.'/.obs/tar_scm');

  my $tar_scm_cache = '';
  open (my $TARSCMFH, '<', $ENV{'HOME'}.'/.obs/tar_scm') or die $!;
  while (<$TARSCMFH>)
  {
    if (/^\s*CACHEDIRECTORY=["'](.*)["']\s*$/)
    {
      $tar_scm_cache=$1;
    }
  }
  close $TARSCMFH;

  die "tar_scm_cache is empty" if ($tar_scm_cache eq '');

  # yes, newline character is intended
  my $gitremotesha = sha256_hex($gitremote.'
');
  my $gitdir = $tar_scm_cache.'/repo/'.$gitremotesha.'/.git';
  my $file = basename($SDIR).'.changes';
  my @lines;

  die "gitdir $gitdir does not exist" if (! -d $gitdir);
  die "file $file does not exist" if (! -e $file);

  my $cmd = "git --git-dir='".$gitdir."' log --pretty=format:%s --no-merges ".$oldgitrev."...".$gitrev;
  push @lines, `$cmd`;
  @lines = reverse(@lines);
  chomp(@lines);

  if (scalar(@lines) == 0) {
    warn "WARNING: did not find any log messages\n";
    push @lines, "-- no messages found --";
  }

  chomp(my $date = `LC_ALL=POSIX TZ=UTC date`);

  open (my $FH, '>', $file.'.new') or die $!;
  print $FH "-------------------------------------------------------------------\n";
  print $FH $date." - cloud-devel\@suse.de\n";
  print $FH "\n";
  print $FH "- Update to latest git (".$gitrev."):\n";
  for my $line (@lines)
  {
    print $FH '  + '.$line."\n";
  }
  print $FH "\n";

  open (my $OLDFH, '<', $file) or die $!;
  while (<$OLDFH>)
  {
    print $FH $_;
  }

  close $OLDFH;
  close $FH;

  rename $file.'.new', $file;

  return 1;
}


sub find_gitrev($)
{
  my $files = shift || die "Error: no argument passed to find_gitrev()";
  my $retval = '';
  for my $PACK (@{$files})
  {
    if ($PACK =~ /\.([a-f0-9]+)\.(?:tar\.\w+|obscpio)$/) { $retval = $1; }
  }

  return $retval;
}


sub osc_checkin()
{
  my $exitcode = system(@OSCBASE, 'ci', '-m', 'autocheckin from jenkins, revision: '.$gitrev);
  return $exitcode >> 8;
}

#### MAIN ####

  # make sure the caching directories are setup
  unless ( -e "$ENV{HOME}/.obs/tar_scm")
  {
    system("mkdir -p $ENV{HOME}/.obs/cache/tar_scm/{incoming,repo,repourl}");
    system(qq(echo '[tar_scm]\nCACHEDIRECTORY="$ENV{HOME}/.obs/cache/tar_scm"' > ~/.obs/tar_scm));
  }

  die "Error: can not find .osc project in this directory: " unless ( -d '.osc');
  $project = `osc info | grep "Package name" | sed -e "s/.*: //"`;
  chomp $project;

  system(@OSCBASE, 'up') && die "Error: osc up failed, maybe due to local changes. Please check manually.";
  system(@OSCBASE, 'pull'); # exit code does not count

  # check for conflict
  if (osc_st('C'))
  {
    # we used to rebranch here, but then we loose either of the changes (change in Staging or in Stable branch)
    # we rather error out here and want somebody to look at it
    die "Error: Detected a conflict. Both packages in Staging and Stable branch have changed. Please fix the conflict manually.";
  }

  $xmldom = servicefile_read_xml($xmlfile);
  eval {
    $gitremote = xml_get_text($xmldom, '/services/service[@name="obs_scm" or @name="tar_scm"][1]/param[@name="url"][1]');
  };
  my $custom_service;
  my $changesgenerate;
  if($@ =~m/Could not find an xml element with the statement/) {
    eval {
      $custom_service=xml_get_text($xmldom, '/services/service[@name="git_tarballs"][1]/param[@name="url"][1]');
    };
    eval {
      $custom_service=xml_get_text($xmldom, '/services/service[@name="github_tarballs"][1]/param[@name="url"][1]');
    };
    eval {
      $custom_service=xml_get_text($xmldom, '/services/service[@name="download_files"][1]/param[@name="changesgenerate"][1]');
    };
    eval {
      $custom_service=xml_get_text($xmldom, '/services/service[@name="renderspec"][1]/param[@name="output-name"][1]');
    };
    die $@ unless $custom_service;
  }
  eval {
    $custom_service=xml_get_text($xmldom, '/services/service[@name="python_sdist"][1]/param[@name="basename"][1]');
  };
  eval {
    $changesgenerate=xml_get_text($xmldom, '/services/service[@name="obs_scm" or @name="tar_scm"][1]/param[@name="changesgenerate"][1]');
  };
  my $revision = $ENV{GITREV} || '';

  my $tarball;
  my $tarballbase;

  if (!$custom_service)
  {
    eval {
      $tarballbase = xml_get_text($xmldom, '/services/service[@name="recompress"][1]/param[@name="file"][1]');
    };
    eval {
      $tarballbase = xml_get_text($xmldom, '/services/service[@name="obs_scm" or @name="tar_scm"][1]/param[@name="filename"][1]') . "*";
    };

    if ($tarballbase) {
      my $tarballext = "*.obscpio";
      eval {
        $tarballext  = xml_get_text($xmldom, '/services/service[@name="recompress"][1]/param[@name="compression"][1]');
      };
      $tarball = "$tarballbase.$tarballext";
      push @oldtarballfiles, glob($tarball);
      $oldgitrev = find_gitrev(\@oldtarballfiles);

      @oldtarballfiles || die "Error: Could not find any current tarball. Please check the state of the osc checkout manually.";
      system('osc', 'rm', @oldtarballfiles) && die "Error: osc rm failed. Please check manually.";
    }
  }

  my $exitcode;
  # run source service
  $exitcode = pack_servicerun();
  die_on_error('service', $exitcode);
  if ($custom_service)
  {
    $gitrev=`perl -ne 'if(m/Version:.*\\.([0-9a-f]+)/){print \$1;exit}' *.spec`;
  } else
  {
    push @tarballfiles, glob($tarball);
    $gitrev = find_gitrev(\@tarballfiles);

    my @changedfiles = osc_st('ADM');
    if (scalar(@changedfiles) == 0)
    {
      print "\n-->\n";
      print "--> No changes detected. Skipping build and submit.\n";
      # revert all deleted packages to get back to a consistent checkout
      print "-->\n";
      print "--> Reverting back to consistent checkout.\n";
      system('osc', 'rm', @tarballfiles) && die "Error: Could not 'osc rm' the new broken files. Please cleanup manually.";
      system('osc', 'revert', @oldtarballfiles) && die "Error: Could not revert the deleted packages. Please cleanup manually.";
      print "-->\n";
      print "--> Successfully reverted back.\n";
      exit 0;
    }

    print "\n-->\n";
    print "--> Detected ".scalar(@changedfiles)." changed files.\n";

    system('osc', 'add', @tarballfiles) && die "Error: osc add failed. Please check manually.";

    my @revertedfiles = osc_st('R');
    if (scalar(@revertedfiles) == scalar(@changedfiles))
    {
      # we only have reverted files and no changes, switch back to consistent checkout
      print "-->\n";
      print "--> Sorry. The new files are just the same as the old ones.\n";
      print "--> Reverting back to consistent checkout.\n";
      system('osc', 'rm', @tarballfiles) && die "Error: Could not 'osc rm' the new broken files. Please cleanup manually.";
      system('osc', 'revert', @oldtarballfiles) && die "Error: Could not revert the deleted packages. Please cleanup manually.";
      print "-->\n";
      print "--> Successfully reverted back.\n";
      exit 0;
    }
  }

  if (!$custom_service && !$changesgenerate)
  {
    eval {
      add_changes_entry();
    };
    if ($@) {
      warn $@;
      die "Error: Could not create a changes entry.";
    }
    print "--> Added a changes entry.\n";
  }

  print "--> Now trying to build package.\n";

  # run osc build
  $OSC_BUILD_LOG="../$project.build.log.0";
  $OSC_BUILD_LOG_OLD="../$project.build.log.1";
  rename($OSC_BUILD_LOG, $OSC_BUILD_LOG_OLD);
  $exitcode = osc_build();
  die_on_error('build', $exitcode);

  $exitcode = osc_checkin();

  die_on_error('checkin', $exitcode);
