#!/usr/bin/env bash

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

set -o errexit

# Ensure the necessary variables are set
source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh ansible_tests

pushd ${CURRENT_FOLDER} > /dev/null
    # Generates the expected inventory for ses-ansible
    ansible-playbook prepare-ses-ansible.yml -i ${MAIN_FOLDER}/inventory-ses.ini
    pushd ${MAIN_FOLDER}/ses-ansible/
        ansible-playbook ses-install.yml -i inventory.ini -e ses_openstack_config=True
    popd
    ansible-playbook get-ses-data.yml -i ${MAIN_FOLDER}/inventory-ses.ini
    ansible-playbook set-user-variables.yml -i ${MAIN_FOLDER}/inventory-ses.ini
popd
