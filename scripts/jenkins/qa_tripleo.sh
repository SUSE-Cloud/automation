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
$zypper in diskimage-builder tripleo-image-elements

## setup some useful defaults
export NODE_ARCH=amd64
export TE_DATAFILE=~/tripleo/testenv.json

# temporary hacks delete me
$zypper -n --gpg-auto-import-keys ref
$zypper in libxslt-devel
export NODE_DIST="opensuse"
export DIB_COMMON_ELEMENTS=${DIB_COMMON_ELEMENTS:-"stackuser"}
export LIBVIRT_NIC_DRIVER=virtio

# workaround kvm bug
$zypper in kvm
sudo /sbin/udevadm control --reload-rules  || :
sudo /sbin/udevadm trigger || :

mkdir -p ~/tripleo/

if [ ! -f ~/tripleo/testenv.json ]; then
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -f "~/.ssh/id_rsa" -P ''
    fi
    cat - > ~/tripleo/testenv.json <<EOF
    {
        "node-macs": "52:54:00:07:00:01 52:54:00:07:00:02 52:54:00:07:00:03",
        "ssh-key": "$(base64 -w 0 < ~/.ssh/id_rsa)"
    }
EOF
fi

if [ ! -d ~/tripleo/tripleo-incubator ]; then
    (
        cd ~/tripleo/
        git clone git://git.openstack.org/openstack/tripleo-incubator
    )
fi

# This should be part of the devtest scripts imho, but
# currently isn't.
(
  export PATH=$PATH:~/tripleo/tripleo-incubator/scripts/

  install-dependencies

  # workaround yet another libvirt packaging bug...
  virsh net-define /usr/share/libvirt/networks/default.xml || :

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

if [ ! -d ~/tripleo/diskimage-builder ]; then
    mkdir -p ~/tripleo/diskimage-builder
    ln -s /usr/bin ~/tripleo/diskimage-builder/bin
    ln -s /usr/share/diskimage-builder/elements ~/tripleo/diskimage-builder/elements
    ln -s /usr/share/diskimage-builder/lib ~/tripleo/diskimage-builder/lib
fi

# Use tripleo-image-elements from packages

if [ ! -d ~/tripleo/tripleo-image-elements ]; then
    mkdir -p ~/tripleo/tripleo-image-elements
    ln -s /usr/bin ~/tripleo/tripleo-image-elements/bin
    ln -s /usr/share/tripleo-image-elements ~/tripleo/tripleo-image-elements/elements
fi

cd tripleo-ci

export USE_CACHE=1
export TRIPLEO_CLEANUP=0

exec ./toci_devtest.sh


