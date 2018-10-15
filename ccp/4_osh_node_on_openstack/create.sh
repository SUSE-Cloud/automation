#!/bin/bash
set -o errexit

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

openstack server create --image ${SERVER_IMAGE} --flavor ${SERVER_FLAVOR} --security-group ${SECURITY_GROUP} --key-name ${KEYNAME} --network ${INTERNAL_NETWORK} --wait ${SERVER_NAME} --format shell

echo "Create and attach volume"
openstack volume create --size 80 ${SERVER_NAME}-vol
openstack server add volume ${SERVER_NAME} ${SERVER_NAME}-vol


IP_CREATE=$(openstack floating ip create ${EXTERNAL_NETWORK} -c floating_ip_address --format value)
echo "Assigning Floating IP: $IP_CREATE"
openstack server add floating ip ${SERVER_NAME} $IP_CREATE

pushd ${MAIN_FOLDER}
    echo ${IP_CREATE} > .osh_ip
    if [ ! -f inventory-osh.ini ]; then
        echo '[osh-deploy]' > inventory-osh.ini
    fi
    echo "${SERVER_NAME} ansible_ssh_host=${IP_CREATE} ansible_host=${IP_CREATE} ansible_user=root ansible_ssh_user=root" >> inventory-osh.ini

    echo "Waiting for the node to come up before scanning ssh key" && sleep 120 # 60 seconds are not enough
    ssh-keyscan -H ${IP_CREATE} >> ~/.ssh/known_hosts
popd

ssh root@${IP_CREATE} << 'ENDSSH'
zypper ar -f -G http://provo-clouddata.cloud.suse.de/repos/x86_64/SLES12-SP3-Pool/ product;
zypper ar -f -G http://provo-clouddata.cloud.suse.de/repos/x86_64/SLES12-SP3-Updates/ SLES12-SP3-Updates
zypper ar -f -G http://provo-clouddata.cloud.suse.de/repos/x86_64/SLE12-SP3-SDK-Pool/ SDK-Pool;
zypper ar -f -G http://provo-clouddata.cloud.suse.de/repos/x86_64/SLE12-SP3-SDK-Updates/ SDK-Updates;
zypper ar -f -G http://download.suse.de/ibs/SUSE:/CA/SLE_12_SP3/ SUSE-CA;
zypper ar -f -G http://provo-clouddata.cloud.suse.de/repos/x86_64/SUSE-OpenStack-Cloud-8-Pool/ SUSE-OpenStack-Cloud-8-Pool;
zypper ar -f -G https://download.opensuse.org/repositories/utilities/SLE_12/ SLE12-utilities;
zypper ar -f -G https://download.opensuse.org/repositories/devel:/tools/SLE_12_SP3/devel:tools.repo;
zypper ar -f -G https://download.opensuse.org/repositories/Virtualization:/containers/SLE_12_SP3/Virtualization:containers.repo && echo "Repos configured";
zypper refresh && zypper up -y ;
systemctl disable SuSEfirewall2_setup.service;
systemctl disable SuSEfirewall2_init.service;
ssh-keygen -t rsa -f ~/.ssh/id_rsa -N "";
cat .ssh/id_rsa.pub >> .ssh/authorized_keys;
ssh-keyscan -H  127.0.0.1 >> ~/.ssh/known_hosts
ENDSSH
