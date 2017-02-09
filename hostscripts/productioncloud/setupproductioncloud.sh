#!/bin/bash
hostname crowbar
zypper ar http://clouddata.cloud.suse.de/repos/x86_64/SLES12-SP2-Pool/ pool
zypper -n in git-core patch
zypper rr pool
git clone https://github.com/SUSE-Cloud/automation.git
cd automation
git checkout p3
cd scripts

export want_ldap=1
export want_all_ssl=1
export controller_raid_volumes=2
export want_ssl_keys=root@cloud.suse.de:/etc/cloud-keys/
export cloudsource=GM7
#export TESTHEAD=1
export cloud=p3
export nodenumber=3
#export want_mtu_size=8900 # creates trouble for gate->crowbarp3
export cephvolumenumber=1
# 2nd node only has 64GB RAM, making it more suitable for controller
export want_node_roles=compute=1,controller=1,compute=1
export want_node_aliases=n1=1,dashboard=1,n2=1
export want_rootpw=securepassword
export want_tempest=0
# avoid crashing controller node from ovs+gre (bnc#970720)
# or use ethtool... gso off
export networkingplugin=linuxbridge
export networkingmode=vlan
# workaround OpteronG3 (bnc#872677) and general SVM nested virt bugs (bnc#946701/946068)
#TODO: update to SP2 export UPDATEREPOS=http://download.suse.de/ibs/home:/bmwiedemann:/branches:/Devel:/Virt:/SLE-12-SP1/SUSE_SLE-12-SP1_Update_standard/
# allow VMs to be reachable while controller node is down
#export want_dvr=1
# add CA
export pre_prepare_proposals=$(base64 -w 0 <<'EOF'
for m in $(get_all_suse_nodes) ; do ssh $m "
zypper ar http://download.suse.de/ibs/SUSE:/CA/SLE_12_SP1/ ca
zypper -n in ca-certificates-suse"
done
EOF
)

export pre_do_installcrowbar=$(base64 -w 0 <<EOF
( cd /opt/dell/ ; ln -s barclamps/core/updates ; curl https://github.com/crowbar/crowbar-core/compare/master...SUSE-Cloud:p1cloud.patch | patch -p1 )
EOF
)

( . qa_crowbarsetup.sh ;
onadmin_runlist addupdaterepo prepareinstallcrowbar bootstrapcrowbar installcrowbar allocate setup_aliases proposal setupproduction testsetup

# give read-permissions to the users that will need it
get_novacontroller
oncontroller '
for u in {keystone,glance,cinder,neutron,nova} ; do
    setfacl -m u:$u:r /etc/cloud-keys/*.key
    done
    '
echo TODO set public name to dashboard.p3.cloud.suse.de

# on admin node to enable real certs:
cd ~/automation/hostscripts/productioncloud/
crowbar batch build batch-ssl.yaml
crowbar batch build batch-ssh-keys.yaml
crowbar batch build batch-users.yaml
#crowbar batch build batch-ceph.yaml
)
