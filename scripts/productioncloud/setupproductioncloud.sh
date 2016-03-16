#!/bin/bash
wget https://raw.githubusercontent.com/SUSE-Cloud/automation/production/scripts/qa_crowbarsetup.sh

export want_ldap=1
export want_all_ssl=1
export controller_raid_volumes=2
export want_ssl_keys=root@cloud.suse.de:/etc/cloud-keys/
export cloudsource=GM6+up
export TESTHEAD=1
export cloud=p1
export nodenumber=4
export cephvolumenumber=1
export want_rootpw=securepassword
export want_tempest=0
# add CA
export pre_prepare_proposals=$(base64 -w 0 <<'EOF'
for m in $(get_all_suse_nodes) ; do ssh $m "
zypper ar http://download.suse.de/ibs/SUSE:/CA/SLE_12_SP1/ ca
zypper -n in ca-certificates-suse"
done
EOF
)

( . qa_crowbarsetup.sh ;
onadmin_runlist prepareinstallcrowbar installcrowbar allocate proposal testsetup

# give read-permissions to the users that will need it
get_novacontroller
oncontroller '
for u in {keystone,glance,cinder,neutron,nova} ; do
    setfacl -m u:$u:r /etc/cloud-keys/*.key
    done
    '

# on admin node to enable real certs:
wget https://raw.githubusercontent.com/SUSE-Cloud/automation/production/scripts/productioncloud/batch-ssl.yaml
crowbar batch build batch-ssl.yaml
)
