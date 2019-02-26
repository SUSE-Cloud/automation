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

echo "test: search non existing job"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleannothing,Juno,12 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid returncode"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleanvm,Juno,13 a
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "test: invalid ci type"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci foobar --matrix openstack-cleanvm,Juno 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

echo "set (OpenStack) openstack-cleanvm to success"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci opensuse --matrix openstack-cleanvm,Cloud:OpenStack:Juno,14 0
echo "returncode: $?"
read -p "Press any key to continue... " -n1 -s
echo ""

BUILDNR=$(( ( RANDOM % 10000 )  + 1 ))
echo "Buildnr is ${BUILDNR}"
echo "Start new matrix run"
echo "cloud-trackupstream (${BUILDNR}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-trackupstream,Devel:Cloud:7:Staging,${BUILDNR} 0
echo "returncode: $?"

echo "cloud-trackupstream (${BUILDNR}) run failed"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-trackupstream,Devel:Cloud:7:Staging,${BUILDNR} 1
echo "returncode: $?"

echo "cloud-trackupstream (${BUILDNR}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-trackupstream,Devel:Cloud:7:Staging,${BUILDNR} 0
echo "returncode: $?"

echo ""
echo "State should be failed"
read -p "Press any key to continue... " -n1 -s
echo ""

BUILDNR_NEXT=$(( BUILDNR + 1 ))
echo "Buildnr is now ${BUILDNR_NEXT}"
echo "Start new matrix run to with already set buildnr"
echo "cloud-trackupstream (${BUILDNR_NEXT}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-trackupstream,Devel:Cloud:7:Staging,${BUILDNR_NEXT} 0
echo "returncode: $?"

echo ""
echo "State should be successful and Buildnr should change from ${BUILDNR} to ${BUILDNR_NEXT}"
read -p "Press any key to continue... " -n1 -s
echo ""

BUILDNR=$(( ( RANDOM % 10000 )  + 1 ))
echo "Buildnr is ${BUILDNR}"
echo "Start new matrix run"
echo "cloud-mediacheck (${BUILDNR}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-mediacheck,Devel:Cloud:7/SLE_12_SP1,${BUILDNR} 0
echo "returncode: $?"

echo "cloud-mediacheck (${BUILDNR}) run failed"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-mediacheck,Devel:Cloud:7/SLE_12_SP1,${BUILDNR} 1
echo "returncode: $?"

echo "cloud-mediacheck (${BUILDNR}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-mediacheck,Devel:Cloud:7/SLE_12_SP1,${BUILDNR} 0
echo "returncode: $?"

echo ""
echo "State should be failed"
read -p "Press any key to continue... " -n1 -s
echo ""

BUILDNR_NEXT=$(( BUILDNR + 1 ))
echo "Buildnr is now ${BUILDNR_NEXT}"
echo "Start new matrix run to with already set buildnr"
echo "cloud-mediacheck (${BUILDNR_NEXT}) run successful"
${RUBY} jtsync.rb --board ${TEST_BOARD} --ci suse --matrix cloud-mediacheck,Devel:Cloud:7/SLE_12_SP1,${BUILDNR_NEXT} 0
echo "returncode: $?"

echo ""
echo "State should be successful and Buildnr should change from ${BUILDNR} to ${BUILDNR_NEXT}"
read -p "Press any key to continue... " -n1 -s
echo ""
