#!/usr/bin/env bash

set -o errexit
set -o pipefail

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

CAASP_IMAGE=${CAASP_IMAGE:-"caasp-3.0.0-GM-OpenStack-qcow"}
SERVER_FLAVOR=${SERVER_FLAVOR:-"m1.large"}
SECURITY_GROUP=${SECURITY_GROUP:-"all-incoming"}
EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-"floating"}
INTERNAL_NETWORK=${INTERNAL_NETWORK:-"${PREFIX}-net"}
STACK_NAME="${PREFIX}-$RANDOM"

echo "Stackname will be:"
echo ${STACK_NAME} | tee ${MAIN_FOLDER}/.stackname

pushd ${CURRENT_FOLDER}
    echo "Creating caasp cluster"
    openstack stack create --verbose --wait -t caasp-stack.yaml ${STACK_NAME} \
        --parameter image="${CAASP_IMAGE}" \
        --parameter external_net="${EXTERNAL_NETWORK}" \
        --parameter internal_network="${INTERNAL_NETWORK}" \
        --parameter internal_subnet="${INTERNAL_SUBNET}" \
        --parameter security_group="${SECURITY_GROUP}" \
        --parameter keypair="${KEYNAME}" \
        | tee -a $LOG


    # compatibility for caasp tooling requires the creation of ssh key
    if [ ! -d ../misc-files/ ]; then
        mkdir ../misc-files
    fi
    if [ ! -f ../misc-files/id_shared ]; then
        ssh-keygen -b 2048 -t rsa -f ../misc-files/id_shared -N ""
    fi

    ./tools/generate-environment "$STACK_NAME"
    ./misc-tools/generate-ssh-config environment.json
    PYTHONUNBUFFERED=1 "./misc-tools/wait-for-velum" https://$(jq -r '.dashboardExternalHost' environment.json)
    cp environment.json ${MAIN_FOLDER}
popd
