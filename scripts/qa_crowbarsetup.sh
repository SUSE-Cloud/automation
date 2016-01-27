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
: ${cinder_backend:=''}
: ${cinder_netapp_storage_protocol:=iscsi}
: ${cinder_netapp_login:=openstack}
: ${cinder_netapp_password:=''}
: ${clouddata:=$(dig -t A +short clouddata.nue.suse.com)}
: ${distsuse:=dist.nue.suse.com}
distsuseip=$(dig -t A +short $distsuse)
: ${want_raidtype:="raid1"}

: ${arch:=$(uname -m)}

# global variables that are set within this script
novacontroller=
horizonserver=
horizonservice=
manila_service_vm_uuid=
manila_service_vm_ip=
clusternodesdrbd=
clusternodesdata=
clusternodesnetwork=
clusternodesservices=
clusternamedata="data"
clusternameservices="services"
clusternamenetwork="network"
wanthyperv=
crowbar_api=http://localhost:3000
crowbar_api_installer_path=/installer/installer
crowbar_install_log=/var/log/crowbar/install.log

export nodenumber=${nodenumber:-2}
export tempestoptions=${tempestoptions:--t -s}
export want_sles12
[[ "$want_sles12" = 0 ]] && want_sles12=
export nodes=
export cinder_backend
export cinder_netapp_storage_protocol
export cinder_netapp_login
export cinder_netapp_password
export localreposdir_target
export want_ipmi=${want_ipmi:-false}
[ -z "$want_test_updates" -a -n "$TESTHEAD" ] && export want_test_updates=1
[ "$libvirt_type" = hyperv ] && export wanthyperv=1
[ "$libvirt_type" = xen ] && export wantxenpv=1 # xenhvm is broken anyway

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

export ZYPP_LOCK_TIMEOUT=120

function horizon_barclamp()
{
    if iscloudver 6plus; then
        echo "horizon"
    else
        echo "nova_dashboard"
    fi
}

function nova_role_prefix()
{
    if ! iscloudver 6M7plus ; then
        echo "nova-multi"
    else
        echo "nova"
    fi
}

function complain() # {{{
{
    local ex=$1; shift
    printf "Error: %s\n" "$@" >&2
    [[ $ex = - ]] || exit $ex
} # }}}

safely () {
    if "$@"; then
        true
    else
        complain 30 "$* failed! (safelyret=$?) Aborting."
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

onadmin_help()
{
    cat <<EOUSAGE
    want_neutronsles12=1 (default 0)
        if there is a SLE12 node, deploy neutron-network role into the SLE12 node
    want_mtu_size=<size>|"jumbo" (default='')
        Option to set variable MTU size or select Jumbo Frames for Admin and Storage nodes. 1500 is used if not set.
    want_raidtype (default='raid1')
        The type of RAID to create.
    want_node_aliases=list of aliases to assign to nodes
        Takes all provided aliases and assign them to available nodes successively.
        Note that this doesn't take care about node assignment itself.
        Examples:
            want_node_aliases='controller=1,ceph=2,compute=1'
              assigns the aliases to 4 nodes as controller, ceph1, ceph2, compute
            want_node_aliases='data=1,services=2,storage=2'
              assigns the aliases to 5 nodes as data, service1, service2, storage1, storage2
    want_node_os=list of OSs to assign to nodes
        Takes all provided OS values and assign them to available nodes successively.
        Example:
            want_node_os=suse-12.1=3,suse-12.0=3,hyperv-6.3=1
              assigns SLES12SP1 to first 3 nodes, SLES12 to next 3 nodes, HyperV to last one
    want_node_roles=list of intended roles to assign to nodes
        Takes all provided intended role values and assign them to available nodes successively.
        Possible role values: controller, compute, storage, network.
        Example:
            want_node_roles=controller=1,compute=2,storage=3
    want_test_updates=0 | 1  (default=1 if TESTHEAD is set, 0 otherwise)
        add test update repositories
EOUSAGE
}

setcloudnetvars()
{
    local cloud=$1
    export cloudfqdn=${cloudfqdn:-$cloud.cloud.suse.de}
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
            net_public=$netp.177
            vlan_storage=568
            vlan_public=567
            vlan_fixed=566
            want_ipmi=true
        ;;
        d2)
            nodenumber=2
            net=$netp.186
            net_public=$netp.185
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
        qa4)
            nodenumber=7
            net=${netp}.66
            net_public=$net
            vlan_public=715
            #vlan_admin=714
            vlan_fixed=717
            vlan_storage=716
            want_ipmi=true
        ;;
        p2)
            net=$netp.171
            net_public=$netp.164
            net_fixed=44.0.0
            vlan_storage=563
            vlan_public=564
            vlan_fixed=565
            want_ipmi=true
        ;;
        p)
            net=$netp.169
            net_public=$netp.168
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
            net_public=$netp.190
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
    : ${admingw:=$net.1}
    : ${adminip:=$net.10}
}

# run hook code before the actual script does its function
# example usage: export pre_do_installcrowbar=$(base64 -w 0 <<EOF
# echo foo
# EOF
# )
function pre_hook()
{
    func=$1
    pre=$(eval echo \$pre_$func | base64 -d)
    setcloudnetvars $cloud
    test -n "$pre" && eval "$pre"
    echo $func >> /root/qa_crowbarsetup.steps.log
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

    local original_xstatus=${-//[^x]/}
    set +x
    echo "Waiting for: $waitfor"
    echo "  until this condition is true: $condition"
    echo "  waiting $timecount cycles of $timesleep seconds = $(( $timecount * $timesleep )) seconds"
    local n=$timecount
    while test $n -gt 0 && ! eval $condition
    do
        echo -n .
        sleep $timesleep
        n=$(($n - 1))
        [[ $(( ($timecount - $n) % 75)) != 0 ]] || echo
    done
    echo

    [[ $original_xstatus ]] && set -x
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
    elif [[ $cloudsource =~ ^.*(cloud|GM)5(\+up)?$ ]] ; then
        echo -n 5
    elif [[ $cloudsource =~ ^(.+6|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM6?(\+up)?)$ ]] ; then
        echo -n 6
    else
        complain 11 "unknown cloudsource version"
    fi
}

# return if cloudsource is referring a certain SUSE Cloud version
# input1: version - 6plus refers to version 6 or later ; only a number refers to one exact version
function iscloudver()
{
    [[ -n "$cloudsource" ]] || return 1
    local v=$1
    local operator="="
    if [[ $v =~ plus ]] ; then
        v=${v%%plus}
        operator="-ge"
    fi
    if [[ $v =~ minus ]] ; then
        v=${v%%minus}
        operator="-le"
    fi
    local ver=`getcloudver` || exit 11
    if [[ $v =~ M[0-9]+$ ]] ; then
        local milestone=${v#*M}
        v=${v%M*}
        if [[ "$ver" -eq "$v" ]] && [[ $cloudsource =~ ^M[0-9]+$ ]] ; then
            [ "${cloudsource#*M}" $operator "$milestone" ]
            return $?
        fi
    fi
    [ "$ver" $operator "$v" ]
    return $?
}

function openstack()
{
    command openstack --insecure "$@"
}
export NEUTRONCLIENT_INSECURE=true
export NOVACLIENT_INSECURE=true
export SWIFTCLIENT_INSECURE=true
export CINDERCLIENT_INSECURE=true
# Extra environment variable because of https://launchpad.net/bugs/1535284
export manilaclient_INSECURE=true
export MANILACLIENT_INSECURE=true
export TROVECLIENT_INSECURE=true

function resize_partition()
{
    local disk=$1
    # only resize if we have a 2nd partition with a rootfs
    if fdisk -l $disk | grep -q "2 *\* *.*83 *Linux" ; then
        # make a bigger partition 2
        echo -e "d\n2\nn\np\n2\n\n\na\n2\nw" | fdisk $disk
        local part2=$(kpartx -asv $disk|perl -ne 'm/add map (\S+2) / && print $1')
        test -n "$part2" || complain 31 "failed to find partition #2"
        local bdev=/dev/mapper/$part2
        safely fsck -y -f $bdev
        safely resize2fs $bdev
        time udevadm settle
        sleep 1 # time for dev to become unused
        safely kpartx -dsv $disk
    fi
}

function export_tftpboot_repos_dir()
{
    tftpboot_repos_dir=/srv/tftpboot/repos
    tftpboot_suse_dir=/srv/tftpboot/suse-11.3

    if iscloudver 5; then
        tftpboot_repos_dir=$tftpboot_suse_dir/repos
        tftpboot_suse12_dir=/srv/tftpboot/suse-12.0
        tftpboot_repos12_dir=$tftpboot_suse12_dir/repos
    fi

    if iscloudver 6plus; then
        tftpboot_suse12sp1_dir=/srv/tftpboot/suse-12.1
        if ! iscloudver 6M7plus ; then
            tftpboot_suse_dir=/srv/tftpboot/suse-11.3
            tftpboot_suse12_dir=/srv/tftpboot/suse-12.0
            tftpboot_repos12sp1_dir=$tftpboot_suse12sp1_dir/repos
        else
            tftpboot_suse_dir=/srv/tftpboot/suse-11.3/x86_64
            tftpboot_suse12_dir=/srv/tftpboot/suse-12.0/x86_64
            tftpboot_repos12sp1_dir=$tftpboot_suse12sp1_dir/x86_64/repos
        fi
        tftpboot_repos_dir=$tftpboot_suse_dir/repos
        tftpboot_repos12_dir=$tftpboot_suse12_dir/repos
    fi
}

function addsp3testupdates()
{
    add_mount "SLES11-SP3-Updates" \
        $clouddata':/srv/nfs/repos/SLES11-SP3-Updates/' \
        "$tftpboot_repos_dir/SLES11-SP3-Updates/" "sp3up"
    add_mount "SLES11-SP3-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/11-SP3:/x86_64/update/' \
        "$tftpboot_repos_dir/SLES11-SP3-Updates-test/" "sp3tup"
    [ -n "$hacloud" ] && add_mount "SLE11-HAE-SP3-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-HAE:/11-SP3:/x86_64/update/' \
        "$tftpboot_repos_dir/SLE11-HAE-SP3-Updates-test/"
}

function addsles12testupdates()
{
    if iscloudver 5; then
        add_mount "SLES12-Updates-test" \
            $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12:/x86_64/update/' \
            "$tftpboot_repos12_dir/SLES12-Updates-test/"
    else
        add_mount "SLES12-Updates-test" \
            $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12:/x86_64/update/' \
            "$tftpboot_repos12_dir/SLES12-Updates-test/" "sles12gatup"
    fi
    if [ -n "$deployceph" ]; then
        if iscloudver 5; then
            add_mount "SUSE-Enterprise-Storage-1.0-Updates-test" \
                $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/Storage:/1.0:/x86_64/update/' \
                "$tftpboot_repos12_dir/SUSE-Enterprise-Storage-1.0-Updates-test/"
        fi
    fi
}

function addsles12sp1testupdates()
{
    add_mount "SLES12-SP1-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP1:/x86_64/update/' \
        "$tftpboot_repos12sp1_dir/SLES12-SP1-Updates-test/" "sles12sp1tup"
    [ -n "$hacloud" ] && add_mount "SLE12-SP1-HA-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP1:/x86_64/update/' \
        "$tftpboot_repos12sp1_dir/SLE12-SP1-HA-Updates-test/"
    echo "FIXME: setup Storage 2.1 test channels once available"
    # TODO not there yet
    #[ -n "$deployceph" ] && add_mount "SUSE-Enterprise-Storage-2.1-Updates-test" \
    #    $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/Storage:/2.1:/x86_64/update/' \
    #    "$tftpboot_repos12sp1_dir/SUSE-Enterprise-Storage-2.1-Updates-test/"

}

function addcloud4maintupdates()
{
    add_mount "SUSE-Cloud-4-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-4-Updates/' \
        "$tftpboot_repos_dir/SUSE-Cloud-4-Updates/" "cloudmaintup"
}

function addcloud4testupdates()
{
    add_mount "SUSE-Cloud-4-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/4:/x86_64/update/' \
        "$tftpboot_repos_dir/SUSE-Cloud-4-Updates-test/" "cloudtup"
}

function addcloud5maintupdates()
{
    add_mount "SUSE-Cloud-5-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-Updates/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Updates/" \
        "cloudmaintup"
    add_mount "SUSE-Cloud-5-SLE-12-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-SLE-12-Updates/' \
        "$tftpboot_repos12_dir/SLE-12-Cloud-Compute5-Updates/"
}

function addcloud5testupdates()
{
    add_mount "SUSE-Cloud-5-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/5:/x86_64/update/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Updates-test/" "cloudtup"
    add_mount "SUSE-Cloud-5-SLE-12-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/12-Cloud-Compute:/5:/x86_64/update' \
        "$tftpboot_repos12_dir/SLE-12-Cloud-Compute5-Updates-test/"
}

function addcloud5pool()
{
    add_mount "SUSE-Cloud-5-Pool" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-Pool/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Pool/" \
        "cloudpool"
}

function addcloud6maintupdates()
{
    add_mount "SUSE-OpenStack-Cloud-6-Updates" $clouddata':/srv/nfs/repos/SUSE-OpenStack-Cloud-6-Updates/' "$tftpboot_repos12_dir/SUSE-OpenStack-Cloud-6-Updates/" "cloudmaintup"
}

function addcloud6testupdates()
{
    echo "FIXME: setup Cloud 6 test channels once available"
    #add_mount "SUSE-OpenStack-Cloud-6-Updates-test" \
    #    $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/6:/x86_64/update/' \
    #    "$tftpboot_repos12sp1_dir/SUSE-OpenStack-Cloud-6-Updates-test/" "cloudtup"
}

function addcloud6pool()
{
    add_mount "SUSE-OpenStack-Cloud-6-Pool" $clouddata':/srv/nfs/repos/SUSE-OpenStack-Cloud-6-Pool/' "$tftpboot_repos12_dir/SUSE-OpenStack-Cloud-6-Pool/" "cloudpool"
}

function addcctdepsrepo()
{
    case "$cloudsource" in
        develcloud5|GM5|GM5+up)
            zypper ar -f http://download.suse.de/ibs/Devel:/Cloud:/Shared:/Rubygem/SLE_11_SP3/Devel:Cloud:Shared:Rubygem.repo
            ;;
        develcloud6|susecloud6|M?|Beta*|RC*|GMC*|GM6|GM6+up)
            zypper ar -f http://download.suse.de/update/build.suse.de/SUSE/Products/SLE-SDK/12-SP1/x86_64/product/ SDK-SP1
            zypper ar -f http://download.suse.de/update/build.suse.de/SUSE/Updates/SLE-SDK/12-SP1/x86_64/update/ SDK-SP1-Update
            ;;
    esac
}

function add_ha_repo()
{
    local repo
    for repo in SLE11-HAE-SP3-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo/sle-11-x86_64" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos_dir/$repo"
    done
}

function add_ha12sp1_repo()
{
    local repo
    for repo in SLE12-SP1-HA-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12sp1_dir/$repo"
    done
}

function add_suse_storage_repo()
{
        local repo
        if iscloudver 5; then
            for repo in SUSE-Enterprise-Storage-1.0-{Pool,Updates}; do
                # Note no zypper alias parameter here since we don't want
                # to zypper addrepo on the admin node.
                add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
                    "$tftpboot_repos12_dir/$repo"
            done
        fi
        if iscloudver 6plus; then
            if [[ $cloudsource =~ ^M[1-7]$ ]]; then
                for repo in SUSE-Enterprise-Storage-2-{Pool,Updates}; do
                    # Note no zypper alias parameter here since we don't want
                    # to zypper addrepo on the admin node.
                    add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
                        "$tftpboot_repos12_dir/$repo"
                done
            else
                for repo in SUSE-Enterprise-Storage-2.1-{Pool,Updates}; do
                    # Note no zypper alias parameter here since we don't want
                    # to zypper addrepo on the admin node.
                    add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
                        "$tftpboot_repos12sp1_dir/$repo"
                done
            fi
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

function get_all_nodes()
{
    crowbar machines list | LC_ALL=C sort
}

function get_all_discovered_nodes()
{
    # names of discovered nodes start with 'd'
    # so it is excluding the crowbar node
    get_all_nodes | grep "^d"
}

function get_crowbar_node()
{
    # crowbar node may have any name, so better use grep -v
    # and make sure it is only one
    get_all_nodes | grep -v "^d" | head -n 1
}

function get_sles12plus_node()
{
    local target="suse-12.0"
    iscloudver 6plus && target="suse-12.1"

    knife search node "target_platform:$target" -a name | grep ^name: | cut -d : -f 2 | sort | tail -n 1 | sed 's/\s//g'
}

function get_docker_nodes()
{
    knife search node "roles:`nova_role_prefix`-compute-docker" -a name | grep ^name: | cut -d : -f 2 | sort | sed 's/\s//g'
}

function remove_node_from_list()
{
    local onenode="$1"
    local list="$@"
    printf "%s\n" $list | grep -iv "$onenode"
}

function cluster_node_assignment()
{
    if [ -n "$clusternodesdata" ] ; then
        # exit if node assignment is already done
        return 0
    fi

    local nodesavailable=`get_all_discovered_nodes`
    local dmachine

    # the nodes that contain drbd volumes are defined via drbdnode_mac_vol
    for dmachine in ${drbdnode_mac_vol//+/ } ; do
        local mac
        local serial
        mac=${dmachine%#*}
        serial=${dmachine#*#}

        # find and remove drbd nodes from nodesavailable
        for node in $nodesavailable ; do
            if crowbar machines show "$node" | grep "\"macaddress\"" | grep -qi $mac ; then
                nodesavailable=`remove_node_from_list "$node" "$nodesavailable"`
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
    unclustered_nodes=$nodesavailable

    echo "............................................................"
    echo "The cluster node assignment (for your information):"
    echo "data cluster:"
    printf "   %s\n" $clusternodesdata
    echo "network cluster:"
    printf "   %s\n" $clusternodesnetwork
    echo "services cluster:"
    printf "   %s\n" $clusternodesservices
    echo "other non-clustered nodes (free for compute / storage):"
    printf "   %s\n" $unclustered_nodes
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
                "$clouddata:/srv/nfs/suse-$suseversion/install" \
                "$targetdir_install"
        fi

        local repo
        for repo in $slesrepolist ; do
            local zypprepo=""
            [ "$WITHSLEUPDATES" != "" ] && zypprepo="$repo"
            add_mount "$zypprepo" \
                "$clouddata:/srv/nfs/repos/$repo" \
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
    onadmin_prepare_sles12_other_repos
}

function onadmin_prepare_sles12sp1_repos()
{
    onadmin_prepare_sles12sp1_repo
    onadmin_prepare_sles12sp1_other_repos
}

function onadmin_prepare_sles12plus_cloud_repos()
{
    if iscloudver 5; then
        onadmin_prepare_sles12_cloud_compute_repo
    fi
    onadmin_create_sles12plus_repos
}

# create empty repository when there is none yet
function onadmin_create_sles12plus_repos()
{
    ensure_packages_installed createrepo

    local sles12optionalrepolist
    local targetdir
    if iscloudver 6plus; then
        sles12optionalrepolist=(
            SUSE-OpenStack-Cloud-6-Pool
            SUSE-OpenStack-Cloud-6-Updates
        )
        targetdir="$tftpboot_repos12sp1_dir"
    else
        sles12optionalrepolist=(
            SLE-12-Cloud-Compute5-Pool
            SLE-12-Cloud-Compute5-Updates
        )
        targetdir="$tftpboot_repos12_dir"
    fi

    for repo in ${sles12optionalrepolist[@]}; do
        if [ ! -e "$targetdir/$repo/repodata/" ] ; then
            mkdir -p "$targetdir/$repo"
            safely createrepo "$targetdir/$repo"
        fi
    done
}

function onadmin_prepare_sles12_repo()
{
    local sles12_mount="$tftpboot_suse12_dir/install"
    add_mount "SLE-12-Server-LATEST/sle-12-x86_64" \
        "$clouddata:/srv/nfs/suse-12.0/install" \
        "$sles12_mount"

    if [ ! -d "$sles12_mount/media.1" ] ; then
        complain 34 "We do not have SLES12 install media - giving up"
    fi
}

function onadmin_prepare_sles12sp1_repo()
{
    for arch in x86_64 s390x; do
        local sles12sp1_mount="$tftpboot_suse12sp1_dir/$arch/install"
        add_mount "SLE-12-SP1-Server-LATEST/sle-12-$arch" \
            "$clouddata:/srv/nfs/suse-12.1/$arch/install" \
            "$sles12sp1_mount"

        if [ ! -d "$sles12sp1_mount/media.1" ] ; then
            complain 34 "We do not have SLES12 SP1 install media - giving up"
        fi
    done
}

function onadmin_prepare_sles12_cloud_compute_repo()
{
    local sles12_compute_mount="$tftpboot_repos12_dir/SLE12-Cloud-Compute"

    if [ -n "$localreposdir_target" ]; then
        echo "FIXME: SLE12-Cloud-Compute not available from clouddata yet." >&2
        echo "Will manually download and rsync." >&2
        # add_mount "SLE12-Cloud-Compute" \
        #     "$clouddata:/srv/nfs/repos/SLE12-Cloud-Compute" \
        #     "$targetdir_install"
    fi
    rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12DISTISO" "$sles12_compute_mount"
}

function onadmin_prepare_sles12_other_repos()
{
    for repo in SLES12-{Pool,Updates}; do
        add_mount "$repo/sle-12-x86_64" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12_dir/$repo"
    done
}

function onadmin_prepare_sles12sp1_other_repos()
{
    for repo in SLES12-SP1-{Pool,Updates}; do
        add_mount "$repo/sle-12-x86_64" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12sp1_dir/$repo"
        if [[ $want_s390 ]] ; then
            add_mount "$repo/sle-12-s390x" "$clouddata:/srv/nfs/repos/s390x/$repo" \
                "$tftpboot_suse12sp1_dir/s390x/repos/$repo"
        fi
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
    iscloudver 6plus && targetdir="$tftpboot_repos12sp1_dir/Cloud"
    mkdir -p ${targetdir}

    if [ -n "${localreposdir_target}" ]; then
        if iscloudver 6plus; then
            add_bind_mount \
                "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-12-x86_64/" \
                "${targetdir}"
        else
            add_bind_mount \
                "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-x86_64/" \
                "${targetdir}"
        fi
    else
        if iscloudver 6plus; then
            rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12DISTISO" "$targetdir"
            if [[ $want_s390 ]] ; then
                rsync_iso "$CLOUDSLE12DISTPATH" "${CLOUDSLE12DISTISO/x86_64/s390x}" "${targetdir/x86_64/s390x}"
            fi
        else
            rsync_iso "$CLOUDSLE11DISTPATH" "$CLOUDSLE11DISTISO" "$targetdir"
        fi

    fi

    if [ ! -e "${targetdir}/media.1" ] ; then
        complain 35 "We do not have cloud install media in ${targetdir} - giving up"
    fi

    case "$cloudsource" in
        GM4+up)
            addcloud4maintupdates
            ;;
        GM5)
            addcloud5pool
            ;;
        GM5+up)
            addcloud5pool
            addcloud5maintupdates
            ;;
        GM6)
            addcloud6pool
            ;;
        GM6+up)
            addcloud6pool
            addcloud6maintupdates
            ;;
    esac

    if [ -n "$want_test_updates" -a "$want_test_updates" != "0" ] ; then
        if iscloudver 6plus; then
            echo "NOT ENABLING TEST UPDATES SINCE TEST UPDATES ARE BROKEN (2016-01-11)"
            echo "**** remove me when fixed"
            return
        fi
        case "$cloudsource" in
            GM4)
                addsp3testupdates
                ;;
            GM4+up)
                addsp3testupdates
                addcloud4testupdates
                ;;
            GM5)
                addsp3testupdates
                addsles12testupdates
                ;;
            GM5+up)
                addsp3testupdates
                addsles12testupdates
                addcloud5testupdates
                ;;
            GM6)
                addsles12testupdates
                [ -n "$want_sles12sp1" ] && addsles12sp1testupdates
                ;;
            GM6+up)
                addsles12testupdates
                [ -n "$want_sles12sp1" ] && addsles12sp1testupdates
                addcloud6testupdates
                ;;
            develcloud4)
                addsp3testupdates
                ;;
            develcloud5)
                addsp3testupdates
                addsles12testupdates
                ;;
            develcloud6|susecloud6|M?|Beta*|RC*|GMC*)
                addsles12sp1testupdates
                ;;
            *)
                complain 26 "no test update repos defined for cloudsource=$cloudsource"
                ;;
        esac
    fi
}


function onadmin_add_cloud_repo()
{
    local targetdir
    if iscloudver 6plus; then
        targetdir="$tftpboot_repos12sp1_dir/Cloud/"
    else
        targetdir="$tftpboot_repos_dir/Cloud/"
    fi

    zypper rr Cloud
    safely zypper ar -f ${targetdir} Cloud

    if [ -n "${localreposdir_target}" ]; then
      echo $CLOUDLOCALREPOS > /etc/cloudversion
    else
      cat "$targetdir/isoversion" > /etc/cloudversion
    fi

    # Just document the list of extra repos
    if [[ -n "$UPDATEREPOS" ]]; then
        local repo
        for repo in ${UPDATEREPOS//+/ } ; do
            echo "+ with extra repo from $repo" >> /etc/cloudversion
        done
    fi

    (
    echo "This cloud was installed on `cat ~/cloud` from: `cat /etc/cloudversion`"
    echo
    if [[ $JENKINS_BUILD_URL ]] ; then
        echo "Installed via Jenkins"
        echo "  created by the job:    $JENKINS_BUILD_URL"
        echo "  on the Jenkins worker: $JENKINS_NODE_NAME"
        echo "  using executor number: $JENKINS_EXECUTOR_NUMBER"
        echo "  using workspace path:  $JENKINS_WORKSPACE"
        echo
    fi
    if [[ $clouddescription ]] ; then
        echo "Cloud Description (set by the deployer):"
        echo "$clouddescription"
        echo
    fi
    ) >> /etc/motd

    echo $cloudsource > /etc/cloudsource
}


function do_set_repos_skip_checks()
{
    # We don't use the proper pool/updates repos when using a devel build
    if iscloudver 6 && [[ $cloudsource =~ ^M[1-6]$ ]]; then
        export REPOS_SKIP_CHECKS+=" SUSE-OpenStack-Cloud-SLE11-$(getcloudver)-Pool SUSE-OpenStack-Cloud-SLE11-$(getcloudver)-Updates"
    elif iscloudver 5plus && [[ $cloudsource =~ (develcloud|GM5$|GM6$) ]]; then
        export REPOS_SKIP_CHECKS+=" SUSE-Cloud-$(getcloudver)-Pool SUSE-Cloud-$(getcloudver)-Updates"
    fi
}


function create_repos_yml_for_platform()
{
    local platform=$1
    local arch=$2
    local tftpboot_dir=$3
    shift; shift; shift
    local platform_created
    local repo
    local repo_name
    local repo_url

    for repo in $*; do
        repo_name=${repo%%=*}
        repo_url=${repo##*=}
        if [ -d "$tftpboot_dir/$repo_name" ]; then
            if [ -z "$platform_created" ]; then
                echo "$platform:"
                echo "  $arch:"
                platform_created=1
            fi

            echo "    $repo_name:"
            echo "      url: '$repo_url'"
        fi
    done
}

function create_repos_yml()
{
    local repos_yml="/etc/crowbar/repos.yml"
    local tmp_yml=$(mktemp).yml

    echo --- > $tmp_yml

    create_repos_yml_for_platform "suse-12.0" "x86_64" "$tftpboot_repos12_dir" \
        SLES12-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12:/x86_64/update/ \
        SUSE-Enterprise-Storage-2-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/2:/x86_64/update/ \
        >> $tmp_yml

    create_repos_yml_for_platform "suse-12.1" "x86_64" "$tftpboot_repos12sp1_dir" \
        SLES12-SP1-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP1:/x86_64/update/ \
        SLE12-SP1-HA-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP1:/x86_64/update/ \
        SUSE-OpenStack-Cloud-6-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/6:/x86_64/update/ \
        SUSE-Enterprise-Storage-2.1-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/2.1:/x86_64/update/ \
        >> $tmp_yml

    mv $tmp_yml $repos_yml
}


function onadmin_set_source_variables()
{
    if iscloudver 6plus; then
        suseversion=12.1
    else
        suseversion=11.3
    fi

    : ${susedownload:=download.nue.suse.com}
    case "$cloudsource" in
        develcloud4)
            CLOUDSLE11DISTPATH=/ibs/Devel:/Cloud:/4/images/iso
            [ -n "$TESTHEAD" ] && CLOUDSLE11DISTPATH=/ibs/Devel:/Cloud:/4:/Staging/images/iso
            CLOUDSLE11DISTISO="S*-CLOUD*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-devel"
        ;;
        develcloud5)
            CLOUDSLE11DISTPATH=/ibs/Devel:/Cloud:/5/images/iso
            [ -n "$TESTHEAD" ] && CLOUDSLE11DISTPATH=/ibs/Devel:/Cloud:/5:/Staging/images/iso
            CLOUDSLE12DISTPATH=$CLOUDSLE11DISTPATH
            CLOUDSLE11DISTISO="SUSE-CLOUD*Media1.iso"
            CLOUDSLE12DISTISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*Media1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-devel"
        ;;
        develcloud6)
            CLOUDSLE12DISTPATH=/ibs/Devel:/Cloud:/6/images/iso
            [ -n "$TESTHEAD" ] && CLOUDSLE12DISTPATH=/ibs/Devel:/Cloud:/6:/Staging/images/iso
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-6-$arch*Media1.iso"
            CLOUDSLE12TESTISO="CLOUD-6-TESTING-$arch*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-devel"
        ;;
        susecloud6)
            CLOUDSLE12DISTPATH=/ibs/SUSE:/SLE-12-SP1:/Update:/Products:/Cloud6/images/iso/
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-6-$arch*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-official"
        ;;
        GM4|GM4+up)
            CLOUDSLE11DISTPATH=/install/SLE-11-SP3-Cloud-4-GM/
            CLOUDSLE11DISTISO="S*-CLOUD*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-4-official"
        ;;
        GM5|GM5+up)
            CLOUDSLE11DISTPATH=/install/SUSE-Cloud-5-GM/
            CLOUDSLE12DISTPATH=$CLOUDSLE11DISTPATH
            CLOUDSLE11DISTISO="SUSE-CLOUD*1.iso"
            CLOUDSLE12DISTISO="SUSE-SLE12-CLOUD-5-COMPUTE-x86_64*1.iso"
            CLOUDLOCALREPOS="SUSE-Cloud-5-official"
        ;;
        M?|GMC*|GM6|GM6+up)
            cs=$cloudsource
            [[ $cs =~ GM6 ]] && cs=GM
            CLOUDSLE12DISTPATH=/install/SLE-12-SP1-Cloud6-$cs/
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-6-$arch*1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-official"
        ;;
        *)
            complain 76 "You must set environment variable cloudsource=develcloud4|develcloud5|develcloud6|susecloud5|GM4|GM5|Mx|GM6"
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
        12.1)
            slesrepolist="SLES12-SP1-Pool SLES12-SP1-Updates"
            slesversion=12-SP1
            slesdist=SLE_12_SP1
            slesmilestone=GM
        ;;
    esac
}


function zypper_refresh()
{
    # --no-gpg-checks for Devel:Cloud repo
    safely zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
}


function ensure_packages_installed()
{
    local zypper_params="--non-interactive --gpg-auto-import-keys --no-gpg-checks"
    local pack
    for pack in "$@" ; do
        rpm -q $pack &> /dev/null || safely zypper $zypper_params install "$pack"
    done
}


function onadmin_repocleanup()
{
    # Workaround broken admin image that has SP3 Test update channel enabled
    zypper mr -d sp3tup
    # disable extra repos
    zypper mr -d sp3sdk
}

# manila-share service (in combination with the generic driver) needs to
# access (via ssh) the service-instance (which is a nova instance) to
# configure the shares (i.e. export a nfs share)
function crowbar_create_network_manila()
{
    local netfile="$1"
    local net=192.168.180
    local je=/opt/dell/bin/json-edit

    $je -a attributes.network.networks.manila.add_bridge --raw -v "false" $netfile
    $je -a attributes.network.networks.manila.add_ovs_bridge --raw -v "false" $netfile
    $je -a attributes.network.networks.manila.bridge_name -v br-manila $netfile
    $je -a attributes.network.networks.manila.broadcast -v $net.255 $netfile
    $je -a attributes.network.networks.manila.conduit -v intf1 $netfile
    $je -a attributes.network.networks.manila.netmask -v 255.255.255.0 $netfile
    $je -a attributes.network.networks.manila.ranges.dhcp.start -v $net.20 $netfile
    $je -a attributes.network.networks.manila.ranges.dhcp.end -v $net.60 $netfile
    $je -a attributes.network.networks.manila.router -v $net.1 $netfile
    $je -a attributes.network.networks.manila.router_pref --raw -v "20" $netfile
    $je -a attributes.network.networks.manila.subnet -v $net.0 $netfile
    $je -a attributes.network.networks.manila.use_vlan --raw -v "true" $netfile
    $je -a attributes.network.networks.manila.vlan --raw -v "501" $netfile
}

# setup network/DNS, add repos and install crowbar packages
function onadmin_prepareinstallcrowbar()
{
    pre_hook $FUNCNAME
    [[ $forcephysicaladmin ]] || lsmod | grep -q ^virtio_blk || complain 25 "this script should be run in the crowbar admin VM"
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
    if [[ $(ping -q -c1 $clouddata |
            perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]]
    then
        longdistance=true
    fi

    if [ -n "${localreposdir_target}" ]; then
        # Delete all repos except PTF repo, because this step could
        # be called after the addupdaterepo step.
        zypper lr -e - | sed -n '/^name=/ {s///; /ptf/! p}' | \
            xargs -r zypper rr
        mount_localreposdir_target
    fi

    onadmin_set_source_variables

    if iscloudver 6plus ; then
        if [[ $cloudsource =~ ^M[1-7]$ ]]; then
            onadmin_prepare_sles12_repos
        fi
        onadmin_prepare_sles12sp1_repos
        onadmin_prepare_sles12plus_cloud_repos
    else
        onadmin_prepare_sles_repos

        if iscloudver 5plus ; then
            onadmin_prepare_sles12_repos
            onadmin_prepare_sles12plus_cloud_repos
        fi
    fi

    if [ -n "$hacloud" ]; then
        if [ "$slesdist" = "SLE_11_SP3" ] && iscloudver 3plus ; then
            add_ha_repo
        elif iscloudver 6plus; then
            add_ha12sp1_repo
        else
            complain 18 "You requested a HA setup but for this combination ($cloudsource : $slesdist) no HA setup is available."
        fi
    fi

    if [ -n "$deployceph" ] && iscloudver 5plus; then
        add_suse_storage_repo
    fi

    ensure_packages_installed rsync netcat

    # setup cloud repos for tftpboot and zypper
    onadmin_prepare_cloud_repos
    onadmin_add_cloud_repo

    zypper_refresh

    # we have potentially new update repos, patch again
    zypper_patch

    # avoid kernel update
    zypper al kernel-default
    zypper -n dup -r Cloud -r cloudtup || zypper -n dup -r Cloud
    zypper rl kernel-default

    if [ -z "$NOINSTALLCLOUDPATTERN" ] ; then
        safely zypper --no-gpg-checks -n in -l -t pattern cloud_admin
        # make sure to use packages from PTF repo (needs zypper dup)
        zypper mr -e cloud-ptf && safely zypper -n dup --from cloud-ptf
    fi

    cd /tmp

    local netfile="/etc/crowbar/network.json"

    local netfilepatch=`basename $netfile`.patch
    [ -e ~/$netfilepatch ] && patch -p1 $netfile < ~/$netfilepatch

    # to revert https://github.com/crowbar/barclamp-network/commit/a85bb03d7196468c333a58708b42d106d77eaead
    sed -i.netbak1 -e 's/192\.168\.126/192.168.122/g' $netfile

    sed -i.netbak -e 's/"conduit": "bmc",$/& "router": "192.168.124.1",/' \
        -e "s/192.168.124/$net/g" \
        -e "s/192.168.125/$net_storage/g" \
        -e "s/192.168.123/$net_fixed/g" \
        -e "s/192.168.122/$net_public/g" \
        -e "s/ 200/ $vlan_storage/g" \
        -e "s/ 300/ $vlan_public/g" \
        -e "s/ 500/ $vlan_fixed/g" \
        -e "s/ [47]00/ $vlan_sdn/g" \
        $netfile

    # extra network to test manila with the generic driver
    if iscloudver 6plus; then
        crowbar_create_network_manila $netfile
    fi

    if [[ $cloud = p || $cloud = p2 ]] ; then
        # production cloud has a /22 network
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.netmask -v 255.255.252.0 $netfile
    fi
    if [[ $cloud =~ qa ]] ; then
        # QA clouds have too few IP addrs, so smaller subnets are used
        wget -O$netfile http://info.cloudadm.qa.suse.de/net-json/${cloud}_dual
        sed -i 's/bc-template-network/template-network/' $netfile
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
    # Setup network attributes for jumbo frames
    if [[ $want_mtu_size ]]; then
        echo "Setting MTU to custom value of: $want_mtu_size"
        local lnet
        for lnet in admin storage os_sdn ; do
            /opt/dell/bin/json-edit -a attributes.network.networks.$lnet.mtu -r -v $want_mtu_size $netfile
        done
    fi

    # to allow integration into external DNS:
    local f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
    grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

    # set default password to 'linux'
    # setup_base_images.rb is for SUSE Cloud 1.0 and update_nodes.rb is for 2.0
    sed -i -e 's/\(rootpw_hash.*\)""/\1"$2y$10$u5mQA7\/8YjHdutDPEMPtBeh\/w8Bq0wEGbxleUT4dO48dxgwyPD8D."/' /opt/dell/chef/cookbooks/provisioner/recipes/setup_base_images.rb /opt/dell/chef/cookbooks/provisioner/recipes/update_nodes.rb

    if  iscloudver 6M7plus ; then
        create_repos_yml
    fi

    if [[ $hacloud = 1 ]] ; then
        f=/opt/dell/chef/cookbooks/nfs-server/templates/default/exports.erb
        mkdir -p /var/lib/glance/images
        if ! grep -q /var/lib/glance/images $f; then
            echo "/var/lib/glance/images     <%= @admin_subnet %>/<%= @admin_netmask %>(rw,async,no_root_squash,no_subtree_check)" >> $f
        fi
        mkdir -p /srv/nfs/{database,rabbitmq}
        if ! grep -q /srv/nfs $f; then
            echo "/srv/nfs     <%= @admin_subnet %>/<%= @admin_netmask %>(rw,async,no_root_squash,no_subtree_check)" >> $f
        fi
    fi

    # exit code of the sed don't matter, so just:
    return 0
}

function crowbar_install_status()
{
    curl -s $crowbar_api$crowbar_api_installer_path/status.json | python -mjson.tool
}

function do_installcrowbar_cloud6plus()
{
    service crowbar status || service crowbar stop
    service crowbar start

    wait_for 30 10 "[[ \`curl -s -o /dev/null -w '%{http_code}' $crowbar_api/installer \` = 200 ]]" "crowbar installer to be available"

    # temporarily support old-new and final installer paths
    if [[ `curl -s -o /dev/null -w "%{http_code}" $crowbar_api$crowbar_api_installer_path` = "404"  ]] ; then
        crowbar_api_installer_path=/installer
    fi


    if crowbar_install_status | grep -q '"success": *true' ; then
        echo "Crowbar is already installed. The current crowbar install status is:"
        crowbar_install_status
        return 0
    fi

    # call api to start asyncronous install job
    curl -s -X POST $crowbar_api$crowbar_api_installer_path/start || complain 39 "crowbar is not running"

    wait_for 60 10 "crowbar_install_status | grep -q '\"success\": *true'" "crowbar to get installed" "tail -n 500 $crowbar_install_log"
}


function do_installcrowbar_legacy()
{
    local instparams="$1 --verbose"
    local instcmd
    if [ -e /tmp/install-chef-suse.sh ]; then
        instcmd="/tmp/install-chef-suse.sh $instparams"
    else
        instcmd="/opt/dell/bin/install-chef-suse.sh $instparams"
    fi
    # screenlog is verbose in legacy mode
    crowbar_install_log=/root/screenlog.0

    cd /root # we expect the screenlog.0 file here
    echo "Command to install chef: $instcmd"
    intercept "install-chef-suse.sh"

    rm -f /tmp/chef-ready
    # run in screen to not lose session in the middle when network is reconfigured:
    screen -d -m -L /bin/bash -c "$instcmd ; touch /tmp/chef-ready"

    wait_for 300 5 '[ -e /tmp/chef-ready ]' "waiting for chef-ready"

    # Make sure install finished correctly
    if ! [ -e /opt/dell/crowbar_framework/.crowbar-installed-ok ]; then
        tail -n 90 /root/screenlog.0
        complain 89 "Crowbar \".crowbar-installed-ok\" marker missing"
    fi

    ensure_packages_installed crowbar-barclamp-tempest

    # Force restart of crowbar
    service crowbar stop
    service crowbar status || service crowbar start
}


function do_installcrowbar()
{
    intercept "crowbar-installation"
    pre_hook $FUNCNAME
    do_set_repos_skip_checks

    rpm -Va crowbar\*
    if iscloudver 6M8plus ; then
        do_installcrowbar_cloud6plus
    else
        do_installcrowbar_legacy $@
    fi
    rpm -Va crowbar\*

    ## common code - installer agnostic
    [ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

    if [ -n "$wanthyperv" ] ; then
        # prepare Hyper-V 2012 R2 PXE-boot env and export it via Samba:
        zypper -n in samba
        rsync -a $clouddata::cloud/hyperv-6.3 /srv/tftpboot/
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

    sleep 20
    if ! curl -m 59 -s $crowbar_api  > /dev/null || \
        ! curl -m 59 -s --digest --user crowbar:crowbar $crowbar_api  | \
        grep -q /nodes/crowbar
    then
        tail -n 90 $crowbar_install_log
        complain 84 "crowbar self-test failed"
    fi

    if ! get_all_nodes | grep -q crowbar.$cloudfqdn ; then
        tail -n 90 $crowbar_install_log
        complain 85 "crowbar 2nd self-test failed"
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
    update_one_proposal dns default

    if ! validate_data_bags; then
        complain 68 "Validation error in default data bags. Aborting."
    fi
}


function onadmin_installcrowbarfromgit()
{
    if iscloudver 5plus ; then
        # on SLE11 we dont have update-alternatives for ruby
        # but we need a "ruby" in PATH for various crowbar scripts
        ln -s /usr/bin/ruby.ruby2.1 /usr/bin/ruby
        ln -s /usr/bin/gem.ruby2.1 /usr/bin/gem
    fi
    export CROWBAR_FROM_GIT=1
    do_installcrowbar "--from-git"
}

function onadmin_installcrowbar()
{
    do_installcrowbar ""
}

# Set a node's attribute (see 2nd argument)
# Must be run after discovery and makes sense mostly before allocation
function set_node_attribute()
{
    local node="$1"
    local attr="$2"
    local value="$3"
    local t=$(mktemp).json
    knife node show -F json "$node" > $t
    json-edit $t -a "normal.$attr" -v "$value"
    knife node from file $t
    rm -f $t
}

function set_node_fs()
{
    set_node_attribute "$1" "crowbar_wall.default_fs" "$2"
}

function set_node_role()
{
    set_node_attribute "$1" "crowbar_wall.intended_role" "$2"
}

function set_node_platform()
{
    set_node_attribute "$1" "target_platform" "$2"
}

function set_node_role_and_platform()
{
    set_node_role "$1" "$2"
    set_node_platform "$1" "$3"
}


# set the RAID configuration for a node before allocating
function set_node_raid()
{
    node="$1"
    raid_type="$2"
    disks_count="$3"
    local t=$(mktemp).json
    knife node show -F json "$node" > $t

    # to find out available disks, we need to look at the nodes directly
    raid_disks=`ssh $node lsblk -n -d | cut -d' ' -f 1 | head -n $disks_count`
    raid_disks=`printf "\"/dev/%s\"," $raid_disks`
    raid_disks="[ ${raid_disks%,} ]"

    json-edit $t -a normal.crowbar_wall.raid_type -v "$raid_type"
    json-edit $t -a normal.crowbar_wall.raid_disks --raw -v "$raid_disks"
    knife node from file $t
    rm -f $t
}


# Reboot the nodes with ipmi
function reboot_nodes_via_ipmi()
{
    do_one_proposal ipmi default
    local nodelist=$(seq 1 $nodenumber)
    local i
    local bmc_values=($(
        crowbar network proposal show default | \
        rubyjsonparse "
            networks = j['attributes']['network']['networks']
            puts networks['bmc']['ranges']['host']['start']
            puts networks['bmc']['router']
        "
    ))
    test -n "${bmc_values[1]}" || bmc_values[1]="0.0.0.0"
    IFS=. read ip1 ip2 ip3 ip4 <<< "${bmc_values[0]}"
    local bmc_net="$ip1.$ip2.$ip3"
    for i in $nodelist ; do
        local pw
        for pw in 'cr0wBar!' $extraipmipw ; do
            local ip=$bmc_net.$(($ip4 + $i))
            (ipmitool -H $ip -U root -P $pw lan set 1 defgw ipaddr "${bmc_values[1]}"
            ipmitool -H $ip -U root -P $pw power on
            ipmitool -H $ip -U root -P $pw power reset) &
        done
    done
    wait
}

function onadmin_allocate()
{
    pre_hook $FUNCNAME

    if $want_ipmi ; then
        reboot_nodes_via_ipmi
    fi

    if [[ $cloud = qa1 ]] ; then
        curl http://$clouddata/git/automation/scripts/qa1_nodes_reboot | bash
    fi

    wait_for 50 10 'test $(get_all_discovered_nodes | wc -l) -ge 1' "first node to be discovered"
    wait_for 100 10 '[[ $(get_all_discovered_nodes | wc -l) -ge $nodenumber ]]' "all nodes to be discovered"
    local n
    for n in `get_all_discovered_nodes` ; do
        wait_for 100 2 "knife node show -a state $n | grep discovered" \
            "node to enter discovered state"
    done
    local controllernodes=(
            $(get_all_discovered_nodes | head -n 2)
        )

    controller_os="suse-11.3"
    if iscloudver 6plus; then
        controller_os="suse-12.1"
    fi

    echo "Setting first node to controller..."
    set_node_role_and_platform ${controllernodes[0]} "controller" $controller_os

    # setup RAID for controller node
    if [[ $controller_raid_volumes -gt 1 ]] ; then
        set_node_raid ${controllernodes[0]} $want_raidtype $controller_raid_volumes
    fi

    if [ -n "$want_node_os" ] ; then
        # OS for nodes provided explicitely: assign them successively to the nodes
        # example: want_node_os=suse-12.0=3,suse-12.1=4,hyperv-6.3=1

        local nodesavailable=`get_all_discovered_nodes`

        for systems in ${want_node_os//,/ } ; do
            local node_os=${systems%=*}
            local number=${systems#*=}
            local i=1
            for node in `printf  "%s\n" $nodesavailable | head -n$number`; do
                set_node_platform $node $node_os
                nodesavailable=`remove_node_from_list "$node" "$nodesavailable"`
                i=$((i+1))
            done
        done
    else
        if [ -n "$want_sles12" ] && iscloudver 5 ; then

            local nodes=(
                $(get_all_discovered_nodes | tail -n 2)
            )
            if [ -n "$deployceph" ] ; then
                echo "Setting second last node to SLE12 Storage..."
                set_node_role_and_platform ${nodes[0]} "storage" "suse-12.0"
            fi
            echo "Setting last node to SLE12 compute..."
            set_node_role_and_platform ${nodes[1]} "compute" "suse-12.0"
        fi
        if [ -n "$deployceph" ] && iscloudver 6 ; then
            local nodes=(
                $(get_all_discovered_nodes | head -n 3)
            )
            if [[ $cloudsource =~ ^M[1-7]$ ]]; then
                storage_os="suse-12.0"
            else
                storage_os="suse-12.1"
            fi
            for n in $(seq 1 2); do
                echo "Setting node $(($n+1)) to Storage..."
                set_node_role_and_platform ${nodes[$n]} "storage" ${storage_os}
            done
        fi
        if [ -n "$wanthyperv" ] ; then
            echo "Setting last node to Hyper-V compute..."
            local computenode=$(get_all_discovered_nodes | tail -n 1)
            set_node_role_and_platform $computenode "compute" "hyperv-6.3"
        fi
    fi

    if [ -n "$want_node_roles" ] ; then
        # roles for nodes provided explicitely: assign them successively to the nodes
        # example: want_node_roles=controller=1,storage=2,compute=2

        local nodesavailable=`get_all_discovered_nodes`

        for roles in ${want_node_roles//,/ } ; do
            local role=${roles%=*}
            local number=${roles#*=}
            local i=1
            for node in `printf  "%s\n" $nodesavailable | head -n$number`; do
                set_node_role $node $role
                nodesavailable=`printf "%s\n" $nodesavailable | grep -iv $node`
                i=$((i+1))
            done
        done
    fi

    # set BTRFS for all nodes when docker is wanted (docker likes btrfs)
    if [ -n "$want_docker" ] ; then
        for node in `get_all_discovered_nodes` ; do
            set_node_fs $node "btrfs"
        done
    fi

    echo "Allocating nodes..."
    local m
    for m in `get_all_discovered_nodes` ; do
        crowbar machines allocate $m
        local i=$(echo $m | sed "s/.*-0\?\([^-\.]*\)\..*/\1/g")
        cat >> .ssh/config <<EOF
Host node$i
    HostName $m
EOF
    done

    # check for error 500 in app/models/node_object.rb:635:in `sort_ifs'#012
    curl -m 9 -s --digest --user crowbar:crowbar $crowbar_api | \
        tee /root/crowbartest.out
    if grep -q "Exception caught" /root/crowbartest.out; then
        complain 27 "simple crowbar test failed"
    fi

    rm -f /root/crowbartest.out
}

function sshtest()
{
    timeout 10 ssh -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
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

function onadmin_wait_tftpd()
{
    wait_for 300 2 \
        "timeout -k 2 2 tftp $adminip 69 -c get /discovery/x86_64/bios/pxelinux.cfg/default /tmp/default"
    echo "Crowbar tftp server ready"
}

function wait_node_ready()
{
    local node=$1
    wait_for 300 10 \
        "crowbar machines show $node state | grep -q '^ready$'" \
        "node $node to transition to ready" "exit 12"
    echo "node $node transitioned to \"ready\""

    wait_for 3 10 \
        "netcat -w 3 -z $node 3389 || sshtest $node rpm -q yast2-core" \
        "node $node" "check_node_resolvconf $node; exit 12"
    echo "node $node ready"
}

function onadmin_waitcloud()
{
    pre_hook $FUNCNAME
    local node
    for node in `get_all_discovered_nodes` ; do
        wait_node_ready $node
    done
}

function onadmin_post_allocate()
{
    pre_hook $FUNCNAME

    # for testing the Manila generic driver, the nodes with the m-shr service
    # and the manila-service VM need an IP from the same subnet. So add all
    # current nodes to the subnet
    if iscloudver 6plus; then
        cmachines=$(get_all_discovered_nodes)
        for machine in $cmachines; do
            crowbar network allocate_ip default $machine manila dhcp
        done
    fi

    if [[ $hacloud = 1 ]] ; then
        # create glance user with fixed uid/gid so they can work on the same
        # NFS share
        cluster_node_assignment

        local clusternodes_var=$(echo clusternodes${clusternameservices})
        local node

        for node in ${!clusternodes_var}; do
            ssh $node "getent group glance >/dev/null ||\
                groupadd -r glance -g 450"
            ssh $node "getent passwd glance >/dev/null || \
                useradd -r -g glance -u 450 -d /var/lib/glance -s /sbin/nologin -c \"OpenStack glance Daemon\" glance"
        done
    fi
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
    pre_hook $FUNCNAME
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

    if  iscloudver 6M7plus ; then
        image="suse-12.1/x86_64/"
    elif iscloudver 6; then
        image="suse-12.1"
    else
        if [ -n "$want_sles12" ] ; then
            image="suse-12.0"
        else
            image="suse-11.3"
        fi
        # install SuSEfirewall2 as it is called in crowbar_register
        #FIXME in barclamp-provisioner
        zyppercmd="zypper -n install SuSEfirewall2 &&"
    fi

    local adminfqdn=`get_crowbar_node`
    local adminip=`knife node show $adminfqdn -a crowbar.network.admin.address | awk '{print $2}'`

    if [[ $keep_existing_hostname -eq 1 ]] ; then
        local hostname="$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 10 | head -n 1)"
        local domain="${adminfqdn#*.}"
        local hostnamecmd='echo "'$hostname'.'$domain'" > /etc/HOSTNAME'
    fi

    inject="
            set -x
            rm -f /tmp/crowbar_register_done;
            zypper -n in wget screen
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


function onadmin_get_proposalstatus()
{
    local proposal=$1
    local proposaltype=$2
    crowbar $proposal proposal show $proposaltype | \
        rubyjsonparse "puts j['deployment']['$proposal']['crowbar-status']"
}

function onadmin_get_machinesstatus()
{
    local onenode
    for onenode in `get_all_discovered_nodes` ; do
        echo -n "$onenode "
        crowbar machines show $onenode state
    done
}

function waitnodes()
{
    local mode=$1
    local proposal=$2
    local proposaltype=${3:-default}
    case "$mode" in
        nodes)
            local allnodesnumber=`get_all_discovered_nodes | wc -l`
            wait_for 800 5 "[[ \`onadmin_get_machinesstatus | grep ' ready$' | wc -l\` -ge $allnodesnumber ]]" "nodes to get ready"

            local onenode
            for onenode in `get_all_discovered_nodes` ; do
                wait_for 500 1 "netcat -w 3 -z $onenode 22 || netcat -w 3 -z $onenode 3389" "node $onenode to be acessible"
                echo "node $onenode ready"
            done
            ;;
        proposal)
            echo -n "Waiting for proposal $proposal($proposaltype) to get successful: "
            local proposalstatus=''
            wait_for 800 1 "proposalstatus=\`onadmin_get_proposalstatus $proposal $proposaltype\` ; [[ \$proposalstatus =~ success|failed ]]" "proposal to be successful"
            if [[ $proposalstatus = failed ]] ; then
                tail -n 90 \
                    /opt/dell/crowbar_framework/log/d*.log \
                    /var/log/crowbar/chef-client/d*.log
                complain 40 "proposal $proposal failed. Exiting."
            fi
            echo "proposal $proposal successful"
            ;;
        *)
            complain 72 "waitnodes was called with wrong parameters"
            ;;
    esac
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

function enable_ssl_generic()
{
    local service=$1
    echo "Enabling SSL for $service"
    local p="proposal_set_value $service default"
    local a="['attributes']['$service']"
    case $service in
        swift)
            $p "$a['ssl']['enabled']" true
        ;;
        nova)
            $p "$a['ssl']['enabled']" true
            $p "$a['novnc']['ssl']['enabled']" true
        ;;
        horizon|nova_dashboard)
            $p "$a['apache']['ssl']" true
            if iscloudver 6M9plus ; then
                $p "$a['apache']['generate_certs']" true
            fi
            return
        ;;
        *)
            $p "$a['api']['protocol']" "'https'"
        ;;
    esac
    $p "$a['ssl']['generate_certs']" true
    $p "$a['ssl']['insecure']" true
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
        "['attributes']['pacemaker']['stonith']['libvirt']['hypervisor_ip']" "'$admingw'"
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

function cinder_netapp_proposal_configuration()
{
    local volnumber=$1
    local storage_protocol=${2:-$cinder_netapp_storage_protocol}
    local p="proposal_set_value cinder default"
    local a="['attributes']['cinder']['volumes']"
    if [[ $volnumber -gt 0 ]]; then
        proposal_modify_value cinder default "$a" "{}" "<<"
        $p "$a[$volnumber]['netapp']" "j['attributes']['cinder']['volume_defaults']['netapp']"
        $p "$a[$volnumber]['backend_driver']" "'netapp'"
    fi
    $p "$a[$volnumber]['backend_name']" "'netapp-backend-${storage_protocol}'"
    $p "$a[$volnumber]['netapp']['storage_family']" "'ontap_cluster'"
    $p "$a[$volnumber]['netapp']['storage_protocol']" "'${storage_protocol}'"
    $p "$a[$volnumber]['netapp']['netapp_server_hostname']" "'netapp-n1-e0m.cloud.suse.de'"
    $p "$a[$volnumber]['netapp']['vserver']" "'cloud-openstack-svm'"
    $p "$a[$volnumber]['netapp']['netapp_login']" "'${cinder_netapp_login}'"
    $p "$a[$volnumber]['netapp']['netapp_password']" "'${cinder_netapp_password}'"
    if [[ $storage_protocol = "nfs" ]] ; then
        $p "$a[$volnumber]['netapp']['nfs_shares']" "'netapp-n1-nfs.cloud.suse.de:/n1_vol_openstack_nfs'"
    fi
}

function provisioner_add_repo()
{
    local repos=$1
    local repodir=$2
    local repo=$3
    local url=$4
    if [ -d "$repodir/$repo/" ]; then
        proposal_set_value provisioner default "$repos['$repo']" "{}"
        proposal_set_value provisioner default "$repos['$repo']['url']" \
            "'$url'"
    fi
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

    local sles12plusnode=`get_sles12plus_node`

    ### NOTE: ONLY USE proposal_{set,modify}_value functions below this line
    ###       The edited proposal will be read and imported at the end
    ###       So, only edit the proposal file, and NOT the proposal itself

    case "$proposal" in
        keystone|glance|neutron|cinder|swift|nova|horizon|nova_dashboard)
            if [[ $want_all_ssl = 1 ]] || eval [[ \$want_${proposal}_ssl = 1 ]] ; then
                enable_ssl_generic $proposal
            fi
        ;;
    esac

    case "$proposal" in
        nfs_client)
            local adminfqdn=`get_crowbar_node`
            proposal_set_value nfs_client $proposaltype "['attributes']['nfs_client']['exports']['glance-images']" "{}"
            proposal_set_value nfs_client $proposaltype "['attributes']['nfs_client']['exports']['glance-images']['nfs_server']" "'$adminfqdn'"
            proposal_set_value nfs_client $proposaltype "['attributes']['nfs_client']['exports']['glance-images']['export']" "'/var/lib/glance/images'"
            proposal_set_value nfs_client $proposaltype "['attributes']['nfs_client']['exports']['glance-images']['mount_path']" "'/var/lib/glance/images'"
            proposal_set_value nfs_client $proposaltype "['attributes']['nfs_client']['exports']['glance-images']['mount_options']" "['']"

            local clusternodes_var=$(echo clusternodes${clusternameservices})
            local nodes=`printf "\"%s\"," ${!clusternodes_var}`
            nodes="[ ${nodes%,} ]"
            proposal_set_value nfs_client $proposaltype "['deployment']['nfs_client']['elements']['nfs-client']" "$nodes"
        ;;
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
            local cmachines=$(get_all_nodes | head -n 3)
            local dnsnodes=`echo \"$cmachines\" | sed 's/ /", "/g'`
            proposal_set_value dns default "['attributes']['dns']['records']" "{}"
            proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']" "{}"
            proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']['ips']" "['10.11.12.13']"
            proposal_set_value dns default "['deployment']['dns']['elements']['dns-server']" "[$dnsnodes]"
        ;;
        ipmi)
            proposal_set_value ipmi default "['attributes']['ipmi']['bmc_enable']" true
        ;;
        keystone)
            # set a custom region name
            proposal_set_value keystone default "['attributes']['keystone']['api']['region']" "'CustomRegion'"
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value keystone default "['deployment']['keystone']['elements']['keystone-server']" "['cluster:$clusternameservices']"
            fi
            if [[ $want_ldap ]] ; then
                local p="proposal_set_value keystone default"
                if iscloudver 6plus; then
                    $p "['attributes']['keystone']['identity']['driver']" "'hybrid'"
                    $p "['attributes']['keystone']['assignment']['driver']" "'hybrid'"
                else
                    $p "['attributes']['keystone']['identity']['driver']" "'keystone.identity.backends.hybrid.Identity'"
                    $p "['attributes']['keystone']['assignment']['driver']" "'keystone.assignment.backends.hybrid.Assignment'"
                fi
                local l="['attributes']['keystone']['ldap']"
                $p "$l['url']" "'ldap://ldap.suse.de'"
                $p "$l['suffix']" "'dc=suse,dc=de'"
                $p "$l['user_tree_dn']" "'ou=accounts,dc=suse,dc=de'"
                $p "$l['user_objectclass']" "'posixAccount'"
                $p "$l['user_id_attribute']" "'suseid'"
                $p "$l['user_name_attribute']" "'uid'"
                $p "$l['use_tls']" "true"
                $p "$l['tls_cacertdir']" "'/etc/ssl/certs'"
                $p "$l['tls_req_cert']" "'allow'" # FIXME: this allows MitM
                # to be secure, set to 'demand' and run on keystone node:
                #zypper ar --refresh http://download.suse.de/ibs/SUSE:/CA/SLE_11_SP3/SUSE:CA.repo
                #zypper -n --gpg-auto-import-keys in ca-certificates-suse
            fi
            if [[ $want_keystone_v3 ]] ; then
                proposal_set_value keystone default "['attributes']['keystone']['api']['version']" "'3'"
            fi
        ;;
        glance)
            if [[ -n "$deployceph" ]]; then
                proposal_set_value glance default "['attributes']['glance']['default_store']" "'rbd'"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value glance default "['deployment']['glance']['elements']['glance-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        manila)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value manila default "['deployment']['manila']['elements']['manila-server']" "['cluster:$clusternameservices']"
            fi

            if iscloudver 6M9plus ; then
                proposal_set_value manila default "['attributes']['manila']['default_share_type']" "'default'"
                # new generic driver options since M9
                if crowbar manila proposal show default|grep service_instance_name_or_id ; then
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_driver']" "'generic'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_name']" "'backend1'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_user']" "'root'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_password']" "'linux'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['share_volume_fstype']" "'ext3'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_name_or_id']" "'$manila_service_vm_uuid'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_net_name_or_ip']" "'$manila_service_vm_ip'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['tenant_net_name_or_ip']" "'fixed'"
                fi
            fi
        ;;
        ceph)
            proposal_set_value ceph default "['attributes']['ceph']['disk_mode']" "'all'"
        ;;
        nova)
            local role_prefix=`nova_role_prefix`
            # custom nova config of libvirt
            proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
            proposal_set_value nova default "['attributes']['nova']['use_migration']" "true"
            [[ "$libvirt_type" = xen ]] && sed -i -e "s/${role_prefix}-compute-$libvirt_type/${role_prefix}-compute-xxx/g; s/${role_prefix}-compute-kvm/${role_prefix}-compute-$libvirt_type/g; s/${role_prefix}-compute-xxx/${role_prefix}-compute-kvm/g" $pfile

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-controller']" "['cluster:$clusternameservices']"

                # only use remaining nodes as compute nodes, keep cluster nodes dedicated to cluster only
                local novanodes
                novanodes=`printf "\"%s\"," $unclustered_nodes`
                novanodes="[ ${novanodes%,} ]"
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-${libvirt_type}']" "$novanodes"
            fi

            if [ -n "$want_sles12" ] && [ -n "$want_docker" ] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-docker']" "['$sles12plusnode']"
                # do not assign another compute role to this node
                proposal_modify_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-${libvirt_type}']" "['$sles12plusnode']" "-="
            fi

            if [[ $nova_shared_instance_storage = 1 ]] ; then
                proposal_set_value nova default "['attributes']['nova']['use_shared_instance_storage']" "true"
            fi
        ;;
        horizon|nova_dashboard)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value $proposal default "['deployment']['$proposal']['elements']['$proposal-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        heat)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value heat default "['deployment']['heat']['elements']['heat-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        ceilometer)
            local ceilometerservice="ceilometer-cagent"
            if iscloudver 6M8plus ; then
                ceilometerservice="ceilometer-polling"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-server']" "['cluster:$clusternameservices']"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['$ceilometerservice']" "['cluster:$clusternameservices']"
                # disabling mongodb, because if in one cluster mode the requirements of drbd and mongodb ha conflict:
                #   drbd can only use 2 nodes max. <> mongodb ha requires 3 nodes min.
                # this should be adapted when NFS mode is supported for data cluster
                proposal_set_value ceilometer default "['attributes']['ceilometer']['use_mongodb']" "false"
                local ceilometernodes
                ceilometernodes=`printf "\"%s\"," $unclustered_nodes`
                ceilometernodes="[ ${ceilometernodes%,} ]"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-agent']" "$ceilometernodes"
            fi
        ;;
        neutron)
            [[ "$networkingplugin" = linuxbridge ]] && networkingmode=vlan
            proposal_set_value neutron default "['attributes']['neutron']['use_lbaas']" "true"

            if iscloudver 5plus; then
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
                    if iscloudver 5plus && ! iscloudver 6M8plus ; then
                        proposal_set_value neutron default "['attributes']['neutron']['use_l2pop']" "false"
                    fi
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
            if [ -n "$want_sles12" ] && [ -z "$hacloud" ] && [ -n "$want_neutronsles12" ] && iscloudver 5plus ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-network']" "['$sles12plusnode']"
            fi

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-server']" "['cluster:$clusternameservices']"
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
                proposal_set_value swift default "['attributes']['swift']['allow_versions']" "true"
                proposal_set_value swift default "['attributes']['swift']['keystone_delay_auth_decision']" "true"
                iscloudver 3 || proposal_set_value swift default "['attributes']['swift']['middlewares']['crossdomain']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['formpost']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['staticweb']['enabled']" "true"
                proposal_set_value swift default "['attributes']['swift']['middlewares']['tempurl']['enabled']" "true"
            fi
        ;;
        cinder)
            if iscloudver 4 ; then
                proposal_set_value cinder default "['attributes']['cinder']['enable_v2_api']" "true"
            fi

            proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['${cinder_backend}']" "j['attributes']['cinder']['volume_defaults']['${cinder_backend}']"
            proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['backend_driver']" "'${cinder_backend}'"
            case "$cinder_backend" in
                netapp)
                    cinder_netapp_proposal_configuration "0"
                    ;;
            esac

            # add a second backend to enable multi-backend, if not already present
            if [[ $want_cindermultibackend = 1 ]] ; then
                # in case of testing netapp, add a second backend with a different storage protocol
                if [[ $cinder_backend = "netapp" ]]; then
                    if [[ $cinder_netapp_storage_protocol = "iscsi" ]] ; then
                        cinder_netapp_proposal_configuration "1" "nfs"
                    else
                        cinder_netapp_proposal_configuration "1" "iscsi"
                    fi
                elif ! crowbar cinder proposal show default | grep -q local-multi; then
                    proposal_modify_value cinder default "${volumes}" "{ 'backend_driver' => 'local', 'backend_name' => 'local-multi', 'local' => { 'volume_name' => 'cinder-volumes-multi', 'file_size' => 2000, 'file_name' => '/var/lib/cinder/volume-multi.raw'} }" "<<"
                fi
            fi

            if [[ $hacloud = 1 ]] ; then
                local cinder_volume
                # fetch one of the compute nodes as cinder_volume
                cinder_volume=`printf "%s\n" $unclustered_nodes | tail -n 1`
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-controller']" "['cluster:$clusternameservices']"
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-volume']" "['$cinder_volume']"
            fi
        ;;
        tempest)
            if [[ $hacloud = 1 ]] ; then
                get_novacontroller
                # tempest can only be deployed on one node, and we run it on
                # the same nova controller we use for other stuff.
                tempestnodes="[ '$novacontroller' ]"
                proposal_set_value tempest default "['deployment']['tempest']['elements']['tempest']" "$tempestnodes"
            fi
        ;;
        provisioner)
            if [[ $keep_existing_hostname = 1 ]] ; then
                proposal_set_value provisioner default "['attributes']['provisioner']['keep_existing_hostname']" "true"
            fi

            if ! iscloudver 6M7plus ; then
                proposal_set_value provisioner default "['attributes']['provisioner']['suse']" "{}"
                proposal_set_value provisioner default "['attributes']['provisioner']['suse']['autoyast']" "{}"
                proposal_set_value provisioner default "['attributes']['provisioner']['suse']['autoyast']['repos']" "{}"

                local autoyast="['attributes']['provisioner']['suse']['autoyast']"
                local repos="$autoyast['repos']"

                if iscloudver 5plus ; then
                    repos="$autoyast['repos']['suse-11.3']"
                    proposal_set_value provisioner default "$repos" "{}"
                fi

                provisioner_add_repo $repos "$tftpboot_repos_dir" "SLES11-SP3-Updates-test" \
                    "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/11-SP3:/x86_64/update/"
                provisioner_add_repo $repos "$tftpboot_repos_dir" "SLE11-HAE-SP3-Updates-test" \
                    "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-HAE:/11-SP3:/x86_64/update/"
                provisioner_add_repo $repos "$tftpboot_repos_dir" "SUSE-Cloud-4-Updates-test" \
                    "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/4:/x86_64/update/"
                provisioner_add_repo $repos "$tftpboot_repos_dir" "SUSE-Cloud-5-Updates-test" \
                    "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/5:/x86_64/update/"

                if iscloudver 5plus ; then
                    repos="$autoyast['repos']['suse-12.0']"
                    proposal_set_value provisioner default "$repos" "{}"

                    provisioner_add_repo $repos "$tftpboot_repos12_dir" "SLES12-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12:/x86_64/update/"
                    provisioner_add_repo $repos "$tftpboot_repos12_dir" "SLE-12-Cloud-Compute5-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/12-Cloud-Compute:/5:/x86_64/update/"
                    provisioner_add_repo $repos "$tftpboot_repos12_dir" "SUSE-Enterprise-Storage-1.0-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/1.0:/x86_64/update/"
                    provisioner_add_repo $repos "$tftpboot_repos12_dir" "SUSE-Enterprise-Storage-2-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/2:/x86_64/update/"
                fi

                if iscloudver 6plus ; then
                    repos="$autoyast['repos']['suse-12.1']"
                    proposal_set_value provisioner default "$repos" "{}"

                    provisioner_add_repo $repos "$tftpboot_repos12sp1_dir" "SLES12-SP1-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP1:/x86_64/update/"
                    provisioner_add_repo $repos "$tftpboot_repos12sp1_dir" "SLE12-SP1-HA-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP1:/x86_64/update/"
                    provisioner_add_repo $repos "$tftpboot_repos12sp1_dir" "SUSE-OpenStack-Cloud-6-Updates-test" \
                        "http://$distsuse/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/6:/x86_64/update/"
                fi
            fi

        ;;
        *) echo "No hooks defined for service: $proposal"
        ;;
    esac

    crowbar $proposal proposal --file=$pfile edit $proposaltype ||\
        complain 88 "'crowbar $proposal proposal --file=$pfile edit $proposaltype' failed with exit code: $?"
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
    # C4: swift isn't possible with Cloud5 and SLES12 nodes
    if iscloudver 5 && [[ $deployswift ]] && [[ -n "$want_sles12" ]] ; then
        complain 88 "swift does not work with SLES12 nodes in Cloud5 - use want_swift=0"
    fi

    if iscloudver 6plus ; then
        want_sles12=1
    fi
    ### FINAL swift and ceph check
    if [[ $deployswift && $deployceph ]] ; then
        complain 89 "Can not deploy ceph and swift at the same time."
    fi
    ### do NOT set/change deployceph or deployswift below this line!

    # Tempest
    wanttempest=1
    if [[ $want_tempest == 0 ]] ; then
        wanttempest=
    fi

    # Cinder
    if [[ ! $cinder_backend ]] ; then
        if [[ $deployceph ]] ; then
            cinder_backend="rbd"
        elif [[ $cephvolumenumber -lt 2 ]] ; then
            cinder_backend="local"
        else
            cinder_backend="raw"
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

function prepare_proposals()
{
    pre_hook $FUNCNAME
    waitnodes nodes

    if iscloudver 5plus; then
        update_one_proposal dns default
    fi

    cmachines=$(get_all_nodes)
    local ptfchannel="SLE-Cloud-PTF"
    iscloudver 6plus && ptfchannel="PTF"
    for machine in $cmachines; do
        ssh $machine "zypper mr -p 90 $ptfchannel"
    done

}

# Set dashboard node alias.
#
# FIXME: In HA mode, this results in a single node in the cluster
# which contains the dashboard being aliased to 'dashboard', which is
# misleading.  It might be better to call them dashboard1, dashboard2 etc.
#
# Even in non-HA mode, it doesn't make much sense since typically lots
# of other services run on the same node.  However it might save one
# or two people some typing during manual testing, so let's leave it
# for now.
function set_dashboard_alias()
{
    get_horizon
    set_node_alias_and_role `echo "$horizonserver" | cut -d . -f 1` dashboard controller
}

function deploy_single_proposal()
{
    local proposal=$1

    # proposal filter
    case "$proposal" in
        nfs_client)
            [[ $hacloud = 1 ]] || continue
            ;;
        pacemaker)
            [[ $hacloud = 1 ]] || continue
            ;;
        ceph)
            [[ -n "$deployceph" ]] || continue
            ;;
        manila)
            if ! iscloudver 6plus; then
                # manila barclamp is only in SC6+ and develcloud5 with SLE12CC5
                if ! [[ "$cloudsource" == "develcloud5" ]] || [ -z "$want_sles12" ]; then
                    continue
                fi
            fi
            if iscloudver 6M9plus ; then
                get_novacontroller
                oncontroller oncontroller_manila_generic_driver_setup
                get_manila_service_instance_details
            fi
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
        nfs_client)
            if [[ $hacloud = 1 ]] ; then
                do_one_proposal "$proposal" "$clusternameservices"
            fi
            ;;
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
}

# apply all wanted proposals on crowbar admin node
function onadmin_proposal()
{

    prepare_proposals

    if [[ $hacloud = 1 ]] ; then
        cluster_node_assignment
    else
        # no cluster for non-HA, but get compute nodes
        unclustered_nodes=`get_all_discovered_nodes`
    fi

    local proposal
    for proposal in nfs_client pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova `horizon_barclamp` ceilometer heat manila trove tempest; do
        deploy_single_proposal $proposal
    done

    set_dashboard_alias
}

function set_node_alias()
{
    local node_name=$1
    local node_alias=$2
    if [[ "${node_name}" != "${node_alias}" ]]; then
        crowbar machines rename ${node_name} ${node_alias}
    fi
}

function set_node_alias_and_role()
{
    local node_name=$1
    local node_alias=$2
    local intended_role=$3
    set_node_alias $node_name $node_alias
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

function get_cluster_vip_hostname()
{
    local cluster=$1
    echo "cluster-$cluster.$cloudfqdn"
}

# An entry in an elements section can have single or multiple nodes or
# a cluster alias.  This function will resolve this element name to a
# node name, or to a hostname for a VIP if the second service
# parameter is non-empty and the element refers to a cluster.
function resolve_element_to_hostname()
{
    local name="$1" service="$2"
    name=`printf "%s\n" "$name" | head -n 1`
    case $name in
        cluster:*)
            local cluster=${name#cluster:}
            if [ -z "$service" ]; then
                get_first_node_from_cluster "$cluster"
            else
                get_cluster_vip_hostname "$cluster"
            fi
        ;;
        *)
            echo $name
        ;;
    esac
}

function get_novacontroller()
{
    local role_prefix=`nova_role_prefix`
    local element=`crowbar nova proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['nova']\
                        ['elements']['$role_prefix-controller']"`
    novacontroller=`resolve_element_to_hostname "$element"`
}

function get_horizon()
{
    local horizon=`horizon_barclamp`
    local element=`crowbar $horizon proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['$horizon']\
                        ['elements']['$horizon-server']"`
    horizonserver=`resolve_element_to_hostname "$element"`
    horizonservice=`resolve_element_to_hostname "$element" service`
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

function get_manila_service_instance_details()
{
    manila_service_vm_uuid=`oncontroller "source .openrc; openstack --os-project-name manila-service server show manila-service -f value -c id"`
    manila_service_vm_ip=`oncontroller "source .openrc; openstack --os-project-name manila-service server show manila-service -f value -c addresses|grep -oP '(?<=\bmanila-service=)[^;]+'"`
    test -n "$manila_service_vm_uuid" || complain 91 "uuid from manila-service instance not available"
    test -n "$manila_service_vm_ip" || complain 92 "ip addr from manila-service instance not available"
}

function addfloatingip()
{
    local instanceid=$1
    nova floating-ip-create | tee floating-ip-create.out
    floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
    nova add-floating-ip "$instanceid" "$floatingip"
}

# by setting --dns-nameserver for subnet, docker instance gets this as
# DNS info (otherwise it would use /etc/resolv.conf from its host)
function adapt_dns_for_docker()
{
    # DNS server is the first IP from the allocation pool, or the
    # second one from the network range
    local dns_server=`neutron subnet-show fixed | grep allocation_pools | cut -d '"' -f4`
    if [ -z "$dns_server" ] ; then
        complain 36 "DNS server info not found. Exiting"
    fi
    neutron subnet-update --dns-nameserver "$dns_server" fixed
}

function glance_image_exists()
{
    openstack image list | grep -q "[[:space:]]$1[[:space:]]"
    return $?
}

function glance_image_get_id()
{
    local image_id=$(openstack image list | grep "[[:space:]]$1[[:space:]]" | awk '{ print $2 }')
    echo $image_id
}

function oncontroller_tempest_cleanup()
{
    if iscloudver 5plus; then
        if tempest help cleanup &>/dev/null; then
            tempest cleanup --delete-tempest-conf-objects
        else
            /usr/bin/tempest-cleanup --delete-tempest-conf-objects || :
        fi
    else
        /var/lib/openstack-tempest-test/bin/tempest_cleanup.sh || :
    fi
}

function oncontroller_run_tempest()
{
    local image_name="SLES11-SP3-x86_64-cfntools"

    # Upload a Heat-enabled image
    if ! glance_image_exists $image_name; then
        curl -s \
            http://$clouddata/images/${image_name}.qcow2 | \
            openstack image create \
                --public --disk-format qcow2 --container-format bare \
                --property hypervisor_type=kvm \
                $image_name | tee glance.out
    fi
    local imageid=$(glance_image_get_id $image_name)
    crudini --set /etc/tempest/tempest.conf orchestration image_ref $imageid
    # test if is cnftools image prepared for tempest
    wait_for 300 5 \
        'openstack image show $imageid | grep active &>/dev/null' \
        "prepare cnftools image"
    pushd /var/lib/openstack-tempest-test
    echo 1 > /proc/sys/kernel/sysrq
    if iscloudver 5plus; then
        if tempest help cleanup; then
            tempest cleanup --init-saved-state
        else
            /usr/bin/tempest-cleanup --init-saved-state || :
        fi
    fi
    ./run_tempest.sh -N $tempestoptions 2>&1 | tee tempest.log
    local tempestret=${PIPESTATUS[0]}
    # tempest returns 0 also if no tests were executed - so use "testr last"
    # to verify that some tests were executed
    if [ "$tempestret" -eq 0 ]; then
        testr last || complain 96 "Tempest run succeeded but something is wrong"
    fi
    testr last --subunit | subunit-1to2 > tempest.subunit.log

    oncontroller_tempest_cleanup
    popd
    return $tempestret
}

function oncontroller_manila_generic_driver_setup()
{
    local service_image_url=http://$clouddata/images/other/manila-service-image.qcow2
    local service_image_name=manila-service-image.qcow2
    local sec_group="manila-service"
    local neutron_net=$sec_group

    wget --progress=dot:mega -nc -O $service_image_name \
        "$service_image_url" || complain 73 "manila image not found"

    . .openrc
    manila_service_tenant_id=`openstack project create manila-service -f value -c id`
    openstack role add --project manila-service --user admin admin
    export OS_TENANT_NAME='manila-service'
    openstack image create --file $service_image_name \
        --disk-format qcow2 manila-service-image --public
    nova flavor-create manila-service-image-flavor 100 256 0 1

    nova secgroup-create $sec_group "$sec_group description"
    nova secgroup-add-rule $sec_group icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule $sec_group tcp 22 22 0.0.0.0/0
    nova secgroup-add-rule $sec_group tcp 2049 2049 0.0.0.0/0
    nova secgroup-add-rule $sec_group udp 2049 2049 0.0.0.0/0
    nova secgroup-add-rule $sec_group udp 445 445 0.0.0.0/0
    nova secgroup-add-rule $sec_group tcp 445 445 0.0.0.0/0
    nova secgroup-add-rule $sec_group tcp 137 139 0.0.0.0/0
    nova secgroup-add-rule $sec_group udp 137 139 0.0.0.0/0
    nova secgroup-add-rule $sec_group tcp 111 111 0.0.0.0/0
    nova secgroup-add-rule $sec_group udp 111 111 0.0.0.0/0

    neutron net-create --tenant-id $manila_service_tenant_id \
        --provider:network_type vlan --provider:physical_network physnet1 \
        --provider:segmentation_id 501 $neutron_net
    neutron subnet-create --allocation-pool start=192.168.180.150,end=192.168.180.200 \
        --name $neutron_net $neutron_net 192.168.180.0/24
    fixed_net_id=`neutron net-show fixed -f value -c id`
    manila_service_net_id=`neutron net-show $neutron_net -f value -c id`
    timeout 10m nova boot --poll --flavor 100 --image manila-service-image \
        --security-groups $sec_group,default \
        --nic net-id=$fixed_net_id \
        --nic net-id=$manila_service_net_id manila-service

    [ $? != 0 ] && complain 43 "nova boot for manila failed"
}

# code run on controller/dashboard node to do basic tests of deployed cloud
# uploads an image, create flavor, boots a VM, assigns a floating IP, ssh to VM, attach/detach volume
function oncontroller_testsetup()
{
    . .openrc
    # 28 is the overhead of an ICMP(ping) packet
    [[ $want_mtu_size ]] && iscloudver 5plus && safely ping -M do -c 1 -s $(( want_mtu_size - 28 )) $adminip
    export LC_ALL=C

    if iscloudver 6plus && \
        ! openstack catalog show manila 2>&1 | grep -q "service manila not found"; then
        manila type-create default false || complain 79 "manila type-create failed"
    fi

    # prepare test image with the -test packages containing functional tests
    if iscloudver 6plus && [[ $cloudsource =~ develcloud ]]; then
        local mount_dir="/var/lib/Cloud-Testing"
        rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12TESTISO" "$mount_dir"
        zypper -n ar --refresh -c -G -f "$mount_dir" cloud-test
        zypper_refresh

        ensure_packages_installed python-novaclient-test python-manilaclient-test
    fi

    if [[ -n $deployswift ]] ; then
        ensure_packages_installed python-swiftclient
        swift stat
        swift upload container1 .ssh/authorized_keys
        swift list container1 || complain 33 "swift list failed"
    fi

    radosgwret=0
    if [ "$wantradosgwtest" == 1 ] ; then

        ensure_packages_installed python-swiftclient

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
        oncontroller_run_tempest
        tempestret=$?
    fi


    nova list
    openstack image list

    local image_name="SP3-64"
    local flavor="m1.smaller"
    local ssh_user="root"

    if ! glance_image_exists $image_name ; then
        # SP3-64 image not found, so uploading it
        if [[ -n "$wanthyperv" ]] ; then
            mount $clouddata:/srv/nfs/ /mnt/
            zypper -n in virt-utils
            qemu-img convert -O vpc /mnt/images/SP3-64up.qcow2 /tmp/SP3.vhd
            openstack image create --public --disk-format vhd --container-format bare --property hypervisor_type=hyperv --file /tmp/SP3.vhd $image_name | tee glance.out
            rm /tmp/SP3.vhd ; umount /mnt
        elif [[ -n "$wantxenpv" ]] ; then
            curl -s \
                http://$clouddata/images/jeos-64-pv.qcow2 | \
                openstack image create --public --disk-format qcow2 \
                --container-format bare --property hypervisor_type=xen \
                --property vm_mode=xen  $image_name | tee glance.out
        else
            curl -s \
                http://$clouddata/images/SP3-64up.qcow2 | \
                openstack image create --public --property hypervisor_type=kvm \
                --disk-format qcow2 --container-format bare $image_name | tee glance.out
        fi
    fi

    #test for Glance scrubber service, added after bnc#930739
    if iscloudver 6plus || [[ $cloudsource =~ develcloud ]]; then
        su - glance -s /bin/sh -c "/usr/bin/glance-scrubber" \
            || complain 113 "Glance scrubber doesn't work properly"
    fi

    if [ -n "$want_docker" ] ; then
        image_name="cirros"
        flavor="m1.tiny"
        ssh_user="cirros"
        if ! glance_image_exists $image_name ; then
            curl -s \
                http://$clouddata/images/docker/cirros.tar | \
            openstack image create --public --container-format docker \
                --disk-format raw --property hypervisor_type=docker  \
                $image_name | tee glance.out
        fi
        adapt_dns_for_docker
    fi

    # wait for image to finish uploading
    imageid=$(glance_image_get_id $image_name)
    if ! [[ $imageid ]]; then
        complain 37 "Image ID for $image_name not found"
    fi

    for n in $(seq 1 200) ; do
        openstack image show $imageid | grep status.*active && break
        sleep 5
    done

    if [[ $want_ldap ]] ; then
        openstack user show bwiedemann | grep -q 82608 || complain 103 "LDAP not working"
    fi

    # wait for nova-manage to be successful
    for n in $(seq 1 200) ;  do
        test "$(nova-manage service list  | fgrep -cv -- \:\-\))" -lt 2 && break
        sleep 1
    done

    nova flavor-delete m1.smaller || :
    nova flavor-create m1.smaller 11 512 8 1
    nova delete testvm  || :
    nova keypair-add --pub_key /root/.ssh/id_rsa.pub testkey
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0
    nova secgroup-add-rule default udp 1 65535 0.0.0.0/0
    timeout 10m nova boot --poll --image $image_name --flavor $flavor --key_name testkey testvm | tee boot.out
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
    wait_for 1000 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm booted and ping returned"
    wait_for 500  1 "netcat -z $vmip 22" "ssh daemon on testvm is accessible"

    local ssh_target="$ssh_user@$vmip"

    wait_for 40 5 "timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $ssh_target true" "SSH key to be copied to VM"

    if ! ssh $ssh_target curl $clouddata/test ; then
        complain 95 could not reach internet
    fi

    local volumecreateret=0
    local volumeattachret=0
    local volumeresult=""

    # do volume tests for non-docker scenario only
    if [ -z "$want_docker" ] ; then
        # Workaround SLE12SP1 regression
        iscloudver 6plus && ssh $ssh_target "modprobe acpiphp"
        cinder list | grep -q available || cinder create 1
        wait_for 9 5 "cinder list | grep available" "volume to become available" "volumecreateret=1"
        volumeid=`cinder list | perl -ne "m/^[ |]*([0-9a-f-]+) [ |]*available/ && print \\$1"`
        nova volume-attach "$instanceid" "$volumeid" /dev/vdb | tee volume-attach.out
        volumeattachret=$?
        device=`perl -ne "m!device [ |]*(/dev/\w+)! && print \\$1" volume-attach.out`
        wait_for 29 5 "cinder show $volumeid | grep 'status.*in-use'" "volume to become attached" "volumeattachret=111"
        ssh $ssh_target fdisk -l $device | grep 1073741824 || volumeattachret=$?
        rand=$RANDOM
        ssh $ssh_target "mkfs.ext3 -F $device && mount $device /mnt && echo $rand > /mnt/test.txt && umount /mnt"
        nova volume-detach "$instanceid" "$volumeid"
        wait_for 29 5 "cinder show $volumeid | grep 'status.*available'" "volume to become available after detach" "volumeattachret=55"
        nova volume-attach "$instanceid" "$volumeid" /dev/vdb
        wait_for 29 5 "cinder show $volumeid | grep 'status.*in-use'" "volume to become reattached" "volumeattachret=56"
        ssh $ssh_target fdisk -l $device | grep 1073741824 || volumeattachret=57
        ssh $ssh_target "mount $device /mnt && grep -q $rand /mnt/test.txt" || volumeattachret=58
        volumeresult="$volumecreateret & $volumeattachret"
    else
        volumeresult="tests skipped (not supported for docker)"
    fi

    # cleanup so that we can run testvm without leaking volumes, IPs etc
    nova remove-floating-ip "$instanceid" "$floatingip"
    nova floating-ip-delete "$floatingip"
    nova stop "$instanceid"
    wait_for 100 1 "test \"x\$(nova show \"$instanceid\" | perl -ne 'm/ status [ |]*([a-zA-Z]+)/ && print \$1')\" == xSHUTOFF" "testvm to stop"

    echo "RadosGW Tests: $radosgwret"
    echo "Tempest: $tempestret"
    echo "Volume in VM: $volumeresult"

    test $tempestret = 0 -a $volumecreateret = 0 -a $volumeattachret = 0 -a $radosgwret = 0 || exit 102
}


function oncontroller()
{
    cd /root
    scp qa_crowbarsetup.sh $mkcconf $novacontroller:
    ssh $novacontroller "export deployswift=$deployswift ; export deployceph=$deployceph ; export wanttempest=$wanttempest ;
        export tempestoptions=\"$tempestoptions\" ; export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ;
        export wantradosgwtest=\"$wantradosgwtest\" ; export cloudsource=\"$cloudsource\" ;
        export libvirt_type=\"$libvirt_type\" ;
        export cloud=$cloud ; export TESTHEAD=$TESTHEAD ;
        . ./qa_crowbarsetup.sh ; onadmin_set_source_variables; $@"
    return $?
}

function install_suse_ca()
{
    # trust build key - workaround https://bugzilla.opensuse.org/show_bug.cgi?id=935020
    wget -O build.suse.de.key.pgp http://download.suse.de/ibs/SUSE:/CA/SLE_12/repodata/repomd.xml.key
    safely sha1sum -c <<EOF
ee896d59206e451d563fcecef72608546bf10ad6  build.suse.de.key.pgp
EOF
    rpm --import build.suse.de.key.pgp

    onadmin_set_source_variables # for $slesdist
    zypper ar --refresh http://download.suse.de/ibs/SUSE:/CA/$slesdist/SUSE:CA.repo
    safely zypper -n in ca-certificates-suse
}

function onadmin_testsetup()
{
    pre_hook $FUNCNAME

    if iscloudver 5plus; then
        cmachines=$(get_all_nodes)
        for machine in $cmachines; do
            knife node show $machine -a node.target_platform | grep -q suse- || continue
            ssh $machine 'dig multi-dns.'"'$cloudfqdn'"' | grep -q 10.11.12.13' ||\
                complain 13 "Multi DNS server test failed!"
        done
    fi

    get_novacontroller
    if [ -z "$novacontroller" ] || ! ssh $novacontroller true ; then
        complain 62 "no nova controller - something went wrong"
    fi
    echo "openstack nova controller node:   $novacontroller"

    get_horizon
    echo "openstack horizon server:  $horizonserver"
    echo "openstack horizon service: $horizonservice"
    curl -L -m 120 -s -S -k http://$horizonservice | \
        grep -q -e csrfmiddlewaretoken -e "<title>302 Found</title>" \
    || complain 101 "simple horizon test failed"

    wantcephtestsuite=0
    if [[ -n "$deployceph" ]]; then
        get_ceph_nodes
        [ "$cephradosgws" = nil ] && cephradosgws=""
        echo "ceph mons:" $cephmons
        echo "ceph osds:" $cephosds
        echo "ceph radosgw:" $cephradosgws
        if [ -n "$cephradosgws" ] ; then
            wantcephtestsuite=1
            wantradosgwtest=1
        fi
    fi

    cephret=0
    if [ -n "$deployceph" -a "$wantcephtestsuite" == 1 ] ; then
        ensure_packages_installed git-core

        if test -d qa-automation; then
            pushd qa-automation
            git reset --hard
            git pull
        else
            install_suse_ca
            safely git clone https://gitlab.suse.de/ceph/qa-automation.git
            safely pushd qa-automation
        fi
        if iscloudver 6plus; then
            git checkout storage2
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
        ceph_version=$(ssh $first_mon_node "rpm -q --qf %{version} ceph | sed 's/+.*//g'")

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
        ensure_packages_installed python-PyYAML python-setuptools

        if iscloudver 6plus; then
            rpm -Uvh http://download.suse.de/ibs/SUSE:/SLE-12:/GA/standard/noarch/python-nose-1.3.0-8.4.noarch.rpm
        else
            if ! rpm -q python-nose &> /dev/null; then
                zypper ar http://download.suse.de/ibs/Devel:/Cloud:/Shared:/11-SP3:/Update/standard/Devel:Cloud:Shared:11-SP3:Update.repo
                ensure_packages_installed python-nose
                zypper rr Devel_Cloud_Shared_11-SP3_Update
            fi
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
        ensure_packages_installed python-boto
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

    # prepare docker image at docker compute nodes
    if iscloudver 5 && [ -n "$want_sles12" ] && [ -n "$want_docker" ] ; then
        for n in `get_docker_nodes` ; do
            ssh $n docker pull cirros
        done
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
        scp $novacontroller:/var/lib/openstack-tempest-test/tempest.log .
        scp $novacontroller:/var/lib/openstack-tempest-test/tempest.subunit.log .
        scp $novacontroller:.openrc .
    fi
    exit $ret
}

function onadmin_addupdaterepo()
{
    pre_hook $FUNCNAME

    local UPR=$tftpboot_repos_dir/Cloud-PTF
    iscloudver 6plus && UPR=$tftpboot_repos12sp1_dir/PTF

    mkdir -p $UPR

    if [[ -n "$UPDATEREPOS" ]]; then
        local repo
        for repo in ${UPDATEREPOS//+/ } ; do
            safely wget --progress=dot:mega \
                -r --directory-prefix $UPR \
                --no-check-certificate \
                --no-parent \
                --no-clobber \
                --accept x86_64.rpm,noarch.rpm \
                ${repo%/}/
        done
        ensure_packages_installed createrepo
        createrepo -o $UPR $UPR || exit 8
    fi
    zypper modifyrepo -e cloud-ptf >/dev/null 2>&1 ||\
        safely zypper ar $UPR cloud-ptf
    safely zypper mr -p 90 cloud-ptf
}

function zypper_patch
{
    wait_for 30 3 ' zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks ref ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
    wait_for 30 3 ' zypper --non-interactive patch ; ret=$?; if [ $ret == 103 ]; then zypper --non-interactive patch ; ret=$?; fi; [[ $ret != 4 ]] ' "successful zypper run" "exit 9"
    wait_for 30 3 ' zypper --non-interactive up --repo cloud-ptf ; [[ $? != 4 ]] ' "successful zypper run" "exit 9"
}

function onadmin_runupdate()
{
    onadmin_repocleanup

    pre_hook $FUNCNAME

    zypper_patch
}

function get_neutron_server_node()
{
    local element=$(crowbar neutron proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['neutron']\
                        ['elements']['neutron-server'][0];")
    NEUTRON_SERVER=`resolve_element_to_hostname "$element"`
}

function onneutron_wait_for_neutron()
{
    get_neutron_server_node

    wait_for 300 3 "ssh $NEUTRON_SERVER 'rcopenstack-neutron status' |grep -q running" "neutron-server service running state"
    wait_for 200 3 " ! ssh $NEUTRON_SERVER '. .openrc && neutron agent-list -f csv --quote none'|tail -n+2 | grep -q -v ':-)'" "neutron agents up"

    ssh $NEUTRON_SERVER '. .openrc && neutron agent-list'
    ssh $NEUTRON_SERVER 'ping -c1 -w1 8.8.8.8' > /dev/null
    if [ "x$?" != "x0" ]; then
        complain 14 "ping to 8.8.8.8 from $NEUTRON_SERVER failed."
    fi
}

function power_cycle_and_wait()
{
    local machine=$1

    ssh $machine "reboot"

    # "crowbar machines list" returns FQDNs but "crowbar node_state status"
    # only hostnames. Get hostname part of FQDN
    m_hostname=$(echo $machine | cut -d '.' -f 1)
    wait_for 400 1 'crowbar node_state status | grep -q -P "$m_hostname\s*Power"' \
        "node $m_hostname to power cycle"
}

function complain_if_problem_on_reboot()
{
    if crowbar node_state status | grep ^d | grep -i "problem$"; then
        complain 17 "Some nodes rebooted with state Problem."
    fi
}

function reboot_controller_clusters()
{
    local cluster
    local machine

    # for HA clusters, we have to reboot each node in the cluster one-by-one to
    # avoid confusing pacemaker
    for cluster in data network services; do
        local clusternodes_var=$(echo clusternodes${cluster})
        for machine in ${!clusternodes_var}; do
            m_hostname=$(echo $machine | cut -d '.' -f 1)
            wait_for 400 5 \
                "ssh $m_hostname 'if \`which drbdadm &> /dev/null\`; then drbd-overview; ! drbdadm dstate all | grep -v UpToDate/UpToDate | grep -q .; fi'" \
                "drbd devices to be consistent on node $m_hostname"
            power_cycle_and_wait $machine
            wait_for 400 5 "crowbar node_state status | grep $m_hostname | grep -qiE \"ready$|problem$\"" "node $m_hostname to be online"
        done
        complain_if_problem_on_reboot
    done
}

# reboot all cloud nodes (controller+compute+storage)
# wait for nodes to go down and come up again
function onadmin_rebootcloud()
{
    pre_hook $FUNCNAME
    get_novacontroller

    local machine

    if [[ $hacloud = 1 ]] ; then
        cluster_node_assignment
        reboot_controller_clusters
    else
        unclustered_nodes=`get_all_discovered_nodes`
    fi

    for machine in $unclustered_nodes; do
        power_cycle_and_wait $machine
    done

    wait_for 400 5 "! crowbar node_state status | grep ^d | grep -vqiE \"ready$|problem$\"" "nodes are back online"

    complain_if_problem_on_reboot

    onadmin_waitcloud
    onneutron_wait_for_neutron
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
    safely nova list
    nova start testvm || complain 28 "Failed to start VM"
    safely nova list
    addfloatingip testvm
    local vmip=`nova show testvm | perl -ne 'm/ fixed.network [ |]*[0-9.]+, ([0-9.]+)/ && print $1'`
    [[ -z "$vmip" ]] && complain 12 "no IP found for instance"
    wait_for 100 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm to boot up"
}

function onadmin_rebootneutron()
{
    pre_hook $FUNCNAME
    get_neutron_server_node
    echo "Rebooting neutron server: $NEUTRON_SERVER ..."

    ssh $NEUTRON_SERVER "reboot"
    wait_for 100 1 " ! netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to go down"
    wait_for 200 3 "netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to be back online"

    onneutron_wait_for_neutron
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

    # change CLOUDSLE11DISTISO/CLOUDSLE11DISTPATH according to the new cloudsource
    onadmin_set_source_variables

    # recreate the SUSE-Cloud Repo with the latest iso
    onadmin_prepare_cloud_repos
    onadmin_add_cloud_repo

    # Applying the updater barclamp (in onadmin_cloudupgrade_clients) triggers
    # a chef-client run on the admin node (even it the barclamp is not applied
    # on the admin node, this is NOT a bug). Let's wait for that to finish
    # before trying to install anything.
    wait_for_if_running chef-client
    zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks refresh -f || complain 3 "Couldn't refresh zypper indexes after adding SUSE-Cloud-$update_version repos"
    ensure_packages_installed suse-cloud-upgrade
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
    ensure_packages_installed crudini
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
    for node in $(get_all_discovered_nodes) ; do
        echo "Enabling VendorChange on $node"
        timeout 60 ssh $node "zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks install crudini; crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true"
    done
}

function onadmin_cloudupgrade_clients()
{
    pre_hook $FUNCNAME
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
    for barclamp in nfs_client pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova `horizon_barclamp` ceilometer heat trove tempest; do
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
        ensure_packages_installed crowbar-barclamp-trove
        do_one_proposal trove default
    elif iscloudver 4; then
        ensure_packages_installed crowbar-barclamp-tempest
        do_one_proposal tempest default
    fi

    # TODO: restart any suspended instance?
}

function onadmin_crowbarbackup()
{
    pre_hook $FUNCNAME
    rm -f /tmp/backup-crowbar.tar.gz
    AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
        bash -x /usr/sbin/crowbar-backup backup /tmp/backup-crowbar.tar.gz ||\
        complain 21 "crowbar-backup backup failed"
}

function onadmin_crowbarpurge()
{
    pre_hook $FUNCNAME
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
    pre_hook $FUNCNAME
    # Need to install the addon again, as we removed it
    zypper --non-interactive in --auto-agree-with-licenses -t pattern cloud_admin

    do_set_repos_skip_checks

    AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
        bash -x /usr/sbin/crowbar-backup restore /tmp/backup-crowbar.tar.gz ||\
        complain 20 "crowbar-backup restore failed"
}

function onadmin_qa_test()
{
    pre_hook $FUNCNAME
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

function onadmin_run_cct()
{
    local ret=0
    if iscloudver 5plus && [[ -n $cct_tests ]]; then
        # - install cct dependencies
        addcctdepsrepo
        ensure_packages_installed git-core gcc make ruby2.1-devel

        local checkout_branch=master
        # checkout branches if needed, otherwise use master
        case "$cloudsource" in
            develcloud5|GM5|GM5+up)
                checkout_branch=cloud5
                ;;
            develcloud6)
                cct_tests+="+features:functional"
                ;;
        esac

        # prepare CCT checkout
        local ghdir=/root/github.com/SUSE-Cloud
        mkdir -p $ghdir
        pushd $ghdir
        git clone https://github.com/SUSE-Cloud/cct.git -b $checkout_branch
        cd cct
        if [[ $want_cct_pr ]] ; then
            git config --get-all remote.origin.fetch | grep -q pull || \
                git config --add remote.origin.fetch "+refs/pull/*/head:refs/remotes/origin/pr/*"
            safely git fetch origin
            # checkout the PR
            safely git checkout -t origin/pr/$want_cct_pr
            # merge the PR to always test what will end up in $checkout_branch
            safely git merge $checkout_branch -m temp-merge-commit
        fi

        # run cct
        bundle install
        local IFS
        IFS='+'
        for test in $cct_tests; do
            bundle exec rake $test
            ret=$?
            [[ $ret != 0 ]] && break
        done
        popd
    fi

    return $ret
}

# Set the aliases for nodes.
# This is usually needed before batch step, so batch can refer
# to node aliases in the scenario file.
function onadmin_setup_aliases()
{
    local nodesavailable=`get_all_discovered_nodes`
    local i=1

    if [ -n "$want_node_aliases" ] ; then
        # aliases provided explicitely, assign them successively to the nodes
        # example: want_node_aliases=controller=1,swift=2,kvm=2

        for aliases in ${want_node_aliases//,/ } ; do

            # split off the number => group
            node_alias=${aliases%=*}
            # split off the group => number
            number=${aliases#*=}

            i=1
            for node in `printf  "%s\n" $nodesavailable | head -n$number`; do
                this_node_alias="$node_alias"
                if [[ $number -gt 1 ]]; then
                    this_node_alias="$node_alias$i"
                fi
                set_node_alias $node $this_node_alias
                nodesavailable=`printf "%s\n" $nodesavailable | grep -iv $node`
                i=$((i+1))
            done
        done
    else
        # try to setup aliases automatically
        if [[ $hacloud = 1 ]] ; then
            # 1. HA
            # use the logic from cluster_node_assignment and assign
            #      dataN, serviceN, networkN aliases
            # for nodes in clusternodesdata etc.

            cluster_node_assignment

            for clustername in data network services ; do
                eval "cluster=\$clusternodes$clustername"
                i=1
                for node in $cluster ; do
                    set_node_alias $node "$clustername$i"
                    i=$((i+1))
                done
            done
            i=1
            for node in $unclustered_nodes ; do
                set_node_alias $node "compute$i"
                i=$((i+1))
            done
        else
            # 2. non-HA
            # 1st node is controller by default (intended role is set by onadmin_allocate)
            local controller=`get_all_discovered_nodes  | head -n1`
            set_node_alias $controller "controller"
            nodesavailable=`printf "%s\n" $nodesavailable | grep -iv $controller`

            i=1
            # storage nodes (cephN or swiftN) will exist based on deployceph/deployswift value
            if [ -n "$deployceph" ] || [ -n "$deployswift" ] ; then
                for node in `get_all_discovered_nodes | grep -v $controller | head -n2` ; do
                    set_node_alias $node "storage$i"
                    nodesavailable=`printf "%s\n" $nodesavailable | grep -iv $node`
                    i=$((i+1))
                done
            fi

            # Use computeN for the rest.
            i=1
            for node in $nodesavailable; do
                set_node_alias $node "compute$i"
                i=$((i+1))
            done
        fi
    fi
    return $?
}

function onadmin_batch()
{
    if iscloudver 5plus; then
        if iscloudver 7plus || (iscloudver 6 && ! [[ $cloudsource =~ ^M[1-8]$ ]]); then
            crowbar_batch --exclude manila --timeout 2400 build ${scenario}
            if grep -q "barclamp: manila" ${scenario}; then
                get_novacontroller
                oncontroller oncontroller_manila_generic_driver_setup
                get_manila_service_instance_details
                sed -i "s/##manila_instance_name_or_id##/$manila_service_vm_uuid/g;s/##service_net_name_or_ip##/$manila_service_vm_ip/g" ${scenario}
                crowbar_batch --include manila --timeout 2400 build ${scenario}
            fi
        else
            crowbar_batch --timeout 2400 build ${scenario}
        fi
        return $?
    else
        complain 116 "crowbar_batch is only supported with cloudversions 5plus"
    fi
}

# deactivate proposals and forget cloud nodes
# can be useful for faster testing cycles
function onadmin_teardown()
{
    pre_hook $FUNCNAME
    #BMCs at ${netp}.178.163-6 #node 6-9
    #BMCs at ${netp}.$net.163-4 #node 11-12

    # undo propsal create+commit
    local service
    for service in `horizon_barclamp` nova glance ceph swift keystone database; do
        crowbar "$service" proposal delete default
        crowbar "$service" delete default
    done

    local node
    for node in $(get_all_discovered_nodes) ; do
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
