#!/bin/sh
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual

test $(uname -m) = x86_64 || echo "ERROR: need 64bit"

mkcconf=mkcloud.config
[ -e $mkcconf ] && source $mkcconf

# defaults
: ${libvirt_type:=kvm}

novacontroller=
novadashboardserver=
clusternodesdata=
clusternodesnetwork=
clusternodesservices=
wanthyperv=

export cloud=${1}
shift
export cloudfqdn=${cloudfqdn:-$cloud.cloud.suse.de}
export nodenumber=${nodenumber:-2}
export tempestoptions=${tempestoptions:--t -s}
export want_sles12=${want_sles12:-""}
export nodes=
export debug=${debug:-0}
export cinder_conf_volume_type=${cinder_conf_volume_type:-""}
export cinder_conf_volume_params=${cinder_conf_volume_params:-""}
export localreposdir_target=${localreposdir_target:-""}
export want_ipmi=${want_ipmi:-false}
[ "$libvirt_type" = hyperv ] && export wanthyperv=1
[ "$libvirt_type" = xen ] && export wantxenpv=1 # xenhvm is broken anyway

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

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

if [ -z $cloud ] ; then
    echo "Error: Parameter missing that defines the cloud name"
    echo "Possible values: [d1, d2, p, virtual]"
    echo "Example: $0 d2"
    exit 101
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
mkcloudhostip=${net}.1

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

    wait_for $timecount 5 "! pidofproc ${procname}" "process '${procname}' to terminate"
}

function die()
{
    local exit_code=$1
    shift
    echo >&2
    echo -e "$@" >&2;
    exit $exit_code
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
    if [ -n "${localreposdir_target}" ]; then
        [ -n "${bindsrc}" ] && add_bind_mount "${localreposdir_target}/${bindsrc}" "${targetdir}"
    else
        [ -n "${nfssrc}" ] && add_nfs_mount "${nfssrc}" "${targetdir}"
    fi
    if [ -n "${zypper_alias}" ]; then
        wait_for_if_running zypper
        zypper rr "${zypper_alias}"
        wait_for_if_running zypper
        safely zypper -n ar -f "${targetdir}" "${zypper_alias}"
    fi
}

function getcloudver()
{
    if   [[ $cloudsource =~ ^.*(cloud|GM)3(\+up)?$ ]] ; then
        echo -n 3
    elif [[ $cloudsource =~ ^.*(cloud|GM)4(\+up)?$ ]] ; then
        echo -n 4
    elif [[ $cloudsource =~ ^(.+5|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM5?)$ ]] ; then
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
        if [ "$hacloud" == "2" && "$repo" == "SLE11-HAE-SP3-Updates-test" ] ; then
            continue
        fi
        add_mount "" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" "$tftpboot_repos_dir/$repo"
    done
}

function add_suse_storage_repo()
{
    if [ -n "$want_sles12" ] && iscloudver 5plus ; then
        local repo
        for repo in SUSE-Enterprise-Storage-1.0-{Pool,Updates}; do
            add_mount "$repo" "clouddata.cloud.suse.de:/srv/nfs/repos/$repo" "$tftpboot_repos12_dir/$repo"
        done
    else
        echo "Error: You need SLE12 and SUSE Cloud >= 5 to setup storage repos."
    fi
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
    local L
    L=`crowbar machines list | grep -v crowbar`

    # the nodes that contain drbd volumes are defined via drbdnode_mac_vol
    for dmachine in ${drbdnode_mac_vol//+/ } ; do
        local mac
        local serial
        mac=${dmachine%#*}
        serial=${dmachine#*#}

        # find and remove drbd nodes from L
        for node in $L ; do
            if crowbar machines show "$node" | grep "\"macaddress\"" | grep -qi $mac ; then
                clusternodesdata="$clusternodesdata $node"

                # assign drbd volume via knife
                local nfile
                nfile=knife.node.${node}.json
                knife node show ${node} -F json > $nfile
                $ruby -e "require 'rubygems';require 'json';
                            j=JSON.parse(STDIN.read);
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
        for dnode in $clusternodesdata ; do
            L=`printf "%s\n" $L | grep -iv $dnode`
        done
    done

    # assign nodes to clusters
    clusternodesnetwork=`printf  "%s\n" $L | head -n$nodenumbernetworkcluster`
    clusternodesservices=`printf "%s\n" $L | tail -n$nodenumberservicescluster`

    for n in $clusternodesnetwork $clusternodesservices ; do
        L=`printf "%s\n" $L | grep -iv $n`
    done
    nodescompute=$L
    echo "............................................................"
    echo "The cluster node assignment (for your information):"
    echo "data cluster:"
    printf "   %s\n" $clusternodesdata
    echo "network cluster:"
    printf "   %s\n" $clusternodesnetwork
    echo "services cluster:"
    printf "   %s\n" $clusternodesservices
    echo "compute nodes (no cluster):"
    printf "   %s\n" $L
    echo "............................................................"
}

function onadmin_prepare_sles_repos()
{
    local targetdir_install="$tftpboot_suse_dir/install/"

    if [ -n "${localreposdir_target}" ]; then
        add_mount "SUSE-Cloud-SLE-11-SP3-deps/sle-11-x86_64/" "" "${targetdir_install}" "Cloud-Deps"
        zypper_refresh
    else
        zypper se -s sles-release|grep -v -e "sp.up\s*$" -e "(System Packages)" |grep -q x86_64 || zypper ar http://$susedownload/install/SLP/SLES-${slesversion}-LATEST/x86_64/DVD1/ sles

        if ! $longdistance ; then
            add_mount "" "clouddata.cloud.suse.de:/srv/nfs/suse-$suseversion/install" "${targetdir_install}"
        fi

        local REPO
        for REPO in $slesrepolist ; do
            local zypprepo=""
            [ "$WITHSLEUPDATES" != "" ] && zypprepo="$REPO"
            add_mount "$zypprepo" "clouddata.cloud.suse.de:/srv/nfs/repos/$REPO" "$tftpboot_repos_dir/$REPO"
        done

        # just as a fallback if nfs did not work
        if [ ! -e "${targetdir_install}/media.1/" ] ; then
            local f=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
            local p=$tftpboot_suse_dir/$f
            wget --progress=dot:mega -nc -O$p http://$susedownload/install/SLES-$slesversion-$slesmilestone/$f || complain 70 "iso not found"
            echo $p ${targetdir_install} iso9660 loop,ro >> /etc/fstab
            mount ${targetdir_install}
        fi
    fi

    if [ ! -e "${targetdir_install}/media.1/" ] ; then
        echo "We do not have SLES install media - giving up"
        exit 34
    fi
}

function rsync_iso()
{
    local CLOUDDISTPATH="$1"
    local CLOUDDISTISO="$2"
    local targetdir="$3"
    mkdir -p /mnt/cloud "$targetdir"
    (
        cd "$targetdir"
        wget --progress=dot:mega -r -np -nc -A "$CLOUDDISTISO" http://$susedownload$CLOUDDISTPATH/ || complain 71 "iso not found"
        local CLOUDISO=$(ls */$CLOUDDISTPATH/*.iso|tail -1)
        mount -o loop,ro -t iso9660 $CLOUDISO /mnt/cloud
        rsync -av --delete-after /mnt/cloud/ . ; umount /mnt/cloud
        echo $CLOUDISO > isoversion
    )
}

function onadmin_prepare_sles12_repos()
{
    suse12version=12.0
    local targetdir_install="$tftpboot_suse12_dir/install/"
    local targetdir="$tftpboot_repos12_dir/SLE12-Cloud-Compute"

    if ! $longdistance ; then
        add_mount "" "clouddata.cloud.suse.de:/srv/nfs/suse-12.0/install" "${targetdir_install}"

        for REPO in SLES12-Pool SLES12-Updates ; do
            add_mount "" "clouddata.cloud.suse.de:/srv/nfs/repos/$REPO" \
                "$tftpboot_repos12_dir/$REPO"
        done
    fi

    if [ -n "${localreposdir_target}" ]; then
        echo FIXME add_bind_mount "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-x86_64/" "$targetdir"
    else
        rsync_iso "$CLOUDCOMPUTEPATH" "$CLOUDCOMPUTEISO" "$targetdir"
    fi

    # create empty repository when there is none yet
    safely zypper -n install createrepo
    sles12optionalrepolist="SLE-12-Cloud-Compute5-Pool SLE-12-Cloud-Compute5-Updates SLE12-Cloud-Compute-PTF SLES12-Pool"
    for REPO in $sles12optionalrepolist ; do
        if [ ! -e "$tftpboot_repos12_dir/$REPO/repodata/" ] ; then
            mkdir -p "$tftpboot_repos12_dir/$REPO"
            safely createrepo "$tftpboot_repos12_dir/$REPO"
        fi
    done

    # just as a fallback if nfs did not work
    if [ ! -e "${targetdir_install}/media.1/" ] ; then
        local f=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
        local p=$tftpboot_suse12_dir/$f
        safely wget --progress=dot:mega -nc -O$p http://$susedownload/install/SLES-$slesversion-$slesmilestone/$f || complain 72 "iso not found"
        echo $p ${targetdir_install} iso9660 loop,ro >> /etc/fstab
        safely mount ${targetdir_install}
    fi

    if [ ! -e "${targetdir_install}/media.1/" ] ; then
        echo "We do not have SLES12 install media - giving up"
        exit 34
    fi
}

function onadmin_prepare_cloud_repos()
{
    local targetdir="$tftpboot_repos_dir/Cloud/"
    mkdir -p ${targetdir}

    if [ -n "${localreposdir_target}" ]; then
        add_bind_mount "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-x86_64/" "${targetdir}"
        echo $CLOUDLOCALREPOS > /etc/cloudversion
    else
        rsync_iso "$CLOUDDISTPATH" "$CLOUDDISTISO" "$targetdir"
        cat "$targetdir/isoversion" > /etc/cloudversion
    fi
    echo -n "This cloud was installed on `cat ~/cloud` from: " | cat - /etc/cloudversion >> /etc/motd
    echo $cloudsource > /etc/cloudsource

    if [ ! -e "${targetdir}/media.1" ] ; then
        echo "We do not have cloud install media in ${targetdir} - giving up"
        exit 35
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
            susecloud5|GM5|GM5+up)
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
                echo "no TESTHEAD repos defined for cloudsource=$cloudsource"
                exit 26
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
            susecloud5|GM5|GM5+up)
                addcloud5pool
                ;;
        esac
    fi

    # Ensure Pool/Updates repos are always configured on admin server
    for repo in Pool Updates; do
        name="SUSE-Cloud-$(getcloudver)-$repo"
        if ! zypper lr | grep -q "$name"; then
            safely zypper ar -f "$tftpboot_repos_dir/$name/" $name
        fi
    done
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
        M?|Beta*|RC*|GMC*|GM5)
            cs=$cloudsource
            [ $cs = GM5 ] && cs=GM
            CLOUDDISTPATH=/install/SUSE-Cloud-5-$cs/
            CLOUDCOMPUTEPATH=$CLOUDDISTPATH
            CLOUDDISTISO="SUSE-CLOUD*1.iso"
            CLOUDCOMPUTEISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-official"
        ;;
        *)
            echo "Error: you must set environment variable cloudsource=develcloud3|develcloud4|develcloud5|susecloud5|GM3|GM4"
            exit 76
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


# setup network/DNS, add repos and install crowbar packages
function onadmin_prepareinstallcrowbar()
{
    pre_hook $FUNCNAME
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
        while zypper lr -e - | grep -q '^name='; do
            zypper rr 1
        done
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
            echo "Error: You requested a HA setup but for this combination ($cloudsource : $slesdist) no HA setup is available."
            exit 1
        fi
    fi

    if [ -n "$wantceph" ] && [ -n "$want_sles12" ] && iscloudver 5plus; then
        add_suse_storage_repo
    fi

    safely zypper -n install rsync netcat

    # setup cloud repos for tftpboot and zypper
    onadmin_prepare_cloud_repos


    zypper_refresh

    zypper -n dup -r Cloud -r cloudtup || zypper -n dup -r Cloud
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
        echo "timed out waiting for chef-ready"
        exit 83
    fi
    rpm -Va crowbar\*

    # Make sure install finished correctly
    if ! [ -e /opt/dell/crowbar_framework/.crowbar-installed-ok ]; then
        echo "Crowbar \".crowbar-installed-ok\" marker missing"
        tail -n 90 /root/screenlog.0
        exit 89
    fi

    if iscloudver 4plus; then
        wait_for_if_running zypper
        zypper -n install crowbar-barclamp-tempest
        # Force restart of crowbar
        rccrowbar stop
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
        local pfile=`get_proposal_filename ntp default`
        crowbar ntp proposal show default |
            $ruby -e "require 'rubygems';require 'json';
            j=JSON.parse(STDIN.read);
            j['attributes']['ntp']['external_servers']=['$ntpserver'];
            puts JSON.pretty_generate(j)" > $pfile
        crowbar ntp proposal --file=$pfile edit default
        rm -f $pfile
        crowbar ntp proposal commit default
    fi

    if ! validate_data_bags; then
        echo "Validation error in default data bags. Aborting."
        exit 68
    fi
}


function onadmin_installcrowbarfromgit()
{
    do_installcrowbar "CROWBAR_FROM_GIT=1 /opt/dell/bin/install-chef-suse.sh --from-git --verbose"
}

function onadmin_installcrowbar()
{
    pre_hook $FUNCNAME
    do_installcrowbar "if [ -e /tmp/install-chef-suse.sh ] ; then /tmp/install-chef-suse.sh --verbose ; else /opt/dell/bin/install-chef-suse.sh --verbose ; fi"
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
        local bmc_start=$(crowbar network proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['attributes']['network']['networks']['bmc']['ranges']['host']['start']")
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
    while test $(crowbar machines list | grep ^d|wc -l) -lt $nodenumber ; do sleep 10 ; done
    local nodes=$(crowbar machines list | grep ^d)
    local n
    for n in `crowbar machines list | grep ^d` ; do
        wait_for 100 2 "knife node show -a state $n | grep discovered" "node to enter discovered state"
    done
    echo "Sleeping 50 more seconds..."
    sleep 50
    echo "Setting first node to controller..."
    local controllernode=$(crowbar machines list | LC_ALL=C sort | grep ^d | head -n 1)
    local t=$(mktemp).json

    knife node show -F json $controllernode > $t
    json-edit $t -a normal.crowbar_wall.intended_role -v "controller"
    knife node from file $t
    rm -f $t

    if [ -n "$want_sles12" ] && iscloudver 5plus ; then

        local nodes=( $(crowbar machines list | LC_ALL=C sort | grep ^d | tail -n 2) )
        if [ -n "$wantceph" ] ; then
            echo "Setting second last node to SLE12 Storage..."
            set_node_role_and_platform ${nodes[0]} "storage" "suse-12.0"
        fi

        echo "Setting last node to SLE12 compute..."
        set_node_role_and_platform ${nodes[1]} "compute" "suse-12.0"
    fi

    if [ -n "$wanthyperv" ] ; then
        echo "Setting last node to Hyper-V compute..."
        local computenode=$(crowbar machines list | LC_ALL=C sort | grep ^d | tail -n 1)
        set_node_role_and_platform $computenode "compute" "hyperv-6.3"
    fi

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
        wait_for 200 10 "netcat -w 3 -z $node 3389 || sshtest $node rpm -q yast2-core" "node $node" "check_node_resolvconf $node; exit 12"
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
                    machinestatus=`crowbar machines show $i state`
                    if test "x$machinestatus" = "xfailed" -o "x$machinestatus" = "xnil" ; then
                        echo "Error: machine status is failed. Exiting"
                        exit 39
                    fi
                    sleep 5
                    n=$((n-1))
                    echo -n "."
                done
                n=500 ; while test $n -gt 0 && ! netcat -w 3 -z $i 22 && ! netcat -w 3 -z $i 3389  ; do
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
                proposalstatus=`crowbar $proposal proposal show $proposaltype | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['$proposal']['crowbar-status']"`
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

    $ruby -e   "require 'rubygems';require 'json';
                j=JSON.parse(STDIN.read);
                j${variable}${operator}${value};
                puts JSON.pretty_generate(j)" < $pfile > ${pfile}.tmp
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

function hacloud_configure_cluster_defaults()
{
    clustertype=$1
    shift

    nodes=`printf "\"%s\"," $@`
    nodes="[ ${nodes%,} ]"
    proposal_set_value pacemaker "$clustertype" "['deployment']['pacemaker']['elements']['pacemaker-cluster-member']" "$nodes"

    if [[ "configuration" = "with per_node" ]] ; then
        for node in $@; do
            proposal_set_value pacemaker "$clustertype" "['attributes']['pacemaker']['stonith']['per_node']['nodes']['$node']" "{}"
            proposal_set_value pacemaker "$clustertype" "['attributes']['pacemaker']['stonith']['per_node']['nodes']['$node']['params']" "''"
        done
    fi

    proposal_set_value pacemaker "$clustertype" "['attributes']['pacemaker']['stonith']['mode']" "'libvirt'"
    proposal_set_value pacemaker "$clustertype" "['attributes']['pacemaker']['stonith']['libvirt']['hypervisor_ip']" "'$mkcloudhostip'"
    proposal_set_value pacemaker "$clustertype" "['description']" "'Pacemaker $clustertype cluster'"
}

function hacloud_configure_data_cluster()
{
    proposal_set_value pacemaker data "['attributes']['pacemaker']['drbd']['enabled']" true
    hacloud_configure_cluster_defaults "data" $clusternodesdata
}

function hacloud_configure_network_cluster()
{
    hacloud_configure_cluster_defaults "network" $clusternodesnetwork
}

function hacloud_configure_services_cluster()
{
    hacloud_configure_cluster_defaults "services" $clusternodesservices
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

    # prepare the proposal file to be edited, it will be read once at the end
    # So, ONLY edit the $pfile  -  DO NOT call "crowbar $x proposal .*" command
    local pfile=`get_proposal_filename "${proposal}" "${proposaltype}"`
    crowbar $proposal proposal show $proposaltype > $pfile

    if [[ $debug = 1 && $proposal != swift ]] ; then
        sed -i -e "s/debug\": false/debug\": true/" -e "s/verbose\": false/verbose\": true/" $pfile
    fi

    ### NOTE: ONLY USE proposal_{set,modify}_value functions below this line
    ###       The edited proposal will be read and imported at the end
    ###       So, only edit the proposal file, and NOT the proposal itself

    case "$proposal" in
        pacemaker)
            case $proposaltype in
                data)
                    hacloud_configure_data_cluster
                ;;
                network)
                    hacloud_configure_network_cluster
                ;;
                services)
                    hacloud_configure_services_cluster
                ;;
            esac
        ;;
        database)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value database default "['attributes']['database']['ha']['storage']['mode']" "'drbd'"
                proposal_set_value database default "['attributes']['database']['ha']['storage']['drbd']['size']" "20"
                proposal_set_value database default "['deployment']['database']['elements']['database-server']" "['cluster:data']"
            fi
        ;;
        rabbitmq)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['mode']" "'drbd'"
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['drbd']['size']" "20"
                proposal_set_value rabbitmq default "['deployment']['rabbitmq']['elements']['rabbitmq-server']" "['cluster:data']"
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
                proposal_set_value keystone default "['deployment']['keystone']['elements']['keystone-server']" "['cluster:services']"
            fi
        ;;
        glance)
            if [[ $all_with_ssl = 1 || $glance_with_ssl = 1 ]] ; then
                enable_ssl_for_glance
            fi
            if [[ -n "$wantceph" ]]; then
                proposal_set_value glance default "['attributes']['glance']['default_store']" "'rbd'"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value glance default "['deployment']['glance']['elements']['glance-server']" "['cluster:services']"
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
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-multi-controller']" "['cluster:services']"

                # only use remaining nodes as compute nodes, keep cluster nodes dedicated to cluster only
                local novanodes
                novanodes=`printf "\"%s\"," $nodescompute`
                novanodes="[ ${novanodes%,} ]"
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-multi-compute-${libvirt_type}']" "$novanodes"
            fi
        ;;
        nova_dashboard)
            if [[ $all_with_ssl = 1 || $novadashboard_with_ssl = 1 ]] ; then
                enable_ssl_for_nova_dashboard
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova_dashboard default "['deployment']['nova_dashboard']['elements']['nova_dashboard-server']" "['cluster:services']"
            fi
        ;;
        heat)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value heat default "['deployment']['heat']['elements']['heat-server']" "['cluster:services']"
            fi
        ;;
        ceilometer)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-server']" "['cluster:services']"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-cagent']" "['cluster:services']"
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
                    proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'ml2'"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vlan']"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_mechanism_drivers']" "['openvswitch']"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_provider_network']" "'vlan'"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_tenant_network']" "'gre'"
                elif [ "$networkingplugin" = "linuxbridge" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'ml2'"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['vlan']"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_mechanism_drivers']" "['linuxbridge']"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_provider_network']" "'vlan'"
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_tenant_network']" "'vlan'"
                fi
            else
                if [ -n "$networkingmode" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['networking_mode']" "'$networkingmode'"
                fi
                if [ -n "$networkingplugin" ] ; then
                    proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'$networkingplugin'"
                fi
            fi

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-server']" "['cluster:network']"
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-l3']" "['cluster:network']"
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
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-controller']" "['cluster:services']"
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-volume']" "['$cinder_volume']"
            fi
        ;;
        tempest)
            if [[ $hacloud = 1 ]] ; then
                local tempestnodes
                tempestnodes=`printf "\"%s\"," $nodescompute`
                tempestnodes="[ ${tempestnodes%,} ]"
                proposal_set_value tempest default "['deployment']['tempest']['elements']['tempest']" "$tempestnodes"
            fi
        ;;
        *) echo "No hooks defined for service: $proposal"
        ;;
    esac

    crowbar $proposal proposal --file=$pfile edit $proposaltype
    local ret=$?
    [ $ret != 0 ] && complain 88 "Error: 'crowbar $proposal proposal --file=$pfile edit $proposaltype' failed with exit code: $ret"
}

# set global variables to be used in and after proposal phase
function set_proposalvars()
{
    # Determine if we went through an upgrade
    [ -f /etc/cloudsource ] && export cloudsource=$(</etc/cloudsource)

    wantswift=1
    [ -z "$want_swift" ] && wantceph=1
    [[ -n "$wanthyperv" ]] && wantswift= && wantceph= && networkingmode=vlan
    wanttempest=
    iscloudver 4plus && wanttempest=1
    [[ "$want_tempest" = 0 ]] && wanttempest=

    iscloudver 5 && {
        echo "WARNING: swift currently disabled, because openstack-swift packages for SLES12 are missing"
        wantswift=
    }

    [[ "$nodenumber" -lt 3 || "$cephvolumenumber" -lt 1 ]] && wantceph=
    # we can not use both swift and ceph as each grabs all disks on a node
    [[ -n "$wantceph" ]] && wantswift=
    [[ "$cephvolumenumber" -lt 1 ]] && wantswift=
    crowbar_networking=neutron

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

# configure and commit one proposal
function update_one_proposal()
{
    local proposal=$1
    local proposaltype=${2:-default}

    echo -n "Starting proposal $proposal($proposaltype) at: "
    date
    # hook for changing proposals:
    custom_configuration $proposal $proposaltype
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
        echo "Error: commiting the crowbar '$proposaltype' proposal for '$proposal' failed ($ret)."
        exit 73
    fi
}

# create, configure and commit one proposal
function do_one_proposal()
{
    local proposal=$1
    local proposaltype=${2:-default}

    crowbar "$proposal" proposal create $proposaltype
    update_one_proposal "$proposal" "$proposaltype"
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

    local proposals="pacemaker database rabbitmq keystone ceph glance cinder $crowbar_networking nova nova_dashboard swift ceilometer heat trove tempest"

    local proposal
    for proposal in $proposals ; do
        # proposal filter
        case "$proposal" in
            pacemaker)
                [ -n "$hacloud" ] || continue
                cluster_node_assignment
                ;;
            ceph)
                [[ -n "$wantceph" ]] || continue
                ;;
            swift)
                [[ -n "$wantswift" ]] || continue
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
                for cluster in data services network ; do
                    do_one_proposal "$proposal" "$cluster"
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

function get_novacontroller()
{
    novacontroller=`crowbar nova proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova']['elements']['nova-multi-controller']"`
}


function get_novadashboardserver()
{
    novadashboardserver=`crowbar nova_dashboard proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['nova_dashboard']['elements']['nova_dashboard-server']"`
}

function get_ceph_nodes()
{
    if [[ -n "$wantceph" ]]; then
        cephmons=`crowbar ceph proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-mon']"`
        cephosds=`crowbar ceph proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-osd']"`
        cephradosgws=`crowbar ceph proposal show default | $ruby -e "require 'rubygems';require 'json';puts JSON.parse(STDIN.read)['deployment']['ceph']['elements']['ceph-radosgw']"`
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
    if [[ -n $wantswift ]] ; then
        zypper -n install python-swiftclient
        swift stat
        swift upload container1 .ssh/authorized_keys
        swift list container1 || exit 33
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
        glance image-list|grep -q SLE11SP3-x86_64-cfntools || glance image-create --name=SLE11SP3-x86_64-cfntools --is-public=True --disk-format=qcow2 --container-format=bare --copy-from http://clouddata.cloud.suse.de/images/SLES11-SP3-x86_64-cfntools.qcow2 | tee glance.out
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
        echo "Error: VM IP is empty. Exiting"
        exit 38
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
    nova volume-attach "$instanceid" "$volumeid" /dev/vdb | tee volume-attach.out
    device=`perl -ne "m!device [ |]*(/dev/\w+)! && print \\$1" volume-attach.out`
    sleep 15
    ssh $vmip fdisk -l $device | grep 1073741824
    volumeattachret=$?
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

function onadmin_testsetup()
{
    pre_hook $FUNCNAME

    if iscloudver 5plus; then
        cmachines=`crowbar machines list`
        for machine in $cmachines; do
            knife node show $machine -a node.target_platform | grep -q suse- || continue
            ssh $machine 'dig multi-dns.'"'$cloudfqdn'"' | grep -q 10.11.12.13'
            if [ $? != 0 ]; then
                echo "Multi DNS server test failed!"
                exit 13
            fi
        done
    fi

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
        wait_for_if_running zypper
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

    scp $0 $mkcconf $novacontroller:
    ssh $novacontroller "export wantswift=$wantswift ; export wantceph=$wantceph ; export wanttempest=$wanttempest ;
        export tempestoptions=\"$tempestoptions\" ; export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ;
        export wantradosgwtest=\"$wantradosgwtest\" ; export cloudsource=\"$cloudsource\" ;
        export libvirt_type=\"$libvirt_type\" ;
        oncontroller_testsetup=1 bash -x ./$0 $cloud"
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
    zypper ar $UPR cloud-ptf
}

function onadmin_runupdate()
{
    # Workaround broken admin image that has SP3 Test update channel enabled
    zypper mr -d sp3tup

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
        echo "Error: some nodes rebooted with state Problem."
        exit 1
    fi

    scp $0 $novacontroller:
    ssh $novacontroller "oncontroller_waitforinstance=1 bash -x ./$0 $cloud"
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
    NEUTRON_SERVER=$(crowbar neutron proposal show default| $ruby -e "require 'rubygems';require 'json';
    j=JSON.parse(STDIN.read);
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

function prepare_cloudupgrade()
{
    # TODO: All running cloud instances should be suspended here

    ### Chef-client could lockj zypper and break upgrade
    # zypper locks do still happen
    # TODO: do we need to stop the client on the nodes too?
    rcchef-client stop

    wait_for_if_running chef-client

    test -z "$upgrade_cloudsource" && {
        echo "upgrade_cloudsource is not set"
        exit 1
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
    zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks refresh -f || die 3 "Couldn't refresh zypper indexes after adding SUSE-Cloud-$update_version repos"
    zypper --non-interactive install --force suse-cloud-upgrade || die 3 "Couldn't install suse-cloud-upgrade"
}

function onadmin_cloudupgrade_1st()
{
    # Disable all openstack proposals stop service on the client
    echo 'y' | suse-cloud-upgrade upgrade
    local ret=$?
    if [[ $ret != 0 ]]; then
        echo "Upgrade failed with $ret"
        exit $ret
    fi
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

    echo 'y' | suse-cloud-upgrade upgrade
    local ret=$?
    if [[ $ret != 0 ]]; then
        echo "Upgrade failed with $ret"
        exit $ret
    fi
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
    for barclamp in pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova nova_dashboard ceilometer heat ; do
        applied_proposals=$(crowbar "$barclamp" proposal list )
        if test "$applied_proposals" == "No current proposals"; then
            continue
        fi

        for proposal in $applied_proposals; do
            echo "Commiting proposal $proposal of barclamp ${barclamp}..."
            crowbar "$barclamp" proposal commit "$proposal"
            if [[ $? != 0 ]]; then
                exit 30
            fi
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

function onadmin_qa_test()
{
    zypper -n in -y python-{keystone,nova,glance,heat,cinder,ceilometer}client

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

#-------------------------------------------------------------------------------
#--
#-- for compatibility to legacy calling style
#--
#
# in the long run all steps should be transformed into real functions, just
# like in mkcloud; this makes it easier to read, understand and edit this file
#
ruby=/usr/bin/ruby
iscloudver 5plus && ruby=/usr/bin/ruby.ruby2.1

export_tftpboot_repos_dir

if [[ -n "$testfunc" ]] ; then
    $testfunc "$@"
    exit $?
fi

mount_localreposdir_target

set_proposalvars
if [ -n "$prepareinstallcrowbar" ] ; then
    onadmin_prepareinstallcrowbar
fi

if [ -n "$installcrowbar" ] ; then
    onadmin_installcrowbar
fi

if [ -n "$installcrowbarfromgit" ] ; then
    onadmin_installcrowbarfromgit
fi

if [ -n "$addupdaterepo" ] ; then
    onadmin_addupdaterepo
fi

if [ -n "$runupdate" ] ; then
    onadmin_runupdate
fi

if [ -n "$allocate" ] ; then
    onadmin_allocate
fi

if [ -n "$waitcompute" ] ; then
    onadmin_waitcompute
fi

if [ -n "$prepare_cloudupgrade" ] ; then
    prepare_cloudupgrade
fi

if [ -n "$cloudupgrade_1st" ] ; then
    onadmin_cloudupgrade_1st
fi

if [ -n "$cloudupgrade_2nd" ] ; then
    onadmin_cloudupgrade_2nd
fi

if [ -n "$cloudupgrade_clients" ] ; then
    onadmin_cloudupgrade_clients
fi

if [ -n "$cloudupgrade_reboot_and_redeploy_clients" ] ; then
    onadmin_cloudupgrade_reboot_and_redeploy_clients
fi

set_proposalvars
if [ -n "$proposal" ] ; then
    onadmin_proposal
fi

if [ -n "$testsetup" ] ; then
    onadmin_testsetup
fi
if [ -n "$oncontroller_testsetup" ] ; then
    oncontroller_testsetup
fi

if [ -n "$rebootcompute" ] ; then
    onadmin_rebootcompute
fi

if [ -n "$oncontroller_waitforinstance" ] ; then
    oncontroller_waitforinstance
fi

if [ -n "$rebootneutron" ] ; then
    onadmin_rebootneutron
fi

if [ -n "$securitytests" ] ; then
    onadmin_securitytests
fi

if [ -n "$qa_test" ] ; then
    onadmin_qa_test
fi

if [ -n "$teardown" ] ; then
    onadmin_teardown
fi
