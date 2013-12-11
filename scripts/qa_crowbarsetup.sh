#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual
test $(uname -m) = x86_64 || echo "ERROR: need 64bit"
#resize2fs /dev/vda2

novacontroller=
novadashboardserver=
export cloud=${1}
export nodenumber=${nodenumber:-2}
export nodes=
export debug=${debug:-0}

if [ -z $cloud ] ; then
  echo "Error: Parameter missing that defines the cloud name"
  echo "Possible values: [d1, d2, p, virtual]"
  echo "Example: $0 d2"
  exit 101
fi

# common cloud network prefix within SUSE Nuremberg:
netp=10.122
net=${net_admin:-192.168.124}
case $cloud in
	d1)
		net=$netp.178
		net_storage=$netp.179
		net_public=$netp.177
		net_fixed=$netp.176
		vlan_storage=568
		vlan_public=567
		vlan_fixed=566
	;;
	d2)
		net=$netp.186
		net_storage=$netp.187
		net_public=$netp.185
		net_fixed=$netp.184
		vlan_storage=581
		vlan_public=580
		vlan_fixed=569
	;;
	p2)
		net=$netp.171
		net_storage=$netp.172
		net_public=$netp.164
		net_fixed=44.0.0
		vlan_storage=563
		vlan_public=564
		vlan_fixed=565
	;;
	p)
		net=$netp.169
		net_storage=$netp.170
		net_public=$netp.168
		net_fixed=$netp.160
		vlan_storage=565
		vlan_public=564
		vlan_fixed=563
	;;
        v1)
                net=$netp.180
                net_public=$netp.181
        ;;
        v2)
                net=$netp.182
                net_public=$netp.183
        ;;
	virtual)
                true # defaults are fine (and overridable)
	;;
	cumulus)
		net=$netp.189
		net_storage=$netp.187
		net_public=$netp.190
		net_fixed=$netp.188
		vlan_storage=577
		vlan_public=579
		vlan_fixed=578
    ;;
	*)
		echo "Unknown Cloud"
		exit 1
	;;
esac
# default networks in crowbar:
vlan_storage=${vlan_storage:-200}
vlan_public=${vlan_public:-300}
vlan_fixed=${vlan_fixed:-500}
vlan_sdn=${vlan_sdn:-$vlan_storage}
net_fixed=${net_fixed:-192.168.123}
net_public=${net_public:-192.168.122}
net_storage=${net_storage:-192.168.125}

function intercept()
{
  if [ -n "$shell" ] ; then
    echo "Now starting bash for manual intervention..."
    echo "When ready exit this shell to continue with $1"
    bash
  fi
}

function wait_for()
{
  timecount=${1:-300}
  timesleep=${2:-1}
  condition=${3:-'/bin/true'}
  waitfor=${4:-'unknown process'}
  error_cmd=${5:-'exit 11'}

  echo "Waiting for: $waitfor"
  n=$timecount
  while test $n -gt 0 && ! eval $condition
  do
    echo -n .
    sleep $timesleep
    n=$(($n - 1))
  done
  echo

  if [ $n = 0 ] ; then
    echo "Error: Waiting for '$waitfor' timed out."
    echo "This check was used: $condition"
    eval "$error_cmd"
  fi
}

function addsp2testupdates()
{
    mkdir -p /srv/tftpboot/repos/SLES11-SP{1,2}-Updates
    mount -r you.suse.de:/you/http/download/x86_64/update/SLE-SERVER/11-SP1/ /srv/tftpboot/repos/SLES11-SP1-Updates
    mount -r you.suse.de:/you/http/download/x86_64/update/SLE-SERVER/11-SP2/ /srv/tftpboot/repos/SLES11-SP2-Updates
    zypper ar /srv/tftpboot/repos/SLES11-SP1-Updates sp1tup
    zypper ar /srv/tftpboot/repos/SLES11-SP2-Updates sp2tup
}

function addsp3testupdates()
{
    mkdir -p /srv/tftpboot/repos/SLES11-SP3-Updates
    mount -r you.suse.de:/you/http/download/x86_64/update/SLE-SERVER/11-SP3/ /srv/tftpboot/repos/SLES11-SP3-Updates
    zypper ar /srv/tftpboot/repos/SLES11-SP3-Updates sp3tup
}

function prepareinstallcrowbar()
{
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
  grep -q "^default" /etc/sysconfig/network/routes || echo "default $net.1 - -" > /etc/sysconfig/network/routes
  echo "crowbar.$cloud.cloud.suse.de" > /etc/HOSTNAME
  hostname `cat /etc/HOSTNAME`
  # these vars are used by rabbitmq
  export HOSTNAME=`cat /etc/HOSTNAME`
  export HOST=$HOSTNAME
  grep -q "$net.*crowbar" /etc/hosts || echo $net.10 crowbar.$cloud.cloud.suse.de crowbar >> /etc/hosts
  rcnetwork restart
  hostname -f # make sure it is a FQDN
  ping -c 1 `hostname -f`
  longdistance=${longdistance:-false}
  if [[ $(ping -q -c1 clouddata.cloud.suse.de|perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]] ; then
    longdistance=true
  fi

  mkdir -p /mnt/dist /mnt/cloud
  mkdir -p /srv/tftpboot/repos/Cloud/
  cd /srv/tftpboot/repos/Cloud/

  suseversion=11.2
  : ${susedownload:=download.nue.suse.com}
  case $cloudsource in
      develcloud1.0)
          CLOUDDISTPATH=/ibs/Devel:/Cloud:/1.0/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
      ;;
      develcloud2.0)
          CLOUDDISTPATH=/ibs/Devel:/Cloud:/2.0/images/iso
          [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/2.0:/Staging/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
          suseversion=11.3
      ;;
      develcloud3)
          CLOUDDISTPATH=/ibs/Devel:/Cloud:/3/images/iso
          [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/3:/Staging/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
          suseversion=11.3
      ;;
      develcloud)
          echo "The cloudsource 'develcloud' is no longer supported."
          echo "Please use 'develcloud1.0' resp. 'develcloud2.0'."
          exit 11
      ;;
      susecloud|susecloud1.0)
          CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP2:/Update:/Products:/Test/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
      ;;
      susecloud2.0)
          CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/GA:/Products:/Test/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
          suseversion=11.3
      ;;
      susecloud3)
          CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/Update:/Products:/Test/images/iso
          CLOUDDISTISO="S*-CLOUD*Media1.iso"
          suseversion=11.3
      ;;
      GM|GM1.0)
          CLOUDDISTPATH=/install/SLE-11-SP2-CLOUD-GM/
          CLOUDDISTISO="S*-CLOUD*GM-DVD1.iso"
      ;;
      Beta*|RC*|GMC*|GM2.0)
          cs=$cloudsource
          [ $cs = GM2.0 ] && cs=GM
          CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-$cs/
          CLOUDDISTISO="S*-CLOUD*1.iso"
          suseversion=11.3
      ;;
      *)
          echo "Error: you must set environment variable cloudsource=develcloud|susecloud|Beta1"
          exit 76
      ;;
  esac

  case $suseversion in
      11.2)
        slesrepolist="SLES11-SP1-Pool SLES11-SP1-Updates SLES11-SP2-Core SLES11-SP2-Updates"
        slesversion=11-SP2
        slesdist=SLE_11_SP2
        slesmilestone=GM
      ;;
      11.3)
        slesrepolist="SLES11-SP3-Pool SLES11-SP3-Updates"
        slesversion=11-SP3
        slesdist=SLE_11_SP3
        slesmilestone=GM
      ;;
  esac

  zypper se -s sles-release|grep -v -e "sp.up\s*$" -e "(System Packages)" |grep -q x86_64 || zypper ar http://$susedownload/install/SLP/SLES-${slesversion}-LATEST/x86_64/DVD1/ sles

  if [ "x$WITHSLEUPDATES" != "x" ] ; then
    if [ $suseversion = "11.2" ] ; then
      zypper ar "http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP1/" sp1-up
      zypper ar "http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/11-SP2/" sp2-up
    else
      zypper ar "http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/$slesversion/" ${slesversion}-up
    fi
  fi


  zypper -n install rsync netcat
  wget --progress=dot:mega -r -np -nc -A "$CLOUDDISTISO" http://$susedownload$CLOUDDISTPATH/
  CLOUDISO=$(ls */$CLOUDDISTPATH/*.iso|tail -1)
  echo $CLOUDISO > /etc/cloudversion
  echo -n "This cloud was installed on `cat ~/cloud` from: " | cat - /etc/cloudversion >> /etc/motd
  mount -o loop,ro -t iso9660 $CLOUDISO /mnt/cloud
  rsync -av --delete-after /mnt/cloud/ . ; umount /mnt/cloud
  if [ ! -e "/srv/tftpboot/repos/Cloud/media.1" ] ; then
    echo "We do not have cloud install media - giving up"
    exit 35
  fi


  zypper ar /srv/tftpboot/repos/Cloud Cloud
  if [ -n "$TESTHEAD" ] ; then
      case "$cloudsource" in
          develcloud1.0)
              addsp2testupdates
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/1.0/$slesdist/Devel:Cloud:1.0.repo
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/1.0:/Crowbar/$slesdist/Devel:Cloud:1.0:Crowbar.repo
              zypper mr -p 70 Devel_Cloud # more important
              zypper mr -p 60 Devel_Cloud_Crowbar # even more important
              zypper mr -p 60 DCCdirect # as important - just use newer ver
              ;;
          develcloud2.0)
              addsp3testupdates
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/2.0:/Staging/$slesdist/Devel:Cloud:2.0:Staging.repo
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/2.0/$slesdist/Devel:Cloud:2.0.repo
              zypper mr -p 60 Devel_Cloud_2.0_Staging
              zypper mr -p 70 Devel_Cloud_2.0
              ;;
          susecloud3)
              addsp3testupdates
              ;;
          develcloud3)
              addsp3testupdates
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/3:/Staging/$slesdist/Devel:Cloud:3:Staging.repo
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/3/$slesdist/Devel:Cloud:3.repo
              zypper ar http://download.nue.suse.com/ibs/Devel:/Cloud:/Shared:/11-SP3/standard/ cloud-shared-11sp3
              zypper mr -p 60 Devel_Cloud_3_Staging
              zypper mr -p 70 Devel_Cloud_3
              ;;
          GM|GM1.0)
              addsp2testupdates
              mkdir -p /srv/tftpboot/repos/SUSE-Cloud-1.0-Updates
              mount -r clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-1.0-Updates-test /srv/tftpboot/repos/SUSE-Cloud-1.0-Updates
              zypper ar /srv/tftpboot/repos/SUSE-Cloud-1.0-Updates cloudtup
              ;;
          GM2.0)
              addsp3testupdates
              mkdir -p /srv/tftpboot/repos/SUSE-Cloud-2.0-Updates
              mount -r clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-2.0-Updates-test /srv/tftpboot/repos/SUSE-Cloud-2.0-Updates
              zypper ar /srv/tftpboot/repos/SUSE-Cloud-2.0-Updates cloudtup
              ;;
          *)
              echo "no TESTHEAD repos defined for cloudsource=$cloudsource"
              exit 26
              ;;
      esac
  fi
  # --no-gpg-checks for Devel:Cloud repo
  zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref

  zypper --no-gpg-checks -n in -l -t pattern cloud_admin
  ret=$?

  if [ $ret = 0 ] ; then
    echo "The cloud admin successfully installed."
    echo ".... continuing"
  else
    echo "Error: zypper returned with exit code $? when installing cloud admin"
    exit 86
  fi


  mkdir -p /srv/tftpboot/suse-$suseversion/install
  if ! $longdistance && ! grep -q suse-$suseversion /etc/fstab ; then
    echo "clouddata.cloud.suse.de:/srv/nfs/suse-$suseversion/install /srv/tftpboot/suse-$suseversion/install    nfs    ro,nosuid,rsize=8192,wsize=8192,hard,intr,nolock  0 0" >> /etc/fstab
    mount /srv/tftpboot/suse-$suseversion/install
  fi

  case $cloudsource in
      develcloud1.0|susecloud1.0|GM|GM1.0)
      zypper -n install createrepo
      for REPO in SUSE-Cloud-1.0-Pool SUSE-Cloud-1.0-Updates ; do
          mkdir -p /srv/tftpboot/repos/$REPO
          cd /srv/tftpboot/repos/$REPO
          [ -e repodata ] || createrepo .
      done
      ;;
  esac

  for REPO in $slesrepolist ; do
    grep -q $REPO /etc/fstab && continue
    r=/srv/tftpboot/repos/$REPO
    test -d $r/rpm && continue
    mkdir -p $r
    echo "clouddata.cloud.suse.de:/srv/nfs/repos/$REPO  $r   nfs    ro,nosuid,rsize=8192,wsize=8192,hard,intr,nolock  0 0" >> /etc/fstab
    mount $r
  done

  # just as a fallback if nfs did not work
  if [ ! -e "/srv/tftpboot/suse-$suseversion/install/media.1/" ] ; then
    f=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
    p=/srv/tftpboot/suse-$suseversion/$f
    wget --progress=dot:mega -nc -O$p http://$susedownload/install/SLES-$slesversion-$slesmilestone/$f
    echo $p /srv/tftpboot/suse-$suseversion/install/ iso9660 loop,ro >> /etc/fstab
    mount /srv/tftpboot/suse-$suseversion/install/
  fi
  if [ ! -e "/srv/tftpboot/suse-$suseversion/install/media.1/" ] ; then
    echo "We do not have SLES install media - giving up"
    exit 34
  fi
  cd /tmp

  netfile="/opt/dell/chef/data_bags/crowbar/bc-template-network.json"
  netfilepatch=`basename $netfile`.patch
  [ -e ~/$netfilepatch ] && patch -p1 $netfile < ~/$netfilepatch

  # to revert https://github.com/crowbar/barclamp-network/commit/a85bb03d7196468c333a58708b42d106d77eaead
  sed -i.netbak1 -e 's/192\.168\.126/192.168.122/g' $netfile

  sed -i.netbak -e 's/"conduit": "bmc",/& "router":"192.168.124.1",/' \
                -e "s/192.168.124/$net/g" \
                -e "s/192.168.125/$net_storage/g" \
                -e "s/192.168.123/$net_fixed/g" \
                -e "s/192.168.122/$net_public/g" \
                -e "s/200/$vlan_storage/g" \
                -e "s/300/$vlan_public/g" \
                -e "s/500/$vlan_fixed/g" \
                -e "s/700/$vlan_sdn/g" \
      $netfile

  if [[ $cloud = p || $cloud = p2 ]] ; then
    # production cloud has a /22 network
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.netmask -v 255.255.252.0 $netfile
  fi
  if [[ $cloud = p2 ]] ; then
          /opt/dell/bin/json-edit -a attributes.network.networks.public.netmask -v 255.255.252.0 $netfile
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.ranges.dhcp.end -v 44.0.3.254 $netfile
          # floating net is the 2nd half of public net:
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.netmask -v 255.255.254.0 $netfile
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.subnet -v 10.122.166.0 $netfile
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.start -v 10.122.166.1 $netfile
          /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.end -v 10.122.167.191 $netfile
          # todo? broadcast
  fi
  cp -a $netfile /etc/crowbar/network.json # new place since 2013-07-18

  # to allow integration into external DNS:
  f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
  grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

  # workaround for performance bug (bnc#770083)
  sed -i -e "s#<\(partitions.*\)/>#<\1><partition><mount>swap</mount><size>auto</size></partition><partition><mount>/</mount><size>max</size><fstopt>data=writeback,barrier=0,noatime</fstopt></partition></partitions>#" /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
  # set default password to 'linux'
  # setup_base_images.rb is for SUSE Cloud 1.0 and update_nodes.rb is for 2.0
  sed -i -e 's/\(rootpw_hash.*\)""/\1"$2y$10$u5mQA7\/8YjHdutDPEMPtBeh\/w8Bq0wEGbxleUT4dO48dxgwyPD8D."/' /opt/dell/chef/cookbooks/provisioner/recipes/setup_base_images.rb /opt/dell/chef/cookbooks/provisioner/recipes/update_nodes.rb

}

function installcrowbar()
{
  intercept "install-chef-suse.sh"

  rm -f /tmp/chef-ready
  rpm -Va crowbar\*
  export REPOS_SKIP_CHECKS="Cloud SUSE-Cloud-1.0-Pool SUSE-Cloud-1.0-Updates"
  # run in screen to not lose session in the middle when network is reconfigured:
  screen -d -m -L /bin/bash -c 'if [ -e /tmp/install-chef-suse.sh --verbose ] ; then /tmp/install-chef-suse.sh ; else /opt/dell/bin/install-chef-suse.sh --verbose ; fi ; touch /tmp/chef-ready'
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
  rpm -Va crowbar\*

  [ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

  sleep 20
  if ! curl -m 29 -s http://localhost:3000 > /dev/null || ! curl -m 29 -s --digest --user crowbar:crowbar localhost:3000 | grep -q /nodes/crowbar ; then
    tail -n 90 /tmp/screenlog.0
    echo "crowbar self-test failed"
    exit 84
  fi

  if ! crowbar machines list | grep -q crowbar.$cloud ; then
    tail -n 90 /tmp/screenlog.0
    echo "crowbar 2nd self-test failed"
    exit 85
  fi

  if ! (rcxinetd status && rcdhcpd status) ; then
     echo "Error: provisioner failed to configure all needed services!"
     echo "Please fix manually."
     exit 67
  fi
    if [ -n "$ntpserver" ] ; then
      crowbar ntp proposal show default |
        ruby -e "require 'rubygems';require 'json';
    j=JSON.parse(STDIN.read);
    j['attributes']['ntp']['external_servers']=['$ntpserver'];
        puts JSON.pretty_generate(j)" > /root/ntpproposal
      crowbar ntp proposal --file=/root/ntpproposal edit default
      crowbar ntp proposal commit default
    fi

}

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh
if [ -n "$allocate" ] ; then

#chef-client
if [ $cloud != virtual ] ; then
        nodelist="3 4 5 6"
        # protect machine 3 on d2 for tomasz
        if [ "$cloud" = "d2" ]; then
            nodelist="4 5"
        fi
	for i in $nodelist ; do
	  for pw in root crowbar 'cr0wBar!' ; do
		  (ipmitool -H "$net.16$i" -U root -P $pw lan set 1 defgw ipaddr "$net.1"
		  ipmitool -H "$net.16$i" -U root -P $pw power reset) &
	  done
	done
	wait
fi

echo "Waiting for nodes to come up..."
while ! crowbar machines list | grep ^d ; do sleep 10 ; done
echo "Found one node"
while test $(crowbar machines list | grep ^d|wc -l) -lt $nodenumber ; do sleep 10 ; done
nodes=$(crowbar machines list | grep ^d)
for n in $nodes ; do
        wait_for 100 2 "knife node show -a state $n | grep discovered" "node to enter discovered state"
done
echo "Sleeping 50 more seconds..."
sleep 50
for m in `crowbar machines list | grep ^d` ; do
	while knife node show -a state $m | grep discovered; do # workaround bnc#773041
		crowbar machines allocate "$m"
		sleep 10
	done
done

# check for error 500 in app/models/node_object.rb:635:in `sort_ifs'#012
curl -m 9 -s --digest --user crowbar:crowbar http://localhost:3000| tee /root/crowbartest.out
grep "Exception caught" /root/crowbartest.out && exit 27

fi

function sshtest()
{
        perl -e "alarm 10 ; exec qw{ssh -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no}, @ARGV" "$@"
}

function ssh_password()
{
  SSH_ASKPASS=/root/echolinux
  cat > $SSH_ASKPASS <<EOSSHASK
#!/bin/sh
echo linux
EOSSHASK
  chmod +x $SSH_ASKPASS
  DISPLAY=dummydisplay:0 SSH_ASKPASS=$SSH_ASKPASS setsid ssh "$@"
}

function check_node_resolvconf()
{
  ssh_password $1 'grep "^nameserver" /etc/resolv.conf || echo fail'
}

if [ -n "$waitcompute" ] ; then
  for node in $(crowbar machines list | grep ^d) ; do
    wait_for 180 10 "sshtest $node rpm -q yast2-core" "node $node" "check_node_resolvconf $node; exit 12"
    echo "node $node ready"
  done
fi


function waitnodes()
{
  n=800
  mode=$1
  proposal=$2
  case $mode in
    nodes)
      echo -n "Waiting for nodes to get ready: "
      for i in `crowbar machines list | grep ^d` ; do
        machinestatus=''
        while test $n -gt 0 && ! test "x$machinestatus" = "xready" ; do
          machinestatus=`crowbar machines show $i | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['state']"`
          if test "x$machinestatus" = "xfailed" -o "x$machinestatus" = "xnil" ; then
            echo "Error: machine status is failed. Exiting"
            exit 39
          fi
          sleep 5
          n=$((n-1))
          echo -n "."
        done
        n=500 ; while test $n -gt 0 && ! netcat -z $i 22 ; do
          sleep 1
          n=$(($n - 1))
          echo -n "."
        done
        echo "node $i ready"
      done
      ;;
    proposal)
      echo -n "Waiting for proposal $proposal to get successful: "
      proposalstatus=''
      while test $n -gt 0 && ! test "x$proposalstatus" = "xsuccess" ; do
        proposalstatus=`crowbar $proposal proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['$proposal']['crowbar-status']"`
        if test "x$proposalstatus" = "xfailed" ; then
          tail -n 90 /opt/dell/crowbar_framework/log/d*.log /var/log/crowbar/chef-client/d*.log
          echo "Error: proposal $proposal failed. Exiting."
          exit 40
        fi
        sleep 5
        n=$((n-1))
        echo -n "."
      done
      echo
      echo "proposal $proposal successful"
      ;;
    default)
      echo "Error: waitnodes was called with wrong parameters"
      exit 72
      ;;
  esac

  if [ $n == 0 ] ; then
    echo "Error: Waiting timed out. Exiting."
    exit 74
  fi
}


function manual_2device_ceph_proposal()
{
  # configure nodes and devices for ceph
  crowbar ceph proposal show default |
    ruby -e "require 'rubygems';require 'json';
      nodes=ENV['nodes'].split(\"\n\");
      controller=nodes.shift;
      j=JSON.parse(STDIN.read);
      e=j['deployment']['ceph']['elements'];
      e['ceph-mon-master']=[controller];
      e['ceph-mon']=nodes[0..1];
      e['ceph-store']=nodes;
      j['attributes']['ceph']['devices'] = ENV['cloud']=='virtual'?['/dev/vdb','/dev/vdc']:['/dev/sdb'];
    puts JSON.pretty_generate(j)" > /root/cephproposal
  crowbar ceph proposal --file=/root/cephproposal edit default
}


# generic function to set values in proposals
#   Note: strings have to be quoted like this: "'string'"
#         "true" resp. "false" or "['one', 'two']" act as ruby values, not as string
function proposal_set_value()
{
  service=$1
  proposal=$2
  variable=$3
  value=$4

  pfile=/root/${service}.${proposal}.proposal

  crowbar $service proposal show $proposal |
    ruby -e "require 'rubygems';require 'json';
             j=JSON.parse(STDIN.read);
             j${variable}=${value};
             puts JSON.pretty_generate(j)" > $pfile
  crowbar $service proposal --file=$pfile edit $proposal
}

function enable_ssl_for_keystone()
{
  echo "Enabling SSL for keystone"
  proposal_set_value keystone default "['attributes']['keystone']['api']['protocol']" "'https'"
}

function enable_ssl_for_glance()
{
  echo "Enabling SSL for glance"
  proposal_set_value glance default "['attributes']['glance']['api']['protocol']" "'https'"
}

function enable_ssl_for_nova()
{
  echo "Enabling SSL for nova"
  proposal_set_value nova default "['attributes']['nova']['api']['protocol']" "'https'"
  proposal_set_value nova default "['attributes']['nova']['glance_ssl_no_verify']" true
  proposal_set_value nova default "['attributes']['nova']['novnc']['ssl_enabled']" true
}


function enable_ssl_for_nova_dashboard()
{
  echo "Enabling SSL for nova_dashboard"
  proposal_set_value nova_dashboard default "['attributes']['nova_dashboard']['apache']['use_https']" true
  proposal_set_value nova_dashboard default "['attributes']['nova_dashboard']['apache']['use_http']" false
  proposal_set_value nova_dashboard default "['attributes']['nova_dashboard']['apache']['redirect_to_https']" false
  proposal_set_value nova_dashboard default "['attributes']['nova_dashboard']['ssl_no_verify']" true
}


function custom_configuration()
{
  service=$1
  crowbaredit="crowbar $service proposal edit default"
  if [[ $debug = 1 && $service != swift ]] ; then
    EDITOR='sed -i -e "s/debug\": false/debug\": true/" -e "s/verbose\": false/verbose\": true/"' $crowbaredit
  fi
  case $service in
    keystone)
      if [[ $all_with_ssl = 1 || $keystone_with_ssl = 1 ]] ; then
        enable_ssl_for_keystone
      fi
    ;;
    glance)
      if [[ $all_with_ssl = 1 || $glance_with_ssl = 1 ]] ; then
        enable_ssl_for_glance
      fi
    ;;
    ceph) manual_2device_ceph_proposal
    ;;
    nova)
      # custom nova config of libvirt
      [ -n "$libvirt_type" ] || libvirt_type='kvm';
      proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
#      EDITOR="sed -i -e 's/nova-multi-compute-$libvirt_type/nova-multi-compute-xxx/g; s/nova-multi-compute-qemu/nova-multi-compute-$libvirt_type/g; s/nova-multi-compute-xxx/nova-multi-compute-qemu/g'" $crowbaredit

      if [[ $all_with_ssl = 1 || $nova_with_ssl = 1 ]] ; then
        enable_ssl_for_nova
      fi
    ;;
    nova_dashboard)
      if [[ $all_with_ssl = 1 || $novadashboard_with_ssl = 1 ]] ; then
        enable_ssl_for_nova_dashboard
      fi
    ;;
    neutron)
      if [[ $networkingplugin = linuxbridge ]] ; then
        proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'$networkingplugin'"
        proposal_set_value neutron default "['attributes']['neutron']['networking_mode']" "'vlan'"
      fi
    ;;
    quantum)
      if [[ $networkingplugin = linuxbridge ]] ; then
        proposal_set_value quantum default "['attributes']['quantum']['networking_plugin']" "'$networkingplugin'"
        proposal_set_value quantum default "['attributes']['quantum']['networking_mode']" "'vlan'"
      fi
    ;;
    swift)
      [[ "$nodenumber" -lt 3 ]] && proposal_set_value swift default "['attributes']['swift']['zones']" "1"
    ;;
    *) echo "No hooks defined for service: $service"
    ;;
  esac
}

function get_crowbarnodes()
{
  #FIXME this is ugly
  [ -x /opt/dell/bin/crowbar ] && nodes=`crowbar machines list | grep ^d`
}


get_crowbarnodes
wantswift=1
wantceph=1
cloud2='cloud2.0|Beta|RC|GMC|GM2.0'
cloud3='cloud3'
[[ $cloudsource =~ $cloud2 ]] && wantceph=
[[ "$nodenumber" -lt 3 || "$cephvolumenumber" -lt 1 ]] && wantceph=
# we can not use both swift and ceph as each grabs all disks on a node
[[ -n "$wantceph" ]] && wantswift=
[[ "$cephvolumenumber" -lt 1 ]] && wantswift=
crowbar_networking=neutron
[[ $cloudsource =~ $cloud2 ]] && crowbar_networking=quantum

if [ -n "$proposal" ] ; then
waitnodes nodes

for service in database keystone ceph glance rabbitmq cinder $crowbar_networking nova nova_dashboard swift ceilometer heat ; do
  case $service in
    ceph)
      [[ -n "$wantceph" ]] || continue
      ;;
    swift)
      [[ -n "$wantswift" ]] || continue
      ;;
    rabbitmq|cinder|quantum|neutron|ceilometer|heat)
      [[ $cloudsource =~ $cloud3|$cloud2 ]] || continue
      ;;
  esac
  crowbar "$service" proposal create default
  # hook for changing proposals:
  custom_configuration $service
  crowbar "$service" proposal commit default
  echo $?
  waitnodes proposal $service
  sleep 10
  ret=$?
  echo "exitcode: $ret"
  if [ $ret != 0 ] ; then
    tail -n 90 /opt/dell/crowbar_framework/log/d*.log /var/log/crowbar/chef-client/d*.log
    echo "Error: commiting the crowbar proposal for '$service' failed ($ret)."
    exit 73
  fi
done
fi

function get_novacontroller()
{
  novacontroller=`crowbar nova proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova']['elements']['nova-multi-controller']"`
}


function get_novadashboardserver()
{
  novadashboardserver=`crowbar nova_dashboard proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova_dashboard']['elements']['nova_dashboard-server']"`
}


function tempest_configure()
{
  rm -rf tempestlog
  mkdir -p tempestlog
  get_novadashboardserver
  scp ./run_tempest.sh root@${novadashboardserver}:
  ssh root@${novadashboardserver} 'export nosetestparameters=${nosetestparameters} ; bash -x ./run_tempest.sh configure'
  ret=$?
  scp root@${novadashboardserver}:tempest/etc/tempest.conf tempestlog/
  echo "return code from tempest configuration: $ret"
  return $ret
}


function tempest_run()
{
  mkdir -p tempestlog
  get_novadashboardserver
  scp ./run_tempest.sh root@${novadashboardserver}:
  ssh root@${novadashboardserver} 'export nosetestparameters=${nosetestparameters} ; bash -x ./run_tempest.sh run'
  ret=$?
  scp root@${novadashboardserver}:tempest/tempest_*.log tempestlog/
  scp root@${novadashboardserver}:tempest/etc/tempest.conf tempestlog/tempest.conf_after
  echo "return code from tempest run: $ret"
  return $ret
}



if [ -n "$testsetup" ] ; then
    get_novacontroller
	if [ -z "$novacontroller" ] || ! ssh $novacontroller true ; then
		echo "no nova contoller - something went wrong"
		exit 62
	fi
	echo "openstack nova contoller: $novacontroller"
	curl -m 20 -s http://$novacontroller | grep -q -e csrfmiddlewaretoken -e "<title>302 Found</title>" || exit 101
	ssh $novacontroller "export wantswift=$wantswift ; "'set -x
		. .openrc
		export LC_ALL=C
                if [[ -n $wantswift ]] ; then
                    zypper -n install python-swiftclient
                    swift stat
                    swift upload container1 .ssh/authorized_keys
                    swift list container1 || exit 33
                fi
		curl -s w3.suse.de/~bwiedemann/cloud/defaultsuseusers.pl | perl
		nova list
		glance image-list
	        glance image-list|grep -q SP2-64 || glance image-create --name=SP2-64 --is-public=True --property vm_mode=hvm --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SP2-64up.qcow2 | tee glance.out
                # glance image-create --name=jeos-12.1-pv --is-public=True --property vm_mode=xen --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/jeos-64-pv.qcow2
        # wait for image to finish uploading
        imageid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" glance.out`
        for n in $(seq 1 200) ; do
          glance image-show $imageid|grep status.*active && break
          sleep 5
        done
        # wait for nova-manage to be successful
        for n in $(seq 1 200) ;  do
            test "$(nova-manage service list  | fgrep -cv -- \:\-\))" -lt 2 && break
            sleep 1
        done
        nova flavor-delete m1.smaller || :
        nova flavor-create m1.smaller 11 512 10 1
        nova delete testvm # cleanup earlier run # cleanup
		nova keypair-add --pub_key /root/.ssh/id_rsa.pub testkey
		nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
		nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0
		nova secgroup-add-rule default udp 1 65535 0.0.0.0/0
		nova boot --image SP2-64 --flavor m1.smaller --key_name testkey testvm | tee boot.out
		instanceid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" boot.out`
		sleep 30
		vmip=`nova show $instanceid | perl -ne "m/fixed.network [ |]*([0-9.]+)/ && print \\$1"`
		echo "VM IP address: $vmip"
        if [ -z "$vmip" ] ; then
          tail -n 90 /var/log/nova/*
          echo "Error: VM IP is empty. Exiting"
          exit 38
        fi
		nova floating-ip-create | tee floating-ip-create.out
		floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
		nova add-floating-ip $instanceid $floatingip # insufficient permissions
		vmip=$floatingip
		n=1000 ; while test $n -gt 0 && ! ping -q -c 1 -w 1 $vmip >/dev/null ; do
		  n=$(expr $n - 1)
		  echo -n .
		  set +x
		done
		set -x
		if [ $n = 0 ] ; then
			echo testvm boot or net failed
			exit 94
		fi
        echo -n "Waiting for the VM to come up: "
        n=500 ; while test $n -gt 0 && ! netcat -z $vmip 22 ; do
          sleep 1
          n=$(($n - 1))
          echo -n "."
	  set +x
        done
	set -x
        if [ $n = 0 ] ; then
          echo "VM not accessible in reasonable time, exiting."
          exit 96
        fi
        WAITSSH=200
        echo "Waiting $WAITSSH seconds for the SSH keys to be copied over"
        sleep $WAITSSH
		if ! ssh $vmip curl www3.zq1.de/test ; then
			echo could not reach internet
			exit 95
		fi
		set -x
		ssh $vmip modprobe acpiphp # workaround bnc#824915
		nova volume-create 1 ; sleep 2
		nova volume-list | grep available
		volumecreateret=$?
		volumeid=`nova volume-list | perl -ne "m/^[ |]*([0-9a-f-]+) [ |]*available/ && print \\$1"`
		nova volume-attach $instanceid $volumeid /dev/vdb
		sleep 15
		ssh $vmip fdisk -l /dev/vdb | grep 1073741824
		volumeattachret=$?
		nova volume-detach $instanceid $volumeid ; sleep 10
		nova volume-attach $instanceid $volumeid /dev/vdb ; sleep 10
		ssh $vmip fdisk -l /dev/vdb | grep 1073741824 || volumeattachret=57
		test $volumecreateret = 0 -a $volumeattachret = 0
	'
	ret=$?
	echo ret:$ret
	exit $ret
fi

function addupdaterepo()
{
  UPR=/srv/tftpboot/repos/Cloud-PTF
  mkdir -p $UPR
  for repo in ${UPDATEREPOS//+/ } ; do
    wget --progress=dot:mega -r --directory-prefix $UPR --no-parent --no-clobber --accept x86_64.rpm,noarch.rpm $repo || exit 8
  done
  zypper -n install createrepo
  createrepo -o $UPR $UPR || exit 8
  zypper ar $UPR cloud-ptf
}

function runupdate()
{
  wait_for 30 3 " zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks ref ; [[ $? != 4 ]] " "successful zypper run" "exit 9"
  wait_for 30 3 " zypper --non-interactive up --repo cloud-ptf ; [[ $? != 4 ]] " "successful zypper run" "exit 9"
}

function rebootcompute()
{
  get_novacontroller

  cmachines=`crowbar machines list | grep ^d`
  for m in $cmachines ; do
    ssh $m "reboot"
    wait_for 100 1 " ! netcat -z $m 22 >/dev/null" "node $m to go down"
  done

  for m in $cmachines ; do
    wait_for 200 3 "netcat -z $m 22 >/dev/null" "node $m to be back online"
  done
  echo "Waiting another 20 seconds"
  sleep 20

  scp $0 $novacontroller:
  ssh $novacontroller "waitforrebootcompute=1 bash -x ./$0 $cloud"
  ret=$?
  echo "ret:$ret"
  exit $ret
}

function waitforrebootcompute()
{
  . .openrc
  nova list
  nova reboot testvm
  nova list
  vmip=`nova show testvm | perl -ne 'm/ fixed.network [ |]*([0-9.]+)/ && print $1'`
  wait_for 100 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm to boot up"
}

function create_owasp_testsuite_config()
{
  get_novadashboardserver
  cat > ${1:-openstack_horizon-testing.ini} << EOOWASP
[DEFAULT]
; OpenStack Horizon (Django) responses with 403 FORBIDDEN if the token does not match
csrf_token_regex = name=\'csrfmiddlewaretoken\'.*value=\'([A-Za-z0-9\/=\+]*)\'
csrf_token_name = csrfmiddlewaretoken
csrf_uri = https://${novadashboardserver}:443/
cookie_name = sessionid

; SSL setup
[OWASP_CM_001]
skip = 0
dbg = 0
host = ${novadashboardserver}
port = 443
; 0=no debugging, 1=ciphers, 2=trace, 3=dump data, unfortunately just using this causes debugging regardless of the value
ssleay_trace = 0
; Add sleep so broken servers can keep up
ssleay_slowly = 1
sslscan_path = /usr/bin/sslscan
weak_ciphers = RC2, NULL, EXP
short_keys = 40, 56

; HTTP Methods, HEAD bypass, and XST
[OWASP_CM_008]
skip = 0
dbg = 0
host = ${novadashboardserver}
port = 443
; this doesnt work when the UID is in a cookie
uri_private = /nova

; user enumeration
[OWASP_AT_002]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
login_method = POST
logout_method = GET
cred_valid = method=Login&username=admin&password=crowbar
cred_invalid_pass = method=Login&username=admin&password=WRONG
cred_invalid_user = method=Login&username=WRONG&password=WRONG
uri_user_valid = https://${novadashboardserver}:443/doesnotwork
uri_user_invalid = https://${novadashboardserver}:443/doesntworkeither

; Logout and Browser Cache Management
[OWASP_AT_007]
; this testcase causes a false positive, maybe use regex to detect redirect to login page
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_private = https://${novadashboardserver}:443/nova
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
login_regex = An error occurred authenticating
cookie_name = sessionid
timeout = 600

; Path Traversal
[OWASP_AZ_001]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_file = https://${novadashboardserver}:443/auth/login?next=/FUZZ/
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; cookies attributes
[OWASP_SM_002]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; Session Fixation
[OWASP_SM_003]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_public = https://${novadashboardserver}:443/
login_method = POST
logout_method = GET
;login_regex = \"Couldn\'t log you in as\"
login_regex = An error occurred authenticating
cred_attacker = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=Mini Me&password=minime123
cred_victim = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
cookie_name = sessionid

; Exposed Session Variables
[OWASP_SM_004]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_public = https://${novadashboardserver}:443/
login_method = POST
logout_method = GET
login_regex = An error occurred authenticating
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; CSRF
[OWASP_SM_005]
; test does not work because the Customer Center has no POST action
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_private = https://${novadashboardserver}:443/i18n/setlang/
uri_private_form = "language=fr"
login_method = POST
logout_method = GET
login_regex = An error occurred authenticating
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; Reflected Cross site scripting
[OWASP_DV_001]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_page = https://${novadashboardserver}/nova/?month=FUZZ&year=FUZZ
fuzz_file = fuzzdb-read-only/attack-payloads/xss/xss-rsnake.txt
request_method = GET
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; Stored Cross site scripting
[OWASP_DV_002]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/
uri_logout = https://${novadashboardserver}:443/auth/logout/
; page fo data input
uri_page_fuzz = https://${novadashboardserver}/nova/?month=FUZZ&year=FUZZ
; page that displays the malicious input
uri_page_stored = https://${novadashboardserver}/nova/
fuzz_file = fuzzdb-read-only/attack-payloads/xss/xss-rsnake.txt
request_method = GET
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; SQL Injection
[OWASP_DV_005]
skip = 1 ; untested
dbg = 1
uri_login = https://${novadashboardserver}:443/
uri_logout = https://${novadashboardserver}:443/auth/logout/
uri_page = https://${novadashboardserver}:443/?email=thomas%40suse.de&password=lalalala&commit=FUZZ
fuzz_file = fuzzdb-read-only/attack-payloads/sql-injection/detect/GenericBlind.fuzz.txt
request_method = POST
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F10.122.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
detect_http_code = 302
EOOWASP
}



function securitytests()
{
  # download latest owasp package
  owaspdomain=clouddata.cloud.suse.de   # works only SUSE-internally for now
  owasppath=/tools/security-testsuite/
  #owaspdomain=download.opensuse.org
  #owasppath=/repositories/home:/thomasbiege/openSUSE_Factory/noarch/

  owaspsource=http://$owaspdomain$owasppath
  rm -rf owasp
  mkdir -p owasp

  zypper lr | grep -q devel_languages_perl || zypper ar http://download.opensuse.org/repositories/devel:/languages:/perl/$slesdist/devel:languages:perl.repo
  # pulled in automatically
  #zypper --non-interactive in perl-HTTP-Cookies perl-Config-Simple

  wget --progress=dot:mega -r --directory-prefix owasp -np -nc -A "owasp*.rpm","sslscan*rpm" $owaspsource
  zypper --non-interactive --gpg-auto-import-keys in `find owasp/ -type f -name "*rpm"`

  pushd /usr/share/owasp-test-suite >/dev/null
  # create config
  owaspconf=openstack_horizon-testing.ini
  create_owasp_testsuite_config $owaspconf

  # call tests
  ./owasp.pl output=short $owaspconf
  ret=$?
  popd >/dev/null
  exit $ret
}


function teardown()
{
  #BMCs at 10.122.178.163-6 #node 6-9
  #BMCs at 10.122.$net.163-4 #node 11-12

  # undo propsal create+commit
  for service in nova_dashboard nova glance ceph swift keystone database ; do
    crowbar "$service" proposal delete default
    crowbar "$service" delete default
  done

  for node in $(crowbar machines list | grep ^d) ; do
    crowbar machines delete $node
  done
}

#-------------------------------------------------------------------------------
#--
#-- for compatibility to legacy calling style
#--
#
# in the long run all steps should be transformed into real functions, just
# like in mkcloud; this makes it easier to read, understand and edit this file
#


if [ -n "$prepareinstallcrowbar" ] ; then
  prepareinstallcrowbar
  exit $?
fi

if [ -n "$installcrowbar" ] ; then
  installcrowbar
  exit $?
fi

if [ -n "$addupdaterepo" ] ; then
  addupdaterepo
  exit $?
fi

if [ -n "$runupdate" ] ; then
  runupdate
  exit $?
fi

if [ -n "$rebootcompute" ] ; then
  rebootcompute
  exit $?
fi

if [ -n "$waitforrebootcompute" ] ; then
  waitforrebootcompute
  exit $?
fi

if [ -n "$securitytests" ] ; then
  securitytests
  exit $?
fi

if [ -n "$tempestconfigure" ] ; then
  tempest_configure
  exit $?
fi

if [ -n "$tempestrun" ] ; then
  tempest_run
  exit $?
fi

if [ -n "$teardown" ] ; then
  teardown
  exit $?
fi
