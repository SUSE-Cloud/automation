#!/usr/bin/env bash

TEST_BOARD="fL7fv67z"
RUBY=$(which ruby)

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed (no notification)"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to success"
${RUBY} jtsync.rb  --board ${TEST_BOARD} --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (cloud) to success"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix crowbar-trackupstream,Devel:Cloud:7:Staging 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (cloud) to failed"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix crowbar-trackupstream,Devel:Cloud:7:Staging 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (openstack)"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleanvm,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: search non existing job"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleannothing,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid returncode"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleanvm,Juno a
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid ci type"
${RUBY} ./jtsync.rb --board ${TEST_BOARD}--ci foobar --matrix openstack-cleanvm,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""
