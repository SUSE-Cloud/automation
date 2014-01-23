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

$zypper -n --gpg-auto-import-keys ref
$zypper in python-keystoneclient make patch python-PyYAML git-core busybox libvirt-client
$zypper in libvirt-daemon-driver-network python-os-apply-config

# Setup default.xml.. somehow we need this
virsh net-define /usr/share/libvirt/networks/default.xml || :

# Clean up from previous run
rm -rf /tmp/toci*

## setup some useful defaults
export NODE_ARCH=amd64
export TE_DATAFILE=~/tripleo/testenv.json

export http_proxy=http://proxy.suse.de:3128/

mkdir -p ~/tripleo/

if [ ! -f ~/tripleo/testenv.json ]; then
    ssh-keygen -f "private" -P ''
    cat - > ~/tripleo/testenv.json <<EOF
    {
        "ssh-key": "$(base64 -w 0 < private)"
    }
EOF
    rm -f private*
fi

if [ ! -d ~/tripleo/tripleo-incubator ]; then
    (
        cd ~/tripleo/
        git clone git://git.openstack.org/openstack/tripleo-incubator
    )
fi

if [ ! -d tripleo-ci ]; then
    git clone git://git.openstack.org/openstack-infra/tripleo-ci
fi

cd tripleo-ci

exec ./toci_devtest.sh


