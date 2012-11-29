#!/bin/sh
# usage:
# curl http://openqa.suse.de/sle/qatests/qa_openstack.sh | sh -x
# needs 2.1GB space for /var/lib/{glance,nova}
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
if test -e $dev ; then #&& file -s $dev | grep -q "/dev/vdb: data" ; then
	mkfs.ext3 $dev
	mount $dev /mnt/ ; mv /var/lib/* /mnt/ ; mount --move /mnt /var/lib
	echo $dev /var/lib ext3 noatime,barrier=0,data=writeback 2 1 >> /etc/fstab
fi
mount -o remount,noatime,barrier=0 /

# setup repos
VERSION=11
REPO=SLE_11_SP2
if grep "VERSION = 12.2" /etc/SuSE-release ; then
  VERSION=12.2
  REPO=openSUSE_12.2
fi
hostname=dist.suse.de
ip a|grep -q 10\.100\. && hostname=fallback.suse.cz
if [ "$cloudsource" = develcloud1.0 ] ; then
	zypper ar http://dist.suse.de/ibs/Devel:/Cloud:/1.0/$REPO/Devel:Cloud:1.0.repo
	if test -n "$OSHEAD" ; then
		zypper ar http://dist.suse.de/ibs/Devel:/Cloud:/1.0:/OpenStack/$REPO/ cloudhead
	fi
else
	zypper ar http://dist.suse.de/ibs/Devel:/Cloud/$REPO/Devel:Cloud.repo
	if test -n "$OSHEAD" ; then
		zypper ar http://dist.suse.de/ibs/Devel:/Cloud:/Head/$REPO/ cloudhead
	fi
fi
# use high prio so that packages will be preferred from here over Devel:Cloud
zypper mr --priority 42 cloudhead
if [ $VERSION = 11 ] ; then
  zypper ar http://$hostname/install/SLP/SLES-11-SP2-LATEST/$ARCH/DVD1/ SLES-11-SP2-LATEST
  #zypper ar 'http://smt.suse.de/repo/$RCE/SLES11-SP1-Updates/sle-11-x86_64/' sp1up
  #zypper ar 'http://smt.suse.de/repo/$RCE/SLES11-SP2-Updates/sle-11-x86_64/' sp2up
  zypper ar http://dist.suse.de/install/SLP/SLE-11-SP2-CLOUD-GM/x86_64/DVD1/ CloudProduct
  zypper ar http://download.nue.suse.com/ibs/SUSE:/SLE-11-SP2:/Update:/Products:/Test/standard/SUSE:SLE-11-SP2:Update:Products:Test.repo
  zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP1/ SP1up # for python268
  zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP2/ SP2up
  zypper ar http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/$ARCH/update/SLE-SERVER/11-SP2-CORE/ SP2core
fi

#zypper ar http://$hostname/install/SLP/SLE-11-SP2-SDK-LATEST/$ARCH/DVD1/ SLE-11-SDK-SP2-LATEST # for memcached and python-m2crypto (otherwise on CloudProduct)
zypper --gpg-auto-import-keys -n ref
zypper -n dup -r Devel_Cloud # upgrade python
#zypper -v --gpg-auto-import-keys -n install patterns-OpenStack-controller patterns-OpenStack-compute-node || exit 123
zypper -v --gpg-auto-import-keys -n install -t pattern cloud_controller cloud_compute
zypper -n install openstack-quickstart python-glanceclient # was not included in meta-patterns
ls -la /var/lib/nova

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

if [ "$MODE" = lxc ] ; then # copied from quickstart # TODO: drop
        sed -i -e 's/\(--libvirt_type\).*/\1=lxc/' /etc/nova/nova.conf
        zypper -n install lxc
        echo mount -t cgroup none /cgroup >> /etc/init.d/boot.local
        mkdir /cgroup
        mount -t cgroup none /cgroup
fi

openstack-quickstart-demosetup
sed -i -e s/br0/brclean/ /etc/nova/nova.conf
echo --bridge_interface=brclean >> /etc/nova/nova.conf
echo --vncserver_listen=0.0.0.0 >> /etc/nova/nova.conf ; /etc/init.d/openstack-nova-compute restart

ps ax
. /etc/bash.bashrc.local
# enable forwarding
( cd /proc/sys/net/ipv4/conf/all/ ; echo 1 > forwarding ; echo 1 > proxy_arp )

nova flavor-create smaller --ephemeral 20 12 768 0 1
#nova flavor-create smaller --ephemeral 20 12 1536 0 1 # for host

# nova-volume
nova volume-create 1 ; sleep 2
nova volume-list
lvscan | grep .
volumeret=$?

if [ "$MODE" = xen ] ; then
	glance add is_public=True disk_format=aki container_format=aki name=debian-kernel < xen-kernel/vmlinuz-2.6.24-19-xen
	glance add is_public=True disk_format=ari container_format=ari name=debian-initrd < xen-kernel/initrd.img-2.6.24-19-xen
	glance add is_public=True disk_format=ami container_format=ami name=debian-5 vm_mode=pv ramdisk_id=f663eb9a-986b-466f-bd3e-f0aa2c847eef kernel_id=d654691a-0135-4f6d-9a60-536cf534b284 < debian.5-0.x86.img
fi
if [ "$MODE" != lxc ] ; then
	#curl http://openqa.suse.de/sle/img/openSUSE_11.4_JeOS.i686-0.0.1.raw.gz | gzip -cd | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
	#curl http://openqa.suse.de/sle/img/openSUSE_12.1_jeos.vmdk.gz | gzip -cd | glance add name="debian-5" is_public=True disk_format=vmdk container_format=bare
	glance image-create --name="debian-5" --is-public=True --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SP2-64up.qcow2
#	curl http://openqa.opensuse.org/openqa/img/openSUSE-12.2-Beta2.img.gz | gzip -cd | glance add name="12.2b2-mini" is_public=True disk_format=raw container_format=bare
#	curl http://openqa.suse.de/sle/img/SP2-64-HA.img.gz | gzip -cd | glance add name="SP2-64-HA" is_public=True disk_format=raw container_format=bare
#	curl http://openqa.suse.de/sle/img/SP2-64up.img.gz | gzip -cd | glance add name="SP2-64up" is_public=True disk_format=raw container_format=bare
#	curl http://clouddata.cloud.suse.de/images/SP2-64up.qcow2 | glance add name="SP2-64up" is_public=True disk_format=qcow2 container_format=bare
#	curl http://openqa.suse.de/sle/img/SP1-32-GM.img.gz | gzip -cd | glance add name="SP2-32" is_public=True disk_format=raw container_format=bare
else
	 glance image-create --name="debian-5" --is-public=True --disk-format=ami --container-format=ami --copy-from http://clouddata.cloud.suse.de/images/debian.5-0.x86.qcow2
	#curl http://clouddata.cloud.suse.de/images/euca-debian-5.0-i386.tar.gz | tar xzO euca-debian-5.0-i386/debian.5-0.x86.img | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
	#curl http://openqa.suse.de/sle/img/euca-debian-5.0-i386.tar.gz | tar xzO euca-debian-5.0-i386/debian.5-0.x86.img | glance add name="debian-5" is_public=True disk_format=ami container_format=ami
fi
glance image-list
#imgid=$(glance index|grep debian-5|cut -f1 -d" ")
imgid=debian-5
mkdir -p ~/.ssh
( umask 77 ; nova keypair-add testkey > ~/.ssh/id_rsa )
nova boot --flavor 12 --image $imgid --key_name testkey testvm | tee boot.out
instanceid=`perl -ne 'm/ id [ |]*([0-9a-f-]+)/ && print $1' boot.out`
nova list
sleep 10
n=30 ; rm -f /tmp/du.old /tmp/du
#while test $n -gt 0 && ! du -s /var/lib/nova/instances/* | diff /tmp/du.old - ; do n=$(expr $n - 1) ; du -s /var/lib/nova/instances/* > /tmp/du.old ; sleep 35 ; done # used by non-interactive jenkins test - do not remove
watch --no-title "du -s /var/lib/nova/instances/*" # will have stillimage when done
#nova volume-attach $instanceid 1 /dev/vdb # only for qemu/kvm
pstree|grep -A5 lxc
virsh --connect lxc:/// list
. /etc/openstackquickstartrc
echo "iptables -t nat -I POSTROUTING -s $testnet -o eth0 -j MASQUERADE" >> /etc/init.d/boot.local
tail -1 /etc/init.d/boot.local | sh
vmip=`perl -e '$_=shift;s,(\d+)/\d+,($1+2),e;print' $testnet`
ssh -o "StrictHostKeyChecking no" root@$vmip curl --silent www3.zq1.de/test.txt && test $volumeret = 0

