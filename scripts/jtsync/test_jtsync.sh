#!/usr/bin/env bash

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed"
bundle exec jtsync.rb --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to failed (no notification)"
bundle exec jtsync.rb --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "set (Cloud 7) cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 to success"
bundle exec jtsync.rb --ci suse --job cloud-mkcloud7-job-4nodes-linuxbridge-x86-64 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (cloud) to success"
bundle exec jtsync.rb --ci suse --matrix crowbar-trackupstream,Devel:Cloud:7:Staging 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (cloud) to failed"
bundle exec jtsync.rb --ci suse --matrix crowbar-trackupstream,Devel:Cloud:7:Staging 1
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: matrix job (openstack)"
bundle exec jtsync.rb --ci opensuse --matrix openstack-cleanvm,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: search non existing job"
bundle exec jtsync.rb --ci opensuse --matrix openstack-cleannothing,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid returncode"
bundle exec jtsync.rb --ci opensuse --matrix openstack-cleanvm,Juno a
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid ci type"
bundle exec jtsync.rb --ci foobar --matrix openstack-cleanvm,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""
