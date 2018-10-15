#!/bin/bash
#set -o errexit

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

# Ensure the necessary variables are set
source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

SERVER_NAME="${PREFIX}-osh"
SERVER_IMAGE=${SERVER_IMAGE:-"SLES12-SP3"}
SERVER_FLAVOR=${SERVER_FLAVOR:-"m1.large"}
SECURITY_GROUP=${SECURITY_GROUP:-"all-incoming"}
EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-"floating"}
INTERNAL_NETWORK=${INTERNAL_NETWORK:-"${PREFIX}-net"}

openstack server delete --wait ${SERVER_NAME}
openstack volume delete ${SERVER_NAME}-vol

pushd ${MAIN_FOLDER}
  if [ -f .osh_ip ]; then
      echo "Cleaning up known hosts"
      ssh-keygen -R $(cat .osh_ip)
  fi

  if [ -f inventory-osh.ini ]; then
      echo "Cleaning up inventory"
      rm inventory-osh.ini
  fi
popd
