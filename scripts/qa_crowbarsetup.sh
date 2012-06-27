#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual
test $(uname -m) = x86_64 || echo "ERROR: need 64bit"
#resize2fs /dev/vda2

cloud=${1:-d2}

case $cloud in
	d1)
		net=10.122.178
		net_storage=179
		net_public=177
		net_fixed=176
		vlan_storage=568
		vlan_public=567
		vlan_fixed=566
	;;
	d2)
		net=10.122.186
		net_storage=187
		net_public=185
		net_fixed=184
		vlan_storage=581
		vlan_public=580
		vlan_fixed=569
	;;
	p)
		net=10.122.169
		net_storage=170
		net_public=168
		net_fixed=160
		vlan_storage=565
		vlan_public=564
		vlan_fixed=563
	;;
	virtual)
		net=192.168.124
	;;
	*)
		echo "Unknown Cloud"
		exit 1
	;;
esac	

if [ -n "$installcrowbar" ] ; then

echo configure static IP and absolute + resolvable hostname crowbar.$cloud.cloud.suse.de gw:$net.1
cat > /etc/sysconfig/network/ifcfg-eth0 <<EOF
NAME='eth0'
STARTMODE='auto'
BOOTPROTO='static'
IPADDR='$net.10'
NETMASK='255.255.255.0'
BROADCAST='$net.255'
EOF
ifdown br0
rm -f /etc/sysconfig/network/ifcfg-br0
echo "default $net.1 - -" > /etc/sysconfig/network/routes
echo "crowbar.$cloud.cloud.suse.de" > /etc/HOSTNAME
hostname `cat /etc/HOSTNAME`
grep -q "$net.*crowbar" /etc/hosts || echo $net.10 crowbar.$cloud.cloud.suse.de crowbar >> /etc/hosts
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

d=dist.suse.de
case $cloudsource in
	develcloud)
		CLOUDDISTURL=$d/ibs/Devel:/Cloud/images/iso
		CLOUDDISTISO="SLE-CLOUD*Media1.iso"
	;;
	susecloud)
		CLOUDDISTURL=$d/ibs/SUSE:/SLE-11-SP2:/Update:/Products:/Test/images/iso
		CLOUDDISTISO="SLE-CLOUD*Media1.iso"
	;;
	Beta*)
		
		CLOUDDISTURL=$d/install/SLE-11-SP2-CLOUD-$cloudsource/
		CLOUDDISTISO="SLE-CLOUD*$cloudsource-DVD1.iso"
	;;
	*)
		echo "Error: you must set environment variable cloudsource=develcloud|susecloud|Beta1"
		exit 76
	;;
esac
wget -q -r -np -nc -A "$CLOUDDISTISO" http://$CLOUDDISTURL/
mount -o loop,ro $CLOUDDISTURL/*.iso /mnt/cloud
rsync -a --delete-after /mnt/cloud/ . ; umount /mnt/cloud
rm -rf "dist.suse.de"
zypper ar /srv/tftpboot/repos/Cloud Cloud
# --no-gpg-checks for Devel:Cloud repo
zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
zypper --no-gpg-checks -n in -t pattern cloud_admin # for Beta2
zypper --no-gpg-checks -n in crowbar # for Beta1

cd /tmp
if [ ! -e "/srv/tftpboot/suse-11.2/install/media.1/" ] ; then
	wget -q -nc http://dist.suse.de/install/SLES-11-SP2-GM/SLES-11-SP2-DVD-x86_64-GM-DVD1.iso
	mount -o loop,ro *.iso /mnt
	rsync -a /mnt/ /srv/tftpboot/suse-11.2/install/
	umount /mnt
	rm *.iso
fi

if [ $cloud != virtual ] ; then
	sed -i.netbak -e "s/192.168.124/$net/g" \
              -e "s/192.168.125/10.122.$net_storage/g" \
              -e "s/192.168.123/10.122.$net_fixed/g" \
              -e "s/192.168.122/10.122.$net_public/g" \
              -e "s/200/$vlan_storage/g" \
              -e "s/300/$vlan_public/g" \
              -e "s/500/$vlan_fixed/g" \
              /opt/dell/barclamps/network/chef/data_bags/crowbar/bc-template-network.json
fi
if [ $cloud = p ] ; then
	# production cloud has a /21 network
	perl -i.perlbak -pe 'if(m/255.255.255.0/){$n++} if($n==3){s/255.255.255.0/255.255.248.0/}' /opt/dell/barclamps/network/chef/data_bags/crowbar/bc-template-network.json
fi

#+bmc router

#fix autoyast xml.erb update channels
if [ ! -e "/srv/tftpboot/repos/SLES11-SP2-Updates" ] ; then
	sed -i.bak -e 's#<media_url>http://<%= @admin_node_ip %>:8091/repos/SLES11-SP\(.\)-Updates/</media_url>#<media_url>http://euklid.suse.de/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP\1/</media_url>#'\
    -e "s/<domain>[^<]*</<domain>$cloud.cloud.suse.de</" \
    /opt/dell/barclamps/provisioner/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
fi
if [ ! -e /srv/tftpboot/repos/SLES11-SP2-Core ] ; then
	sed -i.bak2 -e 's#<media_url>http://<%= @admin_node_ip %>:8091/repos/SLES11-SP1-Pool/#<media_url>http://euklid.suse.de/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP1-POOL/#' -e 's#/repos/SLES11-SP2-Core/#/suse-11.2/install/#' /opt/dell/barclamps/provisioner/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
fi

rm -f /tmp/chef-ready
# run in screen to not lose session in the middle when network is reconfigured:
screen -d -m -L /bin/bash -c '/opt/dell/bin/install-chef-suse.sh ; touch /tmp/chef-ready'
n=300
while [ $n -gt 0 ] && [ ! -e /tmp/chef-ready ] ; do
	n=$(expr $n - 1)
	sleep 5;
	echo -n .
done
if [ $n = 0 ] ; then
	echo "timed out waiting for chef-ready"
	exit 83
fi
sleep 20
if ! curl -s http://localhost:3000 > /dev/null ; then
	tail -30 /tmp/screenlog.0
	echo "crowbar self-test failed"
	exit 84
fi
fi

if [ -n "$allocate" ] ; then
. /etc/profile.d/crowbar.sh

#chef-client
if [ $cloud != virtual ] ; then
	for i in 3 4 5 6 ; do
	  for pw in root crowbar ; do
		  (ipmitool -H "$net.16$i" -U root -P $pw lan set 1 defgw ipaddr "$net.1"
		  ipmitool -H "$net.16$i" -U root -P $pw power reset) &
	  done
	done
	wait
fi

echo "Waiting for nodes to come up..."
while ! crowbar machines list | grep ^d ; do sleep 10 ; done
echo "Found one node"
while test $(crowbar machines list | grep ^d|wc -l) -lt 2 ; do sleep 10 ; done
echo "Sleeping 50 more seconds..."
sleep 50
for m in `crowbar machines list | grep ^d` ; do
	crowbar machines allocate "$m"
done

fi

if [ -n "$proposal" ] ; then
for service in postgresql keystone glance nova nova_dashboard ; do
	crowbar "$service" proposal create default
	crowbar "$service" proposal commit default
done
fi



#BMCs at 10.122.178.163-6 #node 6-9
#BMCs at 10.122.$net.163-4 #node 11-12

# undo propsal create+commit
if false; then
for service in nova_dashboard nova glance keystone postgresql ; do
        crowbar "$service" proposal delete default
        crowbar "$service" delete default
done
fi
