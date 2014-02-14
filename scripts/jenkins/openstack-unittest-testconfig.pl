#!/usr/bin/perl -w
#
# This is the collection of the commands to run the unittests
# This file is placed on the worker nodes via update_automation and is thus automatically updated on each testrun.


my $uttrigger = {
  "Cloud:OpenStack:Master" => {
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
                                         "TESTCMD=testr init && testr run --parallel --testr-args=\"--concurrency=1\"\n",
        'openstack-cinder'            => "COMPONENT=openstack-cinder\n",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard\n".
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-designate'         => "COMPONENT=openstack-designate\n".
                                         "TESTCMD=nosetests -v",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'openstack-ironic'            => "COMPONENT=openstack-ironic\n" .
                                         "TESTCMD=testr init && testr run --parallel\n",
        'openstack-trove'             => "COMPONENT=openstack-trove\n" .
                                         "TESTCMD=testr init && testr run --parallel\n",
        'openstack-tuskar'            => "COMPONENT=openstack-tuskar\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'openstack-marconi'           => "COMPONENT=openstack-marconi\n" .
                                         "TESTCMD=nosetests -v",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-neutron'           => "COMPONENT=openstack-neutron",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient",
        'python-designateclient'      => "COMPONENT=python-designateclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-ironicclient'         => "COMPONENT=python-ironicclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop",
        'python-marconiclient'        => "COMPONENT=python-marconiclient\n" .
                                         "TESTCMD=nosetests -v",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-neutronclient'        => "COMPONENT=python-neutronclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-troveclient'          => "COMPONENT=python-troveclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-tuskarclient'         => "COMPONENT=python-tuskarclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-openstackclient'      => "COMPONENT=python-openstackclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-oslo.messaging'       => "COMPONENT=python-oslo.messaging\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-oslo.version'         => "COMPONENT=python-oslo.version\n" .
                                         "TESTCMD=testr init && testr run --parallel",
    }
  },
  "Cloud:OpenStack:Grizzly:Staging" => {
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
                                         "TESTCMD=nosetests -v\n" .
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
        'python-cinderclient'         => "COMPONENT=python-cinderclient\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient\n".
                                         "TESTCMD=nosetests",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=nosetests",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TESTCMD=nosetests\n".
                                         "TEARDOWNCMD=rcmemcached stop",
        'python-novaclient'           => "COMPONENT=python-novaclient\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n".
                                         "TESTCMD=testr init && testr run --parallel",
    }
  },
  "Cloud:OpenStack:Havana:Staging" => {
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
                                         "TESTCMD=testr init && testr run --parallel --testr-args=\"--concurrency=1\"",
        'openstack-cinder'            => "COMPONENT=openstack-cinder",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard\n".
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=testr init && testr run --parallel",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=nosetests",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-neutron'           => "COMPONENT=openstack-neutron",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-neutronclient'        => "COMPONENT=python-neutronclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
        'python-openstackclient'      => "COMPONENT=python-openstackclient\n" .
                                         "TESTCMD=testr init && testr run --parallel",
    }
  },
};


my $distribution = shift;
my $testtype = shift;
my $package = shift;

unless ($distribution && $package && $testtype) { die "Usage: $0 <distribution> <testtype> <package>"; }
my $testcmd = $uttrigger->{$distribution}->{$testtype}->{$package};
unless (defined $testcmd)
{
  print "exit 1";
  die "Error: package does not exist"
}
$testcmd =~ s/^(\w+)=(.*)/$1="$2"/mg;
print $testcmd."\n";
