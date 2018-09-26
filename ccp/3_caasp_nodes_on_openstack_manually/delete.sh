#!/bin/bash

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

SERVER_IMAGE=${SERVER_IMAGE:-"caasp-3.0.0-GM-OpenStack-qcow"}
SERVER_FLAVOR=${SERVER_FLAVOR:-"m1.large"}
SECURITY_GROUP=${SECURITY_GROUP:-"all-incoming"}

EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-"floating"}
INTERNAL_NETWORK=${INTERNAL_NETWORK:-"${PREFIX}-net"}
NAME="${PREFIX}"


for server in "${NAME}-master" "${NAME}-worker0" "${NAME}-worker1" "${NAME}-admin"; do
    openstack server delete ${server}
done

pushd ${MAIN_FOLDER} > /dev/null
    if [ -f inventory-caasp.ini ]; then
        rm inventory-caasp.ini
    fi
    if [ -f .velum_ip ]; then
        rm .velum_ip
    fi
popd > /dev/null
