#!/usr/bin/perl -w
#
# This tool creates a new Jenkins config file for the openstack-unittests trigger jobs.
# With the first prarameter being set to "upload" all jobs will be updated/created
#

my $upload = ($ARGV[0] =~ /^upload$/) ? 1:0;

my $uttrigger = {
  Master => {
    functest   => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=swift-init main start\n".
                                         "TESTCMD=./.functests\n".
                                         "TEARDOWNCMD=swift-init main stop"
    },
    probetests => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=swift-init all start\n".
                                         "TESTCMD=./.probetests\n".
                                         "TEARDOWNCMD=swift-init all stop"
    },
    unittest   => {
        'openstack-ceilometer'        => "COMPONENT=openstack-ceilometer\n".
                                         "TESTCMD=./run_tests.sh -N",
        'openstack-cinder'            => "COMPONENT=openstack-cinder",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat",
        'openstack-keystone'          => "COMPONENT=openstack-keystone",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n".
                                         "TESTCMD=nosetests",
        'python-heatclient'           => "COMPONENT=python-heatclient",
        'python-keystoneclient'       => "COMPONENT=python-keystoneclient",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n".
                                         "TESTCMD=nosetests",
        'python-swiftclient'          => "COMPONENT=python-swiftclient"
    }
  },
  Folsom => {}
};

# only keep the following line while the jobs are not differing
$uttrigger->{Folsom}=$uttrigger->{Master};

my @output = ();
my @output_create = ();

my $apicheckcgi= "http://clouddata.cloud.suse.de/cgi-bin/apicheck";
my $obsapi = "api.opensuse.org";


foreach my $subproject (keys %{$uttrigger})
{
  my $obsproject="Cloud:OpenStack:$subproject";
  my $projectsource="PROJECTSOURCE=OBS/$obsproject";
  my $apicheck="$apicheckcgi/$obsapi/build/$obsproject/SLE_11_SP2/x86_64";

  foreach my $testtype (keys $uttrigger->{$subproject})
  {
    foreach my $package (keys $uttrigger->{$subproject}->{$testtype})
    {
      my $jobdisabled='false';
      if ($testtype =~ /^functest$/) # functests are disabled for now by default
      {
        $jobdisabled='true';
      }

      my $jobname = "$testtype-$package-$subproject";
      my $jobenv = $uttrigger->{$subproject}->{$testtype}->{$package}."\n$projectsource";
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
  <disabled>$jobdisabled</disabled>
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
        push @output_update, $updatestr;
        push @output_create, $createstr;
      }
    } # end foreach package
  } # end foreach testtype
} # end foreach subproject

if (! $upload)
{
  print "\nConfigs created locally\n";
  print "Please update the jenkins config by running these commands:\n";

  print "_Update_ the jobs with these commands:\n";
  print join("\n", @output_update)."\n";
  print "----------------------\n";
  print "_Create_ the jobs with these commands:\n";
  print join("\n", @output_create)."\n";
}
