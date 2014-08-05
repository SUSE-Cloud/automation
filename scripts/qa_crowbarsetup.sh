#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual
test $(uname -m) = x86_64 || echo "ERROR: need 64bit"
#resize2fs /dev/vda2

novacontroller=
novadashboardserver=
export cloud=${1}
export cloudfqdn=${cloudfqdn:-$cloud.cloud.suse.de}
export nodenumber=${nodenumber:-2}
export tempestoptions=${tempestoptions:--t -s}
export nodes=
export debug=${debug:-0}
export cinder_conf_volume_type=${cinder_conf_volume_type:-""}
export cinder_conf_volume_params=${cinder_conf_volume_params:-""}
export localreposdir_target=${localreposdir_target:-""}
export want_ipmi=${want_ipmi:-false}

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

if [ -z $cloud ] ; then
    echo "Error: Parameter missing that defines the cloud name"
    echo "Possible values: [d1, d2, p, virtual]"
    echo "Example: $0 d2"
    exit 101
fi

# common cloud network prefix within SUSE Nuremberg:
netp=10.122
net=${net_admin:-192.168.124}
case "$cloud" in
    d1)
        net=$netp.178
        net_storage=$netp.179
        net_public=$netp.177
        net_fixed=$netp.176
        vlan_storage=568
        vlan_public=567
        vlan_fixed=566
        want_ipmi=true
    ;;
    d2)
        net=$netp.186
        net_storage=$netp.187
        net_public=$netp.185
        net_fixed=$netp.184
        vlan_storage=581
        vlan_public=580
        vlan_fixed=569
        want_ipmi=true
    ;;
    d3)
        net=$netp.189
        net_public=$netp.188
        vlan_storage=586
        vlan_public=588
        vlan_fixed=589
        want_ipmi=true
    ;;
    p2)
        net=$netp.171
        net_storage=$netp.172
        net_public=$netp.164
        net_fixed=44.0.0
        vlan_storage=563
        vlan_public=564
        vlan_fixed=565
        want_ipmi=true
    ;;
    p)
        net=$netp.169
        net_storage=$netp.170
        net_public=$netp.168
        net_fixed=$netp.160
        vlan_storage=565
        vlan_public=564
        vlan_fixed=563
        want_ipmi=true
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
                true # defaults are fine (and overridable)
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
    local timecount=${1:-300}
    local timesleep=${2:-1}
    local condition=${3:-'/bin/true'}
    local waitfor=${4:-'unknown process'}
    local error_cmd=${5:-'exit 11'}

    echo "Waiting for: $waitfor"
    local n=$timecount
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

function mount_localreposdir_target()
{
    if [ -z "$localreposdir_target" ]; then
        return
    fi
    mkdir -p $localreposdir_target
    if ! grep -q "$localreposdir_target\s\+$localreposdir_target" /etc/fstab ; then
        echo "$localreposdir_target $localreposdir_target 9p    ro,trans=virtio,version=9p2000.L,msize=262144  0 0" >> /etc/fstab
    fi
    mount "$localreposdir_target"
}

function add_bind_mount()
{
    local src="$1"
    local dst="$2"
    mkdir -p "${dst}"

    if ! [ -d "${src}" ] ; then
        echo "source ${src} for bind-mount does not exist"
        exit 1
    fi

    umount "${dst}"
    if ! grep -q "$src\s\+$dst" /etc/fstab ; then
        echo "$src $dst bind defaults,bind  0 0" >> /etc/fstab
    fi
    mount "$dst"
}

function add_nfs_mount()
{
    local nfs="$1"
    local dir="$2"

    # skip if dir has content
    test -d "$dir"/rpm && return

    mkdir -p "$dir"
    if grep -q "$nfs\s\+$dir" /etc/fstab ; then
        return
    fi

    echo "$nfs $dir nfs    ro,nosuid,rsize=8192,wsize=8192,hard,intr,nolock  0 0" >> /etc/fstab
    mount "$dir"
}

function add_mount()
{
    local bindsrc="$1"
    local nfssrc="$2"
    local targetdir="$3"
    local zypper_alias="$4"
    if [ -n "${localreposdir_target}" ]; then
        add_bind_mount "${localreposdir_target}/${bindsrc}" "${targetdir}"
    else
        add_nfs_mount "${nfssrc}" "${targetdir}"
    fi
    if [ -n "${zypper_alias}" ]; then
        zypper rr "${zypper_alias}"
        zypper ar -f "${targetdir}" "${zypper_alias}"
    fi
}

function iscloudver()
{
    local v=$1
    local bplus=""
    if [[ $v =~ plus ]] ; then
        v=${v%%plus}
        bplus=$(($v+1))plus
    fi
    case "$v" in
        2)
            [[ $cloudsource =~ 2.0 ]]
            ;;
        3)
            [[ $cloudsource =~ 3 ]]
            ;;
        4)
            [[ $cloudsource =~ 4 ]]
            ;;
        *)
            return 1
            ;;
    esac
    [ $? = 0 ] && return 0
    if [ -n "$bplus" ] ; then
        iscloudver $bplus
        return $?
    fi
    return 1
}

# inner part of our test of iscloudver function
function iscloudvertest()
{
    iscloudver 2
    echo v2=$?
    iscloudver 2plus
    echo v2plus=$?
    iscloudver 3
    echo v3=$?
    iscloudver 3plus
    echo v3plus=$?
}
# outer part of our test of iscloudver function
function iscloudvertest2()
{
    local cloudsource
    for cloudsource in susecloud2.0 develcloud3 develcloud4 ; do
        echo "cloudsource=$cloudsource"
        iscloudvertest
    done
    exit 0
}

function addsp3testupdates()
{
    add_mount "SLES11-SP3-Updates" 'you.suse.de:/you/http/download/x86_64/update/SLE-SERVER/11-SP3/' "/srv/tftpboot/repos/SLES11-SP3-Updates/" "sp3tup"
}

function addcloud2testupdates()
{
    add_mount "SUSE-Cloud-2-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/2.0/' "/srv/tftpboot/repos/SUSE-Cloud-2-Updates/" "cloudtup"
}

function addcloud3testupdates()
{
    add_mount "SUSE-Cloud-3-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/3.0/' "/srv/tftpboot/repos/SUSE-Cloud-3-Updates/" cloudtup
}

function addcloud4testupdates()
{
    add_mount "SUSE-Cloud-4-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/4/' "/srv/tftpboot/repos/SUSE-Cloud-4-Updates/" "cloudtup"
}

function add_ha_repo()
{
    slesdist="$1"
    didha=
    if iscloudver 3plus ; then
        if [ "$slesdist" = "SLE_11_SP3" ] ; then
            local repo
            for repo  in "SLE11-HAE-SP3-Pool" "SLE11-HAE-SP3-Updates" "SLE11-HAE-SP3-Updates-test" ; do
                add_mount "${repo}" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" "/srv/tftpboot/repos/$repo"
            done
            didha=1
        fi
    fi

    if [ -z "$didha" ] ; then
        echo "Error: You requested a HA setup but for this combination ($cloudsource : $slesdist) no HA setup is available."
        exit 1
    fi
}

function h_prepare_cloud_repos()
{
    local targetdir="/srv/tftpboot/repos/Cloud/"
    mkdir -p ${targetdir}

    if [ -n "${localreposdir_target}" ]; then
        add_bind_mount "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-x86_64/" "${targetdir}"
        echo $CLOUDLOCALREPOS > /etc/cloudversion
    else
        cd ${targetdir}
        mkdir -p /mnt/cloud
        wget --progress=dot:mega -r -np -nc -A "$CLOUDDISTISO" http://$susedownload$CLOUDDISTPATH/
        local CLOUDISO=$(ls */$CLOUDDISTPATH/*.iso|tail -1)
        echo $CLOUDISO > /etc/cloudversion
        mount -o loop,ro -t iso9660 $CLOUDISO /mnt/cloud
        rsync -av --delete-after /mnt/cloud/ . ; umount /mnt/cloud
    fi
    echo -n "This cloud was installed on `cat ~/cloud` from: " | cat - /etc/cloudversion >> /etc/motd

    if [ ! -e "${targetdir}/media.1" ] ; then
        echo "We do not have cloud install media in ${targetdir} - giving up"
        exit 35
    fi

    zypper rr Cloud
    zypper ar -f ${targetdir} Cloud
}

function prepareinstallcrowbar()
{
    echo configure static IP and absolute + resolvable hostname crowbar.$cloudfqdn gw:$net.1
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
    echo "crowbar.$cloudfqdn" > /etc/HOSTNAME
    hostname `cat /etc/HOSTNAME`
    # these vars are used by rabbitmq
    export HOSTNAME=`cat /etc/HOSTNAME`
    export HOST=$HOSTNAME
    grep -q "$net.*crowbar" /etc/hosts || echo $net.10 crowbar.$cloudfqdn crowbar >> /etc/hosts
    rcnetwork restart
    hostname -f # make sure it is a FQDN
    ping -c 1 `hostname -f`
    longdistance=${longdistance:-false}
    if [[ $(ping -q -c1 clouddata.cloud.suse.de|perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]] ; then
        longdistance=true
    fi

    if [ -n "${localreposdir_target}" ]; then
        for x in `seq 1 10` ; do
            zypper rr 1
        done
    fi

    suseversion=11.3
    : ${susedownload:=download.nue.suse.com}
    case "$cloudsource" in
        develcloud2.0)
            CLOUDDISTPATH=/ibs/Devel:/Cloud:/2.0/images/iso
            [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/2.0:/Staging/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-2-devel"
        ;;
        develcloud3)
            CLOUDDISTPATH=/ibs/Devel:/Cloud:/3/images/iso
            [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/3:/Staging/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-3-devel"
        ;;
        develcloud4)
            CLOUDDISTPATH=/ibs/Devel:/Cloud:/4/images/iso
            [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/4:/Staging/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-devel"
        ;;
        susecloud2.0)
            CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/GA:/Products:/Test/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-2-official"
        ;;
        susecloud3)
            CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/Update:/Products:/Test/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-3-official"
        ;;
        susecloud4)
            CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/Update:/Cloud4:/Test/images/iso
            CLOUDDISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-official"
        ;;
        GM2.0)
            CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-GM/
            CLOUDDISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-2-official"
        ;;
        GM3)
            CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-3-GM/
            CLOUDDISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-3-official"
        ;;
        Beta*|RC*|GMC*|GM4)
            cs=$cloudsource
            [ $cs = GM4 ] && cs=GM
            CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-4-$cs/
            CLOUDDISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-official"
        ;;
        *)
            echo "Error: you must set environment variable cloudsource=develcloud4|susecloud4|GM3"
            exit 76
        ;;
    esac

    case "$suseversion" in
        11.3)
            slesrepolist="SLES11-SP3-Pool SLES11-SP3-Updates"
            slesversion=11-SP3
            slesdist=SLE_11_SP3
            slesmilestone=GM
        ;;
    esac

    zypper se -s sles-release|grep -v -e "sp.up\s*$" -e "(System Packages)" |grep -q x86_64 || zypper ar http://$susedownload/install/SLP/SLES-${slesversion}-LATEST/x86_64/DVD1/ sles

    if [ "x$WITHSLEUPDATES" != "x" ] ; then
        if [ $suseversion = "11.3" ] ; then
            zypper ar "http://euklid.nue.suse.com/mirror/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER/$slesversion/" ${slesversion}-up
        fi
    fi

    [ -n "$hacloud" ] && add_ha_repo "$slesdist"

    zypper -n install rsync netcat

    # setup cloud repos for tftpboot and zypper
    h_prepare_cloud_repos

    if [ -n "$TESTHEAD" ] ; then
        case "$cloudsource" in
            develcloud2.0)
                addsp3testupdates
                ;;
            susecloud3)
                addsp3testupdates
                addcloud3testupdates
                ;;
            develcloud3)
                addsp3testupdates
                ;;
            susecloud4|GM4)
                addsp3testupdates
                addcloud4testupdates
                ;;
            develcloud4)
                addsp3testupdates
                ;;
            GM2.0)
                addsp3testupdates
                addcloud2testupdates
                ;;
            GM3)
                addsp3testupdates
                addcloud3testupdates
                ;;
            *)
                echo "no TESTHEAD repos defined for cloudsource=$cloudsource"
                exit 26
                ;;
        esac
    fi
    # --no-gpg-checks for Devel:Cloud repo
    zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
    zypper -n dup -r Cloud -r cloudtup # to upgrade pre-installed packages
    # disable extra repos
    zypper mr -d sp3sdk

    if [ -z "$NOINSTALLCLOUDPATTERN" ] ; then
        zypper --no-gpg-checks -n in -l -t pattern cloud_admin
        local ret=$?

        if [ $ret = 0 ] ; then
            echo "The cloud admin successfully installed."
            echo ".... continuing"
        else
            echo "Error: zypper returned with exit code $? when installing cloud admin"
            exit 86
        fi
    fi

    if ! $longdistance ; then
        #FIXME (toabctl): path should use $suseversion and not hardcoded 11.3
        add_mount "${localreposdir_target}/SLES11-SP3-GM/sle-11-x86_64/" "clouddata.cloud.suse.de:/srv/nfs/suse-$suseversion/install" "/srv/tftpboot/suse-$suseversion/install/"
    fi

    local REPO

    for REPO in $slesrepolist ; do
        add_mount "${localreposdir_target}/${REPO}/sle-11-x86_64/" "clouddata.cloud.suse.de:/srv/nfs/repos/$REPO" "/srv/tftpboot/repos/$REPO"
    done

    # just as a fallback if nfs did not work
    if [ ! -e "/srv/tftpboot/suse-$suseversion/install/media.1/" ] ; then
        local f=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
        local p=/srv/tftpboot/suse-$suseversion/$f
        wget --progress=dot:mega -nc -O$p http://$susedownload/install/SLES-$slesversion-$slesmilestone/$f
        echo $p /srv/tftpboot/suse-$suseversion/install/ iso9660 loop,ro >> /etc/fstab
        mount /srv/tftpboot/suse-$suseversion/install/
    fi
    if [ ! -e "/srv/tftpboot/suse-$suseversion/install/media.1/" ] ; then
        echo "We do not have SLES install media - giving up"
        exit 34
    fi
    cd /tmp

    local netfile="/opt/dell/chef/data_bags/crowbar/bc-template-network.json"
    local netfilepatch=`basename $netfile`.patch
    [ -e ~/$netfilepatch ] && patch -p1 $netfile < ~/$netfilepatch

    # to revert https://github.com/crowbar/barclamp-network/commit/a85bb03d7196468c333a58708b42d106d77eaead
    sed -i.netbak1 -e 's/192\.168\.126/192.168.122/g' $netfile

    sed -i.netbak -e 's/"conduit": "bmc",/& "router": "192.168.124.1",/' \
        -e "s/192.168.124/$net/g" \
        -e "s/192.168.125/$net_storage/g" \
        -e "s/192.168.123/$net_fixed/g" \
        -e "s/192.168.122/$net_public/g" \
        -e "s/200/$vlan_storage/g" \
        -e "s/300/$vlan_public/g" \
        -e "s/500/$vlan_fixed/g" \
        -e "s/[47]00/$vlan_sdn/g" \
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
    local f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
    grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

    # workaround for performance bug (bnc#770083)
    sed -i -e "s#<\(partitions.*\)/>#<\1><partition><mount>swap</mount><size>auto</size></partition><partition><mount>/</mount><size>max</size><fstopt>data=writeback,barrier=0,noatime</fstopt></partition></partitions>#" /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
    # set default password to 'linux'
    # setup_base_images.rb is for SUSE Cloud 1.0 and update_nodes.rb is for 2.0
    sed -i -e 's/\(rootpw_hash.*\)""/\1"$2y$10$u5mQA7\/8YjHdutDPEMPtBeh\/w8Bq0wEGbxleUT4dO48dxgwyPD8D."/' /opt/dell/chef/cookbooks/provisioner/recipes/setup_base_images.rb /opt/dell/chef/cookbooks/provisioner/recipes/update_nodes.rb

    # exit code of the sed don't matter, so just:
    return 0
}

function do_installcrowbar()
{
    local instcmd=$1
    echo "Command to install chef: $instcmd"
    intercept "install-chef-suse.sh"

    rm -f /tmp/chef-ready
    rpm -Va crowbar\*
    export REPOS_SKIP_CHECKS="Cloud SUSE-Cloud-1.0-Pool SUSE-Cloud-1.0-Updates"
    # run in screen to not lose session in the middle when network is reconfigured:
    screen -d -m -L /bin/bash -c "$instcmd ; touch /tmp/chef-ready"
    local n=300
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

    # Make sure install finished correctly
    if ! [ -e /opt/dell/crowbar_framework/.crowbar-installed-ok ]; then
        echo "Crowbar ".crowbar-install-ok" marker missing"
        tail -n 90 /root/screenlog.0
        exit 89
    fi

    rccrowbar status || rccrowbar start
    [ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

    sleep 20
    if ! curl -m 59 -s http://localhost:3000 > /dev/null || ! curl -m 59 -s --digest --user crowbar:crowbar localhost:3000 | grep -q /nodes/crowbar ; then
        tail -n 90 /root/screenlog.0
        echo "crowbar self-test failed"
        exit 84
    fi

    if ! crowbar machines list | grep -q crowbar.$cloudfqdn ; then
        tail -n 90 /root/screenlog.0
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

    if iscloudver 4plus; then
        zypper -n install crowbar-barclamp-tempest
    fi

    if ! validate_data_bags; then
        echo "Validation error in default data bags. Aborting."
        exit 68
    fi
}


function installcrowbarfromgit()
{
    do_installcrowbar "CROWBAR_FROM_GIT=1 /opt/dell/bin/install-chef-suse.sh --from-git --verbose"
}

function installcrowbar()
{
    do_installcrowbar "if [ -e /tmp/install-chef-suse.sh ] ; then /tmp/install-chef-suse.sh --verbose ; else /opt/dell/bin/install-chef-suse.sh --verbose ; fi"
}

function allocate()
{
    #chef-client
    if $want_ipmi ; then
        do_one_proposal ipmi default
        local nodelist="3 4 5 6 7 8"
        # protect machine 3 on d2 for tomasz
        if [ "$cloud" = "d2" ]; then
            nodelist="4 5"
        fi
        local i
        for i in $nodelist ; do
            local pw
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
    local nodes=$(crowbar machines list | grep ^d)
    local n
    for n in $nodes ; do
        wait_for 100 2 "knife node show -a state $n | grep discovered" "node to enter discovered state"
    done
    echo "Sleeping 50 more seconds..."
    sleep 50
    echo "Setting first node to controller..."
    local controllernode=$(crowbar machines list | sort | grep ^d | head -n 1)
    local t=$(mktemp).json

    knife node show -F json $controllernode > $t
    json-edit $t -a normal.crowbar_wall.intended_role -v "controller"
    knife node from file $t
    rm -f $t

    echo "Allocating nodes..."
    local m
    for m in `crowbar machines list | grep ^d` ; do
        while knife node show -a state $m | grep discovered; do # workaround bnc#773041
            crowbar machines allocate "$m"
            sleep 10
        done
    done

    # check for error 500 in app/models/node_object.rb:635:in `sort_ifs'#012
    curl -m 9 -s --digest --user crowbar:crowbar http://localhost:3000| tee /root/crowbartest.out
    if grep -q "Exception caught" /root/crowbartest.out; then
        exit 27
    fi
}

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

function do_waitcompute()
{
    local node
    for node in $(crowbar machines list | grep ^d) ; do
        wait_for 180 10 "sshtest $node rpm -q yast2-core" "node $node" "check_node_resolvconf $node; exit 12"
        echo "node $node ready"
    done
}


function waitnodes()
{
    local n=800
    local mode=$1
    local proposal=$2
    local proposaltype=${3:-default}
    case "$mode" in
        nodes)
            echo -n "Waiting for nodes to get ready: "
            local i
            for i in `crowbar machines list | grep ^d` ; do
                local machinestatus=''
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
            echo -n "Waiting for proposal $proposal($proposaltype) to get successful: "
            local proposalstatus=''
            while test $n -gt 0 && ! test "x$proposalstatus" = "xsuccess" ; do
                proposalstatus=`crowbar $proposal proposal show $proposaltype | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['$proposal']['crowbar-status']"`
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


# generic function to modify values in proposals
#   Note: strings have to be quoted like this: "'string'"
#         "true" resp. "false" or "['one', 'two']" act as ruby values, not as string
function proposal_modify_value()
{
    local proposal="$1"
    local proposaltype="$2"
    local variable="$3"
    local value="$4"
    local operator="${5:-=}"

    local pfile=/root/${proposal}.${proposaltype}.proposal

    crowbar $proposal proposal show $proposaltype |
        ruby -e "require 'rubygems';require 'json';
                j=JSON.parse(STDIN.read);
                j${variable}${operator}${value};
                puts JSON.pretty_generate(j)" > $pfile
    crowbar $proposal proposal --file=$pfile edit $proposaltype
}

# wrapper for proposal_modify_value
function proposal_set_value()
{
    proposal_modify_value "$1" "$2" "$3" "$4" "="
}

# wrapper for proposal_modify_value
function proposal_increment_int()
{
    proposal_modify_value "$1" "$2" "$3" "$4" "+="
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
    local proposal=$1
    local proposaltype=${2:-default}

    local crowbaredit="crowbar $proposal proposal edit $proposaltype"
    if [[ $debug = 1 && $proposal != swift ]] ; then
        EDITOR='sed -i -e "s/debug\": false/debug\": true/" -e "s/verbose\": false/verbose\": true/"' $crowbaredit
    fi
    case "$proposal" in
        ipmi)
            proposal_set_value ipmi default "['attributes']['ipmi']['bmc_enable']" true
        ;;
        keystone)
            if [[ $all_with_ssl = 1 || $keystone_with_ssl = 1 ]] ; then
                enable_ssl_for_keystone
            fi
        ;;
        glance)
            if [[ $all_with_ssl = 1 || $glance_with_ssl = 1 ]] ; then
                enable_ssl_for_glance
            fi
            if [[ -n "$wantceph" ]]; then
                proposal_set_value glance default "['attributes']['glance']['default_store']" "'rbd'"
            fi
        ;;
        ceph)
            if iscloudver 2; then
                manual_2device_ceph_proposal
            else
                proposal_set_value ceph default "['attributes']['ceph']['disk_mode']" "'all'"
            fi
        ;;
        nova)
            # custom nova config of libvirt
            [ -n "$libvirt_type" ] || libvirt_type='kvm';
            proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
            proposal_set_value nova default "['attributes']['nova']['use_migration']" "true"
            EDITOR="sed -i -e 's/nova-multi-compute-$libvirt_type/nova-multi-compute-xxx/g; s/nova-multi-compute-kvm/nova-multi-compute-$libvirt_type/g; s/nova-multi-compute-xxx/nova-multi-compute-kvm/g'" $crowbaredit # FIXME replace with ruby json to be idempotent

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
            [[ "$networkingplugin" = linuxbridge ]] && networkingmode=vlan
            if iscloudver 4plus; then
                proposal_set_value neutron default "['attributes']['neutron']['use_lbaas']" "true"
            fi
            if [ -n "$networkingplugin" ] ; then
                proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'$networkingplugin'"
            fi
            if [ -n "$networkingmode" ] ; then
                proposal_set_value neutron default "['attributes']['neutron']['networking_mode']" "'$networkingmode'"
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
            if iscloudver 3plus ; then
                proposal_set_value swift default "['attributes']['swift']['ssl']['generate_certs']" "true"
                proposal_set_value swift default "['attributes']['swift']['ssl']['insecure']" "true"
                proposal_set_value swift default "['attributes']['swift']['allow_versions']" "true"
                proposal_set_value swift default "['attributes']['swift']['keystone_delay_auth_decision']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['crossdomain']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['formpost']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['staticweb']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['tempurl']['enabled']" "true"
            fi
        ;;
        cinder)
            if iscloudver 4plus ; then
                proposal_set_value cinder default "['attributes']['cinder']['enable_v2_api']" "true"

                volumes="['attributes']['cinder']['volumes']"
                proposal_set_value cinder default "${volumes}[0]['${cinder_conf_volume_type}']" "j['attributes']['cinder']['volume_defaults']['${cinder_conf_volume_type}']"
                proposal_set_value cinder default "${volumes}[0]['backend_driver']" "'${cinder_conf_volume_type}'"

                if [ -n "$cinder_conf_volume_params" ]; then
                    echo "${cinder_conf_volume_params}" | while read -a l; do
                        case "$cinder_conf_volume_type" in
                            netapp)
                                proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['netapp']['${l[0]}']" "${l[1]}"
                                ;;
                            *)
                                echo "Warning: selected cinder volume type $cinder_conf_volume_type is currently not supported"
                                ;;
                        esac
                    done
                fi

                # add a second backend to enable multi-backend, if not already present
                if ! crowbar cinder proposal show default | grep -q local-multi; then
                    proposal_modify_value cinder default "${volumes}" "{ 'backend_driver' => 'local', 'backend_name' => 'local-multi', 'local' => { 'volume_name' => 'cinder-volumes-multi', 'file_size' => 2000, 'file_name' => '/var/lib/cinder/volume-multi.raw'} }" "<<"
                fi
            else
                proposal_set_value cinder default "['attributes']['cinder']['volume']['volume_type']" "'${cinder_conf_volume_type}'"

                if [ -n "$cinder_conf_volume_params" ]; then
                    echo "${cinder_conf_volume_params}" | while read -a l; do
                        case "$cinder_conf_volume_type" in
                            netapp)
                                proposal_set_value cinder default "['attributes']['cinder']['volume']['netapp']['${l[0]}']" "${l[1]}"
                                ;;
                            *)
                                echo "Warning: selected cinder volume type $cinder_conf_volume_type is currently not supported"
                                ;;
                        esac
                    done
                fi
            fi
        ;;
        *) echo "No hooks defined for service: $proposal"
        ;;
    esac
}

function get_crowbarnodes()
{
    #FIXME this is ugly
    [ -x /opt/dell/bin/crowbar ] && nodes=`crowbar machines list | grep ^d`
}


function set_proposalvars()
{
    get_crowbarnodes
    wantswift=1
    wantceph=1
    iscloudver 2 && wantceph=
    wanttempest=
    iscloudver 4plus && wanttempest=1

    # FIXME: Ceph is currently broken
    #iscloudver 4 && {
    #    echo "WARNING: ceph currently disabled as it is broken"
    #    echo "https://bugzilla.novell.com/show_bug.cgi?id=872326"
    #    wantceph=
    #}

    [[ "$nodenumber" -lt 3 || "$cephvolumenumber" -lt 1 ]] && wantceph=
    # we can not use both swift and ceph as each grabs all disks on a node
    [[ -n "$wantceph" ]] && wantswift=
    [[ "$cephvolumenumber" -lt 1 ]] && wantswift=
    crowbar_networking=neutron
    iscloudver 2 && crowbar_networking=quantum

    if [[ -z "$cinder_conf_volume_type" ]]; then
        if [[ -n "$wantceph" ]]; then
            cinder_conf_volume_type="rbd"
        elif [[ "$cephvolumenumber" -lt 2 ]]; then
            cinder_conf_volume_type="local"
        else
            cinder_conf_volume_type="raw"
        fi
    fi
}

function do_one_proposal()
{
    local proposal=$1
    local proposaltype=${2:-default}

    crowbar "$proposal" proposal create $proposaltype
    # hook for changing proposals:
    custom_configuration $proposal $proposaltype
    crowbar "$proposal" proposal commit $proposaltype
    local ret=$?
    echo "Commit exit code: $ret"
    if [ "$ret" = "0" ]; then
        waitnodes proposal $proposal $proposaltype
        ret=$?
        echo "Proposal exit code: $ret"
        sleep 10
    fi
    if [ $ret != 0 ] ; then
        tail -n 90 /opt/dell/crowbar_framework/log/d*.log /var/log/crowbar/chef-client/d*.log
        echo "Error: commiting the crowbar '$proposaltype' proposal for '$proposal' failed ($ret)."
        exit 73
    fi
}

function do_proposal()
{
    waitnodes nodes
    local proposals="database rabbitmq keystone ceph glance cinder $crowbar_networking nova nova_dashboard swift ceilometer heat tempest"

    local proposal
    for proposal in $proposals ; do
        # proposal filter
        case "$proposal" in
            ceph)
                [[ -n "$wantceph" ]] || continue
                ;;
            swift)
                [[ -n "$wantswift" ]] || continue
                ;;
            tempest)
                [[ -n "$wanttempest" ]] || continue
                ;;
        esac

        # create proposal
        case "$proposal" in
            *)
                do_one_proposal "$proposal" "default"
                ;;
        esac
    done

    # Set dashboard node alias
    get_novadashboardserver
    set_node_alias `echo "$novadashboardserver" | cut -d . -f 1` dashboard
}

function set_node_alias()
{
    local node_name=$1
    local node_alias=$2
    if [[ "${node_name}" != "${node_alias}" ]]; then
        crowbar machines rename ${node_name} ${node_alias}
    fi
}

function get_novacontroller()
{
    novacontroller=`crowbar nova proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova']['elements']['nova-multi-controller']"`
}


function get_novadashboardserver()
{
    novadashboardserver=`crowbar nova_dashboard proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova_dashboard']['elements']['nova_dashboard-server']"`
}

function get_ceph_nodes()
{
    if [[ -n "$wantceph" ]]; then
        cephmons=`crowbar ceph proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-mon']"`
        cephosds=`crowbar ceph proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-osd']"`
        cephradosgws=`crowbar ceph proposal show default | ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-radosgw']"`
    else
        cephmons=
        cephosds=
        cephradosgws=
    fi
}


function do_testsetup()
{
    get_novacontroller
    if [ -z "$novacontroller" ] || ! ssh $novacontroller true ; then
        echo "no nova contoller - something went wrong"
        exit 62
    fi
    echo "openstack nova contoller: $novacontroller"
    curl -m 40 -s http://$novacontroller | grep -q -e csrfmiddlewaretoken -e "<title>302 Found</title>" || exit 101

    wantcephtestsuite=0
    if [[ -n "$wantceph" ]]; then
        get_ceph_nodes
        echo "ceph mons:" $cephmons
        echo "ceph osds:" $cephosds
        echo "ceph radosgw:" $cephradosgws
        iscloudver 4plus && wantcephtestsuite=1
    fi

    ssh $novacontroller "export wantswift=$wantswift ; export wantceph=$wantceph ; export wanttempest=$wanttempest ;
        export tempestoptions=\"$tempestoptions\" ; export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ; "'set -x
        . .openrc
        export LC_ALL=C
                if [[ -n $wantswift ]] ; then
                    zypper -n install python-swiftclient
                    swift stat
                    swift upload container1 .ssh/authorized_keys
                    swift list container1 || exit 33
                fi

                cephret=0
                if [ -n "$wantceph" -a "$wantcephtestsuite" == 1 ] ; then
                    rpm -q git-core &> /dev/null || zypper -n install git-core

                    if test -d qa-automation; then
                        pushd qa-automation
                        git reset --hard
                        git pull
                    else
                        git clone git://git.suse.de/ceph/qa-automation.git
                        pushd qa-automation
                    fi

                    # write configuration files that we need
                    cat > setup.cfg <<EOH
[env]
loglevel = debug
EOH

                    # test suite will expect node names without domain, and in the right
                    # order; since we will write them in reverse order, use a sort -r here
                    yaml_allnodes=`echo $cephmons $cephosds | sed "s/ /\n/g" | sed "s/\..*//g" | sort -ru`
                    yaml_mons=`echo $cephmons | sed "s/ /\n/g" | sed "s/\..*//g" | sort -ru`
                    yaml_osds=`echo $cephosds | sed "s/ /\n/g" | sed "s/\..*//g" | sort -ru`
                    # for radosgw, we only want one node, so enforce that
                    yaml_radosgw=`echo $cephradosgws | sed "s/ .*//g" | sed "s/\..*//g"`
                    ceph_version=`rpm -q --qf %{version} ceph`

                    sed -i "s/^ceph_version:.*/ceph_version: $ceph_version/g" yamldata/testcloud_sanity.yaml
                    sed -i "s/^radosgw_node:.*/radosgw_node: $yaml_radosgw/g" yamldata/testcloud_sanity.yaml

                    sed -i "/teuthida-4/d" yamldata/testcloud_sanity.yaml
                    for node in $yaml_allnodes; do
                        sed -i "/^allnodes:$/a - $node" yamldata/testcloud_sanity.yaml
                    done
                    for node in $yaml_mons; do
                        sed -i "/^initmons:$/a - $node" yamldata/testcloud_sanity.yaml
                    done
                    for node in $yaml_osds; do
                        sed -i "/^osds:$/a - $node:vdb2" yamldata/testcloud_sanity.yaml
                    done

                    # dependency for the test suite
                    rpm -q python-PyYAML &> /dev/null || zypper -n install python-PyYAML

                    if ! rpm -q python-nose &> /dev/null; then
                        zypper ar http://download.suse.de/ibs/Devel:/Cloud:/Shared:/11-SP3:/Update/standard/Devel:Cloud:Shared:11-SP3:Update.repo
                        zypper -n --gpg-auto-import-keys --no-gpg-checks install python-nose
                        zypper rr Devel_Cloud_Shared_11-SP3_Update
                    fi

                    nosetests testsuites/testcloud_sanity.py
                    cephret=$?

                    popd
                fi

                # Run Tempest Smoketests if configured to do so
                tempestret=0
                if [ "$wanttempest" = "1" ]; then
                    # Upload a Heat-enabled image
                    glance image-list|grep -q SLE11SP3-x86_64-cfntools || glance image-create --name=SLE11SP3-x86_64-cfntools --is-public=True --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SLES11-SP3-x86_64-cfntools.qcow2 | tee glance.out
                    imageid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" glance.out`
                    crudini --set /etc/tempest/tempest.conf orchestration image_ref $imageid
                    pushd /var/lib/openstack-tempest-test
                    ./run_tempest.sh -N $tempestoptions
                    tempestret=$?
                    popd
                    /opt/tempest/bin/tempest_cleanup.sh || :
                fi
        nova list
        glance image-list
            glance image-list|grep -q SP3-64
                if [ "x$?" != "x0" ]; then
                    # SP3-64 image not found, so uploading it
                    glance image-create --name=SP3-64 --is-public=True --property vm_mode=hvm --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SP3-64up.qcow2 | tee glance.out
                else
                    glance image-show SP3-64 | tee glance.out
                fi
        # wait for image to finish uploading
        imageid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" glance.out`
        if [ "x$imageid" == "x" ]; then
            echo "Error: Image ID for SP3-64 not found"
            exit 37
        fi

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
        nova boot --poll --image SP3-64 --flavor m1.smaller --key_name testkey testvm | tee boot.out
        instanceid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" boot.out`
        nova show "$instanceid"
        vmip=`nova show "$instanceid" | perl -ne "m/fixed.network [ |]*([0-9.]+)/ && print \\$1"`
        echo "VM IP address: $vmip"
        if [ -z "$vmip" ] ; then
            tail -n 90 /var/log/nova/*
            echo "Error: VM IP is empty. Exiting"
            exit 38
        fi
        nova floating-ip-create | tee floating-ip-create.out
        floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
        nova add-floating-ip "$instanceid" "$floatingip" # insufficient permissions
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

        set +x
        echo "Waiting for the SSH keys to be copied over"
        i=0
        MAX_RETRIES=40
        while timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $vmip "echo cloud" 2> /dev/null; [ $? != 0 ]
        do
            sleep 5  # wait before retry
            if [ $i -gt $MAX_RETRIES ] ; then
                echo "VM not accessible via SSH, something could be wrong with SSH keys"
                exit 97
            fi
            i=$((i+1))
            echo -n "."
        done
        set -x
        if ! ssh $vmip curl www3.zq1.de/test ; then
            echo could not reach internet
            exit 95
        fi
        nova volume-list | grep -q available || nova volume-create 1 ; sleep 2
        nova volume-list | grep available
        volumecreateret=$?
        volumeid=`nova volume-list | perl -ne "m/^[ |]*([0-9a-f-]+) [ |]*available/ && print \\$1"`
        nova volume-attach "$instanceid" "$volumeid" /dev/vdb
        sleep 15
        ssh $vmip fdisk -l /dev/vdb | grep 1073741824
        volumeattachret=$?
        rand=$RANDOM
        ssh $vmip "mkfs.ext3 /dev/vdb && mount /dev/vdb /mnt && echo $rand > /mnt/test.txt && umount /mnt"
        nova volume-detach "$instanceid" "$volumeid" ; sleep 10
        nova volume-attach "$instanceid" "$volumeid" /dev/vdb ; sleep 10
        ssh $vmip fdisk -l /dev/vdb | grep 1073741824 || volumeattachret=57
        ssh $vmip "mount /dev/vdb /mnt && grep -q $rand /mnt/test.txt" || volumeattachret=58
        nova stop testvm
        test $cephret = 0 -a $tempestret = 0 -a $volumecreateret = 0 -a $volumeattachret = 0
    '
    ret=$?
    echo ret:$ret
    exit $ret
}

function addupdaterepo()
{
    local UPR=/srv/tftpboot/repos/Cloud-PTF
    mkdir -p $UPR
    local repo
    for repo in ${UPDATEREPOS//+/ } ; do
        wget --progress=dot:mega -r --directory-prefix $UPR --no-parent --no-clobber --accept x86_64.rpm,noarch.rpm $repo || exit 8
    done
    zypper -n install createrepo
    createrepo -o $UPR $UPR || exit 8
    zypper ar $UPR cloud-ptf
}

function runupdate()
{
    wait_for 30 3 ' zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks ref ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
    wait_for 30 3 ' zypper --non-interactive up --repo cloud-ptf ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
}

function rebootcompute()
{
    get_novacontroller

    local cmachines=`crowbar machines list | grep ^d`
    local m
    for m in $cmachines ; do
        ssh $m "reboot"
        wait_for 100 1 " ! netcat -z $m 22 >/dev/null" "node $m to go down"
    done

    wait_for 400 5 "! crowbar node_state status | grep ^d | grep -vqiE \"ready$|problem$\"" "nodes are back online"

    if crowbar node_state status | grep ^d | grep -i "problem$"; then
        echo "Error: some nodes rebooted with state Problem."
        exit 1
    fi

    scp $0 $novacontroller:
    ssh $novacontroller "waitforrebootcompute=1 bash -x ./$0 $cloud"
    local ret=$?
    echo "ret:$ret"
    exit $ret
}

function waitforrebootcompute()
{
    . .openrc
    nova list
    nova start testvm || exit 28
    nova list
    local vmip=`nova show testvm | perl -ne 'm/ fixed.network [ |]*[0-9.]+, ([0-9.]+)/ && print $1'`
    wait_for 100 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm to boot up"
}

function get_neutron_server_node()
{
    NEUTRON_SERVER=$(crowbar neutron proposal show default|ruby -e "require 'rubygems';require 'json';
    j=JSON.parse(STDIN.read);
    puts j['deployment']['neutron']['elements']['neutron-server'][0];")
}

function rebootneutron()
{
    get_neutron_server_node
    echo "Rebooting neutron server: $NEUTRON_SERVER ..."

    ssh $NEUTRON_SERVER "reboot"
    wait_for 100 1 " ! netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to go down"
    wait_for 200 3 "netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to be back online"

    wait_for 300 3 "ssh $NEUTRON_SERVER 'rcopenstack-neutron status' |grep -q running" "neutron-server service running state"
    wait_for 200 3 " ! ssh $NEUTRON_SERVER '. .openrc && neutron agent-list -f csv --quote none'|tail -n+2 | grep -q -v ':-)'" "neutron agents up"

    ssh $NEUTRON_SERVER '. .openrc && neutron agent-list'
    ssh $NEUTRON_SERVER 'ping -c1 -w1 8.8.8.8' > /dev/null
    if [ "x$?" != "x0" ]; then
        echo "Error: ping to 8.8.8.8 from $NEUTRON_SERVER failed."
        exit 1
    fi
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
    local owaspdomain=clouddata.cloud.suse.de   # works only SUSE-internally for now
    local owasppath=/tools/security-testsuite/
    #owaspdomain=download.opensuse.org
    #owasppath=/repositories/home:/thomasbiege/openSUSE_Factory/noarch/

    local owaspsource=http://$owaspdomain$owasppath
    rm -rf owasp
    mkdir -p owasp

    zypper lr | grep -q devel_languages_perl || zypper ar http://download.opensuse.org/repositories/devel:/languages:/perl/$slesdist/devel:languages:perl.repo
    # pulled in automatically
    #zypper --non-interactive in perl-HTTP-Cookies perl-Config-Simple

    wget --progress=dot:mega -r --directory-prefix owasp -np -nc -A "owasp*.rpm","sslscan*rpm" $owaspsource
    zypper --non-interactive --gpg-auto-import-keys in `find owasp/ -type f -name "*rpm"`

    pushd /usr/share/owasp-test-suite >/dev/null
    # create config
    local owaspconf=openstack_horizon-testing.ini
    create_owasp_testsuite_config $owaspconf

    # call tests
    ./owasp.pl output=short $owaspconf
    local ret=$?
    popd >/dev/null
    return $ret
}


function qa_test()
{
    zypper -n in -y python-{keystone,nova,glance,heat,ceilometer}client

    get_novacontroller
    scp $novacontroller:.openrc ~/

    if [ ! -d "qa-openstack-cli" ] ; then
        echo "Error: please provide a checkout of the qa-openstack-cli repo on the crowbar node."
        exit 1
    fi

    pushd qa-openstack-cli
    mkdir -p ~/qa_test.logs
    ./run.sh | perl -pe '$|=1;s/\e\[?.*?[\@-~]//g' | tee ~/qa_test.logs/run.sh.log
    local ret=${PIPESTATUS[0]}
    popd
    return $ret
}


function teardown()
{
    #BMCs at 10.122.178.163-6 #node 6-9
    #BMCs at 10.122.$net.163-4 #node 11-12

    # undo propsal create+commit
    local service
    for service in nova_dashboard nova glance ceph swift keystone database ; do
        crowbar "$service" proposal delete default
        crowbar "$service" delete default
    done

    local node
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

mount_localreposdir_target

if [ -n "$prepareinstallcrowbar" ] ; then
    prepareinstallcrowbar
fi

if [ -n "$installcrowbar" ] ; then
    installcrowbar
fi

if [ -n "$installcrowbarfromgit" ] ; then
    installcrowbarfromgit
fi

if [ -n "$addupdaterepo" ] ; then
    addupdaterepo
fi

if [ -n "$runupdate" ] ; then
    runupdate
fi

if [ -n "$allocate" ] ; then
    allocate
fi

if [ -n "$waitcompute" ] ; then
    do_waitcompute
fi

set_proposalvars
if [ -n "$proposal" ] ; then
    do_proposal
fi

if [ -n "$testsetup" ] ; then
    do_testsetup
fi

if [ -n "$rebootcompute" ] ; then
    rebootcompute
fi

if [ -n "$waitforrebootcompute" ] ; then
    waitforrebootcompute
fi

if [ -n "$rebootneutron" ] ; then
    rebootneutron
fi

if [ -n "$securitytests" ] ; then
    securitytests
fi

if [ -n "$qa_test" ] ; then
    qa_test
fi

if [ -n "$teardown" ] ; then
    teardown
fi
