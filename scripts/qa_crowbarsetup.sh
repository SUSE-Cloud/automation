#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual

test $(uname -m) = x86_64 || echo "ERROR: need 64bit"

mkcconf=mkcloud.config
if [ -z "$testfunc" ] && [ -e $mkcconf ]; then
    source $mkcconf
fi

# this needs to be after mkcloud.config got sourced
if [[ $debug_qa_crowbarsetup = 1 ]] ; then
    set -x
fi

# defaults
: ${libvirt_type:=kvm}
: ${networkingplugin:=openvswitch}

# global variables that are set within this script
novacontroller=
novadashboardserver=
clusternodesdrbd=
clusternodesdata=
clusternodesnetwork=
clusternodesservices=
clusternamedata="data"
clusternameservices="services"
clusternamenetwork="network"
wanthyperv=

export cloudfqdn=${cloudfqdn:-$cloud.cloud.suse.de}
export nodenumber=${nodenumber:-2}
export tempestoptions=${tempestoptions:--t -s}
export want_sles12
[[ "$want_sles12" = 0 ]] && want_sles12=
export nodes=
export cinder_conf_volume_type
export cinder_conf_volume_params
export localreposdir_target
export want_ipmi=${want_ipmi:-false}
[ "$libvirt_type" = hyperv ] && export wanthyperv=1
[ "$libvirt_type" = xen ] && export wantxenpv=1 # xenhvm is broken anyway

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

export ZYPP_LOCK_TIMEOUT=120

function complain() # {{{
{
    local ex=$1; shift
    printf "Error: %s\n" "$@" >&2
    [[ $ex != - ]] && exit $ex
} # }}}

safely () {
    if ! "$@"; then
        complain 30 "$* failed! Aborting."
    fi
}

rubyjsonparse()
{
    $ruby -e "
        require 'rubygems'
        require 'json'
        j=JSON.parse(STDIN.read)
        $1"
}

if [ -z "$cloud" ] ; then
    complain 101 "Parameter missing that defines the cloud name" \
        "Possible values: [d1, d2, p, virtual]" \
        "Example: $0 d2"
fi

# common cloud network prefix within SUSE Nuremberg:
netp=10.162
net=${net_admin:-192.168.124}
case "$cloud" in
    d1)
        nodenumber=5
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
        nodenumber=2
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
        nodenumber=3
        net=$netp.189
        net_public=$netp.188
        vlan_storage=586
        vlan_public=588
        vlan_fixed=589
        want_ipmi=true
    ;;
    qa1)
        nodenumber=6
        net=${netp}.26
        net_public=$net
        vlan_public=300
        vlan_fixed=500
        vlan_storage=200
        want_ipmi=false
    ;;
    qa2)
        nodenumber=7
        net=${netp}.24
        net_public=$net
        vlan_public=12
        #vlan_admin=610
        vlan_fixed=611
        vlan_storage=612
        want_ipmi=true
    ;;
    qa3)
        nodenumber=8
        net=${netp}.25
        net_public=$net
        vlan_public=12
        #vlan_admin=615
        vlan_fixed=615
        vlan_storage=616
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
mkcloudhostip=${net}.1
: ${adminip:=$net.10}

# run hook code before the actual script does its function
function pre_hook()
{
    func=$1
    pre=$(eval echo \$pre_$func | base64 -d)
    test -n "$pre" && eval "$pre"
}

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

function wait_for_if_running()
{
    local procname=${1}
    local timecount=${2:-300}

    wait_for $timecount 5 "! pidofproc ${procname} >/dev/null" "process '${procname}' to terminate"
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
        complain 31 "source ${src} for bind-mount does not exist"
    fi

    umount "${dst}"
    if ! grep -q "$src\s\+$dst" /etc/fstab ; then
        echo "$src $dst bind defaults,bind  0 0" >> /etc/fstab
    fi
    safely mount "$dst"
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
    safely mount "$dir"
}

# mount a zypper repo either from NFS or from the host (if localreposdir_target is set)
#   also adds an entry to /etc/fstab so that mounts can be restored after a reboot
# input1: bindsrc - dir used for mounts from the host
# input2: nfssrc  - remote NFS dir to mount
# input3: targetdir - where to mount (usually in /srv/tftpboot/repos/DIR )
# input4(optional): zypper_alias - if set, this dir is added as a local repo for zypper
function add_mount()
{
    local bindsrc="$1"
    local nfssrc="$2"
    local targetdir="$3"
    local zypper_alias="$4"

    if [ -n "$localreposdir_target" ]; then
        if [ -z "$bindsrc" ]; then
            complain 50 "BUG: add_mount() called with empty bindsrc parameter" \
                "(nfssrc=$nfssrc targetdir=$targetdir alias=$zypper_alias)\n" \
                "This will break for those not using NFS."
        fi
        add_bind_mount "$localreposdir_target/$bindsrc" "$targetdir"
    else
        if [ -z "$nfssrc" ]; then
            complain 50 "BUG: add_mount() called with empty nfssrc parameter" \
                "(bindsrc=$bindsrc targetdir=$targetdir alias=$zypper_alias)\n" \
                "This will break for those using NFS."
        fi
        add_nfs_mount "$nfssrc" "$targetdir"
    fi

    if [ -n "${zypper_alias}" ]; then
        zypper rr "${zypper_alias}"
        safely zypper -n ar -f "${targetdir}" "${zypper_alias}"
    fi
}

function getcloudver()
{
    if   [[ $cloudsource =~ ^.*(cloud|GM)3(\+up)?$ ]] ; then
        echo -n 3
    elif [[ $cloudsource =~ ^.*(cloud|GM)4(\+up)?$ ]] ; then
        echo -n 4
    elif [[ $cloudsource =~ ^(.+5|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM5?(\+up)?)$ ]] ; then
        echo -n 5
    else
        complain 11 "unknown cloudsource version"
    fi
}

# return if cloudsource is referring a certain SUSE Cloud version
# input1: version - 4plus refers to version 4 or later ; only a number refers to one exact version
function iscloudver()
{
    local v=$1
    local operator="="
    if [[ $v =~ plus ]] ; then
        v=${v%%plus}
        operator="-ge"
    fi
    local ver=`getcloudver` || exit 11
    [ "$ver" $operator "$v" ]
    return $?
}

function export_tftpboot_repos_dir()
{
    tftpboot_repos_dir=/srv/tftpboot/repos
    tftpboot_suse_dir=/srv/tftpboot/suse-11.3

    if iscloudver 5plus; then
        tftpboot_suse12_dir=/srv/tftpboot/suse-12.0

        if iscloudver 6plus || [[ ! $cloudsource =~ ^M[1-4]+$ ]]; then
            tftpboot_repos_dir=$tftpboot_suse_dir/repos
            tftpboot_repos12_dir=$tftpboot_suse12_dir/repos
        else
            # Cloud 5 M1 to M4 use the old-style paths
            tftpboot_repos12_dir=/srv/tftpboot/repos
        fi
    fi
}

function addsp3testupdates()
{
    add_mount "SLES11-SP3-Updates" 'you.suse.de:/you/http/download/x86_64/update/SLE-SERVER/11-SP3/' "$tftpboot_repos_dir/SLES11-SP3-Updates/" "sp3tup"
}
function add_sles12ga_testupdates()
{
    echo "TODO: add SLES-12-GA Updates-test repo"
}

function addcloud3maintupdates()
{
    add_mount "SUSE-Cloud-3-Updates" 'clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-3-Updates/' "$tftpboot_repos_dir/SUSE-Cloud-3-Updates/" "cloudmaintup"
}

function addcloud3testupdates()
{
    add_mount "SUSE-Cloud-3-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/3.0/' "$tftpboot_repos_dir/SUSE-Cloud-3-Updates/" "cloudtup"
}

function addcloud4maintupdates()
{
    add_mount "SUSE-Cloud-4-Updates" 'clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-4-Updates/' "$tftpboot_repos_dir/SUSE-Cloud-4-Updates/" "cloudmaintup"
}

function addcloud4testupdates()
{
    add_mount "SUSE-Cloud-4-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/4/' "$tftpboot_repos_dir/SUSE-Cloud-4-Updates/" "cloudtup"
}

function addcloud5maintupdates()
{
    add_mount "SUSE-Cloud-5-Updates" 'clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-5-Updates/' "$tftpboot_repos_dir/SUSE-Cloud-5-Updates/" "cloudmaintup"
}

function addcloud5testupdates()
{
    add_mount "SUSE-Cloud-5-Updates" 'you.suse.de:/you/http/download/x86_64/update/SUSE-CLOUD/5/' "$tftpboot_repos_dir/SUSE-Cloud-5-Updates/" "cloudtup"
}

function addcloud5pool()
{
    add_mount "SUSE-Cloud-5-Pool" 'clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-5-Pool/' "$tftpboot_repos_dir/SUSE-Cloud-5-Pool/" "cloudpool"
}

function add_ha_repo()
{
    local repo
    for repo in SLE11-HAE-SP3-{Pool,Updates,Updates-test}; do
        if [ "$hacloud" == "2" -a "$repo" == "SLE11-HAE-SP3-Updates-test" ] ; then
            continue
        fi
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo/sle-11-x86_64" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" \
            "$tftpboot_repos_dir/$repo"
    done
}

function add_suse_storage_repo()
{
        local repo
        for repo in SUSE-Enterprise-Storage-1.0-{Pool,Updates}; do
            # Note no zypper alias parameter here since we don't want
            # to zypper addrepo on the admin node.
            add_mount "$repo" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" \
                "$tftpboot_repos12_dir/$repo"
        done
}

function get_disk_id_by_serial_and_libvirt_type()
{
    # default libvirt_type is "kvm"
    local libvirt="${1:-kvm}"
    local serial="$2"
    diskid="unknown"
    case "$libvirt" in
        xen) diskid="scsi-SATA_QEMU_HARDDISK_$serial" ;;
        kvm) diskid="virtio-$serial" ;;
    esac
    echo -n "$diskid"
}

function cluster_node_assignment()
{
    local nodesavailable
    nodesavailable=`crowbar machines list | grep -v crowbar`

    # the nodes that contain drbd volumes are defined via drbdnode_mac_vol
    for dmachine in ${drbdnode_mac_vol//+/ } ; do
        local mac
        local serial
        mac=${dmachine%#*}
        serial=${dmachine#*#}

        # find and remove drbd nodes from nodesavailable
        for node in $nodesavailable ; do
            if crowbar machines show "$node" | grep "\"macaddress\"" | grep -qi $mac ; then
                clusternodesdrbd="$clusternodesdrbd $node"

                # assign drbd volume via knife
                local nfile
                nfile=knife.node.${node}.json
                knife node show ${node} -F json > $nfile
                rubyjsonparse "
                            j['normal']['crowbar_wall']['claimed_disks'].each do |k,v|
                                next if v.is_a? Hash and v['owner'] !~ /LVM_DRBD/;
                                j['normal']['crowbar_wall']['claimed_disks'].delete(k);
                            end ;
                            j['normal']['crowbar_wall']['claimed_disks']['/dev/disk/by-id/$(get_disk_id_by_serial_and_libvirt_type "$libvirt_type" "$serial")']={'owner' => 'LVM_DRBD'};
                            puts JSON.pretty_generate(j)" < $nfile > ${nfile}.tmp
                mv ${nfile}.tmp ${nfile}
                knife node from file ${nfile}
            fi
        done
    done
    for dnode in $clusternodesdrbd ; do
        # run chef-client on the edited nodes to fill back the hidden data fields (like dmi data)
        # this is a workaround, because the hidden node data can not be exported, imported or kept during editing
        echo "not done yet" > ${dnode}.chef-client.ret
        screen -d -m -L /bin/bash -c "ssh $dnode 'chef-client' ; echo \$? > ${dnode}.chef-client.ret"
    done
    wait_for 40 15 "! cat *.chef-client.ret | grep -qv '^0$'" "all chef-clients to succeed" \
        "cat *.chef-client.ret ; complain 73 'Manually triggered chef-client run failed on at least one node.'"

    ### Examples for clusterconfig:
    # clusterconfig="data+services+network=2"
    # clusterconfig="services+data=2:network=3:::"
    # clusterconfig="services=3:data=2:network=2:"

    for cluster in ${clusterconfig//:/ } ; do
        [ -z "$cluster" ] && continue
        # split off the number => group
        local group=${cluster%=*}
        # split off the group => number
        local number=${cluster#*=}

        # get first element of the group => clustername
        local clustername=${group%%+*}
        local nodes=

        # clusternodesdata can only be the drbd nodes
        if [[ $group =~ data ]] ; then
            nodes="$clusternodesdrbd"
        fi

        # fetch nodes for this cluster if not yet defined
        if [ -z "$nodes" ] ; then
            nodes=`printf  "%s\n" $nodesavailable | head -n$number`
        fi

        # remove the selected nodes from the list of available nodes
        for onenode in $nodes ; do
            nodesavailable=`printf "%s\n" $nodesavailable | grep -iv $onenode`
        done

        case $clustername in
            data)
                clusternodesdata="$nodes"
                [[ $group =~ "+services" ]] && clusternameservices=$clustername
                [[ $group =~ "+network" ]]  && clusternamenetwork=$clustername
            ;;
            services)
                clusternodesservices="$nodes"
                [[ $group =~ "+data" ]]     && clusternamedata=$clustername
                [[ $group =~ "+network" ]]  && clusternamenetwork=$clustername
            ;;
            network)
                clusternodesnetwork="$nodes"
                [[ $group =~ "+data" ]]     && clusternamedata=$clustername
                [[ $group =~ "+services" ]] && clusternameservices=$clustername
            ;;
        esac
    done
    nodescompute=$nodesavailable

    echo "............................................................"
    echo "The cluster node assignment (for your information):"
    echo "data cluster:"
    printf "   %s\n" $clusternodesdata
    echo "network cluster:"
    printf "   %s\n" $clusternodesnetwork
    echo "services cluster:"
    printf "   %s\n" $clusternodesservices
    echo "compute nodes (no cluster):"
    printf "   %s\n" $nodesavailable
    echo "............................................................"
}

function onadmin_prepare_sles_repos()
{
    local targetdir_install="$tftpboot_suse_dir/install"

    if [ -n "${localreposdir_target}" ]; then
        add_mount "SUSE-Cloud-SLE-11-SP3-deps/sle-11-x86_64/" "" \
            "${targetdir_install}" "Cloud-Deps"
        zypper_refresh
    else
        zypper se -s sles-release | \
            grep -v -e "sp.up\s*$" -e "(System Packages)" | \
            grep -q x86_64 \
        || zypper ar \
            http://$susedownload/install/SLP/SLES-${slesversion}-LATEST/x86_64/DVD1/ \
            sles

        if ! $longdistance ; then
            add_mount "" \
                "clouddata.cloud.suse.de:/srv/nfs/suse-$suseversion/install" \
                "$targetdir_install"
        fi

        local repo
        for repo in $slesrepolist ; do
            local zypprepo=""
            [ "$WITHSLEUPDATES" != "" ] && zypprepo="$repo"
            add_mount "$zypprepo" \
                "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" \
                "$tftpboot_repos_dir/$repo"
        done

        # just as a fallback if nfs did not work
        if [ ! -e "$targetdir_install/media.1/" ]; then
            download_and_mount_sles "$tftpboot_suse_dir" "$targetdir_install"
        fi
    fi

    if [ ! -e "${targetdir_install}/media.1/" ] ; then
        complain 34 "We do not have SLES install media - giving up"
    fi
}

function rsync_iso()
{
    local distpath="$1"
    local distiso="$2"
    local targetdir="$3"
    mkdir -p /mnt/cloud "$targetdir"
    (
        cd "$targetdir"
        wget --progress=dot:mega -r -np -nc -A "$distiso" \
            http://$susedownload$distpath/ \
        || complain 71 "iso not found"
        local cloudiso=$(ls */$distpath/*.iso | tail -1)
        safely mount -o loop,ro -t iso9660 $cloudiso /mnt/cloud
        safely rsync -av --delete-after /mnt/cloud/ .
        safely umount /mnt/cloud
        echo $cloudiso > isoversion
    )
}

function onadmin_prepare_sles12_repos()
{
    onadmin_prepare_sles12_repo
    onadmin_prepare_sles12_compute_repo

    # These aren't available yet?
    onadmin_prepare_sles12_other_repos

    onadmin_create_sles12_repos
}

# create empty repository when there is none yet
function onadmin_create_sles12_repos()
{
    safely zypper -n install createrepo
    local sles12optionalrepolist=(
        SLE-12-Cloud-Compute5-Pool
        SLE-12-Cloud-Compute5-Updates
    )
    for repo in ${sles12optionalrepolist[@]}; do
        if [ ! -e "$tftpboot_repos12_dir/$repo/repodata/" ] ; then
            mkdir -p "$tftpboot_repos12_dir/$repo"
            safely createrepo "$tftpboot_repos12_dir/$repo"
        fi
    done
}

function onadmin_prepare_sles12_repo()
{
    local sles12_mount="$tftpboot_suse12_dir/install"
    add_mount "SLE-12-Server-LATEST/sle-12-x86_64" \
        "clouddata.cloud.suse.de:/srv/nfs/suse-12.0/install" \
        "$sles12_mount"

    if [ ! -d "$sles12_mount/media.1" ] ; then
        complain 34 "We do not have SLES12 install media - giving up"
    fi
}

function onadmin_prepare_sles12_compute_repo()
{
    local sles12_compute_mount="$tftpboot_repos12_dir/SLE12-Cloud-Compute"
    if [ -n "$localreposdir_target" ]; then
        echo "FIXME: SLE12-Cloud-Compute not available from clouddata yet." >&2
        echo "Will manually download and rsync." >&2
        # add_mount "SLE12-Cloud-Compute" \
        #     "clouddata.cloud.suse.de:/srv/nfs/repos/SLE12-Cloud-Compute" \
        #     "$targetdir_install"
    fi
    rsync_iso "$CLOUDCOMPUTEPATH" "$CLOUDCOMPUTEISO" "$sles12_compute_mount"
}

function onadmin_prepare_sles12_other_repos()
{
    for repo in SLES12-{Pool,Updates}; do
        add_mount "$repo/sle-12-x86_64" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12_dir/$repo"
    done
}

function download_and_mount_sles()
{
    local iso_dir="$1"
    local mountpoint="$2"

    local iso_file=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
    local iso_path=$iso_dir/$iso_file

    local url="http://$susedownload/install/SLES-$slesversion-$slesmilestone/$iso_file"
    wget --progress=dot:mega -nc -O$iso_path "$url" \
        || complain 72 "iso not found"
    echo "$iso_path $mountpoint iso9660 loop,ro" >> /etc/fstab
    safely mount "$mountpoint"
}

function onadmin_prepare_cloud_repos()
{
    local targetdir="$tftpboot_repos_dir/Cloud/"
    mkdir -p ${targetdir}

    if [ -n "${localreposdir_target}" ]; then
        add_bind_mount \
            "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-x86_64/" \
            "${targetdir}"
        echo $CLOUDLOCALREPOS > /etc/cloudversion
    else
        rsync_iso "$CLOUDDISTPATH" "$CLOUDDISTISO" "$targetdir"
        cat "$targetdir/isoversion" > /etc/cloudversion
    fi
    echo -n "This cloud was installed on `cat ~/cloud` from: " | \
        cat - /etc/cloudversion >> /etc/motd
    echo $cloudsource > /etc/cloudsource

    if [ ! -e "${targetdir}/media.1" ] ; then
        complain 35 "We do not have cloud install media in ${targetdir} - giving up"
    fi

    zypper rr Cloud
    safely zypper ar -f ${targetdir} Cloud

    if [ -n "$TESTHEAD" ] ; then
        case "$cloudsource" in
            GM3|GM3+up)
                addsp3testupdates
                addcloud3testupdates
                ;;
            GM4|GM4+up)
                addsp3testupdates
                addcloud4testupdates
                ;;
            susecloud5|M?|Beta*|RC*|GMC*|GM5|GM5+up)
                addsp3testupdates
                add_sles12ga_testupdates
                addcloud5testupdates
                addcloud5pool
                ;;
            develcloud3|develcloud4)
                addsp3testupdates
                ;;
            develcloud5)
                addsp3testupdates
                add_sles12ga_testupdates
                ;;
            *)
                complain 26 "no TESTHEAD repos defined for cloudsource=$cloudsource"
                ;;
        esac
    else
        case "$cloudsource" in
            GM3+up)
                addcloud3maintupdates
                ;;
            GM4+up)
                addcloud4maintupdates
                ;;
            susecloud5|M?|Beta*|RC*|GMC*|GM5|GM5+up)
                addcloud5maintupdates
                addcloud5pool
                ;;
        esac
    fi
}


function do_set_repos_skip_checks()
{
    if iscloudver 5plus && [[ $cloudsource =~ develcloud ]]; then
        # We don't use the proper pool/updates repos when using a devel build
        export REPOS_SKIP_CHECKS+=" SUSE-Cloud-$(getcloudver)-Pool SUSE-Cloud-$(getcloudver)-Updates"
    fi
}


function onadmin_set_source_variables()
{
    suseversion=11.3
    : ${susedownload:=download.nue.suse.com}
    case "$cloudsource" in
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
        develcloud5)
            CLOUDDISTPATH=/ibs/Devel:/Cloud:/5/images/iso
            [ -n "$TESTHEAD" ] && CLOUDDISTPATH=/ibs/Devel:/Cloud:/5:/Staging/images/iso
            CLOUDCOMPUTEPATH=$CLOUDDISTPATH
            CLOUDDISTISO="SUSE-CLOUD*Media1.iso"
            CLOUDCOMPUTEISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-devel"
        ;;
        susecloud5)
            CLOUDDISTPATH=/ibs/SUSE:/SLE-11-SP3:/Update:/Cloud5:/Test/images/iso
            CLOUDCOMPUTEPATH=/ibs/SUSE:/SLE-12:/Update:/Products:/Cloud5/images/iso/
            CLOUDDISTISO="SUSE-CLOUD*Media1.iso"
            CLOUDCOMPUTEISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-official"
        ;;
        GM3|GM3+up)
            CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-3-GM/
            CLOUDDISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-3-official"
        ;;
        GM4|GM4+up)
            CLOUDDISTPATH=/install/SLE-11-SP3-Cloud-4-GM/
            CLOUDDISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-official"
        ;;
        M?|Beta*|RC*|GMC*|GM5|GM5+up)
            cs=$cloudsource
            [[ $cs =~ GM5 ]] && cs=GM
            CLOUDDISTPATH=/install/SUSE-Cloud-5-$cs/
            CLOUDCOMPUTEPATH=$CLOUDDISTPATH
            CLOUDDISTISO="SUSE-CLOUD*1.iso"
            CLOUDCOMPUTEISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-official"
        ;;
        *)
            complain 76 "You must set environment variable cloudsource=develcloud3|develcloud4|develcloud5|susecloud5|GM3|GM4"
        ;;
    esac

    [ -n "$TESTHEAD" ] && CLOUDLOCALREPOS="$CLOUDLOCALREPOS-staging"

    case "$suseversion" in
        11.3)
            slesrepolist="SLES11-SP3-Pool SLES11-SP3-Updates"
            slesversion=11-SP3
            slesdist=SLE_11_SP3
            slesmilestone=GM
        ;;
    esac
}


function zypper_refresh()
{
    # --no-gpg-checks for Devel:Cloud repo
    safely zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
}

function onadmin_repocleanup()
{
    # Workaround broken admin image that has SP3 Test update channel enabled
    zypper mr -d sp3tup
    # disable extra repos
    zypper mr -d sp3sdk
}

# setup network/DNS, add repos and install crowbar packages
function onadmin_prepareinstallcrowbar()
{
    pre_hook $FUNCNAME
    onadmin_repocleanup
    echo configure static IP and absolute + resolvable hostname crowbar.$cloudfqdn gw:$net.1
    # We want to use static networking which needs a static resolv.conf .
    # The SUSE sysconfig/ifup scripts drop DNS-servers received from DHCP
    # when switching from DHCP to static.
    # This dropping is avoided by stripping comments.
    sed -i -e 's/#.*//' /etc/resolv.conf
    cat > /etc/sysconfig/network/ifcfg-eth0 <<EOF
NAME='eth0'
STARTMODE='auto'
BOOTPROTO='static'
IPADDR='$adminip'
NETMASK='255.255.255.0'
BROADCAST='$net.255'
EOF
    ifdown br0
    rm -f /etc/sysconfig/network/ifcfg-br0
    routes_file=/etc/sysconfig/network/routes
    if ! [ -e $routes_file ] || ! grep -q "^default" $routes_file; then
        echo "default $net.1 - -" > $routes_file
    fi
    echo "crowbar.$cloudfqdn" > /etc/HOSTNAME
    hostname `cat /etc/HOSTNAME`
    # these vars are used by rabbitmq
    export HOSTNAME=`cat /etc/HOSTNAME`
    export HOST=$HOSTNAME
    grep -q "$net.*crowbar" /etc/hosts || \
        echo $adminip crowbar.$cloudfqdn crowbar >> /etc/hosts
    rcnetwork restart
    hostname -f # make sure it is a FQDN
    ping -c 1 `hostname -f`
    longdistance=${longdistance:-false}
    if [[ $(ping -q -c1 clouddata.cloud.suse.de |
            perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]]
    then
        longdistance=true
    fi

    if [ -n "${localreposdir_target}" ]; then
        while zypper lr -e - | grep -q '^name='; do
            zypper rr 1
        done
        mount_localreposdir_target
    fi

    onadmin_set_source_variables

    onadmin_prepare_sles_repos

    if iscloudver 5plus ; then
        onadmin_prepare_sles12_repos
    fi

    if [ -n "$hacloud" ]; then
        if [ "$slesdist" = "SLE_11_SP3" ] && iscloudver 3plus ; then
            add_ha_repo
        else
            complain 18 "You requested a HA setup but for this combination ($cloudsource : $slesdist) no HA setup is available."
        fi
    fi

    if [ -n "$deployceph" ] && iscloudver 5plus; then
        add_suse_storage_repo
    fi

    safely zypper -n install rsync netcat

    # setup cloud repos for tftpboot and zypper
    onadmin_prepare_cloud_repos


    zypper_refresh

    zypper -n dup -r Cloud -r cloudtup || zypper -n dup -r Cloud

    if [ -z "$NOINSTALLCLOUDPATTERN" ] ; then
        zypper --no-gpg-checks -n in -l -t pattern cloud_admin
        local ret=$?

        if [ $ret = 0 ] ; then
            echo "The cloud admin successfully installed."
            echo ".... continuing"
        else
            complain 86 "zypper returned with exit code $? when installing cloud admin"
        fi
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
    if [[ $cloud = qa1 ]] ; then
        # QA clouds have too few IP addrs, so smaller subnets are used
        wget -O$netfile http://info.cloudadm.qa.suse.de/net-json/dual_private_vm_network
    fi
    if [[ $cloud = qa2 ]] ; then
        # QA clouds have too few IP addrs, so smaller subnets are used
        wget -O$netfile http://info.cloudadm.qa.suse.de/net-json/cloud2_dual_private_vm_network
    fi
    if [[ $cloud = qa3 ]] ; then
        wget -O$netfile http://info.cloudadm.qa.suse.de/net-json/cloud3_dual_private_vm_network
    fi
    if [[ $cloud = p2 ]] ; then
        /opt/dell/bin/json-edit -a attributes.network.networks.public.netmask -v 255.255.252.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.ranges.dhcp.end -v 44.0.3.254 $netfile
        # floating net is the 2nd half of public net:
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.netmask -v 255.255.254.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.subnet -v $netp.166.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.start -v $netp.166.1 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.end -v $netp.167.191 $netfile
        # todo? broadcast
    fi
    # Setup specific network configuration for d2 cloud
    if [[ $cloud = d2 ]] ; then
        /opt/dell/bin/json-edit -a attributes.network.mode -v dual $netfile
        /opt/dell/bin/json-edit -a attributes.network.teaming.mode -r -v 5 $netfile
    fi

    cp -a $netfile /etc/crowbar/network.json # new place since 2013-07-18

    # to allow integration into external DNS:
    local f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
    grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

    # set default password to 'linux'
    # setup_base_images.rb is for SUSE Cloud 1.0 and update_nodes.rb is for 2.0
    sed -i -e 's/\(rootpw_hash.*\)""/\1"$2y$10$u5mQA7\/8YjHdutDPEMPtBeh\/w8Bq0wEGbxleUT4dO48dxgwyPD8D."/' /opt/dell/chef/cookbooks/provisioner/recipes/setup_base_images.rb /opt/dell/chef/cookbooks/provisioner/recipes/update_nodes.rb

    # exit code of the sed don't matter, so just:
    return 0
}

# run the crowbar install script
# and do some sanity checks on the result
function do_installcrowbar()
{
    local instcmd=$1

    do_set_repos_skip_checks

    cd /root # we expect the screenlog.0 file here
    echo "Command to install chef: $instcmd"
    intercept "install-chef-suse.sh"

    rm -f /tmp/chef-ready
    rpm -Va crowbar\*
    # run in screen to not lose session in the middle when network is reconfigured:
    screen -d -m -L /bin/bash -c "$instcmd ; touch /tmp/chef-ready"

    if [ -n "$wanthyperv" ] ; then
        # prepare Hyper-V 2012 R2 PXE-boot env and export it via Samba:
        zypper -n in samba
        rsync -a clouddata.cloud.suse.de::cloud/hyperv-6.3 /srv/tftpboot/
        chkconfig smb on
        chkconfig nmb on
        cat >> /etc/samba/smb.conf <<EOF
[reminst]
        comment = MS Windows remote install
        guest ok = Yes
        inherit acls = Yes
        path = /srv/tftpboot
        read only = Yes
        force user = root
EOF
        service smb restart
    fi
    local n=300
    while [ $n -gt 0 ] && [ ! -e /tmp/chef-ready ] ; do
        n=$(expr $n - 1)
        sleep 5;
        echo -n .
    done
    if [ $n = 0 ] ; then
        complain 83 "timed out waiting for chef-ready"
    fi
    rpm -Va crowbar\*

    # Make sure install finished correctly
    if ! [ -e /opt/dell/crowbar_framework/.crowbar-installed-ok ]; then
        tail -n 90 /root/screenlog.0
        complain 89 "Crowbar \".crowbar-installed-ok\" marker missing"
    fi

    if iscloudver 4plus; then
        zypper -n install crowbar-barclamp-tempest
        # Force restart of crowbar
        rccrowbar stop
    fi

    rccrowbar status || rccrowbar start
    [ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

    sleep 20
    if ! curl -m 59 -s http://localhost:3000 > /dev/null || \
        ! curl -m 59 -s --digest --user crowbar:crowbar localhost:3000 | \
        grep -q /nodes/crowbar
    then
        tail -n 90 /root/screenlog.0
        complain 84 "crowbar self-test failed"
    fi

    if ! crowbar machines list | grep -q crowbar.$cloudfqdn ; then
        tail -n 90 /root/screenlog.0
        complain 85 "crowbar 2nd self-test failed"
    fi

    if ! (rcxinetd status && rcdhcpd status) ; then
        complain 67 "provisioner failed to configure all needed services!" \
            "Please fix manually."
    fi
    if [ -n "$ntpserver" ] ; then
        local pfile=`get_proposal_filename ntp default`
        crowbar ntp proposal show default |
            rubyjsonparse "
            j['attributes']['ntp']['external_servers']=['$ntpserver'];
            puts JSON.pretty_generate(j)" > $pfile
        crowbar ntp proposal --file=$pfile edit default
        rm -f $pfile
        crowbar ntp proposal commit default
    fi

    update_one_proposal provisioner default

    if ! validate_data_bags; then
        complain 68 "Validation error in default data bags. Aborting."
    fi
}


function onadmin_installcrowbarfromgit()
{
    do_installcrowbar \
        "CROWBAR_FROM_GIT=1
            /opt/dell/bin/install-chef-suse.sh --from-git --verbose"
}

function onadmin_installcrowbar()
{
    pre_hook $FUNCNAME
    do_installcrowbar "
        if [ -e /tmp/install-chef-suse.sh ]; then
            /tmp/install-chef-suse.sh --verbose;
        else
            /opt/dell/bin/install-chef-suse.sh --verbose
        fi"
}

# set a node's role and platform
# must be run after discovery and before allocation
function set_node_role_and_platform()
{
    node="$1"
    role="$2"
    platform="$3"
    local t=$(mktemp).json
    knife node show -F json "$node" > $t
    json-edit $t -a normal.crowbar_wall.intended_role -v "$role"
    json-edit $t -a normal.target_platform -v "$platform"
    knife node from file $t
    rm -f $t
}

function onadmin_allocate()
{
    pre_hook $FUNCNAME
    #chef-client
    if $want_ipmi ; then
        do_one_proposal ipmi default
        local nodelist=$(seq 1 $nodenumber)
        local i
        local bmc_start=$(
            crowbar network proposal show default | \
            rubyjsonparse "
                networks = j['attributes']['network']['networks']
                puts networks['bmc']['ranges']['host']['start']
            "
        )
        IFS=. read ip1 ip2 ip3 ip4 <<< "$bmc_start"
        local bmc_net="$ip1.$ip2.$ip3"
        for i in $nodelist ; do
            local pw
            for pw in 'cr0wBar!' $extraipmipw ; do
                local ip=$bmc_net.$(($ip4 + $i))
                (ipmitool -H $ip -U root -P $pw lan set 1 defgw ipaddr "$bmc_net.1"
                ipmitool -H $ip -U root -P $pw power on
                ipmitool -H $ip -U root -P $pw power reset) &
            done
        done
        wait
    fi

    echo "Waiting for nodes to come up..."
    while ! crowbar machines list | grep ^d ; do sleep 10 ; done
    echo "Found one node"
    while test $(crowbar machines list | grep ^d|wc -l) -lt $nodenumber; do
        sleep 10
    done
    local nodes=$(crowbar machines list | grep ^d)
    local n
    for n in `crowbar machines list | grep ^d` ; do
        wait_for 100 2 "knife node show -a state $n | grep discovered" \
            "node to enter discovered state"
    done
    echo "Sleeping 50 more seconds..."
    sleep 50
    echo "Setting first node to controller..."
    local controllernode=$(
        crowbar machines list | LC_ALL=C sort | grep ^d | head -n 1
    )
    local t=$(mktemp).json

    knife node show -F json $controllernode > $t
    json-edit $t -a normal.crowbar_wall.intended_role -v "controller"
    knife node from file $t
    rm -f $t

    if [ -n "$want_sles12" ] && iscloudver 5plus ; then

        local nodes=(
            $(crowbar machines list | LC_ALL=C sort | grep ^d | tail -n 2)
        )
        if [ -n "$deployceph" ] ; then
            echo "Setting second last node to SLE12 Storage..."
            set_node_role_and_platform ${nodes[0]} "storage" "suse-12.0"
        fi

        echo "Setting last node to SLE12 compute..."
        set_node_role_and_platform ${nodes[1]} "compute" "suse-12.0"
    fi

    if [ -n "$wanthyperv" ] ; then
        echo "Setting last node to Hyper-V compute..."
        local computenode=$(
            crowbar machines list | LC_ALL=C sort | grep ^d | tail -n 1
        )
        set_node_role_and_platform $computenode "compute" "hyperv-6.3"
    fi

    echo "Allocating nodes..."
    local m
    for m in `crowbar machines list | grep ^d` ; do
        while knife node show -a state $m | grep discovered; do # workaround bnc#773041
            crowbar machines allocate "$m"
            sleep 10
        done
        local i=$(echo $m | sed "s/.*-0\?\([^-\.]*\)\..*/\1/g")
        cat >> .ssh/config <<EOF
Host node$i
    HostName $m
EOF
    done

    # check for error 500 in app/models/node_object.rb:635:in `sort_ifs'#012
    curl -m 9 -s --digest --user crowbar:crowbar http://localhost:3000 | \
        tee /root/crowbartest.out
    if grep -q "Exception caught" /root/crowbartest.out; then
        complain 27 "simple crowbar test failed"
    fi

    rm -f /root/crowbartest.out
}

function sshtest()
{
    timeout 10 ssh -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no "$@"
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

function onadmin_waitcompute()
{
    pre_hook $FUNCNAME
    local node
    for node in $(crowbar machines list | grep ^d) ; do
        wait_for 200 10 \
            "netcat -w 3 -z $node 3389 || sshtest $node rpm -q yast2-core" \
            "node $node" "check_node_resolvconf $node; exit 12"
        echo "node $node ready"
    done
}

function mac_to_nodename()
{
    local mac=$1
    echo "d${mac//:/-}.$cloudfqdn"
}

function onadmin_get_ip_from_dhcp()
{
    local mac=$1
    local leasefile=${2:-/var/lib/dhcp/db/dhcpd.leases}

    awk '
        /^lease/   { ip=$2 }
        /ethernet /{ if ($3=="'$mac';") res=ip }
        END{ if (res=="") exit 1; print res }' $leasefile
}

# register a new node with crowbar_register
function onadmin_crowbar_register()
{
    wait_for 150 10 "onadmin_get_ip_from_dhcp '$lonelymac'" "node to get an IP from DHCP" "exit 78"
    local crowbar_register_node_ip=`onadmin_get_ip_from_dhcp "$lonelymac"`

    [ -n "$crowbar_register_node_ip" ] || complain 84 "Could not get IP address of crowbar_register_node"

    wait_for 150 10 "ping -q -c 1 -w 1 $crowbar_register_node_ip >/dev/null" "ping to return from ${cloud}-lonelynode" "complain 82 'could not ping crowbar_register VM ($crowbar_register_node_ip)'"

    # wait a bit for sshd.service on ${cloud}-lonelynode
    wait_for 10 10 "ssh_password $crowbar_register_node_ip 'echo'" "ssh to be running on ${cloud}-lonelynode" "complain 82 'sshd is not responding on ($crowbar_register_node_ip)'"

    local pubkey=`cat /root/.ssh/id_rsa.pub`
    ssh_password $crowbar_register_node_ip "mkdir -p /root/.ssh; echo '$pubkey' >> /root/.ssh/authorized_keys"

    # call crowbar_register on the lonely node
    local inject
    local zyppercmd
    if [ -n "$want_sles12" ] ; then
        image="suse-12.0"
    else
        image="suse-11.3"
        # install SuSEfirewall2 as it is called in crowbar_register
        #FIXME in barclamp-provisioner
        zyppercmd="zypper -n install SuSEfirewall2 &&"
    fi

    local adminfqdn=`crowbar machines list | grep crowbar`
    local adminip=`knife node show $adminfqdn -a crowbar.network.admin.address | awk '{print $2}'`

    if [[ $keep_existing_hostname -eq 1 ]] ; then
        local hostname="$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 10 | head -n 1)"
        local domain="${adminfqdn#*.}"
        local hostnamecmd='echo "'$hostname'.'$domain'" > /etc/HOSTNAME'
    fi

    inject="
            set -x
            rm -f /tmp/crowbar_register_done;
            wget http://$adminip:8091/$image/crowbar_register &&
            chmod a+x crowbar_register &&
            $zyppercmd
            $hostnamecmd
            zypper -n ref &&
            zypper -n up &&
            screen -d -m -L /bin/bash -c '
            yes | ./crowbar_register --no-gpg-checks &&
            touch /tmp/crowbar_register_done;'
        "

    ssh $crowbar_register_node_ip "$inject"

    # wait for ip to be changed to a new one
    wait_for 160 10 "! ping -q -c 1 -w 1 $crowbar_register_node_ip >/dev/null" "ping to fail from ${cloud}-lonelynode (mac: $lonelymac)." "complain 81 'crowbar_register VM did not change its IP'"
    # get new ip from crowbar
    sleep 10
    local crowbar_register_node_ip_new
    if [[ $keep_existing_hostname -eq 1 ]] ; then
        local node="$hostname.$domain"
    else
        local node=`mac_to_nodename $lonelymac`
    fi
    crowbar_register_node_ip_new=`knife node show $node -a crowbar.network.admin.address | awk '{print $2}'`

    [ -n "$crowbar_register_node_ip_new" ] || complain 84 "Could not get Crowbar assigned IP address of crowbar_register_node"

    wait_for 160 10 "ssh $crowbar_register_node_ip_new '[ -e /tmp/crowbar_register_done ]'" "crowbar_register on $node" "complain 83 'crowbar_register failed'"
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
                    machinestatus=`crowbar machines show $i state`
                    if test "x$machinestatus" = "xfailed" -o "x$machinestatus" = "xnil" ; then
                        complain 39 "machine status is failed. Exiting"
                    fi
                    sleep 5
                    n=$((n-1))
                    echo -n "."
                done
                n=500
                while test $n -gt 0 && \
                    ! netcat -w 3 -z $i 22 && \
                    ! netcat -w 3 -z $i 3389
                do
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
                proposalstatus=$(
                    crowbar $proposal proposal show $proposaltype | \
                    rubyjsonparse "
                        puts j['deployment']['$proposal']['crowbar-status']"
                )
                if test "x$proposalstatus" = "xfailed" ; then
                    tail -n 90 \
                        /opt/dell/crowbar_framework/log/d*.log \
                        /var/log/crowbar/chef-client/d*.log
                    complain 40 "Error: proposal $proposal failed. Exiting."
                fi
                sleep 5
                n=$((n-1))
                echo -n "."
            done
            echo
            echo "proposal $proposal successful"
            ;;
        *)
            complain 72 "Error: waitnodes was called with wrong parameters"
            ;;
    esac

    if [ $n == 0 ] ; then
        complain 74 "Waiting timed out. Exiting."
    fi
}

function get_proposal_filename()
{
    echo "/root/${1}.${2}.proposal"
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

    local pfile=`get_proposal_filename "${proposal}" "${proposaltype}"`

    safely rubyjsonparse "
        j${variable}${operator}${value}
        puts JSON.pretty_generate(j)
    " < $pfile > ${pfile}.tmp
    mv ${pfile}.tmp ${pfile}
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

function hacloud_configure_cluster_members()
{
    local clustername=$1
    shift

    local nodes=`printf "\"%s\"," $@`
    nodes="[ ${nodes%,} ]"
    local role
    for role in pacemaker-cluster-member hawk-server; do
        proposal_modify_value pacemaker "$clustername" \
            "['deployment']['pacemaker']['elements']['$role']" "[]" "||="
        proposal_modify_value pacemaker "$clustername" \
            "['deployment']['pacemaker']['elements']['$role']" "$nodes" "+="
    done

    if [[ "configuration" = "with per_node" ]] ; then
        for node in $@; do
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['per_node']['nodes']['$node']" "{}"
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['per_node']['nodes']['$node']['params']" "''"
        done
    fi
}

function hacloud_configure_cluster_defaults()
{
    local clustername=$1
    local clustertype=$2
    local cnodes=

    # assigning the computed nodes as members to the clusters
    if [[ $clustername == $clustertype ]] ; then
        case $clustername in
            data)     cnodes="$clusternodesdata"     ;;
            services) cnodes="$clusternodesservices" ;;
            network)  cnodes="$clusternodesnetwork"  ;;
        esac
        hacloud_configure_cluster_members $clustername "$cnodes"
    fi

    proposal_set_value pacemaker "$clustername" \
        "['attributes']['pacemaker']['stonith']['mode']" "'libvirt'"
    proposal_set_value pacemaker "$clustername" \
        "['attributes']['pacemaker']['stonith']['libvirt']['hypervisor_ip']" "'$mkcloudhostip'"
    proposal_modify_value pacemaker "$clustername" \
        "['description']" "'Clustername: $clustername, type: $clustertype ; '" "+="
}

function hacloud_configure_data_cluster()
{
    proposal_set_value pacemaker $clusternamedata "['attributes']['pacemaker']['drbd']['enabled']" true
    hacloud_configure_cluster_defaults $clusternamedata "data"
}

function hacloud_configure_network_cluster()
{
    hacloud_configure_cluster_defaults $clusternamenetwork "network"
}

function hacloud_configure_services_cluster()
{
    hacloud_configure_cluster_defaults $clusternameservices "services"
}

function dns_proposal_configuration()
{
    local cnumber=`crowbar machines list | wc -l`
    local cnumber=`expr $cnumber - 1`
    [[ $cnumber -gt 3 ]] && local local cnumber=3
    local cmachines=`crowbar machines list | sort | head -n ${cnumber}`
    local dnsnodes=`echo \"$cmachines\" | sed 's/ /", "/g'`
    proposal_set_value dns default "['attributes']['dns']['records']" "{}"
    proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']" "{}"
    proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']['ips']" "['10.11.12.13']"
    proposal_set_value dns default "['deployment']['dns']['elements']['dns-server']" "[$dnsnodes]"
}


# configure one crowbar barclamp proposal using global vars as source
#   does not include proposal create or commit
# input1: name of the barclamp to change
# input2(optional): type/name of the proposal - if not given, "default" is used
function custom_configuration()
{
    local proposal=$1
    local proposaltype=${2:-default}
    local proposaltypemapped=$proposaltype
    proposaltype=${proposaltype%%+*}

    # prepare the proposal file to be edited, it will be read once at the end
    # So, ONLY edit the $pfile  -  DO NOT call "crowbar $x proposal .*" command
    local pfile=`get_proposal_filename "${proposal}" "${proposaltype}"`
    crowbar $proposal proposal show $proposaltype > $pfile

    if [[ $debug_openstack = 1 && $proposal != swift ]] ; then
        sed -i -e "s/debug\": false/debug\": true/" -e "s/verbose\": false/verbose\": true/" $pfile
    fi

    ### NOTE: ONLY USE proposal_{set,modify}_value functions below this line
    ###       The edited proposal will be read and imported at the end
    ###       So, only edit the proposal file, and NOT the proposal itself

    case "$proposal" in
        pacemaker)
            # multiple matches possible, so separate if's, to allow to configure mapped clusters
            if [[ $proposaltypemapped =~ .*data.* ]] ; then
                hacloud_configure_data_cluster
            fi
            if [[ $proposaltypemapped =~ .*services.* ]] ; then
                hacloud_configure_services_cluster
            fi
            if [[ $proposaltypemapped =~ .*network.* ]] ; then
                hacloud_configure_network_cluster
            fi
        ;;
        database)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value database default "['attributes']['database']['ha']['storage']['mode']" "'drbd'"
                proposal_set_value database default "['attributes']['database']['ha']['storage']['drbd']['size']" "$drbd_database_size"
                proposal_set_value database default "['deployment']['database']['elements']['database-server']" "['cluster:$clusternamedata']"
            fi
        ;;
        rabbitmq)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['mode']" "'drbd'"
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['drbd']['size']" "$drbd_rabbitmq_size"
                proposal_set_value rabbitmq default "['deployment']['rabbitmq']['elements']['rabbitmq-server']" "['cluster:$clusternamedata']"
            fi
        ;;
        dns)
            dns_proposal_configuration
        ;;
        ipmi)
            proposal_set_value ipmi default "['attributes']['ipmi']['bmc_enable']" true
        ;;
        keystone)
            if [[ $all_with_ssl = 1 || $keystone_with_ssl = 1 ]] ; then
                enable_ssl_for_keystone
            fi
            # set a custom region name
            if iscloudver 4plus ; then
                proposal_set_value keystone default "['attributes']['keystone']['api']['region']" "'CustomRegion'"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value keystone default "['deployment']['keystone']['elements']['keystone-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        glance)
            if [[ $all_with_ssl = 1 || $glance_with_ssl = 1 ]] ; then
                enable_ssl_for_glance
            fi
            if [[ -n "$deployceph" ]]; then
                proposal_set_value glance default "['attributes']['glance']['default_store']" "'rbd'"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value glance default "['deployment']['glance']['elements']['glance-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        ceph)
            proposal_set_value ceph default "['attributes']['ceph']['disk_mode']" "'all'"
        ;;
        nova)
            # custom nova config of libvirt
            proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
            proposal_set_value nova default "['attributes']['nova']['use_migration']" "true"
            [[ "$libvirt_type" = xen ]] && sed -i -e "s/nova-multi-compute-$libvirt_type/nova-multi-compute-xxx/g; s/nova-multi-compute-kvm/nova-multi-compute-$libvirt_type/g; s/nova-multi-compute-xxx/nova-multi-compute-kvm/g" $pfile

            if [[ $all_with_ssl = 1 || $nova_with_ssl = 1 ]] ; then
                enable_ssl_for_nova
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-multi-controller']" "['cluster:$clusternameservices']"

                # only use remaining nodes as compute nodes, keep cluster nodes dedicated to cluster only
                local novanodes
                novanodes=`printf "\"%s\"," $nodescompute`
                novanodes="[ ${novanodes%,} ]"
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-multi-compute-${libvirt_type}']" "$novanodes"
            fi
            if [[ $nova_shared_instance_storage = 1 ]] ; then
                proposal_set_value nova default "['attributes']['nova']['use_shared_instance_storage']" "true"
            fi
        ;;
        nova_dashboard)
            if [[ $all_with_ssl = 1 || $novadashboard_with_ssl = 1 ]] ; then
                enable_ssl_for_nova_dashboard
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova_dashboard default "['deployment']['nova_dashboard']['elements']['nova_dashboard-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        heat)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value heat default "['deployment']['heat']['elements']['heat-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        ceilometer)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-server']" "['cluster:$clusternameservices']"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-cagent']" "['cluster:$clusternameservices']"
                # disabling mongodb, because if in one cluster mode the requirements of drbd and mongodb ha conflict:
                #   drbd can only use 2 nodes max. <> mongodb ha requires 3 nodes min.
                # this should be adapted when NFS mode is supported for data cluster
                proposal_set_value ceilometer default "['attributes']['ceilometer']['use_mongodb']" "false"
                local ceilometernodes
                ceilometernodes=`printf "\"%s\"," $nodescompute`
                ceilometernodes="[ ${ceilometernodes%,} ]"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-agent']" "$ceilometernodes"
            fi
        ;;
        neutron)
            [[ "$networkingplugin" = linuxbridge ]] && networkingmode=vlan
            if iscloudver 4plus; then
                proposal_set_value neutron default "['attributes']['neutron']['use_lbaas']" "true"
            fi

            # For Cloud > 5 M4, proposal attribute names changed
            # TODO(toabctl): the milestone/cloud6 check can be removed when milestone 5 is released
            if iscloudver 5 && [[ ! $cloudsource =~ ^M[1-4]+$ ]] || iscloudver 6plus; then
                if [ "$networkingplugin" = "openvswitch" ] ; then
                    if [[ "$networkingmode" = vxlan ]] || iscloudver 6plus; then
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vxlan','vlan']"
                        if [[ -n "$want_dvr" ]]; then
                            proposal_set_value neutron default "['attributes']['neutron']['use_dvr']" "true"
                        fi
                    else
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vlan']"
                    fi
                elif [ "$networkingplugin" = "linuxbridge" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['vlan']"
                    proposal_set_value neutron default "['attributes']['neutron']['use_l2pop']" "false"
                else
                    complain 106 "networkingplugin '$networkingplugin' not yet covered in mkcloud"
                fi
                proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'ml2'"
                proposal_set_value neutron default "['attributes']['neutron']['ml2_mechanism_drivers']" "['$networkingplugin']"
                if [ -n "$networkingmode" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_provider_network']" "'$networkingmode'"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_tenant_network']" "'$networkingmode'"
                fi
            else
                if [ -n "$networkingmode" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['networking_mode']" "'$networkingmode'"
                fi
                if [ -n "$networkingplugin" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'$networkingplugin'"
                fi
            fi

            # assign neutron-network role to one of SLE12 nodes
            if [ -n "$want_sles12" ] && [ -z "$hacloud"] && [ -n "$want_neutronsles12" ] && iscloudver 5plus ; then
                # 2015-03-03 off-by-default because Failed to validate proposal: Role neutron-network can't be used for suse 12.0, windows /.*/ platform(s).
                local sle12node=$(knife search node "target_platform:suse-12.0" -a name | grep ^name: | cut -d : -f 2 | tail -n 1 | sed 's/\s//g')
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-network']" "['$sle12node']"
            fi

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-server']" "['cluster:$clusternamenetwork']"
                # neutron-network role is only available since Cloud5+Updates
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-network']" "['cluster:$clusternamenetwork']" || \
                    proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-l3']" "['cluster:$clusternamenetwork']"
            fi
            if [[ "$networkingplugin" = "vmware" ]] ; then
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['user']" "'$nsx_user'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['password']" "'$nsx_password'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['controllers']" "'$nsx_controllers'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['tz_uuid']" "'$nsx_tz_uuid'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['l3_gw_uuid']" "'$nsx_l3_gw_uuid'"
            fi
        ;;
        swift)
            [[ "$nodenumber" -lt 3 ]] && proposal_set_value swift default "['attributes']['swift']['zones']" "1"
            if iscloudver 3plus ; then
                proposal_set_value swift default "['attributes']['swift']['ssl']['generate_certs']" "true"
                proposal_set_value swift default "['attributes']['swift']['ssl']['insecure']" "true"
                proposal_set_value swift default "['attributes']['swift']['allow_versions']" "true"
                proposal_set_value swift default "['attributes']['swift']['keystone_delay_auth_decision']" "true"
                iscloudver 3 || proposal_set_value swift default "['attributes']['swift']['middlewares']['crossdomain']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['formpost']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['staticweb']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['tempurl']['enabled']" "true"
            fi
        ;;
        cinder)
            if iscloudver 4plus ; then
                if iscloudver 4 ; then
                    proposal_set_value cinder default "['attributes']['cinder']['enable_v2_api']" "true"
                fi

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
            if [[ $hacloud = 1 ]] ; then
                local cinder_volume
                # fetch one of the compute nodes as cinder_volume
                cinder_volume=`printf "%s\n" $nodescompute | tail -n 1`
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-controller']" "['cluster:$clusternameservices']"
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-volume']" "['$cinder_volume']"
            fi
        ;;
        tempest)
            if [[ $hacloud = 1 ]] ; then
                local tempestnodes
                # tempest can only be deployed on one node
                tempestnodes=`printf "'%s',\n" $nodescompute | head -n 1`
                tempestnodes="[ ${tempestnodes%,} ]"
                proposal_set_value tempest default "['deployment']['tempest']['elements']['tempest']" "$tempestnodes"
            fi
        ;;
        provisioner)
            if [[ $keep_existing_hostname = 1 ]] ; then
                proposal_set_value provisioner default "['attributes']['provisioner']['keep_existing_hostname']" "true"
            fi
        ;;
        *) echo "No hooks defined for service: $proposal"
        ;;
    esac

    crowbar $proposal proposal --file=$pfile edit $proposaltype ||\
        complain 88 "Error: 'crowbar $proposal proposal --file=$pfile edit $proposaltype' failed with exit code: $?"
}

# set global variables to be used in and after proposal phase
function set_proposalvars()
{
    # Determine if we went through an upgrade
    if [[ -f /etc/cloudsource ]] ; then
        export cloudsource=$(</etc/cloudsource)
    fi

    ### dynamic defaults
    case "$nodenumber" in
        0|1)
            deployswift=
            deployceph=
        ;;
        2)
            deployswift=1
            deployceph=
        ;;
        *)
            deployswift=
            deployceph=1
        ;;
    esac

    ### filter (temporarily changing defaults)
    # F1: hyperV only without swift and ceph
    if [[ $wanthyperv ]] ; then
        deployswift=
        deployceph=
        networkingmode=vlan
    fi

    ### user requests (can override defaults and filters)
    case "$want_ceph" in
        '') ;;
        0)  deployceph= ;;
        *)  deployceph=1
            deployswift=
        ;;
    esac
    case "$want_swift" in
        '') ;;
        0)  deployswift= ;;
        *)  deployswift=1
            deployceph=
        ;;
    esac

    ### constraints
    # C1: need at least 3 nodes for ceph
    if [[ $nodenumber -lt 3 && $deployceph == 1 ]] ; then
        complain 87 "Ceph needs at least 3 nodes to be deployed. You have ${nodenumber} nodes."
    fi

    # C2: ceph or swift is only possible with at least one volume
    if [[ $cephvolumenumber -lt 1 ]] ; then
        deployswift=
        deployceph=
    fi
    # C3: Cloud5 only has ceph for SLES12
    if iscloudver 5 && [ -z "$want_sles12" ] ; then
        deployceph=
    fi
    ### FINAL swift and ceph check
    if [[ $deployswift && $deployceph ]] ; then
        complain 89 "Can not deploy ceph and swift at the same time."
    fi
    ### do NOT set/change deployceph or deployswift below this line!

    # Tempest
    wanttempest=
    iscloudver 4plus && wanttempest=1
    if [[ $want_tempest == 0 ]] ; then
        wanttempest=
    fi

    # Cinder
    if [[ ! $cinder_conf_volume_type ]] ; then
        if [[ $deployceph ]] ; then
            cinder_conf_volume_type="rbd"
        elif [[ $cephvolumenumber -lt 2 ]] ; then
            cinder_conf_volume_type="local"
        else
            cinder_conf_volume_type="raw"
        fi
    fi
}

# configure and commit one proposal
function update_one_proposal()
{
    local proposal=$1
    local proposaltype=${2:-default}
    local proposaltypemapped=$proposaltype
    proposaltype=${proposaltype%%+*}

    echo -n "Starting proposal $proposal($proposaltype) at: "
    date
    # hook for changing proposals:
    custom_configuration $proposal $proposaltypemapped
    crowbar "$proposal" proposal commit $proposaltype
    local ret=$?
    echo "Commit exit code: $ret"
    if [ "$ret" = "0" ]; then
        waitnodes proposal $proposal $proposaltype
        ret=$?
        echo "Proposal exit code: $ret"
        echo -n "Finished proposal $proposal($proposaltype) at: "
        date
        sleep 10
    fi
    if [ $ret != 0 ] ; then
        tail -n 90 /opt/dell/crowbar_framework/log/d*.log /var/log/crowbar/chef-client/d*.log
        complain 73 "Committing the crowbar '$proposaltype' proposal for '$proposal' failed ($ret)."
    fi
}

# create, configure and commit one proposal
function do_one_proposal()
{
    local proposal=$1
    local proposaltype=${2:-default}

    # in ha mode proposaltype may contain names of mapped clusters
    # extract them for the proposal creation, but pass them to update_one_proposal
    local proposaltypemapped=$proposaltype
    proposaltype=${proposaltype%%+*}
    crowbar "$proposal" proposal create $proposaltype
    update_one_proposal "$proposal" "$proposaltypemapped"
}

# apply all wanted proposals on crowbar admin node
function onadmin_proposal()
{
    pre_hook $FUNCNAME
    waitnodes nodes

    if iscloudver 5plus; then
        update_one_proposal dns default
    fi
    if [ "$networkingplugin" = "vmware" ] && iscloudver 5plus ; then
        cmachines=`crowbar machines list`
        for machine in $cmachines; do
            ssh $machine 'zypper mr -p 90 SLE-Cloud-PTF'
        done
    fi

    local proposals="pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova nova_dashboard ceilometer heat trove tempest"

    local proposal
    for proposal in $proposals ; do
        # proposal filter
        case "$proposal" in
            pacemaker)
                [ -n "$hacloud" ] || continue
                cluster_node_assignment
                ;;
            ceph)
                [[ -n "$deployceph" ]] || continue
                ;;
            swift)
                [[ -n "$deployswift" ]] || continue
                ;;
            trove)
                iscloudver 5plus || continue
                ;;
            tempest)
                [[ -n "$wanttempest" ]] || continue
                ;;
        esac

        # create proposal
        case "$proposal" in
            pacemaker)
                local clustermapped
                for clustermapped in ${clusterconfig//:/ } ; do
                    clustermapped=${clustermapped%=*}
                    # pass on the cluster name together with the mapped cluster name(s)
                    do_one_proposal "$proposal" "$clustermapped"
                done
                ;;
            *)
                do_one_proposal "$proposal" "default"
                ;;
        esac
    done

    # Set dashboard node alias
    get_novadashboardserver
    set_node_alias `echo "$novadashboardserver" | cut -d . -f 1` dashboard controller
}

function set_node_alias()
{
    local node_name=$1
    local node_alias=$2
    local intended_role=$3
    if [[ "${node_name}" != "${node_alias}" ]]; then
        crowbar machines rename ${node_name} ${node_alias}
    fi
    iscloudver 5plus && crowbar machines role $node_name $intended_role || :
}

function get_first_node_from_cluster()
{
    local cluster=$1
    crowbar pacemaker proposal show $cluster | \
        rubyjsonparse "
                    puts j['deployment']['pacemaker']\
                        ['elements']['pacemaker-cluster-member'].first"
}

# An entry in an elements section can have single or multiple nodes or a cluster alias
# This function will resolve this element name to a node name.
function resolve_element_to_node()
{
    local name="$1"
    name=`printf "%s\n" "$name" | head -n 1`
    case $name in
        cluster:*)
            get_first_node_from_cluster ${name#cluster:}
        ;;
        *)
            echo $name
        ;;
    esac
}

function get_novacontroller()
{
    novacontroller=`crowbar nova proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['nova']\
                        ['elements']['nova-multi-controller']"`
    novacontroller=`resolve_element_to_node "$novacontroller"`
}

function get_novadashboardserver()
{
    novadashboardserver=`crowbar nova_dashboard proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['nova_dashboard']\
                        ['elements']['nova_dashboard-server']"`
    novadashboardserver=`resolve_element_to_node "$novadashboardserver"`
}

function get_ceph_nodes()
{
    if [[ -n "$deployceph" ]]; then
        cephmons=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-mon']"`
        cephosds=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-osd']"`
        cephradosgws=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-radosgw']"`
    else
        cephmons=
        cephosds=
        cephradosgws=
    fi
}

function addfloatingip()
{
    local instanceid=$1
    nova floating-ip-create | tee floating-ip-create.out
    floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
    nova add-floating-ip "$instanceid" "$floatingip"
}

# code run on controller/dashboard node to do basic tests of deployed cloud
# uploads an image, create flavor, boots a VM, assigns a floating IP, ssh to VM, attach/detach volume
function oncontroller_testsetup()
{
    . .openrc

    export LC_ALL=C
    if [[ -n $deployswift ]] ; then
        zypper -n install python-swiftclient
        swift stat
        swift upload container1 .ssh/authorized_keys
        swift list container1 || complain 33 "swift list failed"
    fi

    radosgwret=0
    if [ "$wantradosgwtest" == 1 ] ; then

        zypper -n install python-swiftclient

        if ! swift post swift-test; then
            echo "creating swift container failed"
            radosgwret=1
        fi

        if [ "$radosgwret" == 0 ] && ! swift list|grep -q swift-test; then
            echo "swift-test container not found"
            radosgwret=2
        fi

        if [ "$radosgwret" == 0 ] && ! swift delete swift-test; then
            echo "deleting swift-test container failed"
            radosgwret=3
        fi

        if [ "$radosgwret" == 0 ] ; then
            # verify file content after uploading & downloading
            swift upload swift-test .ssh/authorized_keys
            swift download --output .ssh/authorized_keys-downloaded swift-test .ssh/authorized_keys
            if ! cmp .ssh/authorized_keys .ssh/authorized_keys-downloaded; then
                echo "file is different content after download"
                radosgwret=4
            fi
        fi
    fi

    # Run Tempest Smoketests if configured to do so
    tempestret=0
    if [ "$wanttempest" = "1" ]; then
        # Upload a Heat-enabled image
        glance image-list|grep -q SLE11SP3-x86_64-cfntools || glance image-create \
            --name=SLE11SP3-x86_64-cfntools --is-public=True --disk-format=qcow2 \
            --container-format=bare --property hypervisor_type=kvm \
            --copy-from http://clouddata.cloud.suse.de/images/SLES11-SP3-x86_64-cfntools.qcow2 | tee glance.out
        imageid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" glance.out`
        crudini --set /etc/tempest/tempest.conf orchestration image_ref $imageid
        pushd /var/lib/openstack-tempest-test
        echo 1 > /proc/sys/kernel/sysrq
        ./run_tempest.sh -N $tempestoptions 2>&1 | tee tempest.log
        tempestret=${PIPESTATUS[0]}
        /var/lib/openstack-tempest-test/bin/tempest_cleanup.sh || :
        popd
    fi
    nova list
    glance image-list

    if glance image-list | grep -q SP3-64 ; then
        glance image-show SP3-64 | tee glance.out
    else
        # SP3-64 image not found, so uploading it
        if [[ -n "$wanthyperv" ]] ; then
            mount clouddata.cloud.suse.de:/srv/nfs/ /mnt/
            zypper -n in virt-utils
            qemu-img convert -O vpc /mnt/images/SP3-64up.qcow2 /tmp/SP3.vhd
            glance --insecure image-create --name=SP3-64 --is-public=True --disk-format=vhd --container-format=bare --property hypervisor_type=hyperv --file /tmp/SP3.vhd | tee glance.out
            rm /tmp/SP3.vhd ; umount /mnt
        elif [[ -n "$wantxenpv" ]] ; then
            glance --insecure image-create --name=SP3-64 --is-public=True --disk-format=qcow2 --container-format=bare --property hypervisor_type=xen --property vm_mode=xen --copy-from http://clouddata.cloud.suse.de/images/jeos-64-pv.qcow2 | tee glance.out
        else
            glance image-create --name=SP3-64 --is-public=True --property vm_mode=hvm --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SP3-64up.qcow2 | tee glance.out
        fi
    fi

    # wait for image to finish uploading
    imageid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" glance.out`
    if [ "x$imageid" == "x" ]; then
        complain 37 "Error: Image ID for SP3-64 not found"
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
    nova delete testvm  || :
    nova keypair-add --pub_key /root/.ssh/id_rsa.pub testkey
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0
    nova secgroup-add-rule default udp 1 65535 0.0.0.0/0
    nova boot --poll --image SP3-64 --flavor m1.smaller --key_name testkey testvm | tee boot.out
    ret=${PIPESTATUS[0]}
    [ $ret != 0 ] && complain 43 "nova boot failed"
    instanceid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" boot.out`
    nova show "$instanceid"
    vmip=`nova show "$instanceid" | perl -ne "m/fixed.network [ |]*([0-9.]+)/ && print \\$1"`
    echo "VM IP address: $vmip"
    if [ -z "$vmip" ] ; then
        tail -n 90 /var/log/nova/*
        complain 38 "VM IP is empty. Exiting"
    fi
    addfloatingip "$instanceid"
    vmip=$floatingip
    n=1000 ; while test $n -gt 0 && ! ping -q -c 1 -w 1 $vmip >/dev/null ; do
        n=$(expr $n - 1)
        echo -n .
        set +x
    done
    set -x
    if [ $n = 0 ] ; then
        complain 94 "testvm boot or net failed"
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
        complain 96 "VM not accessible in reasonable time, exiting."
    fi

    set +x
    echo "Waiting for the SSH keys to be copied over"
    i=0
    MAX_RETRIES=40
    while timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $vmip "echo cloud" 2> /dev/null; [ $? != 0 ]
    do
        sleep 5  # wait before retry
        if [ $i -gt $MAX_RETRIES ] ; then
            complain 97 "VM not accessible via SSH, something could be wrong with SSH keys"
        fi
        i=$((i+1))
        echo -n "."
    done
    set -x
    if ! ssh $vmip curl www3.zq1.de/test ; then
        complain 95 could not reach internet
    fi
    nova volume-list | grep -q available || nova volume-create 1
    local volumecreateret=0
    wait_for 9 5 "nova volume-list | grep available" "volume to become available" "volumecreateret=1"
    volumeid=`nova volume-list | perl -ne "m/^[ |]*([0-9a-f-]+) [ |]*available/ && print \\$1"`
    nova volume-attach "$instanceid" "$volumeid" /dev/vdb | tee volume-attach.out
    local volumeattachret=$?
    device=`perl -ne "m!device [ |]*(/dev/\w+)! && print \\$1" volume-attach.out`
    wait_for 9 5 "nova volume-show $volumeid | grep 'status.*in-use'" "volume to become attached" "volumeattachret=111"
    ssh $vmip fdisk -l $device | grep 1073741824 || volumeattachret=$?
    rand=$RANDOM
    ssh $vmip "mkfs.ext3 -F $device && mount $device /mnt && echo $rand > /mnt/test.txt && umount /mnt"
    nova volume-detach "$instanceid" "$volumeid" ; sleep 10
    nova volume-attach "$instanceid" "$volumeid" /dev/vdb ; sleep 10
    ssh $vmip fdisk -l $device | grep 1073741824 || volumeattachret=57
    ssh $vmip "mount $device /mnt && grep -q $rand /mnt/test.txt" || volumeattachret=58
    # cleanup so that we can run testvm without leaking volumes, IPs etc
    nova remove-floating-ip "$instanceid" "$floatingip"
    nova floating-ip-delete "$floatingip"
    nova stop "$instanceid"
    wait_for 100 1 "test \"x\$(nova show \"$instanceid\" | perl -ne 'm/ status [ |]*([a-zA-Z]+)/ && print \$1')\" == xSHUTOFF" "testvm to stop"

    echo "RadosGW Tests: $radosgwret"
    echo "Tempest: $tempestret"
    echo "Volume in VM: $volumecreateret & $volumeattachret"

    test $tempestret = 0 -a $volumecreateret = 0 -a $volumeattachret = 0 -a $radosgwret = 0 || exit 102
}


function oncontroller()
{
    scp qa_crowbarsetup.sh $mkcconf $novacontroller:
    ssh $novacontroller "export deployswift=$deployswift ; export deployceph=$deployceph ; export wanttempest=$wanttempest ;
        export tempestoptions=\"$tempestoptions\" ; export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ;
        export wantradosgwtest=\"$wantradosgwtest\" ; export cloudsource=\"$cloudsource\" ;
        export libvirt_type=\"$libvirt_type\" ;
        export cloud=$cloud ; . ./qa_crowbarsetup.sh ; $@"
    return $?
}

function onadmin_testsetup()
{
    pre_hook $FUNCNAME

    if iscloudver 5plus; then
        cmachines=`crowbar machines list`
        for machine in $cmachines; do
            knife node show $machine -a node.target_platform | grep -q suse- || continue
            ssh $machine 'dig multi-dns.'"'$cloudfqdn'"' | grep -q 10.11.12.13' ||\
                complain 13 "Multi DNS server test failed!"
        done
    fi

    get_novacontroller
    if [ -z "$novacontroller" ] || ! ssh $novacontroller true ; then
        complain 62 "no nova contoller - something went wrong"
    fi
    echo "openstack nova contoller: $novacontroller"
    curl -m 40 -s http://$novacontroller | grep -q -e csrfmiddlewaretoken -e "<title>302 Found</title>" || complain 101 "simple horizon dashboard test failed"

    wantcephtestsuite=0
    if [[ -n "$deployceph" ]]; then
        get_ceph_nodes
        [ "$cephradosgws" = nil ] && cephradosgws=""
        echo "ceph mons:" $cephmons
        echo "ceph osds:" $cephosds
        echo "ceph radosgw:" $cephradosgws
        if iscloudver 4plus && [ -n "$cephradosgws" ] ; then
            wantcephtestsuite=1
            wantradosgwtest=1
        fi
    fi

    cephret=0
    if [ -n "$deployceph" -a "$wantcephtestsuite" == 1 ] ; then
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

        set -- $yaml_mons
        first_mon_node=$1
        ceph_version=$(ssh $first_mon_node "rpm -q --qf %{version} ceph")

        sed -i "s/^ceph_version:.*/ceph_version: $ceph_version/g" yamldata/testcloud_sanity.yaml
        sed -i "s/^radosgw_node:.*/radosgw_node: $yaml_radosgw/g" yamldata/testcloud_sanity.yaml
        # client node is the same as the rados gw node, to make our life easier
        sed -i "s/^clientnode:.*/clientnode: $yaml_radosgw/g" yamldata/testcloud_sanity.yaml

        sed -i "/teuthida-4/d" yamldata/testcloud_sanity.yaml
        for node in $yaml_allnodes; do
            sed -i "/^allnodes:$/a - $node" yamldata/testcloud_sanity.yaml
        done
        for node in $yaml_mons; do
            sed -i "/^initmons:$/a - $node" yamldata/testcloud_sanity.yaml
        done
        for node in $yaml_osds; do
            nodename=(vda1 vdb1 vdc1 vdd1 vde1)
            for i in $(seq $cephvolumenumber); do
                sed -i "/^osds:$/a - $node:${nodename[$i]}" yamldata/testcloud_sanity.yaml
            done
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

    s3radosgwret=0
    if [ "$wantradosgwtest" == 1 ] ; then
        # test S3 access using python API
        radosgw=`echo $cephradosgws | sed "s/ .*//g" | sed "s/\..*//g"`
        ssh $radosgw radosgw-admin user create --uid=rados --display-name=RadosGW --secret="secret" --access-key="access"

        # using curl directly is complicated, see http://ceph.com/docs/master/radosgw/s3/authentication/
        zypper -n install python-boto
        python << EOF
import boto
import boto.s3.connection

conn = boto.connect_s3(
        aws_access_key_id = "access",
        aws_secret_access_key = "secret",
        host = "$radosgw",
        port = 8080,
        is_secure=False,
        calling_format = boto.s3.connection.OrdinaryCallingFormat()
    )
bucket = conn.create_bucket("test-s3-bucket")
EOF

        # check if test bucket exists using radosgw-admin API
        if ! ssh $radosgw radosgw-admin bucket list|grep -q test-s3-bucket ; then
            echo "test-s3-bucket not found"
            s3radosgwret=1
        fi
    fi

    oncontroller oncontroller_testsetup
    ret=$?

    echo "Tests on controller: $ret"
    echo "Ceph Tests: $cephret"
    echo "RadosGW S3 Tests: $s3radosgwret"

    if [ $ret -eq 0 ]; then
        test $s3radosgwret -eq 0 || ret=105
        test $cephret -eq 0 || ret=104
    fi

    if [ "$wanttempest" = "1" ]; then
        scp $novacontroller:"/var/lib/openstack-tempest-test/tempest.log" .
    fi
    exit $ret
}

function onadmin_addupdaterepo()
{
    pre_hook $FUNCNAME

    local UPR=$tftpboot_repos_dir/Cloud-PTF
    mkdir -p $UPR

    if [[ -n "$UPDATEREPOS" ]]; then
        local repo
        for repo in ${UPDATEREPOS//+/ } ; do
            wget --progress=dot:mega -r --directory-prefix $UPR --no-parent --no-clobber --accept x86_64.rpm,noarch.rpm $repo || exit 8
        done
        safely zypper -n install createrepo
        createrepo -o $UPR $UPR || exit 8
    fi
    zypper modifyrepo -e cloud-ptf >/dev/null 2>&1 ||\
        safely zypper ar $UPR cloud-ptf
}

function onadmin_runupdate()
{
    onadmin_repocleanup

    pre_hook $FUNCNAME

    wait_for 30 3 ' zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks ref ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
    wait_for 30 3 ' zypper --non-interactive patch ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
    wait_for 30 3 ' zypper --non-interactive up --repo cloud-ptf ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
}

# reboot all cloud nodes (controller+compute+storage)
# wait for nodes to go down and come up again
function onadmin_rebootcompute()
{
    pre_hook $FUNCNAME
    get_novacontroller

    local cmachines=`crowbar machines list | grep ^d`
    local m
    for m in $cmachines ; do
        ssh $m "reboot"
        wait_for 100 1 " ! netcat -z $m 22 >/dev/null" "node $m to go down"
    done

    wait_for 400 5 "! crowbar node_state status | grep ^d | grep -vqiE \"ready$|problem$\"" "nodes are back online"

    if crowbar node_state status | grep ^d | grep -i "problem$"; then
        complain 17 "Some nodes rebooted with state Problem."
    fi

    oncontroller oncontroller_waitforinstance
    local ret=$?
    echo "ret:$ret"
    exit $ret
}

# make sure that testvm is up and reachable
# if VM was shutdown, VM is started
# adds a floating IP to VM
function oncontroller_waitforinstance()
{
    . .openrc
    nova list
    nova start testvm || exit 28
    nova list
    addfloatingip testvm
    local vmip=`nova show testvm | perl -ne 'm/ fixed.network [ |]*[0-9.]+, ([0-9.]+)/ && print $1'`
    [[ -z "$vmip" ]] && complain 12 "no IP found for instance"
    wait_for 100 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm to boot up"
}

function get_neutron_server_node()
{
    NEUTRON_SERVER=$(crowbar neutron proposal show default| rubyjsonparse "
    puts j['deployment']['neutron']['elements']['neutron-server'][0];")
}

function onadmin_rebootneutron()
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
        complain 14 "ping to 8.8.8.8 from $NEUTRON_SERVER failed."
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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

; cookies attributes
[OWASP_SM_002]
skip = 0
dbg = 0
uri_login = https://${novadashboardserver}:443/auth/login/
uri_logout = https://${novadashboardserver}:443/auth/logout/
login_method = POST
logout_method = GET
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

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
cred_attacker = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=Mini Me&password=minime123
cred_victim = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar

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
cred = method=Login&region=http%3A%2F%2F${netp}.186.83%3A5000%2Fv2.0&username=admin&password=crowbar
detect_http_code = 302
EOOWASP
}



function onadmin_securitytests()
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

function onadmin_prepare_cloudupgrade()
{
    # TODO: All running cloud instances should be suspended here

    ### Chef-client could lockj zypper and break upgrade
    # zypper locks do still happen
    # TODO: do we need to stop the client on the nodes too?
    rcchef-client stop

    wait_for_if_running chef-client

    test -z "$upgrade_cloudsource" && {
        complain 15 "upgrade_cloudsource is not set"
    }

    export cloudsource=$upgrade_cloudsource

    # Update new repo paths
    export_tftpboot_repos_dir

    # Client nodes need to be up to date
    onadmin_cloudupgrade_clients

    # change CLOUDDISTISO/CLOUDDISTPATH according to the new cloudsource
    onadmin_set_source_variables

    # recreate the SUSE-Cloud Repo with the latest iso
    onadmin_prepare_cloud_repos

    # Applying the updater barclamp (in onadmin_cloudupgrade_clients) triggers
    # a chef-client run on the admin node (even it the barclamp is not applied
    # on the admin node, this is NOT a bug). Let's wait for that to finish
    # before trying to install anything.
    wait_for_if_running chef-client
    zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks refresh -f || complain 3 "Couldn't refresh zypper indexes after adding SUSE-Cloud-$update_version repos"
    zypper --non-interactive install --force suse-cloud-upgrade || complain 3 "Couldn't install suse-cloud-upgrade"
}

function onadmin_cloudupgrade_1st()
{
    if iscloudver 5; then
        # Workaround registration checks
        echo "SUSE-Cloud-5-Pool SUSE-Cloud-5-Updates" > /etc/zypp/repos.d/ignore-repos
    fi

    export cloudsource=$upgrade_cloudsource
    do_set_repos_skip_checks

    # Disable all openstack proposals stop service on the client
    echo 'y' | suse-cloud-upgrade upgrade ||\
        complain $? "Upgrade failed with $?"
}

function onadmin_cloudupgrade_2nd()
{
    # Allow vender changes for packages as we might be updating an official
    # Cloud release to something form the Devel:Cloud projects. Note: For the
    # client nodes this is needs to happen after the updated provisioner
    # proposal is applied (see below).
    zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks install crudini
    crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true

    # Upgrade Admin node
    zypper --non-interactive up -l
    echo -n "This cloud was upgraded from : " | cat - /etc/cloudversion >> /etc/motd

    echo 'y' | suse-cloud-upgrade upgrade ||\
        complain $? "Upgrade failed with $?"
    crowbar provisioner proposal commit default

    # Allow vendor changes for packages as we might be updating an official
    # Cloud release to something form the Devel:Cloud projects. Note: On the
    # client nodes this needs to happen after the updated provisioner
    # proposal is applied since crudini is not part of older Cloud releases.
    for node in $(crowbar machines list | grep ^d) ; do
        echo "Enabling VendorChange on $node"
        timeout 60 ssh $node "zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks install crudini; crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true"
    done
}

function onadmin_cloudupgrade_clients()
{

    # Upgrade Packages on the client nodes
    crowbar updater proposal create default
    crowbar updater proposal show default > updater.json
    json-edit updater.json -a attributes.updater.zypper.method -v "update"
    json-edit updater.json -a attributes.updater.zypper.licenses_agree --raw -v "true"
    crowbar updater proposal --file updater.json edit default
    rm updater.json
    crowbar updater proposal commit default
}

function onadmin_cloudupgrade_reboot_and_redeploy_clients()
{
    local barclamp=""
    local proposal=""
    local applied_proposals=""
    # reboot client nodes
    echo 'y' | suse-cloud-upgrade reboot-nodes

    # Give it some time and wait for the nodes to be back
    sleep 60
    waitnodes nodes

    # reenable and apply the openstack propsals
    for barclamp in pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova nova_dashboard ceilometer heat trove tempest ; do
        applied_proposals=$(crowbar "$barclamp" proposal list )
        if test "$applied_proposals" == "No current proposals"; then
            continue
        fi

        for proposal in $applied_proposals; do
            echo "Commiting proposal $proposal of barclamp ${barclamp}..."
            crowbar "$barclamp" proposal commit "$proposal" ||\
                complain 30 "committing barclamp-$barclamp failed"
        done
    done

    # Install new features
    if iscloudver 5; then
        update_one_proposal dns default
        zypper --non-interactive install crowbar-barclamp-trove
        do_one_proposal trove default
    elif iscloudver 4; then
        zypper --non-interactive install crowbar-barclamp-tempest
        do_one_proposal tempest default
    fi

    # TODO: restart any suspended instance?
}

function onadmin_crowbarbackup()
{
    rm -f /tmp/backup-crowbar.tar.gz
    AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
        bash -x /usr/sbin/crowbar-backup backup /tmp/backup-crowbar.tar.gz ||\
        complain 21 "crowbar-backup backup failed"
}

function onadmin_crowbarpurge()
{
    # Purge files to pretend we start from a clean state
    cp -a /var/lib/crowbar/cache/etc/resolv.conf /etc/resolv.conf

    for service in crowbar chef-{server,solr,expander,client} couchdb apache2 named dhcpd xinetd rabbitmq-server ; do
        [ -e /etc/init.d/$service ] && /etc/init.d/$service stop
    done
    killall epmd # part of rabbitmq
    killall looper_chef_client.sh

    safely zypper -n rm \
        `rpm -qa|grep -e crowbar -e chef -e rubygem -e susecloud -e apache2` \
        couchdb createrepo erlang rabbitmq-server sleshammer yum-common \
        bind bind-chrootenv dhcp-server tftp

    rm -rf \
        /opt/dell \
        /etc/{bind,chef,crowbar,crowbar.install.key,dhcp3,xinetd.d/tftp} \
        /etc/sysconfig/{dhcpd,named,rabbitmq-server} \
        /var/lib/{chef,couchdb,crowbar,dhcp,named,rabbitmq} \
        /var/run/{chef,crowbar,named,rabbitmq} \
        /var/log/{apache2,chef,couchdb,crowbar,nodes,rabbitmq} \
        /var/cache/chef \
        /var/chef \
        /srv/tftpboot/{discovery/pxelinux.cfg/*,nodes,validation.pem}

    killall epmd ||: # need to kill again after uninstall
}

function onadmin_crowbarrestore()
{
    # Need to install the addon again, as we removed it
    zypper --non-interactive in --auto-agree-with-licenses -t pattern cloud_admin

    do_set_repos_skip_checks

    AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
        bash -x /usr/sbin/crowbar-backup restore /tmp/backup-crowbar.tar.gz ||\
        complain 20 "crowbar-backup restore failed"
}

function onadmin_qa_test()
{
    zypper -n in -y python-{keystone,nova,glance,heat,cinder,ceilometer}client

    get_novacontroller
    scp $novacontroller:.openrc ~/

    if [ ! -d "qa-openstack-cli" ] ; then
        complain 16 "Please provide a checkout of the qa-openstack-cli repo on the crowbar node."
    fi

    pushd qa-openstack-cli
    mkdir -p ~/qa_test.logs
    ./run.sh | perl -pe '$|=1;s/\e\[?.*?[\@-~]//g' | tee ~/qa_test.logs/run.sh.log
    local ret=${PIPESTATUS[0]}
    popd
    return $ret
}

# deactivate proposals and forget cloud nodes
# can be useful for faster testing cycles
function onadmin_teardown()
{
    #BMCs at ${netp}.178.163-6 #node 6-9
    #BMCs at ${netp}.$net.163-4 #node 11-12

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

function onadmin_runlist()
{
    for cmd in "$@" ; do
        onadmin_$cmd || complain $? "$cmd failed with code $?"
    done
}

#--

ruby=/usr/bin/ruby
iscloudver 5plus && ruby=/usr/bin/ruby.ruby2.1
export_tftpboot_repos_dir
set_proposalvars
