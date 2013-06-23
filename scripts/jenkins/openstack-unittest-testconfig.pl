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
                                         "TESTCMD=./run_tests.sh -N",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-heat'              => "COMPONENT=openstack-heat\n".
                                         "TESTCMD=./run_tests.sh -u",
        'openstack-heat-cfntools'     => "COMPONENT=openstack-heat-cfntools\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'openstack-keystone'          => "COMPONENT=openstack-keystone\n".
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-nova'              => "COMPONENT=openstack-nova",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=python setup.py testr --slowest",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n",
        'python-oslo.config'          => "COMPONENT=python-oslo.config\n" .
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
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-ceilometerclient'     => "COMPONENT=python-ceilometerclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n",
        'python-heatclient'           => "COMPONENT=python-heatclient\n" .
                                         "TESTCMD=nosetests",
        'python-keystoneclient'       => "SETUPCMD=rcmemcached start\n" .
                                         "COMPONENT=python-keystoneclient\n" .
                                         "TEARDOWNCMD=rcmemcached stop\n",
        'python-novaclient'           => "COMPONENT=python-novaclient",
        'python-quantumclient'        => "COMPONENT=python-quantumclient\n" .
                                         "TESTCMD=python setup.py testr",
        'python-swiftclient'          => "COMPONENT=python-swiftclient\n",
        'python-oslo.config'          => "COMPONENT=python-oslo.config\n" .
                                         "TESTCMD=nosetests --with-doctest --exclude-dir=tests/testmods\n",
    }
  },
 
  "Cloud:OpenStack:Folsom:Staging" => {
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
        'openstack-cinder'            => "COMPONENT=openstack-cinder\n" .
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-dashboard'         => "COMPONENT=openstack-dashboard" .
                                         "TESTCMD=./run_tests.sh -N",
        'openstack-glance'            => "COMPONENT=openstack-glance\n".
                                         "TESTCMD=./run_tests.sh -N glance",
        'openstack-keystone'          => "COMPONENT=openstack-keystone",
        'openstack-nova'              => "COMPONENT=openstack-nova" .
                                         "TESTCMD=./run_tests.sh -N -P",
        'openstack-quantum'           => "COMPONENT=openstack-quantum",
        'openstack-swift'             => "COMPONENT=openstack-swift\n".
                                         "SWIFT_TEST_CONFIG_FILE=/etc/swift/func_test.conf\n".
                                         "TESTCMD=./.unittests",
        'python-cinderclient'         => "COMPONENT=python-cinderclient",
        'python-glanceclient'         => "COMPONENT=python-glanceclient\n".
                                         "TESTCMD=nosetests",
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
my $testtype = shift;
my $package = shift;

unless ($distribution && $package && $testtype) { die "Usage: $0 <distribution> <testtype> <package>"; }
my $testcmd = $uttrigger->{$distribution}->{$testtype}->{$package};
die "Error: package does not exist" unless defined $testcmd;
$testcmd =~ s/^(\w+)=(.*)/$1="$2"/mg;
print $testcmd."\n";
