#!/bin/bash
set -o errexit

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

# Ensure the necessary variables are set
source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

SERVER_NAME=${PREFIX}-${SERVER_NAME:-'ses'}
SERVER_IMAGE=${SERVER_IMAGE:-"SLES12-SP3"}
SERVER_FLAVOR=${SERVER_FLAVOR:-"m1.large"}
SECURITY_GROUP=${SECURITY_GROUP:-"all-incoming"}
EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-"floating"}
INTERNAL_NETWORK=${INTERNAL_NETWORK:-"${PREFIX}-net"}

openstack server create --image ${SERVER_IMAGE} --flavor ${SERVER_FLAVOR} --security-group ${SECURITY_GROUP} --key-name ${KEYNAME} --network ${INTERNAL_NETWORK} --wait ${SERVER_NAME} --format shell

echo "Create and attach volume"
openstack volume create --size 80 ${SERVER_NAME}-vol
openstack server add volume ${SERVER_NAME} ${SERVER_NAME}-vol


IP_CREATE=$(openstack floating ip create ${EXTERNAL_NETWORK} -c floating_ip_address --format value)
echo "Assigning Floating IP: $IP_CREATE"
openstack server add floating ip ${SERVER_NAME} $IP_CREATE

pushd ${MAIN_FOLDER}
    echo ${IP_CREATE} > .ses_ip
    grep ${IP_CREATE} inventory-ses.ini 2>&1 > /dev/null || (echo "${SERVER_NAME} ansible_ssh_host=${IP_CREATE} ansible_host=${IP_CREATE} ansible_user=root ansible_ssh_user=root" >> inventory-ses.ini)
    echo "Waiting for the node to come up before scanning ssh key" && sleep 120 # 60 seconds are not enough
    ssh-keyscan -H ${IP_CREATE} >> ~/.ssh/known_hosts
popd

pushd ${CURRENT_FOLDER}/playbooks
    #TODO(evrardjp) These 3 can be merged into a single playbook when bumping
    #ansible version to 2.7.  In ansible 2.7 a 'reboot' action plugin will prevent
    #the failures dues to disconnections.
    ansible-playbook firstboot.yml -i ${MAIN_FOLDER}/inventory-ses.ini || true
    ansible-playbook wait-for-host.yml -i ${MAIN_FOLDER}/inventory-ses.ini
    ansible-playbook add-minimum-software.yml -i ${MAIN_FOLDER}/inventory-ses.ini
popd
