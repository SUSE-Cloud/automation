#!/bin/bash

# EXIT STATUS: 0: ok; 1..254: number of errors + failures; 255: error in this script

function check_or_exit()
{
  if [ "$1" -ne 0 ] ; then
    echo "Error detected in phase: $2"
    exit 255
  fi
  return
}

function tempest()
{
  echo "Installing git-core, Python unittest2 and nose..."
  zypper addrepo http://download.opensuse.org/repositories/devel:/tools:/scm/SLE_11_SP2/devel:tools:scm.repo
  zypper addrepo http://download.opensuse.org/repositories/Cloud:/OpenStack:/Grizzly/SLE_11_SP3/Cloud:OpenStack:Grizzly.repo
  zypper -n --gpg-auto-import-keys install python-unittest2 python-nose python-testtools python-testresources git-core

  check_or_exit $? "Installation of packages"

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

  check_or_exit $? "Copying tempest.conf file."

  echo "maybe we need to modify the config file at this point..."
  patch -p0 < ~/tempest.conf.patch
  (. ~/.openrc
    for i in 1 2 ; do
      nova flavor-delete $i
      nova flavor-create --is-public True m1.tiny$i $i 150 0 1
    done
  )
  
    echo "Creating a tenant named demo..."
  keystone tenant-create --name demo

  demo_tenant_id=$(keystone tenant-list | grep '^|\s[[:xdigit:]]*\s*|\s*demo\s*|\s*True\s*|\s*$' | sed 's/|\s//g' | awk '{print $1}')
  echo "Tenant demo's id is $demo_tenant_id"

  echo "Creating a user named demo that is assigned to the tenant demo..."
  keystone user-create --name demo --tenant-id $demo_tenant_id --pass secret --enabled true

  echo "Creating another tenant named alt_demo..."
  keystone tenant-create --name alt_demo

  alt_demo_tenant_id=$(keystone tenant-list | grep '^|\s[[:xdigit:]]*\s*|\s*alt_demo\s*|\s*True\s*|\s*$' | sed 's/|\s//g' | awk '{print $1}')
  echo "Tenant alt_demo's id is $alt_demo_tenant_id"

  echo "Creating a user alt_demo that is assigned to the tenant alt_demo..."
  keystone user-create --name alt_demo --tenant-id $alt_demo_tenant_id --pass secret --enabled true
  
  imgid=$(. ~/.openrc ; nova image-list|perl -ne 'if(m/^\| ([0-9a-f]{8}\S+) /){print $1;exit 0}')
  sed -i -e "s/image_ref = .*/image_ref = $imgid/" etc/tempest.conf
  sed -i -e "s/image_ref_alt = .*/image_ref_alt = $imgid/" etc/tempest.conf
  sed -i -e "s/admin_password = .*/admin_password = crowbar/g" etc/tempest.conf
  sed -i -e "s/admin_tenant_name = .*/admin_tenant_name = openstack/g" etc/tempest.conf
  #bash -i

  currtime=$(date +%y%m%d_%H%M%S)
  echo "Test execution @ $currtime."

  log="tempest_$currtime.log"
  echo "Saving all log information to $log"

  echo "Running tempest (please be patient)..."

  # PLEASE MODIFY THIS WHERE NECESSARY
  time nosetests -v tempest 2>&1 | tee $log

  tempestcode=$?
  #check_or_exit $tempestcode "Tempest run"
  echo "Tempest finished! (Exit code $tempestcode)"

  echo "Parsing the test results..."
  tempest_result=$(tail -n50 $log | grep '^FAILED (')
  echo "Result: $tempest_result"

  # parse the output
  tempest_result_skip=$(echo $tempest_result | grep -o "SKIP=[[:digit:]]*")
  tempest_result_errors=$(echo $tempest_result | grep -o "errors=[[:digit:]]*")
  tempest_result_failures=$(echo $tempest_result | grep -o "failures=[[:digit:]]*")

  # add the number of errors and failures together to get the total
  total=$(( $tempest_result_errors + $tempest_result_failures ))

  echo "Total number of errors: $total"
  [ $total -gt 254 ] && total=254

  return $total
}


#---------------------- START THE SCRIPT HERE !!!--------------------------

# does mkcloud rename the dashboard node to "dashboard" ?

tempest
output=$?
echo "Tempest returned $output"
exit $output
