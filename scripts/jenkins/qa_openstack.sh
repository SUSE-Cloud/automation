#!/bin/sh
# usage:
# curl http://openqa.suse.de/sle/qatests/qa_openstack.sh | sh -x
# needs 2.1GB space for /var/lib/{glance,nova}
interfaces="eth0 br0"
export MODE=kvm
# nested virt is awfully slow, so we do:
MODE=lxc
if ! grep -q -e vmx -e svm /proc/cpuinfo ; then
	MODE=lxc
fi
ARCH=$(uname -i)

ifconfig | grep inet

# setup optional extra disk
dev=/dev/vdb
if ! test -e $dev && file -s /dev/sdb|grep -q "ext3 filesystem data" ; then
    dev=/dev/sdb
fi
if test -e $dev ; then #&& file -s $dev | grep -q "/dev/vdb: data" ; then
    file -s $dev | grep -q "ext3 filesystem" || mkfs.ext3 $dev
    mount $dev /mnt/
    cp -a /var/lib/* /mnt/
    mount --make-private /
    mount --move /mnt /var/lib
    echo $dev /var/lib ext3 noatime,barrier=0,data=writeback 2 1 >> /etc/fstab
fi
mount -o remount,noatime,barrier=0 /

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
  develcloud1.0)
	REPO=SLE_11_SP2
	$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/1.0/$REPO/Devel:Cloud:1.0.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/1.0:/OpenStack/$REPO/ cloudhead
	fi
  ;;
  develcloud2.0)
	$zypper ar -G -f http://clouddata.cloud.suse.de/repos/SUSE-Cloud-2.0/ cloud2iso
	$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/2.0/$REPO/Devel:Cloud:2.0.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/2.0:/Staging/$REPO/ cloudhead
	fi
  ;;
  develcloud3)
	$zypper ar -G -f http://clouddata.cloud.suse.de/repos/SUSE-Cloud-3/ cloud3iso
	$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/3/$REPO/Devel:Cloud:3.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/3:/Staging/$REPO/ cloudhead
	fi
  ;;
  develcloud)
	$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud/$REPO/Devel:Cloud.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://dist.suse.de/ibs/Devel:/Cloud:/Head/$REPO/ cloudhead
	fi
  ;;
  openstackessex)
	$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Essex/$REPO/Cloud:OpenStack:Essex.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Essex:/Staging/$REPO/ cloudhead
	fi
  ;;
  openstackfolsom)
	$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Folsom/$REPO/Cloud:OpenStack:Folsom.repo ||:
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Folsom:/Staging/$REPO/ cloudhead || :
	fi
  ;;
  openstackgrizzly)
	$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Grizzly/$REPO/Cloud:OpenStack:Grizzly.repo
	if test -n "$OSHEAD" ; then
		$zypper ar -G -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Grizzly:/Staging/$REPO/ cloudhead
	fi
  ;;
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

# install maintenance updates
# run twice, first installs zypper update, then the rest
$zypper -n patch --skip-interactive || $zypper -n patch --skip-interactive

# grizzly or master does not want dlp
if [ "$cloudsource" == "develcloud1.0" -o "$cloudsource" == "develcloud" ]; then
    if [ $VERSION = 12.2 ] ; then
        $zypper ar http://download.opensuse.org/repositories/devel:/languages:/python/$REPO/ dlp
        $zypper ar http://download.opensuse.org/repositories/Virtualization:/openSUSE12.2/openSUSE_12.2/Virtualization:openSUSE12.2.repo # workaround https://bugzilla.novell.com/793900
    fi
    $zypper mr --priority 200 dlp
else
    $zypper rr dlp || true
fi

$zypper rr Virtualization_Cloud # repo was dropped but is still in some images for cloud-init
$zypper --gpg-auto-import-keys -n ref

case "$cloudsource" in
  develcloud1*|openstackessex|openstackfolsom)
        cn=""
        tempest=""
  ;;
  develcloud2.0|develcloud3)
        cn="cloud_network"
        tempest=""
  ;;

  *)
        cn="cloud_network"
        tempest="openstack-tempest-test"
  ;;
esac

# deinstall some leftover crap from the cleanvm
$zypper -n rm --force 'python-cheetah < 2.4'

# Everything below here is fatal
set -e

# start with patterns
$zypper -n install -t pattern cloud_controller cloud_compute $cn
$zypper -n install --force openstack-quickstart $tempest

# test -e /tmp/openstack-quickstart-demosetup && mv /tmp/openstack-quickstart-demosetup /usr/sbin/openstack-quickstart-demosetup

crudini=crudini
test -z "$(type -p crudini 2>/dev/null)" && crudini="openstack-config"

if ! rpm -q openstack-neutron-server && ! rpm -q openstack-quantum-server; then
# setup non-bridged network:
cat >/etc/sysconfig/network/ifcfg-brclean <<EOF
BOOTPROTO='static'
BRIDGE='yes'
BRIDGE_FORWARDDELAY='0'
BRIDGE_PORTS=''
BRIDGE_STP='off'
BROADCAST=''
ETHTOOL_OPTIONS=''
IPADDR='10.10.134.17/29'
MTU=''
NETMASK=''
NETWORK=''
REMOTE_IPADDR=''
STARTMODE='auto'
USERCONTROL='no'
NAME=''
EOF
ifup brclean
fi

for i in $interfaces ; do
	IP=$(ip a show dev $i|perl -ne 'm/inet ([0-9.]+)/ && print $1')
	[ -n "$IP" ] && break
done
if [ -n "$IP" ] ; then
	sed -i -e s/127.0.0.1/$IP/ /etc/openstackquickstartrc
fi
if [ -n "$tempest" ]; then
    sed -i -e "s/with_tempest=no/with_tempest=yes/" /etc/openstackquickstartrc
fi
sed -i -e "s/with_horizon=yes/with_horizon=no/" /etc/openstackquickstartrc
sed -i -e s/br0/brclean/ /etc/openstackquickstartrc
unset http_proxy
openstack-quickstart-demosetup

if [ "$(uname -r  | cut -d. -f2)" -ge 10 ]; then
    echo "APPLYING HORRIBLE HACK PLEASE REMOVE"
    # needs to be ported from Nova Network
    # workaround broken debian-5 image, see https://bugzilla.redhat.com/show_bug.cgi?id=910619
    iptables -t mangle -A POSTROUTING -p udp --dport bootpc -j CHECKSUM  --checksum-fill
fi

sed -i -e s/br0/brclean/ /etc/nova/nova.conf
echo --bridge_interface=brclean >> /etc/nova/nova.conf
echo --vncserver_listen=0.0.0.0 >> /etc/nova/nova.conf ; /etc/init.d/openstack-nova-compute restart

ps ax
. /etc/bash.bashrc.local
# enable forwarding
( cd /proc/sys/net/ipv4/conf/all/ ; echo 1 > forwarding ; echo 1 > proxy_arp )

nova flavor-delete smaller || :
nova flavor-create smaller --ephemeral 20 12 768 0 1
#nova flavor-create smaller --ephemeral 20 12 1536 0 1 # for host

if [ "$cloudsource" == "develcloud1.0" -o "$cloudsource" == "develcloud" -o "$cloudsource" == "openstackessex" ]; then
    # nova-volume
    nova volume-create 1 ; sleep 2
    nova volume-list
    NOVA_FLAVOR="12"
else
    # cinder
    cinder create 1 ; sleep 5
    cinder list
    NOVA_FLAVOR="12"
fi
test "$(lvs | wc -l)" -gt 1 || exit 1

if [ "$MODE" = xen ] ; then
	glance image-create --is-public=True --disk-format=qcow2 --container-format=bare --name jeos-64-pv --copy-from http://clouddata.cloud.suse.de/images/jeos-64-pv.qcow2
	glance image-create --is-public=True --disk-format=aki --container-format=aki --name=debian-kernel < xen-kernel/vmlinuz-2.6.24-19-xen
	glance image-create --is-public=True --disk-format=ari --container-format=ari --name=debian-initrd < xen-kernel/initrd.img-2.6.24-19-xen
	glance image-create --is-public=True --disk-format=ami --container-format=ami --name=debian-5 --property vm_mode=xen ramdisk_id=f663eb9a-986b-466f-bd3e-f0aa2c847eef kernel_id=d654691a-0135-4f6d-9a60-536cf534b284 < debian.5-0.x86.img
fi
if [ "$MODE" != lxc ] ; then
	#curl http://openqa.suse.de/openqa/img/openSUSE_11.4_JeOS.i686-0.0.1.raw.gz | gzip -cd | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
	#curl http://openqa.suse.de/openqa/img/openSUSE_12.1_jeos.vmdk.gz | gzip -cd | glance add name="debian-5" is_public=True disk_format=vmdk container_format=bare
	glance image-create --name="debian-5" --is-public=True --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SP2-64up.qcow2
#	curl http://openqa.opensuse.org/openqa/img/openSUSE-12.2-Beta2.img.gz | gzip -cd | glance add name="12.2b2-mini" is_public=True disk_format=raw container_format=bare
#	curl http://openqa.suse.de/openqa/img/SP2-64-HA.img.gz | gzip -cd | glance add name="SP2-64-HA" is_public=True disk_format=raw container_format=bare
#	curl http://openqa.suse.de/openqa/img/SP2-64up.img.gz | gzip -cd | glance add name="SP2-64up" is_public=True disk_format=raw container_format=bare
#	curl http://clouddata.cloud.suse.de/images/SP2-64up.qcow2 | glance add name="SP2-64up" is_public=True disk_format=qcow2 container_format=bare
#	curl http://openqa.suse.de/openqa/img/SP1-32-GM.img.gz | gzip -cd | glance add name="SP2-32" is_public=True disk_format=raw container_format=bare
else
	 glance image-create --name="debian-5" --is-public=True --disk-format=ami --container-format=ami --copy-from http://openqa.opensuse.org/openqa/img/debian.5-0.x86.qcow2
	#curl http://clouddata.cloud.suse.de/images/euca-debian-5.0-i386.tar.gz | tar xzO euca-debian-5.0-i386/debian.5-0.x86.img | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
	#curl http://openqa.suse.de/openqa/img/euca-debian-5.0-i386.tar.gz | tar xzO euca-debian-5.0-i386/debian.5-0.x86.img | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
fi
for i in $(seq 1 20) ; do # wait for image to finish uploading
	glance image-list|grep active && break
	sleep 5
done
glance image-list
imgid=$(glance image-list|grep debian-5|cut -f2 -d" ")
mkdir -p ~/.ssh
( umask 77 ; nova keypair-add testkey > ~/.ssh/id_rsa )

nova boot --flavor $NOVA_FLAVOR --image $imgid --key_name testkey testvm | tee boot.out
instanceid=`perl -ne 'm/ id [ |]*([0-9a-f-]+)/ && print $1' boot.out`
nova list
sleep 30
n=30 ; rm -f /tmp/du.old /tmp/du
if [ "$NONINTERACTIVE" != "0" ] ; then
	while test $n -gt 0 && ! du -s /var/lib/nova/instances/* | diff /tmp/du.old - ; do n=$(expr $n - 1) ; du -s /var/lib/nova/instances/* > /tmp/du.old ; sleep 35 ; done # used by non-interactive jenkins test
else
	watch --no-title "du -s /var/lib/nova/instances/*" # will have stillimage when done
fi
#nova volume-attach $instanceid 1 /dev/vdb # only for qemu/kvm
pstree|grep -A5 lxc || :
virsh --connect lxc:/// list || :
. /etc/openstackquickstartrc
vmip=`nova show testvm|perl -ne 'm/network\D*(\d+\.\d+\.\d+\.\d+)/ && print $1'`
echo "VM IP: $vmip"
if [ -n "$vmip" ]; then
    ping -c 2 $vmip || true
    ssh -o "StrictHostKeyChecking no" root@$vmip curl --silent www3.zq1.de/test.txt || exit 3
else
    echo "INSTANCE doesn't seem to be running:"
    nova show testvm

    exit 1
fi
nova delete testvm || :

# run tempest
if true && [ -e /etc/tempest/tempest.conf ]; then
    $crudini --set /etc/tempest/tempest.conf compute image_ref $imgid
    $crudini --set /etc/tempest/tempest.conf compute image_ref_alt $imgid

    pushd /var/lib/openstack-tempest-test/
        ./run_tests.sh  -N -s || :
    popd
fi
