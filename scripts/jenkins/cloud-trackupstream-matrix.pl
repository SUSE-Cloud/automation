#!/usr/bin/perl -w
#
# This tool creates parts for the Jenkins config file for the cloud-trackupstream job.
# The matrix configuration is computed using the rules in the following big hash.
#

# this hash defines for which project which packages should be tracked via trackupstream
my %tu = (
  "OBS/Cloud:OpenStack:Master" => [ qw(
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
    python-glanceclient
    python-heatclient
    python-keystoneclient
    python-novaclient
    python-quantumclient
    python-swiftclient
    python-oslo.config
  ) ],
  "OBS/Cloud:OpenStack:Folsom:Staging" => [ qw(
    openstack-cinder
    openstack-dashboard
    openstack-glance
    openstack-keystone
    openstack-nova
    openstack-quantum
    openstack-quickstart
    openstack-swift
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
  print join(" && ", @filter);
}

sub project_list($)
{
  my $bs=shift || die "Error: no BS set";
  foreach my $p (keys %tu)
  {
    next unless $p =~ /^$bs/;
    my $pp = $p;
    $pp =~ s#^.BS/##;
    print $pp."\n";
  }
}

sub component_list($)
{
  my $bs=shift || die "Error: no BS set";
  foreach my $p (keys %tu)
  {
    next unless $p =~ /^$bs/;
    print join("\n", @{$tu{$p}} );
  }
}

sub usage()
{
  return "Usage:
  $0 <OBS|IBS> <command>
  commands
    filter:    creates the combination filter (as not all combinations of the matrix are allowed
    project:   creates the list of values for the Matrix Axis 'project'
    component: creates the list of values for the Matrix Axis 'component'
";
}

### MAIN ###

my $BS=shift || die usage();
my $cmd=shift || die usage();

if ($cmd eq 'filter') {
  combination_filter($BS);
} elsif ($cmd eq 'project') {
  project_list($BS);
} elsif ($cmd eq 'component') {
  component_list($BS);
}

