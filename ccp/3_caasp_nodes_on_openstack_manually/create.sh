#!/bin/bash
set -o errexit

MAIN_FOLDER="$(readlink -f $(dirname ${0})/..)"
CURRENT_FOLDER="$(readlink -f $(dirname ${0}))"

# Ensure the necessary variables are set
source ${MAIN_FOLDER}/script_library/pre-flight-checks.sh openstack_tests

SERVER_IMAGE=${CAASP_IMAGE:-"caasp-3.0.0-GM-OpenStack-qcow"}
SERVER_FLAVOR=${SERVER_FLAVOR:-"m1.large"}
SECURITY_GROUP=${SECURITY_GROUP:-"all-incoming"}
EXTERNAL_NETWORK=${EXTERNAL_NETWORK:-"floating"}
INTERNAL_NETWORK=${INTERNAL_NETWORK:-"${PREFIX}-net"}
NAME="${PREFIX}"

pushd $CURRENT_FOLDER > /dev/null
    for role in "admin" "master" "worker0" "worker1"; do
        server="${NAME}-${role}"
        IP_CREATED=$(openstack floating ip create ${EXTERNAL_NETWORK} -c floating_ip_address --format value)

        if [[ ${server}  = *"admin" ]]; then
            echo $IP_CREATED > ${MAIN_FOLDER}/.velum_ip
            export ADMIN_IP=${IP_CREATED}
        fi

        pushd data > /dev/null
            sed "s/ADMINIP/${ADMIN_IP}/g" ${role}.j2 > ${role}.yml
        popd > /dev/null

        echo "Creating $server"
        openstack server create --image ${SERVER_IMAGE} --flavor ${SERVER_FLAVOR} --security-group ${SECURITY_GROUP} --key-name ${KEYNAME} --network ${INTERNAL_NETWORK} --wait --user-data data/${role}.yml  ${server} --format shell > /dev/null

        echo "Assigning Floating IP $IP_CREATED to server $server"
        openstack server add floating ip ${server} $IP_CREATED > /dev/null

        pushd ${MAIN_FOLDER} > /dev/null
          echo "${server} ansible_ssh_host=${IP_CREATED} ansible_host=${IP_CREATED} ansible_user=root ansible_ssh_user=root" >> inventory-caasp.ini
        popd > /dev/null
    done
popd > /dev/null
echo "Wait for velum to go up (5 minutes)"
sleep 120
echo "Wait for velum to go up (3 moar minutes)"
sleep 120
echo "Wait for velum to go up (You are almost ready! 60 seconds!)"
sleep 55
echo "Wait for velum to go up (5 seconds!)"
sleep 1
echo "Wait for velum to go up (4!)"
sleep 1
echo "Wait for velum to go up (3!)"
sleep 1
echo "Wait for velum to go up (2!)"
sleep 1
echo "Wait for velum to go up (2!)"
sleep 1
echo "Wait for velum to go up (1!)"
sleep 1
echo "Happy birthday! Your new baby CaaSP cluster can be used!"
