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
#   zypper in build obs-service-tar_scm obs-service-source_validator obs-service-set_version obs-service-recompress obs-service-verify_file obs-service-format_spec_file
#
# cd $IBS_CHECKOUT; osc co Devel:Cloud:Head
# cd $choose_one_package; osc build (and select to trust the required repos)
#
# prepare caching for disabled runs:
#   mkdir -p ~/.obs/cache/tar_scm/{incoming,repo,repourl}
#   echo 'CACHEDIRECTORY="$HOME/.obs/cache/tar_scm"' > ~/.obs/tar_scm
#
#
#


use strict;
use Archive::Tar;
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
our $OSC_BUILD_DIST = $ENV{OSC_BUILD_DIST} || 'SLE_11_SP2';
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

sub servicefile_write($$)
{
  my ($file, $data) = @_;
  open (my $FH, '>', $file) or die $!;
  binmode $FH;
  print $FH $data;
  close $FH;
}

sub xml_replace_text($$$)
{
  my ($node, $path, $text) = @_;
  die "Error: node, path or text undefined." unless ($node && $path && defined $text);
  my $nodeL = $node->find($path);
  my $onenode;
  $onenode = $nodeL->pop() if $nodeL->size() > 0;
  die "Error: Could not find an xml element with the statement $path, exiting." unless $onenode;
  $onenode->removeChildNodes();
  $onenode->addChild(XML::LibXML::Text->new($text));
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

sub servicefile_modify($)
{
  my $gitrev= shift || '';

  local $XML::LibXML::skipXMLDeclaration = 1;
  my $xmlorig = $xmldom->toString() . "\n";

  xml_replace_text($xmldom, '/services/service[@name="tar_scm"][1]/param[@name="revision"][1]', $gitrev);
  my $xmlnewrev = $xmldom->toString()."\n";
  servicefile_write($xmlfile, $xmlnewrev);
  #xml_replace_text($xmldom, '/services/service[@name="tar_scm"][1]/param[@name="url"][1]', $gitrepo);
}


sub pack_cleanup(@)
{
  my @deletes = @_;
  foreach my $del (@deletes) {
    `rm -fv $del`;
  }
}

sub pack_servicerun()
{
  my @cmd = (@OSCBASE, qw(service disabledrun));
  my $exitcode = system(@cmd);
  return $exitcode >> 8;
}


sub osc_build()
{
  #my @cmd = (@OSCBASE, 'build', '--no-verify', $OSC_BUILD_DIST, $OSC_BUILD_ARCH);
  #my $exitcode = system(@cmd);
  local $| = 1;
  my $cmd = "yes | ".join(' ',@OSCBASE)." build --no-verify $OSC_BUILD_DIST $OSC_BUILD_ARCH 2>&1 | ";
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
      # switch back to a consistent IBS checkout
      system('osc', 'rm', '--force', @tarballfiles) && die "Error: Could not 'osc rm' the broken files. Please check manually.";
      system('osc', 'revert', @oldtarballfiles) && die "Error: Could not 'osc revert' the latest changes. Please check manually.";

      #TODO fetch the last lines of the log
      print "\nTODO: display the last lines of the build log here\n\n";
    }

    exit $exitcode;
  }
}


sub add_changes_entry() {
  return 1 if $oldgitrev eq $gitrev;
  return 0 if ($oldgitrev eq '' || $gitrev eq '');

  return 0 if (! -e $ENV{'HOME'}.'/.obs/tar_scm');

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

  return 0 if ($tar_scm_cache eq '');

  # yes, newline character is intended
  my $gitremotesha = sha256_hex($gitremote.'
');
  my $gitdir = $tar_scm_cache.'/repo/'.$gitremotesha.'/.git';
  my $file = basename($SDIR).'.changes';
  my @lines;

  return 0 if (! -d $gitdir);
  return 0 if (! -e $file);

  my $cmd = "git --git-dir='".$gitdir."' log --pretty=format:%s --no-merges ".$oldgitrev."..".$gitrev;
  push @lines, `$cmd`;
  @lines = reverse(@lines);
  chomp(@lines);

  return 0 if (scalar(@lines) == 0);

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
    if ($PACK =~ /\.([a-f0-9]+)\.tar\.\w+$/) { $retval = $1; }
  }

  return $retval;
}


sub osc_checkin()
{
  system(@OSCBASE, 'ci', '-m', 'autocheckin from jenkins, revision: '.$gitrev);
}

sub get_osc_package_info()
{
  # read xml info from .osc/_files and return a hash
  # later may be extended to make an api call and return all possible information
  my $file = ".osc/_files";
  open (my $FH, '<', $file) or die $!;
  binmode $FH;
  my $parser=XML::LibXML->new();
  my $xmldom = $parser->parse_fh($FH);
  # print Data::Dumper->Dump([$xmldom],["XML"]);
  #print $xmldom->toString();
  close $FH;

  my %info = ();
  $info{project} = `cat .osc/_project`;
  chomp($info{project});
  $info{package} = xml_get_text($xmldom, '/directory[@name][1]', 'name');
  $info{_link_project} = xml_get_text($xmldom, '/directory/linkinfo[@project][1]', 'project');

  return \%info;
}

sub get_tarname_from_spec
{
  my $spec = shift;
  my $tarname = `grep -E Source0?: $spec|awk '{print \$2}'`;
  return $tarname;
}

sub extract_file_from_tarball
{
  my($filename, $tarball, $requires) = @_;

  my $tar = Archive::Tar->new($tarball, 1,
                              {filter => qr/.*\/$requires/});
  my ($tarfile) = $tar->list_files(['name']);
  $tar->extract_file($tarfile, $filename);
}
    
sub email_changes_diff
{
  my ($diff_file, $requires_type) = @_;

  my $to_email = "cloud-devel\@suse.de";
  my $from_email = "hudson\@suse.de";
  my $reply_to = "cloud-devel\@suse.de";
  my $obs_project = `cat .osc/_project`;
  chomp $obs_project;

  open(MAIL,
    "|mail -s \"$requires_type have changed for package ".
    "$obs_project/$project \" ".
    "-r $from_email -R $reply_to -a $diff_file ".
    "$to_email") or die "Cannot open mail: $!";
  print MAIL "The $requires_type from the package $project ".
    "in $obs_project have changed. Please see the attached diff.\n\n";
  close(MAIL);

  print "Sent $requires_type changes email to $to_email.\n";
}

sub check_pip_requires_changes()
{
  my @tarballs = (
    ["old_requires", ".osc/" . get_tarname_from_spec(".osc/$project.spec")],
    ["new_requires", get_tarname_from_spec("$project.spec")]
  );

  foreach my $requires_type ("pip-requires", "test-requires")
  {
    for my $i (@tarballs)
    {
      my ($filename, $tarball) = @{$i};
      extract_file_from_tarball($filename, $tarball, "tools/$requires_type");
    }

    my @keys = map { $_->[0] } @tarballs;

    my $diff = `diff -u @keys > ${project}.diff`;        
    if ($?)
    {
      email_changes_diff("${project}.diff", $requires_type);
    } else
    {
      print "There are no changes in the $requires_type.\n";
    }
    foreach my $file ( @keys, "$project.diff" ) {
      unlink $file or warn "Could not delete $file: $!";
    }
  }
}

#### MAIN ####


  die "Error: can not find .osc project in this directory: " unless ( -d '.osc');
  $project = `osc info | grep "Package name" | sed -e "s/.*: //"`;
  chomp $project;

  system(@OSCBASE, 'up') && die "Error: osc up failed, maybe due to local changes. Please check manually.";
  system(@OSCBASE, 'pull'); # exit code does not count

  # check for conflict
  if (osc_st('C'))
  {
    # rebranch
    my $info = get_osc_package_info();
    system(@OSCBASE, 'branch', '--force', $info->{_link_project}, $info->{package}, $info->{project});
    sleep 60;
    chdir("..");
    system("rm -rf $info->{package} ; osc co $info->{package}");
    chdir($info->{package});
  }

  $xmldom = servicefile_read_xml($xmlfile);
  eval {
    $gitremote = xml_get_text($xmldom, '/services/service[@name="tar_scm"][1]/param[@name="url"][1]');
  };
  my $gittarballs;
  if($@ =~m/Could not find an xml element with the statement/) {
    eval {
      $gittarballs=xml_get_text($xmldom, '/services/service[@name="git_tarballs"][1]/param[@name="url"][1]');
    };
    eval {
      $gittarballs=xml_get_text($xmldom, '/services/service[@name="github_tarballs"][1]/param[@name="url"][1]');
    };
    die $@ unless $gittarballs;
  }
  my $revision = $ENV{GITREV} || '';

  my $tarball;
  if (!$gittarballs)
  {
    my $tarballbase = xml_get_text($xmldom, '/services/service[@name="recompress"][1]/param[@name="file"][1]');
    my $tarballext  = xml_get_text($xmldom, '/services/service[@name="recompress"][1]/param[@name="compression"][1]');
    $tarball = "$tarballbase.$tarballext";
    push @oldtarballfiles, glob($tarball);
    $oldgitrev = find_gitrev(\@oldtarballfiles);
    #pack_cleanup(($tarball,));

    @oldtarballfiles || die "Error: Could not find any current tarball. Please check the state of the osc checkout manually.";
    system('osc', 'rm', @oldtarballfiles) && die "Error: osc rm failed. Please check manually.";

    #servicefile_modify($revision);
  }

  my $exitcode;
  # run source service
  $exitcode = pack_servicerun();
  die_on_error('service', $exitcode);
  if ($gittarballs)
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
    check_pip_requires_changes();

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

  #add_changes_entry() || die "Error: Could not create a changes entry.";
  #print "--> Added a changes entry.\n";

  print "--> Now trying to build package.\n";

  # run osc build
  $OSC_BUILD_LOG="../$project.build.log.0";
  $OSC_BUILD_LOG_OLD="../$project.build.log.1";
  rename($OSC_BUILD_LOG, $OSC_BUILD_LOG_OLD);
  $exitcode = osc_build();
  die_on_error('build', $exitcode);

  osc_checkin();

  die_on_error('checkin', $exitcode);

