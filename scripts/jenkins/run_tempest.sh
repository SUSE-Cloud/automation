#!/bin/bash

# EXIT STATUS: =0 ok, >0 number of errors&failures, <0 error in this script

function tempest()
{
  echo "Installing git-core, Python unittest2 and nose..."
  zypper addrepo http://download.opensuse.org/repositories/devel:/tools:/scm/SLE_11_SP2/devel:tools:scm.repo
  zypper addrepo http://download.opensuse.org/repositories/Cloud:/OpenStack:/Grizzly/SLE_11_SP3/Cloud:OpenStack:Grizzly.repo
  #zypper addrepo http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/SLE_11_SP3/Cloud:OpenStack:Master.repo
  zypper -n --gpg-auto-import-keys install python-unittest2 python-nose python-testtools python-testresources git-core

  if [ "$?" -ne 0 ]; then
    exit -1
  fi

  echo "Cloning the Tempest (grizzly) directory..."
  if [ -e tempest ] ; then
    cd tempest
    git pull
  else
    git clone -b stable/grizzly git://github.com/openstack/tempest.git
    cd tempest
  fi
  
  echo "Copying config file..."
  cp etc/tempest.conf.sample etc/tempest.conf

  if [ "$?" -ne 0 ]; then
    echo "Failed to copy tempest.conf file."
    exit -1
  fi

  echo "maybe we need to modify the config file at this point..."
  patch -p0 < ~/tempest.conf.patch
  #bash -i

  currtime=$(date +%y%m%d_%H%M%S)
  echo "Test execution @ $currtime."

  log="tempest_$currtime.log"
  echo "Saving all log information to $log"

  echo "Running tempest (please be patient)..."

  # PLEASE MODIFY THIS WHERE NECESSARY
  nosetests -v tempest &| tee $log

  echo "Tempest finished! (Exit code $?)"

  echo "Parsing the test results..."
  tempest_result=$(grep 'FAILED (SKIP=' $log)
  echo "Result: $tempest_result"

  # parse the output
  tempest_result=$(echo $tempest_result | sed 's/FAILED (SKIP=//g' | sed 's/, errors=/ /g' | sed 's/, failures=/ /g' | sed 's/)//g')

  # add the number of errors and failures together to get the total
  total=$(echo $tempest_result | awk '{print $2 + $3}')

  echo "Total number of errors: $total"
  [ $total -gt 254 ] && total=254

  return $total
}


#---------------------- START THE SCRIPT HERE !!!--------------------------

# does mkcloud rename the dashboard node to "dashboard" ?

tempest

echo "Tempest returned $output"

exit $output
