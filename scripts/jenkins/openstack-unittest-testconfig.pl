#!/usr/bin/perl -w
#
# This is the collection of the commands to run the unittests
# This file is placed on the worker nodes via update_automation and is thus automatically updated on each testrun.


my $uttrigger = {
  Master => {
    functest   => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=remakerings &amp;&amp; swift-init main start\n".
                                         "TESTCMD=./.functests\n".
                                         "TEARDOWNCMD=swift-init main stop",
                    'openstack-heat'  => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=./run_tests.sh -P -f"
    },
    probetests => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=remakerings &amp;&amp; swift-init main start\n".
                                         "TESTCMD=./.probetests\n".
                                         "TEARDOWNCMD=swift-init main stop"
    },
    unittest   => {
        'openstack-ceilometer'        => "COMPONENT=openstack-ceilometer\n".
                                         "SETUPCMD=rcmongodb start\n".
                                         "TESTCMD=nosetests\n".
                                         "TEARDOWNCMD=rcmongodb stop",
        'openstack-cinder'            => "COMPONENT=openstack-cinder",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard\n".
                                         "TESTCMD=./run_tests.sh -N",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=./run_tests.sh -P -u",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=./run_tests.sh -N -P -xintegration",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n".
                                         "TESTCMD=nosetests",
        'python-heatclient'           => "COMPONENT=python-heatclient\n".
                                         "TESTCMD=nosetests",
        'python-keystoneclient'       => "COMPONENT=python-keystoneclient",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n".
                                         "TESTCMD=nosetests",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n".
                                         "TESTCMD=nosetests",
        'python-oslo-config'          => "COMPONENT=python-oslo-config\n".
                                         "TESTCMD=nosetests",
    }
  },
  Folsom => {
    functest   => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=remakerings &amp;&amp; swift-init main start\n".
                                         "TESTCMD=./.functests\n".
                                         "TEARDOWNCMD=swift-init main stop"
    },
    probetests => { 'openstack-swift' => "COMPONENT=openstack-swift\n".
                                         "SETUPCMD=remakerings &amp;&amp; swift-init main start\n".
                                         "TESTCMD=./.probetests\n".
                                         "TEARDOWNCMD=swift-init main stop"
    },
    unittest   => {
        'openstack-cinder'            => "COMPONENT=openstack-cinder",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
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
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n".
                                         "TESTCMD=nosetests",
    }
  }
};


my $distribution = shift;
my $package = shift;

unless ($distribution && $package) { die "Usage: $0 <distribution> <package>"; }
my ($dist) = $distribution =~ /^(\w+)-?.*/;
die "Error: no or wrong value for distribution" unless $dist;

my $testcmd = $uttrigger->{"\u\L$dist"}->{unittest}->{$package};
die "Error: package does not exist" unless defined $testcmd;
print $testcmd."\n";

