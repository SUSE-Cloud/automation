#!/usr/bin/perl -w
#
# This tool creates a new Jenkins config file for the openstack-trackupstream-trigger job.
#
# Adapt the %tutrigger hash at the top and then run:
#  ./openstack-trackupstream-trigger.config.xml.pl > config.xml
# This file can be uploaded to river.suse.de with this command:
#  curl -X POST -d@config.xml  http://river.suse.de/job/openstack-trackupstream-trigger/config.xml
#
# Note: Due to a bug in Jenkins (bug: JENKINS-7501 https://issues.jenkins-ci.org/browse/JENKINS-7501)
#       we currently use a temporarily adapted format for the COMPONENT variable. See below for details.
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
      <spec>0 0 * * *</spec>
    </hudson.triggers.TimerTrigger>
  </triggers>
  <concurrentBuild>false</concurrentBuild>
  <builders/>
  <publishers>
    <hudson.plugins.parameterizedtrigger.BuildTrigger>
      <configs>
};

foreach my $subp (keys %tutrigger)
{
  foreach my $pack (@{$tutrigger{$subp}})
  {
    print
qq~
        <hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
          <configs>
            <hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
              <properties>COMPONENT=$subp+$pack</properties>
            </hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
          </configs>
          <projects>openstack-trackupstream, </projects>
          <condition>ALWAYS</condition>
          <triggerWithNoParameters>false</triggerWithNoParameters>
        </hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
~;
  }
}

#
# Due to a bug in Jenkins (bug: JENKINS-7501 https://issues.jenkins-ci.org/browse/JENKINS-7501)
#  we use a temporarily adapted format for the COMPONENT variable.
# Now we use:
#  COMPONENT=<subproject>+<package>
#
# Later it will be:
#  COMPONENT=<package>
#  SUBPROJECT=<subproject>
#


print
q{
      </configs>
    </hudson.plugins.parameterizedtrigger.BuildTrigger>
  </publishers>
  <buildWrappers/>
</project>
}
