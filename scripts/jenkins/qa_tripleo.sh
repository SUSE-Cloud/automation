#!/bin/bash

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

# when using OSHEAD, dup from there
if [ -n "$OSHEAD" ]; then
    $zypper dup --from cloudhead
    # use high prio so that packages will be preferred from here over Devel:Cloud
    $zypper mr --priority 42 cloudhead
fi
if [ $VERSION = 11 ] ; then

  if [ "$cloudsource" == "develcloud1.0" -o "$cloudsource" == "develcloud" ]; then
      $zypper ar http://dist.suse.de/install/SLP/SLE-11-SP2-CLOUD-GM/x86_64/DVD1/ CloudProduct
      $zypper ar http://download.nue.suse.com/ibs/SUSE:/SLE-11-SP2:/Update:/Products:/Test/standard/SUSE:SLE-11-SP2:Update:Products:Test.repo
  else
      $zypper rr CloudProduct || true
      $zypper rr SUSE_SLE-11-SP2_Update_Products_Test || true
  fi
  if [ "$REPO" = SLE_11_SP2 ] ; then
    $zypper ar http://$hostname/install/SLP/SLES-11-SP2-LATEST/$ARCH/DVD1/ SLES-11-SP2-LATEST
    $zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP1/ SP1up # for python268
    $zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP2/ SP2up
    $zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP2-CORE/ SP2core
  fi

  if [ "$REPO" = SLE_11_SP3 ] ; then
    $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SLES11-SP3-Pool/sle-11-x86_64/' SP3Pool
  fi
fi


$zypper -n --gpg-auto-import-keys ref
$zypper in python-keystoneclient make patch python-PyYAML git-core busybox libvirt-client
$zypper in libvirt-daemon-driver-network

# Setup default.xml.. somehow we need this
virsh net-define /usr/share/libvirt/networks/default.xml

# Clean up from previous run
rm -rf /tmp/toci*

echo "{}" > /tmp/datafile
export TE_DATAFILE=/tmp/datafile

## setup some useful defaults
export TOCI_ARCH=x86_64

export NODE_DIST="opensuse"

if [ ! -d tripleo-ci ]; then
    git clone git://git.openstack.org/openstack-infra/tripleo-ci
fi

cd tripleo-ci

export http_proxy=http://proxy.suse.de:3128/

# Apply seed-stack-config.json
sed -i -e "s,\"i386\",\"$ARCH\"," /opt/toci/tripleo-image-elements/elements/seed-stack-config/config.json

exec ./toci.sh


