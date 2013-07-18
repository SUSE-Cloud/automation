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

# TODO - make sure configuration function is idempotent
function configure_tempest()
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

  . ~/.openrc

  echo "maybe we need to modify the config file at this point..."
  patch -p0 < ~/tempest.conf.patch
  ( for i in 1 2 ; do
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

  echo "Setting the correct database URI in the tempest.conf file..."
  DB_URI=$(grep -i 'sql_connection=' /etc/nova/nova.conf | sed 's/sql_connection=//g')
  PREDECESSOR=$(grep -i 'db_uri =' ~/tempest/etc/tempest.conf)
  sed -i "s|$PREDECESSOR|db_uri = $DB_URI|g" etc/tempest.conf

  echo "Checking for the test images..."
  IMG1=$(glance image-list | grep 'jeos-64' | awk '{print $2}')
  IMG2=$(glance image-list | grep 'SP2-64' | awk '{print $2}')

  if [ "$IMG1" = "" ]; then
    echo "Retrieving a JEOS-64 image (QCOW2 image for KVM)..."
    glance image-create --name=jeos-64 --is-public=True --container-format=bare --disk-format=qcow2 --copy-from http://clouddata.cloud.suse.de/images/jeos-64.qcow2
    IMG1=$(glance image-list | grep 'jeos-64' | awk '{print $2}')
  else
    echo "JEOS_64 image already in place."
  fi

  if [ "$IMG2" = "" ]; then
    echo "Retrieving SLES_SP2_x86_64 image (QCOW2 image for KVM)..."
    glance image-create --name=SP2-64 --is-public=True --container-format=bare --disk-format=qcow2 --copy-from http://clouddata.cloud.suse.de/images/SP2-64up.qcow2
    IMG2=$(glance image-list | grep 'SP2-64' | awk '{print $2}')
  else
    echo "SLES_SP2_x86_64 image already in place."
  fi

  # some inline substitution inside tempest.conf
  sed -i -e "s/image_ref = .*/image_ref = $IMG1/" etc/tempest.conf
  sed -i -e "s/image_ref_alt = .*/image_ref_alt = $IMG2/" etc/tempest.conf
  sed -i -e "s/admin_password = .*/admin_password = crowbar/g" etc/tempest.conf
  sed -i -e "s/admin_tenant_name = .*/admin_tenant_name = openstack/g" etc/tempest.conf
  sed -i -e "s/quantum_available = .*/quantum_available = true/g" etc/tempest.conf

  echo "Querying for the public_network_id..."
  public_network_id=$(quantum net-list | grep 'floating' | awk '{print $2}')

  if [ "$public_network_id" != "" ] ; then
    echo "Configuring the public_network_id with $public_network_id ..."
    sed -i -e "s/public_network_id = .*/public_network_id = $public_network_id/g" etc/tempest.conf
  else
    echo "Unable to access the public_network_id."
  fi

  echo "Querying for the public_router_id..."
  public_router_id=$(quantum router-list | grep "$public_network_id" | awk '{print $2}')

  if [ "$public_router_id" != "" ] ; then
    echo "Configuring the public_router_id with $public_router_id ..."
    sed -i -e "s/public_router_id = .*/public_router_id = $public_router_id/g" etc/tempest.conf
  else
    echo "Unable to access the public_router_id."
  fi

  echo "Querying for EC2 credentials..."
  ec2_credentials=$( keystone ec2-credentials-list | grep admin | sed -e "s/ //g" | cut -d"|" -f 3,4 )
  ec2_user=$(echo $ec2_credentials | cut -d"|" -f 1)
  ec2_pass=$(echo $ec2_credentials | cut -d"|" -f 2)
  if [ ! -z $ec2_user  && ! -z $ec2_pass ] ; then
    echo "Found EC2 credentials, now writing them to the config."
    sed -i -e "s/aws_access = .*/aws_access = $ec2_user/g" etc/tempest.conf
    sed -i -e "s/aws_secret = .*/aws_secret = $ec2_pass/g" etc/tempest.conf
  else
    echo "Error: No EC2 credentials could be found."
    echo "Tests relying on these credentials will fail."
  fi
}


function run_tempest()
{
  . ~/.openrc
  currtime=$(date +%y%m%d_%H%M%S)
  echo "Test execution @ $currtime."

  log="tempest_$currtime.log"
  echo "Saving all log information to $log"

  echo "Running tempest (please be patient)..."
  echo "(This would normally take about 2 hrs 20 mins)"

  # PLEASE MODIFY THIS WHERE NECESSARY
  time nosetests -v -x -s tempest 2>&1 | tee $log

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

function cleanup_tempest()
{
  # TODO - implement this funtion idempotent
  echo "This function needs to be implemented"
  return 1
}

#---------------------- START THE SCRIPT HERE !!!--------------------------

ret=1
case $1 in
  configure)
    configure_tempest
    ret=$?
  ;;
  cleanup)
    cleanup_tempest
    ret=$?
  ;;
  run)
    run_tempest
    ret=$?
  ;;
  *)
    echo "Function unknown: $1"
    echo "Usage: $0 <configure|run|cleanup>"
    exit 1
  ;;
esac

echo "Tempest return code of step '$1' is '$ret'"
exit $ret
