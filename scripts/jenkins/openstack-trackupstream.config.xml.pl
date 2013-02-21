#!/usr/bin/perl -w
#
# This tool creates a new Jenkins config file for the openstack-trackupstream-trigger job.
#
# Adapt the %tutrigger hash at the top and then run:
#  ./openstack-trackupstream-trigger.config.xml.pl > config.xml
# This file can be uploaded to river.suse.de with this command:
#  curl -X POST --data-binary @config.xml  http://river.suse.de/job/openstack-trackupstream-trigger/config.xml
#

my $upload = ($ARGV[0] =~ /^upload$/) ? 1:0;
my @output_edit = ();
my @output_create = ();

my %tutrigger = (
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
    python-oslo-config
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


foreach my $project (keys %tutrigger)
{
  my $jobname = "trackupstream-".$project;
  $jobname =~ s/[:\/]/-/g;
  open (my $FH, '>', "$jobname.config.xml") or die $@;
  select $FH;

print
q{<?xml version='1.0' encoding='UTF-8'?>
<project>
  <actions/>
  <description>This is the meta job that triggers the openstack-trackupstream job multiple times with different parameters.&lt;br /&gt;&#xd;
&lt;b&gt;Changes to this job ONLY via the &lt;i&gt;openstack-trackupstream.config.xml.pl&lt;/i&gt; tool from the https://github.com/SUSE-Cloud/automation repo.&lt;/b&gt;</description>
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

  foreach my $pack (@{$tutrigger{$project}})
  {
    print
qq~
        <hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
          <configs>
            <hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
              <properties>COMPONENT=$pack
PROJECTSOURCE=$project
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

    my $updatestr = 'curl -X POST --data-binary @'."$jobname.config.xml http://river.suse.de/job/cloud-$jobname-trigger/config.xml";
    my $createstr = 'curl -H "Content-Type: text/xml" -X POST --data-binary @'."$jobname.config.xml http://river.suse.de/createItem?name=cloud-$jobname-trigger";
    if ($upload)
    {
      print "Updating $jobname...";
      if (system("$updatestr -s | grep -iq error") == 0)
      {
        print "Error on updating. Now trying to create job\n";
        print "Creating $jobname...";
        if (system("$createstr -s | grep -iq error") == 0)
        {
          print "Error - Could not update or create job: $jobname\n";
        } else {
          print "done\n";
        }
      } else {
        print "done\n";
      }
      system("rm -f $jobname.config.xml");
    } else {
      push @output_edit, $updatestr;
      push @output_create, $createstr;
    }
}

if (! $upload)
{
  print "\nConfigs created locally\n";
  print "Please update the jenkins config by running these commands:\n";

  print "_Update_ the jobs with these commands:\n";
  print join("\n", @output_edit)."\n";
  print "----------------------\n";
  print "_Create_ the jobs with these commands:\n";
  print join("\n", @output_create)."\n";
}
