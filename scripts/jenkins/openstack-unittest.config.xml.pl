#!/usr/bin/perl -w
#
# This tool creates a new Jenkins config file for the openstack-unittests trigger jobs.
#
#
my $subproject="Master";
my $obsproject="Cloud:OpenStack:$subproject";
my $projectsource="PROJECTSOURCE=OBS/$obsproject";

my $uttrigger = {
    functest   => { 'openstack-swift' =>
'COMPONENT=openstack-swift
SETUPCMD=swift-init main start
TESTCMD=./.functests
TEARDOWNCMD=swift-init main stop'
    },
    probetests => { 'openstack-swift' =>
'COMPONENT=openstack-swift
SETUPCMD=swift-init all start
TESTCMD=./probetests
TEARDOWNCMD=swift-init all stop'
    },
    unittest   => {
        'openstack-ceilometer'        =>
'COMPONENT=openstack-ceilometer
TESTCMD=./run_tests.sh -N',
        'openstack-cinder'            => 'COMPONENT=openstack-cinder',
        'openstack-cinderclient'      => 'COMPONENT=python-cinderclient',
        'openstack-dashboard'         => 'COMPONENT=openstack-dashboard',
        'openstack-glance'            =>
'COMPONENT=openstack-glance
TESTCMD=./run_tests.sh -N',
        'openstack-keystone'          =>
'COMPONENT=openstack-keystone',
        'openstack-nova'              => 'COMPONENT=openstack-nova',
        'openstack-quantum'           => 'COMPONENT=openstack-quantum',
        'openstack-swift'             =>
'COMPONENT=openstack-swift
SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf
TESTCMD=./.unittests',
        'python-glanceclient'         => 'COMPONENT=python-glanceclient',
        'python-heatclient'           => 'COMPONENT=python-heatclient',
        'python-keystoneclient'       => 'COMPONENT=python-keystoneclient',
        'python-novaclient'           => 'COMPONENT=python-novaclient',
        'python-quantumclient'        =>
'COMPONENT=python-quantumclient
TESTCMD=nosetests',
        'python-swiftclient'          => 'COMPONENT=python-swiftclient'
    }
};
my @output = ();
my @output_create = ();

my $apicheckcgi= "http://clouddata.cloud.suse.de/cgi-bin/apicheck";
my $obsapi = "api.opensuse.org";
my $apicheck="$apicheckcgi/$obsapi/build/$obsproject/SLE_11_SP2/x86_64";

foreach my $testtype (keys %{$uttrigger})
{
  foreach my $package (keys $uttrigger->{$testtype})
  {
      my $jobname = "$testtype-$package-$subproject";
      my $jobenv = $uttrigger->{$testtype}->{$package}."\n$projectsource";
      open (my $FH, '>', "$jobname.config.xml") or die $@;
      select $FH;

print qq{<?xml version='1.0' encoding='UTF-8'?>
<project>
  <actions/>
  <description>Starts some services and triggers the cloud-$jobname
&lt;br /&gt;&#xd;
&lt;b&gt;Changes to this job ONLY via the &lt;i&gt;openstack-unittest.config.xml.pl&lt;/i&gt; tool from the automation repo.&lt;/b&gt;
</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class="hudson.scm.NullSCM"/>
  <assignedNode>openstack-unittest</assignedNode>
  <canRoam>false</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers class="vector">
    <org.jenkinsci.plugins.urltrigger.URLTrigger>
      <spec>*/10 * * * *</spec>
      <entries>
        <org.jenkinsci.plugins.urltrigger.URLTriggerEntry>
          <url>$apicheck/$package</url>
          <proxyActivated>false</proxyActivated>
          <checkStatus>false</checkStatus>
          <statusCode>200</statusCode>
          <checkLastModificationDate>false</checkLastModificationDate>
          <inspectingContent>true</inspectingContent>
          <contentTypes>
            <org.jenkinsci.plugins.urltrigger.content.SimpleContentType/>
          </contentTypes>
        </org.jenkinsci.plugins.urltrigger.URLTriggerEntry>
      </entries>
      <labelRestriction>false</labelRestriction>
    </org.jenkinsci.plugins.urltrigger.URLTrigger>
  </triggers>
  <concurrentBuild>false</concurrentBuild>
  <builders/>
  <publishers>
    <hudson.plugins.parameterizedtrigger.BuildTrigger>
      <configs>
        <hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
          <configs>
            <hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
              <properties>$jobenv</properties>
            </hudson.plugins.parameterizedtrigger.PredefinedBuildParameters>
          </configs>
          <projects>openstack-unittest, </projects>
          <condition>SUCCESS</condition>
          <triggerWithNoParameters>false</triggerWithNoParameters>
        </hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
      </configs>
    </hudson.plugins.parameterizedtrigger.BuildTrigger>
  </publishers>
  <buildWrappers/>
</project>

};

    select STDOUT;
    close $FH;

    push @output, 'curl -X POST --data-binary @'."$jobname.config.xml http://river.suse.de/job/cloud-$jobname-trigger/config.xml";
    push @output_create, 'curl -H "Content-Type: text/xml" -X POST --data-binary @'."$jobname.config.xml http://river.suse.de/createItem?name=cloud-$jobname-trigger";

  }
}

print "\nConfigs created locally\n";
print "Please update the jenkins config by running these commands:\n";

print "_Update_ the jobs with these commands:\n";
print join("\n", @output)."\n";
print "----------------------\n";
print "_Create_ the jobs with these commands:\n";
print join("\n", @output_create)."\n";
