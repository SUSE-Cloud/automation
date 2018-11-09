# raw bash instructions to copy-paste
# alpha version - use with care
### PART-1
### from local machine to setup infrastructure on engcloud
export namespace=$USER
export openstacksshkey=xxx
if ! ./heat-setup.sh; then
  echo "Error deploying stack"
  exit 1
fi

admin_ip=`cat .admin_ip`

### PART-2
### mkcloud and surrounding setup
nc -z -w 60 $admin_ip 22 && ssh root@$admin_ip
# and execute this
zypper="zypper --gpg-auto-import-keys -n"

function h_setup_base_repos {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release

        DIST_VERSION=${VERSION}
        $zypper ar -f "http://download.nue.suse.com/update/build.suse.de/SUSE/Products/SLE-SERVER/${DIST_VERSION}/x86_64/product/" Base || :
    fi
}

h_setup_base_repos
$zypper ref
$zypper in git-core screen ca-certificates-mozilla iptables
git clone https://github.com/SUSE-Cloud/automation
pushd ~/automation/scripts
admin_ip=$(ip a|grep 192.168.120|perl -ne 'm#(\d+)/24# && print $1')
cat << EOF > ./cloud9
#!/bin/sh
export cloudsource=develcloud9
export networkingplugin=openvswitch
export nodenumber=3
export TESTHEAD=1
export hacloud=

# these are the more important bits to get mkcloud going
export cephvolumenumber=0
export net_admin=192.168.120
export adminip=\$net_admin.$admin_ip
export mkclouddriver=physical
export want_ironic=0

export want_ceilometer_proposal=0
export want_heat_proposal=0
export want_manila_proposal=0
export want_trove_proposal=0
export want_barbican_proposal=0
export want_magnum_proposal=0
export want_sahara_proposal=0
export want_murano_proposal=0
export want_aodh_proposal=0
export want_tempest_proposal=1

./mkcloud "\$@"
EOF
chmod a+x cloud9

$zypper in nfs-client

./cloud9 prepareinstcrowbar bootstrapcrowbar instcrowbar

# Rick suggested you could add the remaning nodes as lonelynodes to crowbar
# i did not do this it expects dhcp running on admin node whereas 
# i had it from subnet, this is one of the shortcuts i would prefer, didnt try

# so I did crowbar_register manually
# crowbar_register requires running locally or screen and not on ssh, so I had install screen which requires addiing repos.
# So I used the h_setup_base_repos functins above however crowbar_register does not like that, so just rm -rf  /etc/zypp/*

# once node were in ready state
./cloud9 proposal

# you will need to add a bridge on admin node with vlan-300 for "floating-ips" in the inner openstack to work


