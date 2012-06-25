#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual
test $(uname -m) = x86_64 || echo "ERROR: need 64bit"
#resize2fs /dev/vda2

cloud=d2

case $cloud in
	d1)
		net=178
		net_storage=179
		net_public=177
		net_fixed=176
		vlan_storage=568
		vlan_public=567
		vlan_fixed=566
	;;
	d2)
		net=186
		net_storage=187
		net_public=185
		net_fixed=184
		vlan_storage=581
		vlan_public=580
		vlan_fixed=569
	;;
	p)
		net=169
		net_storage=170
		net_public=168
		net_fixed=160
		vlan_storage=565
		vlan_public=564
		vlan_fixed=563
	;;
	*)
		echo "Unknown Cloud"
		exit 1
	;;
esac	

echo configure static IP and absolute + resolvable hostname crowbar.$cloud.cloud.suse.de gw:10.122.$net.1
cat > /etc/sysconfig/network/ifcfg-eth0 <<EOF
NAME='eth0'
STARTMODE='auto'
BOOTPROTO='static'
IPADDR='10.122.$net.10'
NETMASK='255.255.255.0'
BROADCAST='10.122.$net.255'
EOF
echo "default 10.122.$net.1 - -" > /etc/sysconfig/network/routes
echo "crowbar.$cloud.cloud.suse.de" > /etc/HOSTNAME
hostname `cat /etc/HOSTNAME`
rcnetwork restart
hostname -f # make sure it is a FQDN
ping -c 1 `hostname -f`
zypper ar http://dist.suse.de/install/SLP/SLES-11-SP2-LATEST/x86_64/DVD1/ sle11sp2latest
#zypper ar http://dist.suse.de/install/SLP/SLE-11-SP2-SDK-LATEST/x86_64/DVD1/ sle11sp2sdklatest
if [ "x$WITHUPDATES" != "x" ] ; then
  zypper ar "http://euklid.suse.de/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP1/" sp1-updates
  zypper ar "http://euklid.suse.de/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP2/" sp2-updates
fi

mkdir -p /mnt/dist /mnt/cloud
mkdir -p /srv/tftpboot/repos/Cloud/
cd /srv/tftpboot/repos/Cloud/

CLOUDDISTURL=dist.suse.de/ibs/Devel:/Cloud/images/iso
CLOUDDISTURL=dist.suse.de/ibs/SUSE:/SLE-11-SP2:/Update:/Products:/Test/images/iso
CLOUDDISTURL=dist.suse.de/install/SLE-11-SP2-CLOUD-Beta1
wget -q -r -np -nc -A "SLE-CLOUD*Media1.iso" http://$CLOUDDISTURL/
mount -o loop,ro $CLOUDDISTURL/*.iso /mnt/cloud
rsync -a --delete-after /mnt/cloud/ . ; umount /mnt/cloud
rm -rf "dist.suse.de"
zypper ar /srv/tftpboot/repos/Cloud Cloud
zypper -v --gpg-auto-import-keys -n ref
zypper -n in crowbar

cd /tmp
if [ ! -e "/srv/tftpboot/suse-11.2/install/media.1/" ] ; then
	wget -nc http://dist.suse.de/install/SLES-11-SP2-GM/SLES-11-SP2-DVD-x86_64-GM-DVD1.iso
	mount -o loop,ro *.iso /mnt
	rsync -a /mnt/ /srv/tftpboot/suse-11.2/install/
	umount /mnt
	rm *.iso
fi

sed -i.netbak -e "s/192.168.124/10.122.$net/g" \
              -e "s/192.168.125/10.122.$net_storage/g" \
              -e "s/192.168.123/10.122.$net_fixed/g" \
              -e "s/192.168.122/10.122.$net_public/g" \
              -e "s/200/$vlan_storage/g" \
              -e "s/300/$vlan_public/g" \
              -e "s/500/$vlan_fixed/g" \
              /opt/dell/barclamps/network/chef/data_bags/crowbar/bc-template-network.json

#+bmc router

#fix autoyast xml.erb update channels
if [ ! -e "/srv/tftpboot/repos/SLES11-SP2-Updates" ] ; then
	sed -i.bak -e 's#<media_url>http://<%= @admin_node_ip %>:8091/repos/SLES11-SP\(.\)-Updates/</media_url>#<media_url>http://euklid.suse.de/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP\1/</media_url>#' /opt/dell/barclamps/provisioner/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
fi

# run in screen to not lose session in the middle when network is reconfigured:
screen -L /opt/dell/bin/install-chef-suse.sh
. /etc/profile.d/crowbar.sh

#chef-client
for i in 3 4 5 6 ; do
  for pw in root crowbar ; do
	  ipmitool -H "10.122.$net.16$i" -U root -P $pw lan set 1 defgw ipaddr "10.122.$net.1"
	  ipmitool -H "10.122.$net.16$i" -U root -P $pw power reset
  done
done

echo "Waiting for nodes to come up..."
while ! crowbar machines list | grep ^d ; do sleep 1 ; done
echo "Sleeping 50 more seconds..."
sleep 50
for m in `crowbar machines list | grep ^d` ; do
	crowbar machines allocate "$m"
done

for service in postgresql keystone glance nova nova_dashboard ; do
	crowbar "$service" proposal create default
	crowbar "$service" proposal commit default
done

#BMCs at 10.122.178.163-6 #node 6-9
#BMCs at 10.122.$net.163-4 #node 11-12

