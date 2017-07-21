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
export cloudsource=GM7+up
export TESTHEAD=1 # for unreleased openstack-keystone and crowbar-openstack LDAP fixes
export cloud=p3
export nodenumber=5
export want_mtu_size=9000
export hacloud=1
export clusterconfig='services+data+network=2'
export want_ceilometer_proposal=0
export want_sahara_proposal=0
export want_barbican_proposal=0
export want_magnum_proposal=1
export cephvolumenumber=3
# 2nd node only has 64GB RAM, making it more suitable for controller
export want_node_roles=compute=1,controller=1,compute=1
#export want_node_aliases=n1=1,dashboard=1,n2=1
export want_node_roles=controller=2,compute=3
#export want_node_aliases=dashboard=1,n1=1,n2=1
export want_rootpw=securepassword
export want_tempest=0
# avoid crashing controller node from ovs+gre (bnc#970720)
# or use ethtool... gso off
export networkingplugin=openvswitch
export networkingmode=vlan
export want_dvr=1
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
onadmin_runlist addupdaterepo prepareinstallcrowbar bootstrapcrowbar installcrowbar allocate setup_aliases proposal testsetup

# give read-permissions to the users that will need it
get_novacontroller
for controller in "$novacontroller" services1 services2 dashboard ; do
# FIXME: split setupproduction into parts that need to run once per cloud
# and parts that need to run once per controller node (e.g. local file setup)
run_on "$controller" 'set -x
oncontroller_setupproduction
for u in keystone glance cinder neutron nova barbican ceph aodh heat manila ; do
    setfacl -m u:$u:r /etc/cloud-keys/*.key
    done
cat > /etc/openldap/ldap.conf <<EOF
TLS_CACERTDIR   /etc/ssl/certs/
uri     ldaps://ldap.suse.de
base    dc=suse,dc=de
EOF
    '
done

# on admin node to enable real certs:
cd ~/automation/hostscripts/productioncloud/
crowbar batch build batch-publicname.yaml
crowbar batch build batch-ssl.yaml
crowbar batch build batch-ssh-keys.yaml
crowbar batch build batch-users.yaml
crowbar batch build batch-users2.yaml
#crowbar batch build batch-ceph.yaml
)
