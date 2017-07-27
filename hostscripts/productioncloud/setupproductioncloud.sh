#!/bin/bash
hostname crowbar
zypper ar http://download.nue.suse.com/ibs/SUSE/Products/SLE-SERVER/12-SP2/x86_64/product/ pool
zypper -n in git-core patch
zypper rr pool
git clone https://github.com/SUSE-Cloud/automation.git
cd automation
git checkout provo
git pull --rebase
cd scripts

export debug_qa_crowbarsetup=1
export want_ldap=1
export want_all_ssl=1
export controller_raid_volumes=2
export want_ssl_keys=root@cloud.suse.de:/etc/cloud-keys/
#export localreposdir_src=/srv/www/htdocs/repos/clouddata in xml
export localreposdir_target="/repositories"
export localreposdir_is_clouddata=1
export architectures="x86_64"
export cloudsource=GM7+up
#export TESTHEAD=1 # for unreleased openstack-keystone and crowbar-openstack LDAP fixes
export cloud=p2
export nodenumber=5
export want_mtu_size=9000
export hacloud=1
export clusterconfig='services+data+network=2'
export want_ceilometer_proposal=0
export want_sahara_proposal=0
export want_barbican_proposal=0
export want_magnum_proposal=1
export cephvolumenumber=3
export want_ceph=0
# 2nd node only has 64GB RAM, making it more suitable for controller
export want_node_roles=compute=1,controller=1,compute=1
#export want_node_aliases=n1=1,dashboard=1,n2=1
export want_node_roles=controller=2,compute=3
#export want_node_aliases=dashboard=1,n1=1,n2=1
export want_rootpw=securepassword
export want_tempest=0
export ipmi_ip_addrs="192.168.10.105 192.168.10.110 192.168.10.111 192.168.10.112 192.168.10.212 192.168.10.213 192.168.10.226 192.168.10.236 192.168.10.238 192.168.10.240 192.168.10.241 192.168.10.242 192.168.10.248 192.168.10.251 192.168.11.4 192.168.11.30 192.168.11.36"
export want_ipmi_username=ENGCLOUD
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

cat > /srv/www/openstack-dashboard/openstack_dashboard/templates/_login_footer.html <<EOF
<h1 style="color: #ffffff; text-align: center">
Use R&D credentials to login here with Domain "ldap_users"
<span style="color: #aaa">(or "Default" for the few non-LDAP users)</span>

<a href="https://wiki.innerweb.novell.com/index.php/Cloud/cloud.suse.de">See wiki how to use the cloud</a>
</h1>
EOF
    '
done

# on admin node to enable real certs:
cd ~/automation/hostscripts/productioncloud/
crowbar batch build batch-publicname.yaml
crowbar batch build batch-ntp.yaml
crowbar batch build batch-ssl.yaml
crowbar batch build batch-ssh-keys.yaml
crowbar batch build batch-users.yaml
crowbar batch build batch-users2.yaml
#crowbar batch build batch-ceph.yaml
)
