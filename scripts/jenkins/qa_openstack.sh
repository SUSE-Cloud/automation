#!/bin/sh
# usage:
# curl http://openqa.suse.de/sle/qatests/qa_openstack.sh | sh -x
# needs 2.1GB space for /var/lib/{glance,nova}
export MODE=kvm
# Avoid nested virtualisation by setting the line below
# Note that as of today (2014-02-14) OpenStack Nova has known
# bugs. Since upstream tests with kvm, it doesn't really
# make sense to test anything else.
# MODE=lxc
if ! grep -q -e vmx -e svm /proc/cpuinfo ; then
    MODE=lxc
fi
ARCH=$(uname -i)

ifconfig | grep inet

# setup optional extra disk for cinder-volumes
dev_cinder=/dev/vdb
if ! test -e $dev_cinder && file -s /dev/sdb|grep -q "ext3 filesystem data" ; then
    dev_cinder=/dev/sdb
fi
if [ -e $dev_cinder ]; then
    # CINDER_VOLUMES_DEV is evaulated by openstack-loopback-lvm
    # from openstack-quickstart to create the VG
    export CINDER_VOLUMES_DEV=$dev_cinder
fi

# setup optional extra disk for manila-shares
dev_manila=/dev/vdc
if ! test -e $dev_manila && file -s /dev/sdc|grep -q "ext3 filesystem data" ; then
    dev_manila=/dev/sdc
fi
if [ -e $dev_manila ]; then
    # MANILA_SHARES_DEV is evaluated by openstack-loopback-lvm
    # from openstack-quickstart to create the VG
    export MANILA_SHARES_DEV=$dev_manila
fi

mount -o remount,noatime,barrier=0 /


function get_dist_name() {
    . /etc/os-release
    echo $NAME
}

function get_dist_version() {
    . /etc/os-release
    echo $VERSION_ID
}

# setup repos
VERSION=11
REPO=SLE_11_SP3

if [ -f "/etc/os-release" ]; then
    VERSION=$(get_dist_version)
    DIST_NAME=$(get_dist_name)

    case "$DIST_NAME" in
        "SLES")
            REPO="SLE_12"
            [ "$VERSION" = "12.1" ] && REPO="SLE_12_SP1"
            [ "$VERSION" = "12.2" ] && REPO="SLE_12_SP2"
        ;;
        "openSUSE Leap")
            REPO="openSUSE_Leap_${VERSION}"
        ;;
        "openSUSE")
            REPO="openSUSE_${VERSION}"
        ;;
        *)
            echo "Switch to a useful distribution!"
            exit 1
            ;;
    esac
else
    # old style for SLES11
    if grep "^VERSION = 1[2-4]\\.[0-5]" /etc/SuSE-release ; then
        VERSION=$(awk -e '/^VERSION = 1[2-4]\./{print $3}' /etc/SuSE-release)
        REPO=openSUSE_$VERSION
    fi
fi

zypper="zypper --non-interactive"

zypper rr cloudhead || :

case "$cloudsource" in
    openstackicehouse)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Icehouse/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Icehouse:/Staging/$REPO/ cloudhead
        fi
    ;;
    openstackjuno)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Juno/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Juno:/Staging/$REPO/ cloudhead
        fi
    ;;
    openstackkilo)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Kilo/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Kilo:/Staging/$REPO/ cloudhead
        fi
    ;;
    openstackliberty)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Liberty/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Liberty:/Staging/$REPO/ cloudhead
        fi
    ;;
    openstackmitaka)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Mitaka/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Mitaka:/Staging/$REPO/ cloudhead
        fi
    ;;
    openstackmaster)
        $zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/$REPO/ cloud || :
        # no staging for master
        $zypper mr --priority 22 cloud
    ;;
    *)
        echo "unknown cloudsource"
        exit 37
    ;;
esac

# when using OSHEAD, dup from there
if [ -n "$OSHEAD" ]; then
    $zypper dup --from cloudhead
    # use high prio so that packages will be preferred from here over Devel:Cloud
    $zypper mr --priority 42 cloudhead
fi

if [ $VERSION = 11 ] ; then
    $zypper rr CloudProduct || true
    $zypper rr SUSE_SLE-11-SP2_Update_Products_Test || true
    if [ "$REPO" = SLE_11_SP3 ] ; then
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SLES11-SP3-Pool/sle-11-x86_64/' SP3Pool
    fi
fi

if [ "$VERSION" = "12" ] ; then
    $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12/x86_64/product/' SLES12-Pool
    $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12/x86_64/update/' SLES12-Updates
fi

### FIX SP2 setup
if [ "$VERSION" = "12.1" ] || [ "$VERSION" = "12.2" ]; then
    $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12-SP1/x86_64/product/' SLE12-SP1-Pool
    $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12-SP1/x86_64/update/' SLES12-SP1-Updates
fi

# install maintenance updates
# run twice, first installs zypper update, then the rest
$zypper -n patch --skip-interactive || $zypper -n patch --skip-interactive

# grizzly or master does not want dlp
$zypper rr dlp || true

$zypper rr Virtualization_Cloud # repo was dropped but is still in some images for cloud-init
$zypper --gpg-auto-import-keys -n ref

# deinstall some leftover crap from the cleanvm
$zypper -n rm --force 'python-cheetah < 2.4'

# deinstall cloud-init and dependencies
$zypper -n rm --force -u cloud-init
# wickedd needs to be configured properly to avoid overriding
# the hostname (see <https://bugzilla.opensuse.org/show_bug.cgi?id=974661>).
sed -i -e "s/DHCLIENT_SET_HOSTNAME=\"yes\"/DHCLIENT_SET_HOSTNAME=\"no\"/" /etc/sysconfig/network/dhcp
sed -i -e "s/DHCLIENT6_SET_HOSTNAME=\"yes\"/DHCLIENT6_SET_HOSTNAME=\"no\"/" /etc/sysconfig/network/dhcp
# This is to reapply the config to wickedd
ifup all

# install some basics (which is i.e. not installed in the SLE12SP1 JeOS
$zypper -n in wget

# Everything below here is fatal
set -e

# start with patterns
$zypper -n install -t pattern cloud_controller cloud_compute cloud_network
$zypper -n install --force openstack-quickstart openstack-tempest-test

# for debugging, use some files if available after installing
# the openstack-quickstart package
if [ -n "$QUICKSTART_DEBUG" ]; then
    test -e /tmp/openstack-quickstart-demosetup && \
        cp /tmp/openstack-quickstart-demosetup \
            /usr/sbin/openstack-quickstart-demosetup && \
        echo "WARN: using /tmp/openstack-quickstart-demosetup"
    test -e /tmp/keystone_data.sh && \
        cp /tmp/keystone_data.sh /usr/lib/devstack/keystone_data.sh && \
        echo "WARN: using /tmp/keystone_data.sh"
    test -e /tmp/functions.sh && \
        cp /tmp/functions.sh /usr/lib/openstack-quickstart/functions.sh && \
        echo "WARN: using /tmp/functions.sh"
    test -e /tmp/bash.openstackrc && \
        cp /tmp/bash.openstackrc /etc/bash.openstackrc && \
        echo "WARN: using /tmp/bash.openstackrc"
    test -e /tmp/openstack-loopback-lvm && \
        cp /tmp/openstack-loopback-lvm /usr/sbin/openstack-loopback-lvm && \
        echo "WARN: using /tmp/openstack-loopback-lvm"
    test -e /tmp/openstackquickstartrc && \
        cp /tmp/openstackquickstartrc /etc/openstackquickstartrc && \
        echo "WARN: using /tmp/openstackquickstartrc"
fi

crudini=crudini
test -z "$(type -p crudini 2>/dev/null)" && crudini="openstack-config"

for i in eth0 br0 ; do
    IP=$(ip a show dev $i|perl -ne 'm/inet ([0-9.]+)/ && print $1')
    [ -n "$IP" ] && break
done
if [ -n "$IP" ] ; then
    sed -i -e s/127.0.0.1/$IP/ /etc/openstackquickstartrc
fi
sed -i -e "s/with_tempest=no/with_tempest=yes/" /etc/openstackquickstartrc
sed -i -e "s/with_horizon=no/with_horizon=yes/" /etc/openstackquickstartrc
sed -i -e "s/with_magnum=no/with_magnum=yes/" /etc/openstackquickstartrc
sed -i -e "s/node_is_compute=.*/node_is_compute=yes/" /etc/openstackquickstartrc
sed -i -e s/br0/brclean/ /etc/openstackquickstartrc
unset http_proxy
bash -x openstack-quickstart-demosetup

if [ "$(uname -r  | cut -d. -f2)" -ge 10 ]; then
    echo "APPLYING HORRIBLE HACK PLEASE REMOVE"
    # needs to be ported from Nova Network
    # workaround broken debian-5 image, see https://bugzilla.redhat.com/show_bug.cgi?id=910619
    iptables -t mangle -A POSTROUTING -p udp --dport bootpc -j CHECKSUM  --checksum-fill
fi

. /etc/bash.bashrc.local

NOVA_FLAVOR="m1.nano"
nova flavor-delete $NOVA_FLAVOR || :
nova flavor-create $NOVA_FLAVOR 42 128 0 1
nova flavor-delete m1.micro || :
nova flavor-create m1.micro 84 256 0 1

# make sure glance is working
for i in $(seq 1 5); do
    glance image-list || true
    sleep 1
done

# make sure cinder is working
for i in $(seq 1 60); do
    cinder-manage service list | grep volume | fgrep -q ':-)' && break
    sleep 1
done

# cinder
cinder create 1 ; sleep 10
vol_id=$(cinder list | grep available | cut -d' ' -f2)
cinder list
cinder delete $vol_id
test "$(lvs | wc -l)" -gt 1 || exit 1

ssh_user="root"
mirror=http://149.44.161.38/images # ci1-opensuse

cirros_base_url="http://download.cirros-cloud.net/0.3.4/"
cirros_base_url="$mirror"
cirros_base_name="cirros-0.3.4-x86_64"

# since glanceclient Liberty, --is-public is gone and --visibility should be used
if glance help image-create|grep -q visibility; then
    GLANCECLIENT_VISIBILITY_PARAMS=" --visibility=public"
else
    GLANCECLIENT_VISIBILITY_PARAMS=" --is-public=true"
fi

GC_IMAGE_CREATE="glance image-create --progress $GLANCECLIENT_VISIBILITY_PARAMS"

case "$MODE" in
    xen)
        $GC_IMAGE_CREATE --disk-format=qcow2 --container-format=bare --name jeos-64-pv --copy-from http://clouddata.cloud.suse.de/images/jeos-64-pv.qcow2
        $GC_IMAGE_CREATE --disk-format=aki --container-format=aki --name=debian-kernel < xen-kernel/vmlinuz-2.6.24-19-xen
        $GC_IMAGE_CREATE --disk-format=ari --container-format=ari --name=debian-initrd < xen-kernel/initrd.img-2.6.24-19-xen
        $GC_IMAGE_CREATE --disk-format=ami --container-format=ami --name=debian-5 --property vm_mode=xen ramdisk_id=f663eb9a-986b-466f-bd3e-f0aa2c847eef kernel_id=d654691a-0135-4f6d-9a60-536cf534b284 < debian.5-0.x86.img
    ;;
    lxc)
        $GC_IMAGE_CREATE --name="debian-5" --disk-format=ami --container-format=ami --copy-from $mirror/debian.5-0.x86.qcow2
    ;;
    *)
        wget $cirros_base_url/$cirros_base_name-uec.tar.gz
        tar xf $cirros_base_name-uec.tar.gz
        RAMDISK_ID=$($GC_IMAGE_CREATE --name="$cirros_base_name-uec-initrd" \
            --disk-format=ari --container-format=ari < $cirros_base_name-initrd | grep ' id ' | awk '{print $4}')
        KERNEL_ID=$($GC_IMAGE_CREATE --name="$cirros_base_name-vmlinuz" \
            --disk-format=aki --container-format=aki < $cirros_base_name-vmlinuz | grep ' id ' | awk '{print $4}')
        $GC_IMAGE_CREATE --name="$cirros_base_name-uec" \
            --container-format ami --disk-format ami \
            --property kernel_id=$KERNEL_ID --property ramdisk_id=$RAMDISK_ID < $cirros_base_name-blank.img

        $GC_IMAGE_CREATE --name="debian-5" \
            --container-format ami --disk-format ami \
            --property kernel_id=$KERNEL_ID --property ramdisk_id=$RAMDISK_ID < $cirros_base_name-blank.img

        ssh_user="cirros"

        #$GC_IMAGE_CREATE --name="debian-5" --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/cirros-0.3.1-x86_64-disk.img
    ;;
esac

glance image-list
imgid=$(glance image-list|grep debian-5|cut -f2 -d" ")
mkdir -p ~/.ssh
( umask 77 ; nova keypair-add testkey > ~/.ssh/id_rsa )

function get_network_id() {
    local id
    eval `neutron net-show -f shell -F id $1`
    echo "$id"
}

cat - > testvm.stack <<EOF
heat_template_version: 2013-05-23

description: Test VM

resources:
  my_instance:
    type: OS::Nova::Server
    properties:
      key_name: testkey
      image: $imgid
      flavor: $NOVA_FLAVOR
      networks:
        - port: { get_resource: my_fixed_port }

  my_fixed_port:
    type: OS::Neutron::Port
    properties:
      network_id: $(get_network_id fixed)
      security_groups: [ default ]

  my_floating_ip:
    type: OS::Neutron::FloatingIP
    properties:
      floating_network_id: $(get_network_id ext)
      port_id: { get_resource: my_fixed_port }

outputs:
  server_floating_ip:
    value: { get_attr: [ my_floating_ip, floating_ip_address ] }
EOF

heat stack-create -f $PWD/testvm.stack teststack

sleep 60
. /etc/openstackquickstartrc

FLOATING_IP=$(eval echo $(heat output-show teststack server_floating_ip))
echo "FLOATING IP: $FLOATING_IP"
if [ -n "$FLOATING_IP" ]; then
    ping -c 2 $FLOATING_IP || true
    ssh -o "StrictHostKeyChecking no" $ssh_user@$FLOATING_IP curl --silent www3.zq1.de/test || exit 3
else
    echo "INSTANCE doesn't seem to be running:"
    heat resource-show teststack

    exit 1
fi
heat stack-delete teststack || :
sleep 10

for i in $(nova floating-ip-list | grep -P -o "172.31\S+"); do nova floating-ip-delete $i; done

# run tempest
if [ -e /etc/tempest/tempest.conf ]; then
    $crudini --set /etc/tempest/tempest.conf compute image_ssh_user cirros
    $crudini --set /etc/tempest/tempest.conf compute image_alt_ssh_user cirros
    $crudini --set /etc/tempest/tempest.conf compute ssh_user cirros
    $crudini --set /etc/tempest/tempest.conf compute image_ref $imgid
    $crudini --set /etc/tempest/tempest.conf compute image_ref_alt $imgid
    $crudini --set /etc/tempest/tempest.conf compute flavor_ref 42
    $crudini --set /etc/tempest/tempest.conf compute flavor_ref_alt 84

    verbose="-- -v"
    if [ -x "$(type -p testr)" ]; then
        verbose=""
    fi

    pushd /var/lib/openstack-tempest-test/
    # check that test listing works - otherwise we run 0 tests and everything seems to be fine
    # because run_tempest.sh doesn't catch the error
    if ! [ -d ".testrepository" ]; then
        testr init
    fi
    testr list-tests >/dev/null

    if tempest help cleanup; then
        tempest cleanup --init-saved-state
    else
        test -x "$(type -p tempest-cleanup)" && tempest-cleanup --init-saved-state
    fi
    ./run_tempest.sh -N -t -s $verbose 2>&1 | tee console.log
    ret=${PIPESTATUS[0]}
    if tempest help cleanup; then
        tempest cleanup
    fi
    [ $ret == 0 ] || exit 4
    popd
fi
