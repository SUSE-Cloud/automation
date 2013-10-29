#!/usr/bin/perl -w
#
# This tool creates parts for the Jenkins config file for the cloud-trackupstream job.
# The matrix configuration is computed using the rules in the following big hash.
#

use strict;
use XML::LibXML;

# this groovy snippet is added to the combination filter
#  it can be used to temporarily turn off builds for a part of the
#  matrix, that are not influenced by the combination hash below
#  eg. disble builds for C:OS:Master ->  'project != "Cloud:OpenStack:Master"'
my $combination_filter_static='project != "Cloud:OpenStack:Master"';


# this hash defines for which project which packages should be tracked via trackupstream
my %tu = (
  "OBS/Cloud:OpenStack:Master" => [ qw(
    openstack-ceilometer
    openstack-cinder
    openstack-dashboard
    openstack-glance
    openstack-heat
    openstack-heat-cfntools
    openstack-heat-templates
    openstack-keystone
    openstack-marconi
    openstack-nova
    openstack-quantum
    openstack-quickstart
    openstack-swift
    openstack-utils
    python-cinderclient
    python-ceilometerclient
    python-glanceclient
    python-heatclient
    python-keystoneclient
    python-marconiclient
    python-novaclient
    python-quantumclient
    python-swiftclient
    python-swift3
    python-oslo.config
    python-oslo.messaging
    python-oslo.sphinx
    python-oslo.version
  ) ],
  "OBS/Cloud:OpenStack:Grizzly:Staging" => [ qw(
    openstack-ceilometer
    openstack-cinder
    openstack-dashboard
    openstack-glance
    openstack-heat
    openstack-keystone
    openstack-nova
    openstack-quantum
    openstack-quickstart
    openstack-swift
    python-cinderclient
    python-ceilometerclient
    python-glanceclient
    python-heatclient
    python-keystoneclient
    python-novaclient
    python-quantumclient
    python-swiftclient
    python-oslo.config
  ) ],
  "IBS/Devel:Cloud:1.0:OpenStack" => [ qw(
    openstack-dashboard
    openstack-nova
    openstack-glance
    openstack-keystone
    openstack-melange
    openstack-quantum
    openstack-swift
    python-keystoneclient
    python-novaclient
    python-quantumclient
    python-melangeclient
    python-swiftclient
  ) ],
  "OBS/systemsmanagement:crowbar:2.0:staging" => [ qw(
    crowbar
    crowbar-barclamp-ceph
    crowbar-barclamp-chef
    crowbar-barclamp-crowbar
    crowbar-barclamp-database
    crowbar-barclamp-deployer
    crowbar-barclamp-dns
    crowbar-barclamp-ganglia
    crowbar-barclamp-glance
    crowbar-barclamp-ipmi
    crowbar-barclamp-keystone
    crowbar-barclamp-kong
    crowbar-barclamp-logging
    crowbar-barclamp-nagios
    crowbar-barclamp-network
    crowbar-barclamp-nova
    crowbar-barclamp-nova_dashboard
    crowbar-barclamp-ntp
    crowbar-barclamp-openstack
    crowbar-barclamp-provisioner
    crowbar-barclamp-swift
    crowbar-barclamp-test
 ) ],
 "IBS/Devel:Cloud:1.0:Crowbar" => [ qw(
    crowbar
    crowbar-barclamp-ceph
    crowbar-barclamp-crowbar
    crowbar-barclamp-database
    crowbar-barclamp-deployer
    crowbar-barclamp-dns
    crowbar-barclamp-ganglia
    crowbar-barclamp-glance
    crowbar-barclamp-ipmi
    crowbar-barclamp-keystone
    crowbar-barclamp-kong
    crowbar-barclamp-logging
    crowbar-barclamp-nagios
    crowbar-barclamp-network
    crowbar-barclamp-nova
    crowbar-barclamp-nova_dashboard
    crowbar-barclamp-ntp
    crowbar-barclamp-openstack
    crowbar-barclamp-provisioner
    crowbar-barclamp-swift
    crowbar-barclamp-test
 ) ]
);


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

sub xml_replace_elementlist($$$@)
{
  my ($node, $path, $element, @elmlist) = @_;
  die "Error: node, path, element or text undefined." unless ($node && $path && $element && @elmlist);
  my $nodeL = $node->find($path);
  my $onenode;
  $onenode = $nodeL->pop() if $nodeL->size() > 0;
  die "Error: Could not find an xml element with the statement $path, exiting." unless $onenode;
  $onenode->removeChildNodes();

  foreach my $val (sort @elmlist)
  {
    my $newnode = XML::LibXML::Element->new($element);
    $newnode->appendTextNode($val);
    $onenode->addChild($newnode);
  }
}

sub file_read_xml($)
{
  my $file = shift || die "Error: no input file to read the service xml data from.";
  open (my $FH, '<', $file) or die $!;
  binmode $FH;
  my $parser=XML::LibXML->new();
  my $xml = $parser->load_xml(
    IO => $FH,
    { no_blanks => 1 }
  );
  close $FH;
  return $xml;
}

sub file_write($$)
{
  my ($file, $data) = @_;
  open (my $FH, '>', $file) or die $!;
  binmode $FH;
  print $FH $data;
  close $FH;
}

sub combination_filter($)
{
  my $bs=shift || die "Error: no BS set";
  my @filter=();
  foreach my $p (keys %tu)
  {
    my $onerule='';
    next unless $p =~ /^$bs/;
    my $pp = $p;
    $pp =~ s#^.BS/##;
    $onerule .= " ( project==\"$pp\" && [ ";
    foreach my $c (@{$tu{$p}})
    {
      $onerule .= "\"$c\", ";
    }
    $onerule .= " ].contains(component) )";

    push @filter, $onerule;
  }
  return join(" && ", ($combination_filter_static, @filter));
}

sub project_list($)
{
  my $bs=shift || die "Error: no BS set";
  my @projects=();
  foreach my $p (keys %tu)
  {
    next unless $p =~ /^$bs/;
    my $pp = $p;
    $pp =~ s#^.BS/##;
    push @projects, $pp;
  }
  return sort keys %{{ map { $_ => 1 } @projects }};
}

sub component_list($)
{
  my $bs=shift || die "Error: no BS set";
  my @components=();
  foreach my $p (keys %tu)
  {
    next unless $p =~ /^$bs/;
    push @components, @{$tu{$p}};
  }
  return sort keys %{{ map { $_ => 1 } @components }};
}

sub adaptmatrix_jobfile($$)
{
  my $bs=shift || die "Error: no BS set";
  my $tufile=shift || die "Error: no trackupstream file set";
  die "Error: trackupstream file '$tufile' does not exist" if (! -e $tufile);

  my $xmldom=file_read_xml($tufile);
  # replace combination filter
  xml_replace_text($xmldom, "/matrix-project[1]/combinationFilter[1]", combination_filter($bs));
  # replace component axis
  xml_replace_elementlist($xmldom, "/matrix-project[1]/axes[1]/*/name[.='component']/following-sibling::values[1]", "string", component_list($bs));
  # replace project axis
  xml_replace_elementlist($xmldom, "/matrix-project[1]/axes[1]/*/name[.='project']/following-sibling::values[1]",   "string", project_list($bs)  );

  #local $XML::LibXML::skipXMLDeclaration=1;
  file_write($tufile, $xmldom->toString(1));
}

sub usage()
{
  return "Usage:
  $0 <OBS|IBS> <command>
  commands
    filter:    creates the combination filter (as not all combinations of the matrix are allowed
    project:   creates the list of values for the Matrix Axis 'project'
    component: creates the list of values for the Matrix Axis 'component'
    adaptmatrix <jobfile>: changes the axis values and the filter of the trackupstream job in <jobfile>
";
}

### MAIN ###

my $BS=shift || die usage();
my $cmd=shift || die usage();

if ($cmd eq 'filter') {
  print combination_filter($BS);
} elsif ($cmd eq 'project') {
  print join("\n", project_list($BS));
} elsif ($cmd eq 'component') {
  print join("\n", component_list($BS));
} elsif ($cmd eq 'adaptmatrix') {
  my $jobfile=shift || die usage();
  adaptmatrix_jobfile($BS, $jobfile);
} else {
  die usage();
}

