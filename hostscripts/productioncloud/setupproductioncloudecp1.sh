#!/bin/bash
grep -q NumberOfPasswordPrompts ~/.ssh/config || echo NumberOfPasswordPrompts 0 >> ~/.ssh/config

hostname crowbar
zypper ar http://download.nue.suse.com/ibs/SUSE/Products/SLE-SERVER/12-SP2/x86_64/product/ pool
zypper -n in git-core patch
zypper rr pool
git clone --branch provo --depth 1 https://github.com/SUSE-Cloud/automation.git
cd automation
git pull --rebase
cp -a hostscripts/productioncloud/mkcloud.config.ecp1 ~/mkcloud.config
cd scripts
. ~/mkcloud.config

( . qa_crowbarsetup.sh ;
onadmin_runlist addupdaterepo prepareinstallcrowbar bootstrapcrowbar installcrowbar allocate proposal testsetup

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
#crowbar batch build batch-ssl.yaml
crowbar batch build batch-ssh-keys.yaml
crowbar batch build batch-users.yaml
crowbar batch build batch-users2.yaml
#crowbar batch build batch-ceph.yaml
)
