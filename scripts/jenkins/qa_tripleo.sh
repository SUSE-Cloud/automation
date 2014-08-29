#!/bin/bash

set -eux

# setup repos
VERSION=11
REPO=SLE_11_SP3
if grep "^VERSION = 1[2-4]\\.[0-5]" /etc/SuSE-release ; then
    VERSION=$(awk -e '/^VERSION = 1[2-4]\./{print $3}' /etc/SuSE-release)
    REPO=openSUSE_$VERSION
fi
hostname=dist.suse.de
zypper="zypper --non-interactive"

zypper rr cloudhead || :

$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/$REPO/ cloud || :
# no staging for master
$zypper mr --priority 22 cloud

$zypper in make patch python-PyYAML git-core busybox
$zypper in python-os-apply-config python-os-cloud-config
$zypper in diskimage-builder tripleo-image-elements tripleo-heat-templates

## setup some useful defaults
export NODE_ARCH=amd64
export TRIPLEO_TEST=undercloud
export TE_DATAFILE=/opt/stack/new/testenv.json

# temporary hacks delete me
$zypper -n --gpg-auto-import-keys ref
export NODE_DIST="opensuse"
export ZUUL_PROJECT=tripleo-incubator

use_package=1

if [ "$use_package" = "1" ]; then
    export DIB_REPOTYPE_python_ceilometerclient=package
    export DIB_REPOTYPE_python_cinderclient=package
    export DIB_REPOTYPE_python_glanceclient=package
    export DIB_REPOTYPE_python_heatclient=package
    export DIB_REPOTYPE_python_ironicclient=package
    export DIB_REPOTYPE_python_keystoneclient=package
    export DIB_REPOTYPE_python_neutronclient=package
    export DIB_REPOTYPE_python_novaclient=package
    export DIB_REPOTYPE_python_swiftclient=package

    export DIB_REPOTYPE_ceilometer=package
    export DIB_REPOTYPE_glance=package
    export DIB_REPOTYPE_heat=package
    export DIB_REPOTYPE_keystone=package
    export DIB_REPOTYPE_neutron=package
    export DIB_REPOTYPE_nova=package
    export DIB_REPOTYPE_nova_baremetal=package
    export DIB_REPOTYPE_swift=package
fi

export DIB_COMMON_ELEMENTS=${DIB_COMMON_ELEMENTS:-"stackuser"}
export LIBVIRT_NIC_DRIVER=virtio

# workaround kvm packaging bug
$zypper in kvm sudo
sudo /sbin/udevadm control --reload-rules  || :
sudo /sbin/udevadm trigger || :

# workaround libvirt packaging bug
$zypper in libvirt-daemon-driver-network
$zypper in libvirt
systemctl start libvirtd
usermod -a -G libvirt root

# workaround another packaging bug
virsh net-define /usr/share/libvirt/networks/default.xml || :

mkdir -p /opt/stack/new/

# ARGGGGH HATE!!! We use packages!
pushd /opt/stack/new
[ -d heat ] || git clone git://git.openstack.org/openstack/heat
popd

if [ ! -d /opt/stack/new/tripleo-incubator ]; then
    (
        cd /opt/stack/new/
        git clone git://git.openstack.org/openstack/tripleo-incubator

        # TEMP DELETE me (https://review.openstack.org/#/c/117554/)
        pushd tripleo-incubator
        # base64 encoded to avoid stupid Bash8 failures
        base64 -d > diff << EOF
Y29tbWl0IDQzMDJkMzljNmExNzcwMWJjOGRjYjA4MDIxMjE4YWNkMzI4ZWZkYjkKQXV0aG9yOiBE
aXJrIE11ZWxsZXIgPGRpcmtAZG1sbHIuZGU+CkRhdGU6ICAgVGh1IEF1ZyAyOCAxODoxNDoxNSAy
MDE0ICswMjAwCgogICAgRml4IExJQlZJUlREX0dST1VQIGZvciBvcGVuc3VzZQogICAgCiAgICBv
cGVuc3VzZSBpcyBzaW1pbGFyIHRvIHN1c2UgYW5kIGFsc28gaGFzIGxpYnZpcnQgYXMgZ3JvdXAK
ICAgIG5hbWUuIEFkanVzdCBjYXNlLgogICAgCiAgICBDaGFuZ2UtSWQ6IEljYzUxYjJmMjZkNDRm
YmQ2YzAwODMxODkwOTNhNjViNjIxNzc3MzM5CgpkaWZmIC0tZ2l0IGEvc2NyaXB0cy9zZXQtdXNl
cmdyb3VwLW1lbWJlcnNoaXAgYi9zY3JpcHRzL3NldC11c2VyZ3JvdXAtbWVtYmVyc2hpcAppbmRl
eCA3NWM1ZWNiLi41ZGVhOTVkIDEwMDc1NQotLS0gYS9zY3JpcHRzL3NldC11c2VyZ3JvdXAtbWVt
YmVyc2hpcAorKysgYi9zY3JpcHRzL3NldC11c2VyZ3JvdXAtbWVtYmVyc2hpcApAQCAtMyw3ICsz
LDcgQEAgc2V0IC1ldQogCiAjIGxpYnZpcnRkIGdyb3VwCiBjYXNlICIkVFJJUExFT19PU19ESVNU
Uk8iIGluCi0gICAgJ2RlYmlhbicgfCAnc3VzZScpCisgICAgJ2RlYmlhbicgfCAnb3BlbnN1c2Un
IHwgJ3N1c2UnKQogICAgICAgICBMSUJWSVJURF9HUk9VUD0nbGlidmlydCcKICAgICAgICAgOzsK
ICAgICAqKQo=
EOF
        patch -p1 < diff
        rm -f diff
    )
fi


if [ ! -f $TE_DATAFILE ]; then
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -f ~/.ssh/id_rsa -P ''
    fi
    # create intial datafile
    cat - > /opt/stack/new/testenv.json <<EOF
    {
        "host-ip": "192.168.122.1",
        "seed-ip": "192.0.2.1",
        "seed-route-dev": "virbr0",
        "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
        "ssh-user": "root",
        "env-num": "2",
        "arch": "amd64",
        "node-cpu": "1",
        "node-mem": "2048",
        "node-disk": "20",
        "ssh-key": "$(python -c 'print open("/root/.ssh/id_rsa").read().replace("\n", "\\n")')"
    }
EOF

    # This should be part of the devtest scripts imho, but
    # currently isn't.
    (
        export PATH=$PATH:/opt/stack/new/tripleo-incubator/scripts/

        .  /opt/stack/new/tripleo-incubator/scripts/set-os-type

        install-dependencies

        cleanup-env

        setup-network

        setup-seed-vm -a $NODE_ARCH

        # create-nodes changes the datafile and add a "nodes" list
        create-nodes 1 2048 20 amd64 4 brbm 192.168.122.1 $TE_DATAFILE
    )
fi

# When launched interactively, break on error

if [ -t 0 ]; then
    export break=after-error
fi

# Use tripleo-ci from git

if [ ! -d /opt/stack/new/tripleo-ci ]; then
    git clone git://git.openstack.org/openstack-infra/tripleo-ci /opt/stack/new/tripleo-ci
fi

# Use diskimage-builder from packages

if [ ! -d /opt/stack/new/diskimage-builder ]; then
    mkdir -p /opt/stack/new/diskimage-builder
    ln -s /usr/bin /opt/stack/new/diskimage-builder/bin
    ln -s /usr/share/diskimage-builder/elements /opt/stack/new/diskimage-builder/elements
    ln -s /usr/share/diskimage-builder/lib /opt/stack/new/diskimage-builder/lib
fi

# Use tripleo-image-elements from packages

if [ ! -d /opt/stack/new/tripleo-image-elements ]; then
    mkdir -p /opt/stack/new/tripleo-image-elements
    ln -s /usr/bin /opt/stack/new/tripleo-image-elements/bin
    ln -s /usr/share/tripleo-image-elements /opt/stack/new/tripleo-image-elements/elements
fi

# Use tripleo-heat-templates from packages

if [ ! -d /opt/stack/new/tripleo-heat-templates ]; then
    git clone git://git.openstack.org/openstack/tripleo-heat-templates /opt/stack/new/tripleo-heat-templates
fi

cd /opt/stack/new/tripleo-ci

export USE_CACHE=1
export TRIPLEO_CLEANUP=0

usermod -a -G libvirt root

exec su -c "./toci_devtest.sh"
