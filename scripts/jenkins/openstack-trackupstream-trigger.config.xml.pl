#!/usr/bin/perl -w
#
# This tool creates a new Jenkins config file for the openstack-trackupstream-trigger job.
#
# Adapt the %tutrigger hash at the top and then run:
#  ./openstack-trackupstream-trigger.config.xml.pl > config.xml
# This file can be uploaded to river.suse.de with this command:
#  curl -X POST --data-binary @config.xml  http://river.suse.de/job/openstack-trackupstream-trigger/config.xml
#

my %tutrigger = (
  Head => [ qw(
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
  Crowbar => [ qw(
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


foreach my $subp (keys %tutrigger)
{
  open (my $FH, '>', "$subp.config.xml") or die $@;
  select $FH;

print
q{<?xml version='1.0' encoding='UTF-8'?>
<project>
  <actions/>
  <description>This is the meta job that triggers the openstack-trackupstream job multiple times with different parameters.&lt;br /&gt;&#xd;
&lt;b&gt;Add new packages as new triggers to THIS job (see config and scroll down).&lt;/b&gt;</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.scm.NullSCM"/>
  <assignedNode>openstack-trackupstream</assignedNode>
  <canRoam>false</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers class="vector">
    <hudson.triggers.TimerTrigger>
      <spec></spec>
    </hudson.triggers.TimerTrigger>
  </triggers>
  <concurrentBuild>false</concurrentBuild>
  <builders/>
  <publishers>
    <hudson.plugins.parameterizedtrigger.BuildTrigger>
      <configs>
};

  foreach my $pack (@{$tutrigger{$subp}})
  {
    print
qq~
        <hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
          <configs>
            <hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
              <properties>COMPONENT=$pack
SUBPROJECT=$subp
</properties>
            </hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
          </configs>
          <projects>openstack-trackupstream, </projects>
          <condition>ALWAYS</condition>
          <triggerWithNoParameters>false</triggerWithNoParameters>
        </hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
~;
  }


print
q{
      </configs>
    </hudson.plugins.parameterizedtrigger.BuildTrigger>
  </publishers>
  <buildWrappers/>
</project>
};

select STDOUT;
close $FH;

}

print "\nConfigs created locally\n";
print "Please update the jenkins config by running these commands:\n";

foreach my $subp (keys %tutrigger)
{
  my $jobname=lc($subp);
  $jobname="openstack" if ($jobname eq 'head');
  print '# curl -X POST --data-binary @'."$subp.config.xml http://river.suse.de/job/cloud-trackupstream-$jobname-trigger/config.xml\n";
}
