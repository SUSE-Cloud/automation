#!/usr/bin/env bash


MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"
 
source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

pushd ${MAIN_FOLDER} > /dev/null
    if [ -f .stackname ]; then
        STACK_NAME=$(cat ${MAIN_FOLDER}/.stackname)
        echo "Working on ${STACK_NAME}"
        # Do not continue the deletion of files if an error happens in the stack delete
        set -o errexit
        openstack stack delete ${STACK_NAME} -y --wait
    fi

    if [ -f environment.json ]; then
        rm environment.json
    fi

    if [ -f .stackname ]; then
        rm .stackname
    fi

popd > /dev/null

pushd ${CURRENT_FOLDER} > /dev/null
    if [ -f environment.json ]; then
        rm environment.json
    fi
popd > /dev/null
