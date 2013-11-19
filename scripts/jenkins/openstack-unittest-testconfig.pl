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
                                         "TESTCMD=python setup.py testr --slowest --testr-args=\"--concurrency=1\"\n",
        'openstack-cinder'            => "COMPONENT=openstack-cinder\n",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard\n".
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-designate'         => "COMPONENT=openstack-designate\n".
                                         "TESTCMD=nosetests -v",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=python setup.py testr --slowest",
        'openstack-ironic'            => "COMPONENT=openstack-ironic\n" .
                                         "TESTCMD=python setup.py testr\n",
        'openstack-trove'             => "COMPONENT=openstack-trove\n" .
                                         "TESTCMD=python setup.py testr\n",
        'openstack-tuskar'            => "COMPONENT=openstack-tuskar\n" .
                                         "TESTCMD=python setup.py testr",
        'openstack-heat-cfntools'     => "COMPONENT=openstack-heat-cfntools\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=python setup.py testr",
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
                                         "TESTCMD=python setup.py testr --slowest",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'python-ironicclient'         => "COMPONENT=python-ironicclient\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-marconiclient'        => "COMPONENT=python-marconiclient\n" .
                                         "TESTCMD=nosetests -v",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-neutronclient'        => "COMPONENT=python-neutronclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-troveclient'          => "COMPONENT=python-troveclient\n" .
                                         "TESTCMD=python setup.py testr\n",
        'python-tuskarclient'         => "COMPONENT=python-tuskarclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-openstackclient'      => "COMPONENT=python-openstackclient\n" .
                                         "TESTCMD=python setup.py testr\n",
        'python-oslo.messaging'          => "COMPONENT=python-oslo.messaging\n" .
                                         "TESTCMD=python setup.py testr --slowest\n",
        'python-oslo.version'         => "COMPONENT=python-oslo.version\n" .
                                         "TESTCMD=python setup.py testr --slowest\n",
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
        'openstack-heat-cfntools'     => "COMPONENT=openstack-heat-cfntools\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=./run_tests.sh -N -P -xintegration",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient".
                                         "TESTCMD=python setup.py testr",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient".
                                         "TESTCMD=nosetests",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n".
                                         "TESTCMD=python setup.py testr",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=nosetests",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TESTCMD=nosetests\n".
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-novaclient'           => "COMPONENT=python-novaclient".
                                         "TESTCMD=python setup.py testr",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n".
                                         "TESTCMD=python setup.py testr",
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
                                         "TESTCMD=python setup.py testr --slowest --testr-args=\"--concurrency=1\"\n",
        'openstack-cinder'            => "COMPONENT=openstack-cinder\n",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard\n".
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=python setup.py testr --slowest",
        'openstack-heat-cfntools'     => "COMPONENT=openstack-heat-cfntools\n" .
                                         "TESTCMD=python setup.py testr --slowest",
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
                                         "TESTCMD=python setup.py testr",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-neutronclient'        => "COMPONENT=python-neutronclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-openstackclient'      => "COMPONENT=python-openstackclient\n" .
                                         "TESTCMD=python setup.py testr\n",
    }
  },
};


my $distribution = shift;
my $testtype = shift;
my $package = shift;

unless ($distribution && $package && $testtype) { die "Usage: $0 <distribution> <testtype> <package>"; }
my $testcmd = $uttrigger->{$distribution}->{$testtype}->{$package};
die "Error: package does not exist" unless defined $testcmd;
$testcmd =~ s/^(\w+)=(.*)/$1="$2"/mg;
print $testcmd."\n";
