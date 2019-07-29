#!/bin/bash
# usage:
# curl http://openqa.suse.de/sle/qatests/qa_openstack.sh | sh -x
# needs 2.1GB space for /var/lib/{glance,nova}

if [[ $debug_openstack = 1 ]] ; then
    set -x
    PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

: ${MODE:=kvm}
ARCH=$(uname -i)
# Default is one mirror we know is updated fast enough instead of the
# redirector because some mirrors lag and cause a checksum mismatch for rpms
# that keep name and size and only change content.
: ${repomirror:=http://downloadcontent.opensuse.org}
: ${imagemirror:=http://149.44.161.38/images} # ci1-opensuse
: ${cirros_base_url:="$imagemirror"} # could also be "http://download.cirros-cloud.net/0.4.0/"
cloudopenstackmirror=$repomirror/repositories/Cloud:/OpenStack:
# if set to something, skip the base operating system repository setup
: ${skip_reposetup:""}

ip a

# setup optional extra disk for cinder-volumes
: ${dev_cinder:=/dev/vdb}
if ! test -e $dev_cinder ; then
    # maybe we run under xen
    dev_cinder=/dev/xvdb
    if ! test -e $dev_cinder && file -s /dev/sdb|grep -q "ext3 filesystem data" ; then
        dev_cinder=/dev/sdb
    fi
fi
if [ -e $dev_cinder ]; then
    # CINDER_VOLUMES_DEV is evaulated by openstack-loopback-lvm
    # from openstack-quickstart to create the VG
    export CINDER_VOLUMES_DEV=$dev_cinder
fi

# setup optional extra disk for manila-shares
: ${dev_manila:=/dev/vdc}
if ! test -e $dev_manila ; then
    # maybe we run under xen
    dev_manila=/dev/xvdc

    if ! test -e $dev_manila && file -s /dev/sdc|grep -q "ext3 filesystem data" ; then
        dev_manila=/dev/sdc
    fi
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

function addslesrepos {
    case "$VERSION" in
    12.*)
        $zypper ar "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Products/SLE-SERVER/$REPOVER/x86_64/product/" SLES$VERSION-Pool
        $zypper ar --refresh "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Updates/SLE-SERVER/$REPOVER/x86_64/update/" SLES$VERSION-Updates
        ;;
    *)
        for prod in SLE-Product-SLES SLE-Module-Basesystem SLE-Module-Legacy SLE-Module-Development-Tools SLE-Module-Server-Applications; do
            $zypper ar "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Products/$prod/$REPOVER/x86_64/product/" $prod-$VERSION-Pool
            $zypper ar --refresh "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Updates/$prod/$REPOVER/x86_64/update/" $prod-$VERSION-Updates
        done
        ;;
    esac

    case "$VERSION" in
        "12.2")
            $zypper ar --refresh "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Updates/SLE-SERVER/$REPOVER-LTSS/x86_64/update/" SLES$VERSION-LTSS-Updates
            ;;
    esac
}

function addopensuseleaprepos {
    $zypper ar "$repomirror/distribution/leap/$VERSION/repo/oss/" Leap-$VERSION-oss
    $zypper ar --refresh "$repomirror/update/leap/$VERSION/oss/" Leap-$VERSION-oss-update
}

# setup repos
VERSION=11
REPO=SLE_11_SP3

if [ -f "/etc/os-release" ]; then
    VERSION=$(get_dist_version)
    DIST_NAME=$(get_dist_name)

    case "$DIST_NAME" in
        "SLES")
            IFS=. read major minor <<< $VERSION
            # SLE15 do not have a minor version (SP1 will have then)
            # /etc/os-release contains: VERSION="15"
            if [ -z "$minor" ]; then
                REPO="SLE_${major}"
                REPOVER="${major}"
            else
                REPO="SLE_${major}_SP${minor}"
                REPOVER="${major}-SP${minor}"
            fi
            # FIXME for SLE15 to not have SP0
            addrepofunc=addslesrepos
        ;;
        "openSUSE Leap")
            REPO="openSUSE_Leap_${VERSION}"
            addrepofunc=addopensuseleaprepos
        ;;
        *)
            echo "Switch to a useful distribution!"
            exit 1
            ;;
    esac
else
    echo unsupported OS
    exit 54
fi

zypper="zypper --non-interactive"

if test -n "$allow_vendor_change" ; then
    # Allow vendor change for packages that may already be installed on the image
    # but have a newer version in Cloud:OpenStack:*
    # (without a vendor change this scenario would cause zypper to stall deployment
    # with a prompt)
    echo 'solver.allowVendorChange = true' >> /etc/zypp/zypp.conf
fi

zypper rr cloudhead || :

case "$cloudsource" in
    openstackmaster)
        $zypper ar -G -f $cloudopenstackmirror/Master/$REPO/ cloud || :
        # no staging for master
        $zypper mr --priority 22 cloud
    ;;
    openstack?*)
        osrelease=${cloudsource#openstack}
        osrelease=${osrelease^}
        $zypper ar -G -f $cloudopenstackmirror/$osrelease/$REPO/ cloud
        if test -n "$OSHEAD" ; then
            if [[ "$osrelease" =~ (Rocky|Stein) ]]; then
                $zypper ar -G -f $cloudopenstackmirror/$osrelease:/ToTest/$REPO/ cloudhead
            else
                $zypper ar -G -f $cloudopenstackmirror/$osrelease:/Staging/$REPO/ cloudhead
            fi
        fi
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

if [ -z "$skip_reposetup" ]; then
    $addrepofunc
fi

# grizzly or master does not want dlp
$zypper rr dlp || true

$zypper rr Virtualization_Cloud # repo was dropped but is still in some images for cloud-init
$zypper --gpg-auto-import-keys -n ref

# install maintenance updates
# run twice, first installs zypper update, then the rest
$zypper -n patch --skip-interactive || $zypper -n patch --skip-interactive

# wickedd needs to be configured properly to avoid overriding
# the hostname (see <https://bugzilla.opensuse.org/show_bug.cgi?id=974661>).
sed -i -e "s/DHCLIENT_SET_HOSTNAME=\"yes\"/DHCLIENT_SET_HOSTNAME=\"no\"/" /etc/sysconfig/network/dhcp
sed -i -e "s/DHCLIENT6_SET_HOSTNAME=\"yes\"/DHCLIENT6_SET_HOSTNAME=\"no\"/" /etc/sysconfig/network/dhcp

# Make sure the machine's host name is resolvable
echo $(ip addr sh eth0 | grep -w inet | awk '{print $2}' | sed 's#/.*##') $(hostnamectl --static) $(hostnamectl --transient) >> /etc/hosts

# This is to reapply the config to wickedd
ifup all

# install some basics (which is i.e. not installed in the SLE12SP1 JeOS
$zypper -n in wget

# Everything below here is fatal
set -e

if [ -n "$QUICKSTART_DEBUG" ]; then
    # when debugging, allow using a high-prio repo
    if [ -n "$cloudsource_extra" ]; then
        $zypper ar $cloudsource_extra cloudextra
        $zypper mr --priority 5 cloudextra
        echo "WARN: using extra repo $cloudsource_extra"
    fi
fi

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
sed -i -e "s/with_barbican=no/with_barbican=yes/" /etc/openstackquickstartrc
sed -i -e "s/with_sahara=no/with_sahara=yes/" /etc/openstackquickstartrc
sed -i -e "s/with_designate=no/with_designate=yes/" /etc/openstackquickstartrc
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
nova flavor-create $NOVA_FLAVOR 42 128 1 1
nova flavor-delete m1.micro || :
nova flavor-create m1.micro 84 256 1 1

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
cirros_base_name="cirros-0.4.0-x86_64"

GC_IMAGE_CREATE="glance image-create --progress --visibility=public"

case "$MODE" in
    xen)
        $GC_IMAGE_CREATE --disk-format=qcow2 --container-format=bare --name jeos-64-pv --copy-from http://clouddata.cloud.suse.de/images/jeos-64-pv.qcow2
        $GC_IMAGE_CREATE --disk-format=aki --container-format=aki --name=debian-kernel < xen-kernel/vmlinuz-2.6.24-19-xen
        $GC_IMAGE_CREATE --disk-format=ari --container-format=ari --name=debian-initrd < xen-kernel/initrd.img-2.6.24-19-xen
        $GC_IMAGE_CREATE --disk-format=ami --container-format=ami --name=debian-5 --property vm_mode=xen ramdisk_id=f663eb9a-986b-466f-bd3e-f0aa2c847eef kernel_id=d654691a-0135-4f6d-9a60-536cf534b284 < debian.5-0.x86.img
    ;;
    lxc)
        $GC_IMAGE_CREATE --name="debian-5" --disk-format=ami --container-format=ami --copy-from $imagemirror/debian.5-0.x86.qcow2
    ;;
    *)
        wget --timeout=20 $cirros_base_url/$cirros_base_name-uec.tar.gz
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

if [ -f ~/.ssh/id_rsa.pub ]; then
    nova keypair-add --pub-key ~/.ssh/id_rsa.pub testkey
else
    ( umask 077; mkdir -p ~/.ssh; nova keypair-add testkey > ~/.ssh/id_rsa; )
fi

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

use_openstack_floating=1
# older versions don't have a fully working openstackclient for FIPs
case "$cloudsource" in
    openstacknewton|openstackocata)
        use_openstack_floating=
    ;;
esac

openstack stack create -t $(readlink -e $PWD/testvm.stack) teststack

sleep 60

. /etc/openstackquickstartrc

if [ "$with_barbican" = "yes" ] ; then
    # Check basic Barbican API functionality
    openstack secret list
fi

FLOATING_IP=$(openstack stack output show teststack server_floating_ip -f value -c output_value)
echo "FLOATING IP: $FLOATING_IP"
if [ -n "$FLOATING_IP" ]; then
    ping -c 2 $FLOATING_IP || true

    # scientifically correct amount of sleeping
    sleep 60
    ssh -o "StrictHostKeyChecking no" $ssh_user@$FLOATING_IP curl --silent www3.zq1.de/test || exit 3
else
    echo "INSTANCE doesn't seem to be running:"
    openstack stack resource show teststack

    exit 1
fi

openstack stack delete --yes teststack || openstack stack delete teststack || :

sleep 10

if [[ $use_openstack_floating = 1 ]]; then
    for fip in $(openstack floating ip list -f value -c 'Floating IP Address'); do openstack floating ip delete $fip; done
else
    for i in $(nova floating-ip-list | grep -P -o "172.31\S+"); do nova floating-ip-delete $i; done
fi

echo "Tempest.."

# run tempest
if [ -e /etc/tempest/tempest.conf ]; then
    $crudini --set /etc/tempest/tempest.conf compute image_ref $imgid
    $crudini --set /etc/tempest/tempest.conf compute image_ref_alt $imgid
    $crudini --set /etc/tempest/tempest.conf compute flavor_ref 42
    $crudini --set /etc/tempest/tempest.conf compute flavor_ref_alt 84
    $crudini --set /etc/tempest/tempest.conf validation image_ssh_user cirros

    verbose="-- -v"
    if [ -x "$(type -p testr)" ]; then
        verbose=""
    fi

    pushd /var/lib/openstack-tempest-test/

    blacklistoptions=

    # Handle OpenStack release specific blacklisting of known to fail tests
    # NOTE: Currently blacklisting only required for OpenStack Rocky which
    # is stestr based, so only add blacklisting options to stestr and tempest
    # command runs below.
    case "${cloudsource}" in
    openstackrocky)
        # TODO(fmccarthy): Remove once we have addressed issues causing
        # failures for the neutron_tempest_plugin tests (SCRD-8681)
        tee -a tempest-blacklist.txt << __EOF__
# Blacklist the tests matching the pattern: neutron_tempest_plugin\.api\.admin\.test_tag\.Tag(Filter|)(QosPolicy|Trunk)TestJSON
#neutron_tempest_plugin.api.admin.test_tag.TagFilterQosPolicyTestJSON.test_filter_qos_policy_tags
id-c2f9a6ae-2529-4cb9-a44b-b16f8ba27832
#neutron_tempest_plugin.api.admin.test_tag.TagQosPolicyTestJSON.test_qos_policy_tags
id-e9bac15e-c8bc-4317-8295-4bf1d8d522b8
#neutron_tempest_plugin.api.admin.test_tag.TagTrunkTestJSON.test_trunk_tags
id-4c63708b-c4c3-407c-8101-7a9593882f5f
#neutron_tempest_plugin.api.admin.test_tag.TagFilterTrunkTestJSON.test_filter_trunk_tags
id-3fb3ca3a-8e3a-4565-ba73-16413d445e25
__EOF__
        blacklistoptions="--blacklist-file tempest-blacklist.txt"
        ;;
    esac

    # check that test listing works - otherwise we run 0 tests and everything seems to be fine
    # because run_tempest.sh doesn't catch the error
    if [ -f ".testr.conf" ]; then
        if ! [ -d ".testrepository" ]; then
            testr init
        fi
        testr list-tests >/dev/null
    elif [ -f ".stestr.conf" ]; then
        if ! [ -d ".stestr" ]; then
            stestr init
        fi
        stestr list >/dev/null
    else
        echo "No .testr.conf or .stestr.conf in $(pwd)"
        exit 5
    fi

    if tempest help cleanup; then
        tempest cleanup --init-saved-state
    else
        test -x "$(type -p tempest-cleanup)" && tempest-cleanup --init-saved-state
    fi

    if tempest help run; then
        tempest run -t -s $blacklistoptions 2>&1 | tee console.log
    else
        # run_tempest.sh is no longer available since tempest 16 (~ since Pike)
        ./run_tempest.sh -N -t -s $verbose 2>&1 | tee console.log
    fi
    ret=${PIPESTATUS[0]}
    if tempest help cleanup; then
        tempest cleanup
    fi
    [ $ret == 0 ] || exit 4
    popd
fi

echo "SUCCESS."
