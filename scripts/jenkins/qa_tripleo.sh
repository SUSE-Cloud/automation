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

ip a|grep -q 10\.100\. && hostname=fallback.suse.cz
case "$cloudsource" in
  openstackhavana)
	$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Havana/$REPO/Cloud:OpenStack:Havana.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Havana:/Staging/$REPO/ cloudhead
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

$zypper in make patch python-PyYAML git-core busybox
$zypper in python-os-apply-config
$zypper in diskimage-builder tripleo-image-elements tripleo-heat-templates

## setup some useful defaults
export NODE_ARCH=amd64
export TE_DATAFILE=/opt/stack/new/testenv.json

# temporary hacks delete me
$zypper -n --gpg-auto-import-keys ref
export NODE_DIST="opensuse"

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
$zypper in kvm
sudo /sbin/udevadm control --reload-rules  || :
sudo /sbin/udevadm trigger || :

# worarkound libvirt packaging bug
$zypper in libvirt-daemon-driver-network
$zypper in libvirt
systemctl start libvirtd
sleep 2
virsh net-define /usr/share/libvirt/networks/default.xml || :

mkdir -p /opt/stack/new/

if [ ! -f /opt/stack/new/testenv.json ]; then
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -f ~/.ssh/id_rsa -P ''
    fi
    cat - > /opt/stack/new/testenv.json <<EOF
    {
        "node-macs": "52:54:00:07:00:01 52:54:00:07:00:02 52:54:00:07:00:03",
        "ssh-key": "$(base64 -w 0 < ~/.ssh/id_rsa)"
    }
EOF
fi

if [ ! -d /opt/stack/new/tripleo-incubator ]; then
    (
        cd /opt/stack/new/
        # ideally this one would be cloned, but it is broken atm:
        # git clone git://git.openstack.org/openstack/tripleo-incubator
        # needed for https://review.openstack.org/#/c/71265/

        git clone https://github.com/dirkmueller/tripleo-incubator.git
    )
fi

# This should be part of the devtest scripts imho, but
# currently isn't.
(
  export PATH=$PATH:/opt/stack/new/tripleo-incubator/scripts/

  install-dependencies

  cleanup-env

  setup-network
  setup-seed-vm -a $NODE_ARCH
)

# When launched interactively, break on error

if [ -t 0 ]; then
    export break=after-error
fi

# Use tripleo-ci from git

if [ ! -d tripleo-ci ]; then
    git clone git://git.openstack.org/openstack-infra/tripleo-ci
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

cd tripleo-ci

export USE_CACHE=1
export TRIPLEO_CLEANUP=0

exec ./toci_devtest.sh
