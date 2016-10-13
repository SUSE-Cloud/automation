#!/bin/bash
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual

# This has only been tested on aarch64, x86_64 and s390x so far

shopt -s extglob

: ${SCRIPTS_DIR:=$(dirname $(readlink -e $BASH_SOURCE))}
scripts_lib_dir=${SCRIPTS_DIR}/lib
common_scripts="mkcloud-common.sh"
for script in $common_scripts; do
    source ${scripts_lib_dir}/$script
done

mkcconf=mkcloud.config
if [ -z "$testfunc" ] && [ -e $mkcconf ]; then
    source $mkcconf
fi

# this needs to be after mkcloud.config got sourced
if [[ $debug_qa_crowbarsetup = 1 ]] ; then
    set -x
    PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

# defaults
: ${architectures:='aarch64 x86_64 s390x'}
: ${cinder_backend:=''}
: ${cinder_netapp_storage_protocol:=iscsi}
: ${cinder_netapp_login:=openstack}
: ${cinder_netapp_password:=''}
: ${want_rootpw:=linux}
: ${want_raidtype:="raid1"}
: ${want_multidnstest:=1}
: ${want_magnum:=0}
: ${want_barbican:=1}
: ${want_sahara:=1}
: ${want_murano:=0}
: ${want_trove:=1}
: ${want_s390:=''}
: ${want_horizon_integration_test:=''}

if [[ $arch = "s390x" ]] ; then
    want_s390=1
fi

# global variables that are set within this script
novacontroller=
horizonserver=
horizonservice=
manila_service_vm_uuid=
manila_tenant_vm_ip=
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
crowbar_api_digest="--digest -u crowbar:crowbar"
crowbar_install_log=/var/log/crowbar/install.log
crowbar_init_api=http://localhost:4567
crowbar_lib_dir=/var/lib/crowbar
crowbar_api_v2_header="Accept: application/vnd.crowbar.v2.0+json"

export nodenumber=${nodenumber:-2}
export tempestoptions=${tempestoptions:--t -s}
# useful when tempest executes just the smoke tests but
# you want to run some extra (non-smoke) tests
# if set, ostestr is installed and executed with the given params
export ostestroptions=${ostestroptions:-}
export want_sles12
[[ $want_sles12 = 0 ]] && want_sles12=
export nodes=
export cinder_backend
export cinder_netapp_storage_protocol
export cinder_netapp_login
export cinder_netapp_password
export localreposdir_target
export want_ipmi=${want_ipmi:-false}
export want_postgresql=${want_postgresql:-1}
[ -z "$want_test_updates" -a -n "$TESTHEAD" ] && export want_test_updates=1
[ "$libvirt_type" = hyperv ] && export wanthyperv=1
[ "$libvirt_type" = xen ] && export wantxenpv=1 # xenhvm is broken anyway

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

export ZYPP_LOCK_TIMEOUT=120

function horizon_barclamp
{
    if iscloudver 6plus; then
        echo "horizon"
    else
        echo "nova_dashboard"
    fi
}

function nova_role_prefix
{
    if ! iscloudver 6plus ; then
        echo "nova-multi"
    else
        echo "nova"
    fi
}

function onadmin_help
{
    cat <<EOUSAGE
    want_neutronsles12=1 (default 0)
        if there is a SLE12 node, deploy neutron-network role into the SLE12 node
    want_mtu_size=<size> (default='')
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
    want_sbd=1 (default 0)
        Setup SBD over iSCSI for cluster nodes, with iSCSI target on admin node. Only usable for HA configuration.
    want_devel_repos=list of Devel Projects to use for other products
        Adds Devel Projects for other products on deployed nodes
        Example:
            want_devel_repos=storage,virt
        Valid values: ha, storage, virt
EOUSAGE
}

# run hook code before the actual script does its function
# example usage: export pre_do_installcrowbar=$(base64 -w 0 <<EOF
# echo foo
# EOF
# )
function pre_hook
{
    func=$1
    pre=$(eval echo \$pre_$func | base64 -d)
    setcloudnetvars $cloud
    test -n "$pre" && eval "$pre"
    echo $func >> /root/qa_crowbarsetup.steps.log
}

function mount_localreposdir_target
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

function add_bind_mount
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

function add_nfs_mount
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
function add_mount
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

function isupgradecloudver
{
    local cloudsource=$upgrade_cloudsource
    iscloudver "$@"
}

function issusenode
{
    local machine=$1
    [[ $machine =~ ^crowbar\. ]] && return 0
    knife node show $machine -a node.target_platform | grep -q suse-
}

function openstack
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

function isrepoworking
{
    local repo=$1
    curl -s http://$clouddata/repos/disabled | egrep -q "^$repo" && {
        echo "WARNING: The repo $repo is marked as broken"
        return 1
    }
    return 0
}

function export_tftpboot_repos_dir
{
    tftpboot_repos_dir=/srv/tftpboot/repos
    tftpboot_suse_dir=/srv/tftpboot/suse-11.3

    if iscloudver 5; then
        tftpboot_repos_dir=$tftpboot_suse_dir/repos
        tftpboot_suse12_dir=/srv/tftpboot/suse-12.0
        tftpboot_repos12_dir=$tftpboot_suse12_dir/repos
    elif iscloudver 7plus ; then
        tftpboot_suse12sp2_dir=/srv/tftpboot/suse-12.2
        tftpboot_repos12sp2_dir=$tftpboot_suse12sp2_dir/$arch/repos
        # We need SP1 repositories for ceph nodes
        tftpboot_suse12sp1_dir=/srv/tftpboot/suse-12.1
        tftpboot_repos12sp1_dir=$tftpboot_suse12sp1_dir/$arch/repos
    elif iscloudver 6plus; then
        tftpboot_suse12sp1_dir=/srv/tftpboot/suse-12.1
        tftpboot_repos12sp1_dir=$tftpboot_suse12sp1_dir/$arch/repos
    fi
}

function addsp3testupdates
{
    add_mount "SLES11-SP3-Updates" \
        $clouddata':/srv/nfs/repos/SLES11-SP3-Updates/' \
        "$tftpboot_repos_dir/SLES11-SP3-Updates/" "sp3up"
    add_mount "SLES11-SP3-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/11-SP3:/x86_64/update/' \
        "$tftpboot_repos_dir/SLES11-SP3-Updates-test/" "sp3tup"
    [[ $hacloud = 1 ]] && add_mount "SLE11-HAE-SP3-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-HAE:/11-SP3:/x86_64/update/' \
        "$tftpboot_repos_dir/SLE11-HAE-SP3-Updates-test/"
}

function addsles12testupdates
{
    add_mount "SLES12-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12:/x86_64/update/' \
        "$tftpboot_repos12_dir/SLES12-Updates-test/"
    if [ -n "$deployceph" ]; then
        add_mount "SUSE-Enterprise-Storage-1.0-Updates-test" \
            $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/Storage:/1.0:/x86_64/update/' \
            "$tftpboot_repos12_dir/SUSE-Enterprise-Storage-1.0-Updates-test/"
    fi
}

function addsles12sp1testupdates
{
    if isrepoworking SLES12-SP1-Updates-test ; then
        add_mount "SLES12-SP1-Updates-test" \
            $distsuseip":/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP1:/$arch/update/" \
            "$tftpboot_repos12sp1_dir/SLES12-SP1-Updates-test/" "sles12sp1tup"
    fi
    if isrepoworking SLE12-SP1-HA-Updates-test ; then
        [[ $hacloud = 1 ]] && add_mount "SLE12-SP1-HA-Updates-test" \
            $distsuseip":/dist/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP1:/$arch/update/" \
            "$tftpboot_repos12sp1_dir/SLE12-SP1-HA-Updates-test/"
    fi
    if isrepoworking SUSE-Enterprise-Storage-2.1-Updates-test ; then
        [ -n "$deployceph" -a iscloudver 6 ] && add_mount "SUSE-Enterprise-Storage-2.1-Updates-test" \
            $distsuseip":/dist/ibs/SUSE:/Maintenance:/Test:/Storage:/2.1:/$arch/update/" \
            "$tftpboot_repos12sp1_dir/SUSE-Enterprise-Storage-2.1-Updates-test/"
    fi
    if isrepoworking SUSE-Enterprise-Storage-3-Updates-test ; then
        [ -n "$deployceph" -a iscloudver 7plus ] && add_mount "SUSE-Enterprise-Storage-3-Updates-test" \
            $distsuseip":/dist/ibs/SUSE:/Maintenance:/Test:/Storage:/3:/$arch/update/" \
            "$tftpboot_repos12sp1_dir/SUSE-Enterprise-Storage-3-Updates-test/"
    fi
}

function addsles12sp2testupdates
{
    echo "Enable SLES12SP2 Test Updates once available"
    # add_mount "SLES12-SP2-Updates-test" \
    #     $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP2:/x86_64/update/' \
    #     "$tftpboot_repos12sp2_dir/SLES12-SP2-Updates-test/" "sles12sp2tup"
    # [[ $hacloud = 1 ]] && add_mount "SLE12-SP2-HA-Updates-test" \
    #     $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP2:/x86_64/update/' \
    #     "$tftpboot_repos12sp2_dir/SLE12-SP2-HA-Updates-test/"
}

function addcloud4maintupdates
{
    add_mount "SUSE-Cloud-4-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-4-Updates/' \
        "$tftpboot_repos_dir/SUSE-Cloud-4-Updates/" "cloudmaintup"
}

function addcloud4testupdates
{
    add_mount "SUSE-Cloud-4-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/4:/x86_64/update/' \
        "$tftpboot_repos_dir/SUSE-Cloud-4-Updates-test/" "cloudtup"
}

function addcloud5maintupdates
{
    add_mount "SUSE-Cloud-5-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-Updates/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Updates/" \
        "cloudmaintup"
    add_mount "SUSE-Cloud-5-SLE-12-Updates" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-SLE-12-Updates/' \
        "$tftpboot_repos12_dir/SLE-12-Cloud-Compute5-Updates/"
}

function addcloud5testupdates
{
    add_mount "SUSE-Cloud-5-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/SUSE-CLOUD:/5:/x86_64/update/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Updates-test/" "cloudtup"
    add_mount "SUSE-Cloud-5-SLE-12-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/12-Cloud-Compute:/5:/x86_64/update' \
        "$tftpboot_repos12_dir/SLE-12-Cloud-Compute5-Updates-test/"
}

function addcloud5pool
{
    add_mount "SUSE-Cloud-5-Pool" \
        $clouddata':/srv/nfs/repos/SUSE-Cloud-5-Pool/' \
        "$tftpboot_repos_dir/SUSE-Cloud-5-Pool/" \
        "cloudpool"
}

function addcloud6maintupdates
{
    add_mount "SUSE-OpenStack-Cloud-6-Updates" $clouddata':/srv/nfs/repos/SUSE-OpenStack-Cloud-6-Updates/' "$tftpboot_repos12sp1_dir/SUSE-OpenStack-Cloud-6-Updates/" "cloudmaintup"
}

function addcloud6testupdates
{
    add_mount "SUSE-OpenStack-Cloud-6-Updates-test" \
        $distsuseip':/dist/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/6:/x86_64/update/' \
        "$tftpboot_repos12sp1_dir/SUSE-OpenStack-Cloud-6-Updates-test/" "cloudtup"
}

function addcloud6pool
{
    add_mount "SUSE-OpenStack-Cloud-6-Pool" $clouddata':/srv/nfs/repos/SUSE-OpenStack-Cloud-6-Pool/' "$tftpboot_repos12sp1_dir/SUSE-OpenStack-Cloud-6-Pool/" "cloudpool"
}

function addcctdepsrepo
{
    if [[ $cloudsource = @(develcloud5|GM5|GM5+up) ]]; then
        zypper ar -f http://$susedownload/ibs/Devel:/Cloud:/Shared:/Rubygem/SLE_11_SP3/Devel:Cloud:Shared:Rubygem.repo
    else
        add_sdk_repo
    fi
}

function add_sdk_repo
{
    case "$cloudsource" in
        develcloud6|GM6|GM6+up)
            zypper ar -f http://$susedownload/update/build.suse.de/SUSE/Products/SLE-SDK/12-SP1/$arch/product/ SDK-SP1
            zypper ar -f http://$susedownload/update/build.suse.de/SUSE/Updates/SLE-SDK/12-SP1/$arch/update/ SDK-SP1-Update
            ;;
        develcloud7|newtoncloud7|susecloud7|M?|Beta*|RC*|GMC*)
            zypper ar -f http://$susedownload/update/build.suse.de/SUSE/Products/SLE-SDK/12-SP2/x86_64/product/ SDK-SP2
            zypper ar -f http://$susedownload/update/build.suse.de/SUSE/Updates/SLE-SDK/12-SP2/x86_64/update/ SDK-SP2-Update
            ;;
    esac
}

function add_ha_repo
{
    local repo
    for repo in SLE11-HAE-SP3-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo/sle-11-x86_64" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos_dir/$repo"
    done
}

function add_ha12sp1_repo
{
    local repo
    for repo in SLE12-SP1-HA-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12sp1_dir/$repo"
    done
}

function add_ha12sp2_repo
{
    local repo
    for repo in SLE12-SP2-HA-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "$repo" "$clouddata:/srv/nfs/repos/$arch/$repo" \
            "$tftpboot_repos12sp2_dir/$repo"
    done
}

function add_suse_storage_repo
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
        if iscloudver 6; then
            for repo in SUSE-Enterprise-Storage-2.1-{Pool,Updates}; do
                # Note no zypper alias parameter here since we don't want
                # to zypper addrepo on the admin node.
                add_mount "$repo" "$clouddata:/srv/nfs/repos/$repo" \
                    "$tftpboot_repos12sp1_dir/$repo"
            done
        fi
        if iscloudver 7plus; then
            for repo in SUSE-Enterprise-Storage-3-{Pool,Updates}; do
                # Note no zypper alias parameter here since we don't want
                # to zypper addrepo on the admin node.
                add_mount "$repo" "$clouddata:/srv/nfs/repos/$arch/$repo" \
                    "$tftpboot_repos12sp1_dir/$repo"
            done
        fi
}

function get_disk_id_by_serial_and_libvirt_type
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

function get_all_nodes
{
    if iscloudver 6plus; then
        safely crowbarctl node list --no-meta --plain | LC_ALL=C sort
    else
        safely crowbar machines list | LC_ALL=C sort
    fi
}

function get_all_suse_nodes
{
    for m in $(get_all_nodes) ; do
        issusenode "$m" || continue
        echo "$m"
    done
}

function get_all_discovered_nodes
{
    # names of discovered nodes start with 'd'
    # so it is excluding the crowbar node
    get_all_nodes | grep "^d"
}

function get_crowbar_node
{
    # crowbar node may have any name, so better use grep -v
    # and make sure it is only one
    get_all_nodes | grep -v "^d" | head -n 1
}

function get_unclustered_sles12plus_nodes
{
    local target="suse-12.0"
    iscloudver 6 && target="suse-12.1"
    iscloudver 7plus && target="suse-12.2"

    sles12plusnodes=($(knife search node "target_platform:$target AND NOT crowbar_admin_node:true" -a name | grep ^name: | cut -d : -f 2 | sort | sed 's/\s//g'))
    if [[ $hacloud = 1 ]]; then
        # This basically does an intersection of the lists in sles12plusnode and unclustered_node
        # i.e. pick all sles12plus nodes that are not part of a cluster
        sles12plusnodes=$(comm -1 -2 <(printf "%s\n" ${sles12plusnodes[@]}) <(printf "%s\n" $unclustered_nodes))
    fi
    echo $sles12plusnodes
}


function get_docker_nodes
{
    knife search node "roles:`nova_role_prefix`-compute-docker" -a name | grep ^name: | cut -d : -f 2 | sort | sed 's/\s//g'
}

function remove_node_from_list
{
    local onenode="$1"
    local list="$@"
    printf "%s\n" $list | grep -iv "$onenode"
}

function cluster_node_assignment
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
                echo "Claiming disk for DRBD on node: $node"

                # assign drbd volume via knife
                knife exec -E "
                    nodes.find(:name => '${node}').each do |n|
                        if n['crowbar_wall']['claimed_disks']
                            n['crowbar_wall']['claimed_disks'].each do |k,v|
                                next if v.is_a? Hash and v['owner'] !~ /LVM_DRBD/;
                                n['crowbar_wall']['claimed_disks'].delete(k);
                            end
                        else
                            n['crowbar_wall']['claimed_disks'] = {}
                        end
                        n['crowbar_wall']['claimed_disks']['/dev/disk/by-id/$(get_disk_id_by_serial_and_libvirt_type "$libvirt_type" "$serial")']={'owner' => 'LVM_DRBD'};
                        n.save
                    end
                "
            fi
        done
    done

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

function onadmin_prepare_sles11sp3_repos
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
        for repo in SLES11-SP3-Pool SLES11-SP3-Updates ; do
            local zypprepo=""
            [ "$WITHSLEUPDATES" != "" ] && zypprepo="$repo"
            add_mount "$zypprepo" \
                "$clouddata:/srv/nfs/repos/$repo" \
                "$tftpboot_repos_dir/$repo"
        done

        # fallback: download the image and mount it if NFS mount didn't work
        if [ ! -e "$targetdir_install/media.1/" ]; then
            local iso_file=SLES-$slesversion-DVD-x86_64-$slesmilestone-DVD1.iso
            rsync_iso "install/SLES-$slesversion-$slesmilestone/$iso_file" $iso_file $targetdir_install
        fi
    fi

    if [ ! -e "${targetdir_install}/media.1/" ] ; then
        complain 34 "We do not have SLES install media - giving up"
    fi
}

function rsync_iso
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

function onadmin_prepare_sles12sp1_repos
{
    onadmin_prepare_sles12sp1_installmedia
    onadmin_prepare_sles12sp1_other_repos
}

function onadmin_prepare_sles12sp2_repos
{
    onadmin_prepare_sles12sp2_installmedia
    onadmin_prepare_sles12sp2_other_repos
}

function onadmin_prepare_sles12plus_cloud_repos
{
    if iscloudver 5; then
        rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12DISTISO" "$tftpboot_repos12_dir/SLE12-Cloud-Compute"
    fi

    #  create empty repository when there is none yet
    ensure_packages_installed createrepo

    local sles12optionalrepolist
    local targetdir
    if iscloudver 7plus; then
        sles12optionalrepolist=(
            SUSE-OpenStack-Cloud-7-Pool
            SUSE-OpenStack-Cloud-7-Updates
        )
        targetdir="$tftpboot_repos12sp2_dir"
    elif iscloudver 6; then
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

function onadmin_prepare_sles12_installmedia
{
    local sles12_mount="$tftpboot_suse12_dir/install"
    add_mount "SLE-12-Server-LATEST/sle-12-x86_64" \
        "$clouddata:/srv/nfs/suse-12.0/install" \
        "$sles12_mount"

    if [ ! -d "$sles12_mount/media.1" ] ; then
        complain 34 "We do not have SLES12 install media - giving up"
    fi
}

function onadmin_prepare_sles12sp1_installmedia
{
    local a
    for a in $architectures; do
        local sles12sp1_mount="$tftpboot_suse12sp1_dir/$a/install"
        add_mount "SLE-12-SP1-Server-LATEST/sle-12-$a" \
            "$clouddata:/srv/nfs/suse-12.1/$a/install" \
            "$sles12sp1_mount"

        if [ ! -d "$sles12sp1_mount/media.1" ] ; then
            complain 34 "We do not have SLES12 SP1 install media - giving up"
        fi
    done
}

function onadmin_prepare_sles12sp2_installmedia
{
    local a
    for a in $architectures; do
        local sles12sp2_mount="$tftpboot_suse12sp2_dir/$a/install"
        add_mount "SLE-12-SP2-Server-TEST/sle-12-$a" \
            "$clouddata:/srv/nfs/suse-12.2/$a/install" \
            "$sles12sp2_mount"

        if [ ! -d "$sles12sp2_mount/media.1" ] ; then
            complain 34 "We do not have SLES12 SP2 install media - giving up"
        fi
    done
}

function onadmin_prepare_sles12_other_repos
{
    for repo in SLES12-{Pool,Updates}; do
        add_mount "$repo/sle-12-x86_64" "$clouddata:/srv/nfs/repos/$repo" \
            "$tftpboot_repos12_dir/$repo"
    done
}

function onadmin_prepare_sles12sp1_other_repos
{
    for repo in SLES12-SP1-{Pool,Updates}; do
        add_mount "$repo/sle-12-$arch" "$clouddata:/srv/nfs/repos/$arch/$repo" \
            "$tftpboot_repos12sp1_dir/$repo"
        if [[ $want_s390 ]] ; then
            add_mount "$repo/sle-12-s390x" "$clouddata:/srv/nfs/repos/s390x/$repo" \
                "$tftpboot_suse12sp1_dir/s390x/repos/$repo"
        fi
    done
}

function onadmin_prepare_sles12sp2_other_repos
{
    for repo in SLES12-SP2-{Pool,Updates}; do
        add_mount "$repo/sle-12-$arch" "$clouddata:/srv/nfs/repos/$arch/$repo" \
            "$tftpboot_repos12sp2_dir/$repo"
        if [[ $want_s390 ]] ; then
            add_mount "$repo/sle-12-s390x" "$clouddata:/srv/nfs/repos/s390x/$repo" \
                "$tftpboot_suse12sp2_dir/s390x/repos/$repo"
        fi
    done
}

function onadmin_prepare_cloud_repos
{
    local targetdir=
    if iscloudver 7plus; then
        targetdir="$tftpboot_repos12sp2_dir/Cloud"
    elif iscloudver 6plus; then
        targetdir="$tftpboot_repos12sp1_dir/Cloud"
    else
        targetdir="$tftpboot_repos_dir/Cloud/"
    fi
    mkdir -p ${targetdir}

    if [ -n "${localreposdir_target}" ]; then
        if iscloudver 6plus; then
            add_bind_mount \
                "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-12-$arch/" \
                "${targetdir}"
        else
            add_bind_mount \
                "${localreposdir_target}/${CLOUDLOCALREPOS}/sle-11-$arch/" \
                "${targetdir}"
        fi
    else
        if iscloudver 6plus; then
            rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12DISTISO" "$targetdir"
            if [[ $want_s390 ]] ; then
                rsync_iso "$CLOUDSLE12DISTPATH" "${CLOUDSLE12DISTISO/$arch/s390x}" "${targetdir/$arch/s390x}"
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
        case "$cloudsource" in
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
                addsles12sp1testupdates
                ;;
            GM6+up)
                addsles12sp1testupdates
                addcloud6testupdates
                ;;
            develcloud4)
                addsp3testupdates
                ;;
            develcloud5)
                addsp3testupdates
                addsles12testupdates
                ;;
            develcloud6)
                addsles12sp1testupdates
                ;;
            develcloud7|newtoncloud7|susecloud7|M?|Beta*|RC*|GMC*)
                addsles12sp2testupdates
                ;;
            *)
                complain 26 "no test update repos defined for cloudsource=$cloudsource"
                ;;
        esac
    fi
}


function onadmin_add_cloud_repo
{
    local targetdir=
    if iscloudver 7plus; then
        targetdir="$tftpboot_repos12sp2_dir/Cloud/"
    elif iscloudver 6plus; then
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
    if [[ $UPDATEREPOS ]]; then
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


function do_set_repos_skip_checks
{
    # We don't use the proper pool/updates repos when using a devel build
    if iscloudver 5plus && [[ $cloudsource =~ (develcloud|GM5$|GM6$) ]]; then
        export REPOS_SKIP_CHECKS+=" SUSE-Cloud-$(getcloudver)-Pool SUSE-Cloud-$(getcloudver)-Updates"
    fi
}


function create_repos_yml_for_platform
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
        if [ -z "$platform_created" ]; then
            echo "$platform:"
            echo "  $arch:"
            platform_created=1
        fi

        echo "    $repo_name:"
        echo "      url: '$repo_url'"
    done
}

function create_repos_yml
{
    local repos_yml="/etc/crowbar/repos.yml"
    local tmp_yml=$(mktemp).yml
    local additional_repos=

    echo --- > $tmp_yml

    # Clone test updates from admin node
    ### FIXME: point to provisioner urls from admin node rather than direct links
    grep -q SLES12-SP1-Updates-test /etc/fstab && \
        additional_repos+=" SLES12-SP1-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP1:/x86_64/update/"
    grep -q SLES12-SP2-Updates-test /etc/fstab && \
        additional_repos+=" SLES12-SP2-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-SERVER:/12-SP2:/x86_64/update/"
    grep -q SUSE-OpenStack-Cloud-6-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-OpenStack-Cloud-6-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/6:/x86_64/update/"
    grep -q SUSE-OpenStack-Cloud-7-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-OpenStack-Cloud-7-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/OpenStack-Cloud:/7:/x86_64/update/"
    grep -q SLE12-SP1-HA-Updates-test /etc/fstab && \
        additional_repos+=" SLE12-SP1-HA-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP1:/x86_64/update/"
    grep -q SLE12-SP2-HA-Updates-test /etc/fstab && \
        additional_repos+=" SLE12-SP2-HA-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/SLE-HA:/12-SP2:/x86_64/update/"
    grep -q SUSE-Enterprise-Storage-2.1-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-Enterprise-Storage-2.1-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/2.1:/x86_64/update/"
    grep -q SUSE-Enterprise-Storage-3-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-Enterprise-Storage-3-Updates-test=http://$distsuse/ibs/SUSE:/Maintenance:/Test:/Storage:/3:/x86_64/update/"

    if iscloudver 6; then
        for devel_repo in ${want_devel_repos//,/ }; do
            case "$devel_repo" in
                storage)
                    additional_repos+=" Devel-Storage=http://$distsuse/ibs/Devel:/Storage:/2.1/SLE12_SP1/"
                    ;;
                virt)
                    additional_repos+=" Devel-Virt=http://$distsuse/ibs/Devel:/Virt:/SLE-12-SP1/SUSE_SLE-12-SP1_Update_standard/"
                    ;;
                *)
                    complain 72 "do not know how to translate one of the requested devel repos: $want_devel_repos"
                    ;;
            esac
        done
        create_repos_yml_for_platform "suse-12.1" "x86_64" "$tftpboot_repos12sp1_dir" \
            $additional_repos \
            >> $tmp_yml
    fi

    if iscloudver 7; then
        for devel_repo in ${want_devel_repos//,/ }; do
            case "$devel_repo" in
                storage)
                    # FIXME: enable when switching from SES 3 to SES 4
                    # additional_repos+=" Devel-Storage=http://$distsuse/ibs/Devel:/Storage:/4.0/SLE12_SP2/"
                    ;;
                virt)
                    additional_repos+=" Devel-Virt=http://$distsuse/ibs/Devel:/Virt:/SLE-12-SP2/SUSE_SLE-12-SP2_GA_standard/"
                    ;;
                *)
                    complain 72 "do not know how to translate one of the requested devel repos: $want_devel_repos"
                    ;;
            esac
        done
        create_repos_yml_for_platform "suse-12.2" "x86_64" "$tftpboot_repos12sp2_dir" \
            $additional_repos \
            >> $tmp_yml
    fi

    mv $tmp_yml $repos_yml
}


function onadmin_set_source_variables
{
    if iscloudver 7plus && [ -z "$want_sles12sp1_admin" ]; then
        suseversion=12.2
    elif iscloudver 6plus; then
        suseversion=12.1
    else
        suseversion=11.3
    fi

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
        develcloud7)
            CLOUDSLE12DISTPATH=/ibs/Devel:/Cloud:/7/images/iso
            [ -n "$TESTHEAD" ] && CLOUDSLE12DISTPATH=/ibs/Devel:/Cloud:/7:/Staging/images/iso
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-7-$arch*Media1.iso"
            CLOUDSLE12TESTISO="CLOUD-7-TESTING-$arch*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-devel"
        ;;
        newtoncloud7)
            CLOUDSLE12DISTPATH=/ibs/Devel:/Cloud:/7:/Newton/images/iso
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-7-$arch*Media1.iso"
            CLOUDSLE12TESTISO="CLOUD-7-TESTING-$arch*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-official"
        ;;
        susecloud7)
            CLOUDSLE12DISTPATH=/ibs/SUSE:/SLE-12-SP2:/Update:/Products:/Cloud7/images/iso/
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-7-$arch*Media1.iso"
            CLOUDSLE12TESTISO="CLOUD-7-TESTING-$arch*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-official"
        ;;
        GM4+up)
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
        GM6|GM6+up)
            cs=$cloudsource
            [[ $cs =~ GM6 ]] && cs=GM
            CLOUDSLE12DISTPATH=/install/SLE-12-SP1-Cloud6-$cs/
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-6-$arch*1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-official"
        ;;
        M?)
            cs=${cloudsource//M/Milestone}
            CLOUDSLE12DISTPATH=/install/SLE-12-SP2-Cloud7-$cs/
            CLOUDSLE12DISTISO="SUSE-OPENSTACK-CLOUD-7-$arch*1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-official"
        ;;
        *)
            complain 76 "You must set environment variable cloudsource=develcloud4|develcloud5|develcloud6|develcloud7|susecloud7|GM4+up|GM5|Mx|GM6"
        ;;
    esac

    [ -n "$TESTHEAD" ] && CLOUDLOCALREPOS="$CLOUDLOCALREPOS-staging"

    case "$suseversion" in
        11.3)
            slesversion=11-SP3
            slesdist=SLE_11_SP3
            slesmilestone=GM
        ;;
        12.1)
            slesversion=12-SP1
            slesdist=SLE_12_SP1
            slesmilestone=GM
        ;;
        12.2)
            slesversion=12-SP2
            slesdist=SLE_12_SP2
            slesmilestone=GM
        ;;
    esac
}


function onadmin_repocleanup
{
    # Workaround broken admin image that has SP3 Test update channel enabled
    zypper mr -d sp3tup
    # disable extra repos
    zypper mr -d sp3sdk
}

# replace zypper repos from the image with user-specified ones
# because clouddata might not be reachable from where this runs
function onadmin_setup_local_zypper_repositories
{
    # Delete all repos except PTF repo, because this could
    # be called after the addupdaterepo step.
    zypper lr -e - | sed -n '/^name=/ {s///; /ptf/! p}' | \
        xargs -r zypper rr

    uri_base="http://${clouddata}${clouddata_base_path}"
    # restore needed repos depending on localreposdir_target
    if [ -n "${localreposdir_target}" ]; then
        mount_localreposdir_target
        uri_base="file:///repositories"
    fi
    case $(getcloudver) in
        4|5)
            zypper ar $uri_base/SLES11-SP3-Pool/ sles11sp3
            zypper ar $uri_base/SLES11-SP3-Updates/ sles11sp3up
        ;;
        6)
            zypper ar $uri_base/SLES12-SP1-Pool/ sles12sp1
            zypper ar $uri_base/SLES12-SP1-Updates/ sles12sp1up
        ;;
        7)
            if [ "$want_sles12sp1_admin" == 1 ]; then
                zypper ar $uri_base/$arch/SLES12-SP1-Pool/ sles12sp1
                zypper ar $uri_base/$arch/SLES12-SP1-Updates/ sles12sp1up
            else
                zypper ar $uri_base/$arch/SLES12-SP2-Pool/ sles12sp2
                zypper ar $uri_base/$arch/SLES12-SP2-Updates/ sles12sp2up
            fi
        ;;
    esac
}

# setup network/DNS, add repos and install crowbar packages
function onadmin_prepareinstallcrowbar
{
    pre_hook $FUNCNAME
    [[ $forcephysicaladmin ]] || lsmod | grep -q ^virtio_blk || complain 25 "this script should be run in the crowbar admin VM"
    [[ $want_ssl_keys ]] && rsync -a "$want_ssl_keys/" /root/cloud-keys/
    onadmin_repocleanup
    [[ $want_rootpw = linux ]] || echo -e "$want_rootpw\n$want_rootpw" | passwd
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
    # $clouddata is treated as a URL fragment in other places, grab only
    # the host portion.
    clouddata_host=$(echo $clouddata | cut -d/ -f1)
    if [[ $(ping -q -c1 $clouddata_host |
            perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]]
    then
        longdistance=true
    fi

    onadmin_set_source_variables
    onadmin_setup_local_zypper_repositories

    if iscloudver 7plus; then
        # Still needed for SUSE Storage :(
        onadmin_prepare_sles12sp1_repos
        onadmin_prepare_sles12sp2_repos
        onadmin_prepare_sles12plus_cloud_repos
    elif iscloudver 6plus ; then
        onadmin_prepare_sles12sp1_repos
        onadmin_prepare_sles12plus_cloud_repos
    else
        onadmin_prepare_sles11sp3_repos

        if iscloudver 5plus ; then
            onadmin_prepare_sles12_installmedia
            onadmin_prepare_sles12_other_repos
            onadmin_prepare_sles12plus_cloud_repos
        fi
    fi

    if [[ $hacloud = 1 ]]; then
        if [ "$slesdist" = "SLE_11_SP3" ] && iscloudver 4plus ; then
            add_ha_repo
        elif iscloudver 7plus; then
            add_ha12sp2_repo
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
    zypper -n dup --no-recommends -r Cloud -r cloudtup || zypper -n dup --no-recommends -r Cloud
    zypper rl kernel-default

    # Workaround chef-solr crashes
    if [ "$arch" = "aarch64" ]; then
        ensure_packages_installed java-1_7_0-openjdk java-1_7_0-openjdk-headless
    fi

    if [ -z "$NOINSTALLCLOUDPATTERN" ] ; then
        safely zypper --no-gpg-checks -n in -l -t pattern cloud_admin
        # make sure to use packages from PTF repo (needs zypper dup)
        zypper mr -e cloud-ptf && safely zypper -n dup --from cloud-ptf
    fi

    # Workaround broken sleshammer
    if [ "$arch" = "aarch64" ]; then
        rpm -Uvh --force http://clouddata.cloud.suse.de/suse-12.1/aarch64/PTF/sleshammer-aarch64.rpm
    fi

    cd /tmp

    local netfile="/etc/crowbar/network.json"

    local netfilepatch=`basename $netfile`.patch
    [ -e ~/$netfilepatch ] && patch -p1 $netfile < ~/$netfilepatch

    # to revert https://github.com/crowbar/barclamp-network/commit/a85bb03d7196468c333a58708b42d106d77eaead
    sed -i.netbak1 -e 's/192\.168\.126/192.168.122/g' $netfile

    sed -i.netbak -e 's/"conduit": "bmc",$/& "router": "192.168.124.1",/' \
        -e "s/192.168.124/$net/g" \
        -e "s/192.168.130/$net_sdn/g" \
        -e "s/192.168.125/$net_storage/g" \
        -e "s/192.168.123/$net_fixed/g" \
        -e "s/192.168.122/$net_public/g" \
        -e "s/ 200/ $vlan_storage/g" \
        -e "s/ 300/ $vlan_public/g" \
        -e "s/ 500/ $vlan_fixed/g" \
        -e "s/ [47]00/ $vlan_sdn/g" \
        $netfile

    if [[ $cloud = p || $cloud = p2 ]] ; then
        # production cloud has a /22 network
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.netmask -v 255.255.252.0 $netfile
    fi
    if [[ $cloud =~ qa ]] ; then
        # QA clouds have too few IP addrs, so smaller subnets are used
        wget -O$netfile http://gate.cloud2adm.qa.suse.de/network.json/${cloud}_dual
        if iscloudver 6plus; then
            sed -i 's/bc-template-network/template-network/' $netfile
        fi
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
    # Setup network attributes for custom MTU
    if [[ $want_mtu_size -gt 1500 ]]; then
        echo "Setting MTU to custom value of: $want_mtu_size"
        local lnet
        for lnet in admin storage os_sdn ; do
            /opt/dell/bin/json-edit -a attributes.network.networks.$lnet.mtu -r -v $want_mtu_size $netfile
        done
    fi

    # to allow integration into external DNS:
    local f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
    grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

    if iscloudver 6plus ; then
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
    return 0
}

function install_crowbar_init
{
    local apacheconfdir=/etc/apache2/conf.d

    # FIXME: this is temporary until the package is doing that
    # it is currently disabled by default not to break Crowbar
    if [[ $want_postgresql = 0 ]] ; then
        ln -sf $apacheconfdir/crowbar-rails.conf.partial $apacheconfdir/crowbar.conf.partial
    else
        ln -sf $apacheconfdir/crowbar-sinatra.conf.partial $apacheconfdir/crowbar.conf.partial
    fi
    systemctl start crowbar-init
    wait_for 100 3 "onadmin_is_crowbar_init_api_available" "crowbar init service to start"
}

function onadmin_activate_repositories
{
    if iscloudver 5minus; then
        complain 11 "This upgrade path is only supported for Cloud 6+"
    fi

    # activate provisioner repos, so that nodes can use them
    safely crowbar_api_request POST $crowbar_api "/utils/repositories/activate_all.json"
}

function onadmin_bootstrapcrowbar
{
    local upgrademode=$1
    # temporarily make it possible to not use postgres until we switched to the new upgrade process
    # otherwise we would break the upgrade gating
    [[ $want_postgresql = 0 ]] && return
    if iscloudver 7plus ; then
        install_crowbar_init
        if [[ $upgrademode = "with_upgrade" ]] ; then
            safely crowbarctl upgrade database new
        else
            safely crowbar_api_request POST $crowbar_init_api /database/new \
                '--data username=crowbar&password=crowbar' "$crowbar_api_v2_header"
            safely crowbar_api_request POST $crowbar_init_api /init "" "$crowbar_api_v2_header"
        fi
    fi
}

function crowbar_any_status
{
    local api_path=$1
    curl -s ${crowbar_api}${api_path}.json | jsonice
}

function crowbar_any_status_v2
{
    local api_path=$1
    curl -H "$crowbar_api_v2_header" -s ${crowbar_api}${api_path} | jsonice
}

function crowbar_install_status
{
    crowbar_any_status $crowbar_api_installer_path/status
}

function crowbar_restore_status
{
    if iscloudver 6minus; then
        crowbar_any_status /utils/backups/restore_status
    else
        crowbar_any_status_v2 /api/crowbar/backups/restore_status
    fi
}

function crowbar_nodeupgrade_status
{
    crowbar_any_status /installer/upgrade/nodes_status
}

function do_installcrowbar_cloud6plus
{
    if [[ $want_postgresql = 0 ]] || iscloudver 6minus; then
        service crowbar status || service crowbar stop
        service crowbar start

        wait_for 30 10 "onadmin_is_crowbar_api_available" "crowbar service to start"
    fi

    if crowbar_install_status | grep -q '"success": *true' ; then
        echo "Crowbar is already installed. The current crowbar install status is:"
        crowbar_install_status
        return 0
    fi

    # call api to start asyncronous install job
    safely crowbar_api_request POST $crowbar_api $crowbar_api_installer_path/start.json

    wait_for 9 2 "crowbar_install_status | grep -q '\"installing\": *true'" "crowbar to start installing" "tail -n 500 $crowbar_install_log ; complain 88 'crowbar did not start to install'"
    wait_for 180 10 "crowbar_install_status | grep -q '\"installing\": *false'" "crowbar to finish installing" "tail -n 500 $crowbar_install_log ; complain 89 'crowbar installation failed'"
    if ! crowbar_install_status | grep -q '\"success\": *true' ; then
        tail -n 500 $crowbar_install_log
        crowbar_install_status
        complain 90 "Crowbar installation failed"
    fi
}


function do_installcrowbar_legacy
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


function do_installcrowbar
{
    intercept "crowbar-installation"
    pre_hook $FUNCNAME
    do_set_repos_skip_checks

    rpm -Va crowbar\*
    if iscloudver 6plus ; then
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

    wait_for 30 5 "onadmin_is_crowbar_api_available" "crowbar service to start" "tail -n 90 $crowbar_install_log ; exit 11"

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


function onadmin_installcrowbarfromgit
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

function onadmin_installcrowbar
{
    do_installcrowbar ""
}

# Set a node's attribute (see 2nd argument)
# Must be run after discovery and makes sense mostly before allocation
function set_node_attribute
{
    local node="$1"
    local attr="$2"
    local value="$3"

    knife exec -E "
        nodes.find(:name => '${node}').each do |n|
            n.${attr} = '${value}'
            n.save
        end
    "
}

function set_node_fs
{
    set_node_attribute "$1" "crowbar_wall.default_fs" "$2"
}

function set_node_role
{
    set_node_attribute "$1" "crowbar_wall.intended_role" "$2"
}

function set_node_platform
{
    set_node_attribute "$1" "target_platform" "$2"
}

function set_node_role_and_platform
{
    set_node_role "$1" "$2"
    set_node_platform "$1" "$3"
}


# set the RAID configuration for a node before allocating
function set_node_raid
{
    node="$1"
    raid_type="$2"
    disks_count="$3"

    wait_for 10 5 "getent hosts $node &> /dev/null" "$node name to be resolvable"
    # to find out available disks, we need to look at the nodes directly
    raid_disks=`ssh $node lsblk -n -d | cut -d' ' -f 1 | head -n $disks_count`
    test -n "$raid_disks" || complain 90 "no raid disks found on $node"
    raid_disks=`printf "\"/dev/%s\"," $raid_disks`
    raid_disks="[ ${raid_disks%,} ]"

    knife exec -E "
        nodes.find(:name => '${node}').each do |n|
            n.crowbar_wall.raid_type = '${raid_type}'
            n.crowbar_wall.raid_disks = $raid_disks
            n.save
        end
    "
}


# Reboot the nodes with ipmi
function reboot_nodes_via_ipmi
{
    do_one_proposal ipmi default
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
    local i
    for i in $(seq 1 $nodenumbertotal); do
        local pw
        for pw in 'cr0wBar!' $extraipmipw ; do
            local ip=$bmc_net.$(($ip4 + $i))
            if [ $i -gt $nodenumber ]; then
                # power off extra nodes
                ipmitool -H $ip -U root -P $pw power off
                wait_for 2 60 "ipmitool -H $ip -U root -P $pw power status | grep -q 'is off'" "node to power off"
            else
                ping -c 3 $ip > /dev/null || {
                    echo "error: BMC $ip is not reachable!"
                }

                ipmitool -H $ip -U root -P $pw lan set 1 defgw ipaddr "${bmc_values[1]}"
                # Sleep while the BMC is rebooting due to the gateway re-setting
                sleep $((50 + RANDOM % 20))

                ipmitool -H $ip -U root -P $pw chassis bootdev pxe options=persistent
                # Sleep while the BMC is rebooting due to the bootdev re-setting
                sleep $((50 + RANDOM % 20))

                if ipmitool -H $ip -U root -P $pw power status | grep -q "is off"; then
                    ipmitool -H $ip -U root -P $pw power on
                else
                    ipmitool -H $ip -U root -P $pw power cycle
                fi
                # Sleep while the BMC is booting due to doing power on/cycle
                sleep $((50 + RANDOM % 20))
            fi
        done
    done
    wait
}

function onadmin_allocate
{
    pre_hook $FUNCNAME

    if $want_ipmi ; then
        reboot_nodes_via_ipmi
    fi

    if [[ $cloud = qa1 ]] ; then
        curl http://$clouddata/git/automation/scripts/qa1_nodes_reboot | bash
    fi

    [[ $nodenumber -gt 0 ]] && wait_for 50 10 'test $(get_all_discovered_nodes | wc -l) -ge 1' "first node to be discovered"
    wait_for 100 10 '[[ $(get_all_discovered_nodes | wc -l) -ge $nodenumber ]]' "all nodes to be discovered"
    local n
    for n in `get_all_discovered_nodes` ; do
        wait_for 100 2 "knife node show -a state $n | grep -q discovered" \
            "node to enter discovered state"
        if iscloudver 6minus; then
            # provisioner is the last transition discovered role, so we're
            # kludging here and wait for the discovered transition to be really
            # finished.
            wait_for 100 5 \
                "get_proposal_role_elements provisioner provisioner-base | grep -q $n" \
                "node to be in provisioner proposal"
        fi
    done
    local controllernodes=(
            $(get_all_discovered_nodes | head -n 2)
        )

    controller_os="suse-11.3"
    if iscloudver 6; then
        controller_os="suse-12.1"
    fi
    if iscloudver 7plus ; then
        controller_os="suse-12.2"
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
        if [[ $hacloud = 1 ]] ; then
            cluster_node_assignment
            local nodes=($unclustered_nodes)
        else
            local nodes=($(get_all_discovered_nodes))
            nodes=("${nodes[@]:1}") #remove the 1st node, it's the controller
        fi
        local nodes_count=${#nodes[@]}

        if [ -n "$want_sles12" ] && iscloudver 5 ; then
            if [ -n "$deployceph" ] ; then
                echo "Setting second last node to SLE12 Storage..."
                set_node_role_and_platform ${nodes[$(($nodes_count-2))]} "storage" "suse-12.0"
            fi
            echo "Setting last node to SLE12 compute..."
            set_node_role_and_platform ${nodes[$(($nodes_count-1))]} "compute" "suse-12.0"
        fi
        if [ -n "$deployceph" ] && iscloudver 6plus ; then
            storage_os="suse-12.1"
            for n in $(seq 0 1); do
                echo "Setting node ${nodes[$n]} to Storage... "
                set_node_role_and_platform ${nodes[$n]} "storage" ${storage_os}
            done
        fi
        if [ -n "$wanthyperv" ] ; then
            echo "Setting last node to Hyper-V compute..."
            set_node_role_and_platform ${nodes[$(($nodes_count-1))]} "compute" "hyperv-6.3"
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
    if [ $want_docker = 1 ] ; then
        : ${want_rootfs:=btrfs}
    fi

    # set rootfs for all nodes when want_rootfs is set
    if [ -n "$want_rootfs" ] ; then
        for node in `get_all_discovered_nodes` ; do
            set_node_fs $node "$want_rootfs"
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

    onadmin_is_crowbar_api_available || \
        complain 27 "simple crowbar test failed"
}

function check_node_resolvconf
{
    ssh_password $1 'grep "^nameserver" /etc/resolv.conf || echo fail'
}

function onadmin_wait_tftpd
{
    wait_for 300 2 \
        "timeout -k 2 2 tftp $adminip 69 -c get /discovery/x86_64/bios/pxelinux.cfg/default /tmp/default"
    echo "Crowbar tftp server ready"
}

function wait_node_ready
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

function onadmin_waitcloud
{
    pre_hook $FUNCNAME
    local node
    for node in `get_all_discovered_nodes` ; do
        wait_node_ready $node
    done
}

function onadmin_post_allocate
{
    pre_hook $FUNCNAME

    if [[ $hacloud = 1 ]] ; then

        onadmin_set_source_variables

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

        if iscloudver 6plus && [[ $want_sbd = 1 ]] ; then
            zypper --gpg-auto-import-keys -p http://download.opensuse.org/repositories/devel:/languages:/python/$slesdist/ --non-interactive install python-sh
            chmod +x $SCRIPTS_DIR/iscsictl.py
            $SCRIPTS_DIR/iscsictl.py --service target --host $(hostname) --no-key

            local cluster
            local clustername
            for clustername in data network services ; do
                eval "cluster=\$clusternodes$clustername"
                for node in $cluster ; do
                    $SCRIPTS_DIR/iscsictl.py --service initiator --target_host $(hostname) --host $node --no-key
                    sbd_device=$(ssh $node echo '/dev/disk/by-id/scsi-$(lsscsi -i |grep LIO|head -n 1| tr -s " " |cut -d " " -f7)')
                    ssh $node "zypper --non-interactive install sbd; sbd -d $sbd_device create"
                done
            done
        fi
    fi
}

function onadmin_get_ip_from_dhcp
{
    local mac=$1
    local leasefile=${2:-/var/lib/dhcp/db/dhcpd.leases}

    awk '
        /^lease/   { ip=$2 }
        /ethernet /{ if ($3=="'$mac';") res=ip }
        END{ if (res=="") exit 1; print res }' $leasefile
}

# register a new node with crowbar_register
function onadmin_crowbar_register
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

    if iscloudver 6 ; then
        image="suse-12.1/x86_64/"
    elif iscloudver 7plus; then
        image="suse-12.2/$arch/"
    else
        if [ -n "$want_sles12" ] ; then
            image="suse-12.0"
        else
            image="suse-11.3"
        fi
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
            $hostnamecmd
            zypper -n ref &&
            zypper -n up --no-recommends &&
            screen -d -m -L /bin/bash -c '
            yes | bash -x ./crowbar_register --no-gpg-checks &&
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


function onadmin_get_proposalstatus
{
    local proposal=$1
    local proposaltype=$2
    crowbar $proposal proposal show $proposaltype | \
        rubyjsonparse "puts j['deployment']['$proposal']['crowbar-status']"
}

function onadmin_get_machinesstatus
{
    local onenode
    for onenode in `get_all_discovered_nodes` ; do
        echo -n "$onenode "
        crowbar machines show $onenode state
    done
}

function waitnodes
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

function get_proposal_filename
{
    echo "/root/${1}.${2}.proposal"
}

# generic function to modify values in proposals
#   Note: strings have to be quoted like this: "'string'"
#         "true" resp. "false" or "['one', 'two']" act as ruby values, not as string
function proposal_modify_value
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
function proposal_set_value
{
    proposal_modify_value "$1" "$2" "$3" "$4" "="
}

# wrapper for proposal_modify_value
function proposal_increment_int
{
    proposal_modify_value "$1" "$2" "$3" "$4" "+="
}

function enable_ssl_generic
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
            if iscloudver 6plus ; then
                $p "$a['apache']['generate_certs']" true
            fi
            return
        ;;
        heat)
            if ! iscloudver 7plus ; then
                return
            fi
            $p "$a['api']['protocol']" "'https'"
        ;;
        manila)
            if ! iscloudver 7plus ; then
                return
            fi
            $p "$a['api']['protocol']" "'https'"
        ;;
        ceph)
            if ! iscloudver 5plus ; then
                return
            fi
            $p "$a['radosgw']['ssl']['enabled']" true
            $p "$a['radosgw']['ssl']['generate_certs']" true
            $p "$a['radosgw']['ssl']['insecure']" true
            return
        ;;
        *)
            $p "$a['api']['protocol']" "'https'"
        ;;
    esac
    $p "$a['ssl']['generate_certs']" true
    $p "$a['ssl']['insecure']" true
}

function enable_debug_generic
{
    local service=$1
    echo "Enabling DEBUG for $service"
    local p="proposal_set_value $service default"
    local a="['attributes']['$service']"
    case $service in
        *)
            $p "$a['debug']" true
        ;;
    esac
}

function hacloud_configure_cluster_members
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

    if [[ $want_sbd = 1 ]] ; then
        for node in $@; do
            sbd_device=$(ssh $node echo '/dev/disk/by-id/scsi-$(lsscsi -i |grep LIO|head -n 1| tr -s " " |cut -d " " -f7)')
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['sbd']['nodes']['$node']" "{}"
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['sbd']['nodes']['$node']['devices']" "['$sbd_device']"
        done
    fi
}

function hacloud_configure_cluster_defaults
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

    if [[ $want_sbd = 1 ]] ; then
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['mode']" "'sbd'"
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['sbd']['watchdog_module']" "'softdog'"
    else
        if [[ $mkclouddriver = "libvirt" ]]; then
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['mode']" "'libvirt'"
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['libvirt']['hypervisor_ip']" "'$admingw'"
        else
            proposal_set_value pacemaker "$clustername" \
                "['attributes']['pacemaker']['stonith']['mode']" "'manual'"
        fi
    fi
    proposal_modify_value pacemaker "$clustername" \
        "['description']" "'Clustername: $clustername, type: $clustertype ; '" "+="
}

function hacloud_configure_data_cluster
{
    proposal_set_value pacemaker $clusternamedata "['attributes']['pacemaker']['drbd']['enabled']" true
    hacloud_configure_cluster_defaults $clusternamedata "data"
}

function hacloud_configure_network_cluster
{
    hacloud_configure_cluster_defaults $clusternamenetwork "network"
}

function hacloud_configure_services_cluster
{
    hacloud_configure_cluster_defaults $clusternameservices "services"
}

function cinder_netapp_proposal_configuration
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

function provisioner_add_repo
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
function custom_configuration
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

    local unclustered_sles12plusnodes=($(get_unclustered_sles12plus_nodes))

    ### NOTE: ONLY USE proposal_{set,modify}_value functions below this line
    ###       The edited proposal will be read and imported at the end
    ###       So, only edit the proposal file, and NOT the proposal itself

    case "$proposal" in
        keystone|glance|neutron|cinder|swift|ceph|nova|horizon|nova_dashboard|heat|manila)
            if [[ $want_all_ssl = 1 ]] || eval [[ \$want_${proposal}_ssl = 1 ]] ; then
                enable_ssl_generic $proposal
            fi
    esac

    case "$proposal" in
        keystone|glance|neutron|cinder|swift|nova|horizon|nova_dashboard|sahara|murano)
            if [[ $want_all_debug = 1 ]] || eval [[ \$want_${proposal}_debug = 1 ]] ; then
                enable_debug_generic $proposal
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
            if iscloudver 5plus; then
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['trove']['enabled']" true
            fi
        ;;
        dns)
            [ "$want_multidnstest" = 1 ] || return 0
            local cmachines=$(get_all_suse_nodes | head -n 3)
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
            if [[ $want_ldap = 1 ]] ; then
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
                #zypper ar --refresh http://$susedownload/ibs/SUSE:/CA/SLE_11_SP3/SUSE:CA.repo
                #zypper -n --gpg-auto-import-keys in ca-certificates-suse
            fi
            if [[ $want_keystone_v3 ]] ; then
                proposal_set_value keystone default "['attributes']['keystone']['api']['version']" "'3'"
            fi
        ;;
        glance)
            if [[ $deployceph ]]; then
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

            if iscloudver 6plus ; then
                proposal_set_value manila default "['attributes']['manila']['default_share_type']" "'default'"
                # new generic driver options since M9
                if crowbar manila proposal show default|grep service_instance_name_or_id ; then
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_driver']" "'generic'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_name']" "'backend1'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_user']" "'root'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_password']" "'linux'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['share_volume_fstype']" "'ext3'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_name_or_id']" "'$manila_service_vm_uuid'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_net_name_or_ip']" "'$manila_tenant_vm_ip'"
                    proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['tenant_net_name_or_ip']" "'$manila_tenant_vm_ip'"
                fi
            fi
        ;;
        ceph)
            proposal_set_value ceph default "['attributes']['ceph']['disk_mode']" "'all'"
        ;;
        magnum)
            proposal_set_value magnum default "['attributes']['magnum']['trustee']['domain_name']" "'magnum'"
            proposal_set_value magnum default "['attributes']['magnum']['trustee']['domain_admin_name']" "'magnum_domain_admin'"

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value magnum default "['deployment']['magnum']['elements']['magnum-server']" "['cluster:$clusternameservices']"
            fi
            ;;
        barbican)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value barbican default "['deployment']['barbican']['elements']['barbican-server']" "['cluster:$clusternameservices']"
            fi
            ;;
        nova)
            local role_prefix=`nova_role_prefix`
            # custom nova config of libvirt
            [[ $libvirt_type = hyperv ]] || proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
            proposal_set_value nova default "['attributes']['nova']['use_migration']" "true"
            [[ $libvirt_type = xen ]] && sed -i -e "s/${role_prefix}-compute-$libvirt_type/${role_prefix}-compute-xxx/g; s/${role_prefix}-compute-kvm/${role_prefix}-compute-$libvirt_type/g; s/${role_prefix}-compute-xxx/${role_prefix}-compute-kvm/g" $pfile

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-controller']" "['cluster:$clusternameservices']"

                # only use remaining nodes as compute nodes, keep cluster nodes dedicated to cluster only
                local novanodes=($unclustered_nodes)

                # make sure we do not pick SP1 nodes on cloud7
                if [ -n "$deployceph" ] && iscloudver 7 ; then
                    novanodes=$unclustered_sles12plusnodes
                fi

                if [[ ! $novanodes ]]; then
                    complain 105 "No suitable node(s) for ${role_prefix}-compute-${libvirt_type} found."
                fi
                novanodes=$(printf "\"%s\"," $novanodes)
                novanodes="[ ${novanodes%,} ]"
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-${libvirt_type}']" "$novanodes"
            fi

            if [ -n "$want_sles12" ] && [ $want_docker = 1 ] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-docker']" "['${unclustered_sles12plusnodes[0]}']"

                local computetype
                for computetype in "xen" "qemu" "${libvirt_type}"; do
                    # do not assign another compute role to this node
                    proposal_modify_value nova default "['deployment']['nova']['elements']['${role_prefix}-compute-${computetype}']" "['${unclustered_sles12plusnodes[0]}']" "-="
                done
            fi

            if [[ $nova_shared_instance_storage = 1 ]] ; then
                proposal_set_value nova default "['attributes']['nova']['use_shared_instance_storage']" "true"
            fi
            # set some custom vendordata for the metadata server
            if iscloudver 7plus ; then
                proposal_set_value nova default "['attributes']['nova']['metadata']['vendordata']['json']" "'{\"custom-key\": \"custom-value\"}'"
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
            if iscloudver 6plus ; then
                ceilometerservice="ceilometer-central"
                if [[ $cloudsource = GM6 ]] ; then
                    ceilometerservice="ceilometer-polling"
                fi
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-server']" "['cluster:$clusternameservices']"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['$ceilometerservice']" "['cluster:$clusternameservices']"
                # disabling mongodb, because if in one cluster mode the requirements of drbd and mongodb ha conflict:
                #   drbd can only use 2 nodes max. <> mongodb ha requires 3 nodes min.
                # this should be adapted when NFS mode is supported for data cluster
                proposal_set_value ceilometer default "['attributes']['ceilometer']['use_mongodb']" "false"

                local ceilometernodes=($unclustered_nodes)
                # make sure we do not pick SP1 nodes on cloud7
                if [ -n "$deployceph" ] && iscloudver 7 ; then
                    ceilometernodes=$unclustered_sles12plusnodes
                fi
                if [[ ! $ceilometernodes ]]; then
                    complain 105 "No suitable node(s) for ceilometer-agent found."
                fi
                ceilometernodes=$(printf "\"%s\"," $ceilometernodes)
                ceilometernodes="[ ${ceilometernodes%,} ]"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-agent']" "$ceilometernodes"
            fi
        ;;
        neutron)
            if iscloudver 7plus; then
                [[ $networkingplugin = linuxbridge && $networkingmode = gre ]] && networkingmode=vlan
            else
                [[ $networkingplugin = linuxbridge ]] && networkingmode=vlan
            fi
            proposal_set_value neutron default "['attributes']['neutron']['use_lbaas']" "true"

            if iscloudver 5plus; then
                if [ $networkingplugin = openvswitch ] ; then
                    if [[ $networkingmode = vxlan ]] || iscloudver 6plus; then
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vxlan','vlan']"
                        if [[ $want_dvr ]]; then
                            proposal_set_value neutron default "['attributes']['neutron']['use_dvr']" "true"
                        fi
                    else
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vlan']"
                    fi
                elif [ "$networkingplugin" = "linuxbridge" ] ; then
                    if iscloudver 7plus; then
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['vxlan','vlan']"
                    else
                        proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['vlan']"
                    fi
                    if iscloudver 5plus && ! iscloudver 6plus ; then
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
            if [[ $want_sles12 && ! $hacloud && $want_neutronsles12 ]] && iscloudver 5plus ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-network']" "['${unclustered_sles12plusnodes[0]}']"
            fi

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-server']" "['cluster:$clusternameservices']"
                # neutron-network role is only available since Cloud5+Updates
                proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-network']" "['cluster:$clusternamenetwork']" || \
                    proposal_set_value neutron default "['deployment']['neutron']['elements']['neutron-l3']" "['cluster:$clusternamenetwork']"
            fi
            if [[ $networkingplugin = vmware ]] ; then
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['user']" "'$nsx_user'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['password']" "'$nsx_password'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['controllers']" "'$nsx_controllers'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['tz_uuid']" "'$nsx_tz_uuid'"
                proposal_set_value neutron default "['attributes']['neutron']['vmware']['l3_gw_uuid']" "'$nsx_l3_gw_uuid'"
            fi
        ;;
        sahara)
            if iscloudver 7plus ; then
                # we need to set the 'fake' plugin for the tempest tests
                proposal_set_value sahara default "['attributes']['sahara']['plugins']" "'vanilla,spark,cdh,ambari,fake'"
            fi
        ;;
        swift)
            [[ $nodenumber -lt 3 ]] && proposal_set_value swift default "['attributes']['swift']['zones']" "1"
            proposal_set_value swift default "['attributes']['swift']['allow_versions']" "true"
            proposal_set_value swift default "['attributes']['swift']['keystone_delay_auth_decision']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['crossdomain']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['formpost']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['staticweb']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['tempurl']['enabled']" "true"
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
                # fetch one of the compute nodes as cinder_volume
                local cinder_volume=($unclustered_nodes)
                # make sure we do not pick SP1 nodes on cloud7
                if [ -n "$deployceph" ] && iscloudver 7 ; then
                    cinder_volume=$unclustered_sles12plusnodes
                fi
                if [[ ! $cinder_volume ]]; then
                    complain 105 "No suitable node(s) for cinder-volume found."
                fi

                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-controller']" "['cluster:$clusternameservices']"
                proposal_set_value cinder default "['deployment']['cinder']['elements']['cinder-volume']" "['${cinder_volume[0]}']"
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
            # manila options
            if iscloudver 6plus ; then
                proposal_set_value tempest default "['attributes']['tempest']['manila']['image_password']" "'linux'"
            fi
            #magnum options
            if iscloudver 7plus ; then
                proposal_set_value tempest default "['attributes']['tempest']['magnum']['flavor_id']" "'m1.smaller'"
                proposal_set_value tempest default "['attributes']['tempest']['magnum']['master_flavor_id']" "'m2.smaller'"
            fi
        ;;
        provisioner)
            # set default password
            proposal_set_value provisioner default "['attributes']['provisioner']['root_password_hash']" "\"$(openssl passwd -1 $want_rootpw)\""
            # set discovery root password too
            iscloudver 6plus && proposal_set_value provisioner default "['attributes']['provisioner']['discovery']['append']" "\"DISCOVERY_ROOT_PASSWORD=$want_rootpw\""

            if [[ $keep_existing_hostname = 1 ]] ; then
                proposal_set_value provisioner default "['attributes']['provisioner']['keep_existing_hostname']" "true"
            fi

            if ! iscloudver 6plus ; then
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
function set_proposalvars
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
    if iscloudver 5 && [[ $deployswift ]] && [[ $want_sles12 ]] ; then
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
function update_one_proposal
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
function do_one_proposal
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

function prepare_proposals
{
    pre_hook $FUNCNAME
    waitnodes nodes

    if iscloudver 5plus; then
        update_one_proposal dns default
    fi

    local ptfchannel="SLE-Cloud-PTF"
    iscloudver 6plus && ptfchannel="PTF"
    for machine in $(get_all_nodes); do
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
function set_dashboard_alias
{
    get_horizon
    set_node_alias_and_role `echo "$horizonserver" | cut -d . -f 1` dashboard controller
}

function deploy_single_proposal
{
    local proposal=$1

    # proposal filter
    case "$proposal" in
        barbican)
            # Barbican is for magnum and PM does not want magnum to be on s390x, so..
            if [[ $arch = "s390x" ]]; then
                return
            fi
            [[ $want_barbican = 1 ]] || return
            if ! iscloudver 7plus; then
                echo "Barbican is SOC 7+ only. Skipping"
                return
            fi
            ;;
        nfs_client)
            [[ $hacloud = 1 ]] || return
            ;;
        pacemaker)
            [[ $hacloud = 1 ]] || return
            ;;
        ceph)
            [[ $deployceph ]] || return
            ;;
        magnum)
            # PM does not want to support magnum on s390x
            if [[ $arch = "s390x" ]]; then
                return
            fi
            [[ $want_magnum = 1 ]] || return
            if iscloudver 7plus ; then
                get_novacontroller
                safely oncontroller oncontroller_magnum_service_setup
            fi
            ;;
        manila)
            # manila-service can not be deployed currently with docker
            [[ $want_docker = 1 ]] && return
            # manila barclamp is only in SC6+ and develcloud5 with SLE12CC5
            if iscloudver 5minus && ! [[ $cloudsource = develcloud5 && $want_sles12 ]]; then
                return
            fi
            # PM does not want to support manila on non-x86
            if [[ $arch != "x86_64" ]]; then
                return
            fi
            if iscloudver 6plus ; then
                get_novacontroller
                safely oncontroller oncontroller_manila_generic_driver_setup
                get_manila_service_instance_details
            fi
            ;;
        swift)
            [[ $deployswift ]] || return
            ;;
        trove)
            iscloudver 5plus || return
            [[ $want_trove = 1 ]] || return
            ;;
        tempest)
            [[ $wanttempest ]] || return
            ;;
        sahara)
            [[ $want_sahara = 1 ]] || return
            if ! iscloudver 7plus; then
                echo "Sahara is SOC 7+ only. Skipping"
                return
            fi
            ;;
        murano)
            [[ $want_murano = 1 ]] || return
            if ! iscloudver 7plus; then
                echo "Murano is SOC 7+ only. Skipping"
                return
            fi
            ;;
    esac

    # create proposal
    case "$proposal" in
        nfs_client)
            do_one_proposal "$proposal" "$clusternameservices"
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
function onadmin_proposal
{

    prepare_proposals

    if [[ $hacloud = 1 ]] ; then
        cluster_node_assignment
    else
        # no cluster for non-HA, but get compute nodes
        unclustered_nodes=`get_all_discovered_nodes`
    fi

    if [[ $want_ssl_keys ]] ; then
        for m in $(get_all_suse_nodes) ; do
            rsync -a /root/cloud-keys/ $m:/etc/cloud-keys/
        done
    fi
    local proposal
    for proposal in nfs_client pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova `horizon_barclamp` ceilometer heat manila trove barbican magnum sahara murano tempest; do
        deploy_single_proposal $proposal
    done

    set_dashboard_alias
}

function set_node_alias
{
    local node_name=$1
    local node_alias=$2
    if [[ "$node_name" != "$node_alias" ]]; then
        if iscloudver 6plus; then
            safely crowbarctl node rename $node_name $node_alias
        else
            safely crowbar machines rename $node_name $node_alias
        fi
    fi
}

function set_node_alias_and_role
{
    local node_name=$1
    local node_alias=$2
    local intended_role=$3
    set_node_alias $node_name $node_alias
    iscloudver 5plus && crowbar machines role $node_name $intended_role || :
}

function get_first_node_from_cluster
{
    local cluster=$1
    crowbar pacemaker proposal show $cluster | \
        rubyjsonparse "
                    puts j['deployment']['pacemaker']\
                        ['elements']['pacemaker-cluster-member'].first"
}

function get_cluster_vip_hostname
{
    local cluster=$1
    echo "cluster-$cluster.$cloudfqdn"
}

# An entry in an elements section can have single or multiple nodes or
# a cluster alias.  This function will resolve this element name to a
# node name, or to a hostname for a VIP if the second service
# parameter is non-empty and the element refers to a cluster.
function resolve_element_to_hostname
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

function get_novacontroller
{
    local role_prefix=`nova_role_prefix`
    local element=`crowbar nova proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['nova']\
                        ['elements']['$role_prefix-controller']"`
    novacontroller=`resolve_element_to_hostname "$element"`
}

function get_horizon
{
    local horizon=`horizon_barclamp`
    local element=`crowbar $horizon proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['$horizon']\
                        ['elements']['$horizon-server']"`
    horizonserver=`resolve_element_to_hostname "$element"`
    horizonservice=`resolve_element_to_hostname "$element" service`
}

function get_ceph_nodes
{
    if [[ $deployceph ]]; then
        cephmons=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-mon']"`
        cephosds=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-osd']"`
        cephradosgws=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-radosgw']"`
    else
        cephmons=
        cephosds=
        cephradosgws=
    fi
}

function manila_service_instance_get_uuid
{
    local vm_uuid=`openstack --os-project-name manila-service server show manila-service -f value -c id`
    test -n "$vm_uuid" || complain 91 "uuid from manila-service instance not available"
    echo $vm_uuid
}

function manila_service_instance_get_floating_ip
{
    local vm_uuid=`manila_service_instance_get_uuid`
    local vm_floating_ip=`openstack --os-project-name manila-service server show $vm_uuid -f value -c addresses | awk '{print $2}'`
    test -n "$vm_floating_ip" || complain 93 "floating ip addr from manila-service instance not available"
    echo $vm_floating_ip
}

function get_manila_service_instance_details
{
    manila_service_vm_uuid=`oncontroller "manila_service_instance_get_uuid"`
    manila_tenant_vm_ip=`oncontroller "manila_service_instance_get_floating_ip"`
}

function addfloatingip
{
    local instanceid=$1
    nova floating-ip-create | tee floating-ip-create.out
    floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
    nova add-floating-ip "$instanceid" "$floatingip"
}

# by setting --dns-nameserver for subnet, docker instance gets this as
# DNS info (otherwise it would use /etc/resolv.conf from its host)
function adapt_dns_for_docker
{
    # DNS server is the first IP from the allocation pool, or the
    # second one from the network range
    local dns_server=`neutron subnet-show fixed | grep allocation_pools | cut -d '"' -f4`
    if [ -z "$dns_server" ] ; then
        complain 36 "DNS server info not found. Exiting"
    fi
    neutron subnet-update --dns-nameserver "$dns_server" fixed
}

function glance_image_exists
{
    openstack image show "$1" &>/dev/null
    return $?
}

function glance_image_get_id
{
    local image_id=$(openstack image list | grep "[[:space:]]$1[[:space:]]" | awk '{ print $2 }')
    echo $image_id
}

# test if image is fully uploaded
function wait_image_active
{
    local image="$1"
    local purpose="$2"
    wait_for 300 5 \
        'openstack image show "$image" | grep active &>/dev/null' \
        "image $image for $purpose to reach active state"
}

function oncontroller_tempest_cleanup
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

function oncontroller_run_tempest
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
    wait_image_active "$image_name" tempest
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

    if [[ $tempestoptions = "-t" ]] && [[ $tempestret != 0 ]] ; then
        # for tempestfull runs we want less than 1% failed tests (99% pass rate)
        grep -A9 "Ran.*tests" tempest.log | perl -e '
            while(<>) {
                m/Ran:? (\d+) tests in / and $total=$1;
                m/failures=(\d+)/  and $failed=$1; # cloud5
                m/- Failed: (\d+)/ and $failed=$1; # cloud7
            }
            exit 107 unless defined $failed;
            my $failratio = $failed/$total;
            print "Failure ratio: $failratio = $failed/$total\n";
            exit ($failratio > 0.01)   # 0 means success'
        tempestret=$?
    fi
    if [ -n "$ostestroptions" ]; then
        zypper -n in python-os-testr
        ostestr $ostestroptions 2>&1 | tee ostestr.log
        local ostestrret=${PIPESTATUS[0]}
        if [ "$ostestrret" -ne 0 ]; then
            complain 111 "Extra ostestr run failed. See ostestr.log"
        fi
    fi

    oncontroller_tempest_cleanup
    popd
    return $tempestret
}

function oncontroller_run_integration_test()
{
    # Install Mozilla Firefox < 47 to work with Selenium.
    safely zypper -n in 'MozillaFirefox<47'

    # Add Devel:Languages:Python repo (no GPG checks) to install Selenium
    local dlp="http://download.opensuse.org/repositories/devel:/languages:/python/$slesdist/"
    zypper ar --no-gpgcheck --refresh $dlp python
    safely zypper -n in python-selenium
    safely zypper -n in python-nose
    safely zypper -n in python-xvfbwrapper

    source .openrc

    # Disable chef before changing local configuration
    systemctl stop chef-client.service

    local locset=/srv/www/openstack-dashboard/openstack_dashboard/local/local_settings.py

    # Disable local password validator in Horizon
    echo 'HORIZON_CONFIG["password_validator"] = None' >> $locset
    # Allows IPv6 networks (for the UI in Horizon)
    sed -i "s/'enable_ipv6': False,/'enable_ipv6': True,/g" $locset

    # Make the changes effective
    systemctl restart apache2.service

    # Create dummy `public` network
    openstack network create public

    # Remove non-expected images
    openstack image delete cirros-0.3.4-x86_64-tempest-machine-alt
    openstack image delete manila-service-image

    pushd /srv/www/openstack-dashboard

    # Configuration file
    local cfg=openstack_dashboard/test/integration_tests/horizon.conf
    cp -a $cfg $cfg.BACKUP

    local url="http://localhost"
    if [[ $hacloud = 1 ]]; then
        url="http://cluster-services"
    fi

    # [dashboard]
    crudini --set --inplace $cfg dashboard dashboard_url $url
    crudini --set --inplace $cfg dashboard help_url $url/help/
    # [image]
    crudini --set --inplace $cfg image images_list "cirros-0.3.4-x86_64-tempest-kernel,cirros-0.3.4-x86_64-tempest-machine,cirros-0.3.4-x86_64-tempest-ramdisk"
    # [identity]
    crudini --set --inplace $cfg identity username crowbar
    crudini --set --inplace $cfg identity password crowbar
    crudini --set --inplace $cfg identity home_project openstack
    crudini --set --inplace $cfg identity admin_username admin
    crudini --set --inplace $cfg identity admin_password crowbar
    crudini --set --inplace $cfg identity admin_home_project admin
    # [network]
    local cidr=$(openstack subnet show floating -f value -c cidr)
    crudini --set --inplace $cfg network tenant_network_cidr $cidr
    # [launch_instances]
    crudini --set --inplace $cfg launch_instances image_name "cirros-0.3.4-x86_64-tempest-machine (24.0 MB)"
    # [volume]
    crudini --set --inplace $cfg volume volume_type no_type

    # Configure the tests to be headless and run the tests
    export WITH_SELENIUM=1
    export SELENIUM_HEADLESS=1
    export INTEGRATION_TESTS=1
    nosetests openstack_dashboard/test/integration_tests/tests
    local integrationret=$?

    popd

    # Restart chef-client
    systemctl start chef-client.service

    return $integrationret
}

function oncontroller_manila_generic_driver_setup()
{
    if [[ $wantxenpv ]] ; then
        local service_image_url=http://$clouddata/images/other/manila-service-image-xen.raw
        local service_image_name=manila-service-image-xen.raw
        local service_image_params="--disk-format raw --property hypervisor_type=xen --property vm_mode=xen"

    elif [[ $wanthyperv ]] ; then
        local service_image_url=http://$clouddata/images/other/manila-service-image.vhd
        local service_image_name=manila-service-image.vhd
        local service_image_params="--disk-format vhd --property hypervisor_type=hyperv"
    else
        local service_image_url=http://$clouddata/images/other/manila-service-image.qcow2
        local service_image_name=manila-service-image.qcow2
        local service_image_params="--disk-format qcow2 --property hypervisor_type=kvm"
    fi

    local sec_group="manila-service"
    local neutron_net=$sec_group

    local ret=$(wget -N --progress=dot:mega "$service_image_url" 2>&1 >/dev/null)
    if [[ $ret =~ "200 OK" ]]; then
        echo $ret
    elif [[ $ret =~ "Not Found" ]]; then
        complain 73 "manila image not found: $ret"
    else
        complain 74 "failed to retrieve manila image: $ret"
    fi

    . .openrc

    if ! openstack project show manila-service; then
        manila_service_tenant_id=`openstack project create manila-service -f value -c id`
        openstack role add --project manila-service --user admin admin
    fi
    export OS_TENANT_NAME='manila-service'

    # using list subcommand because show requires an ID
    if ! openstack image list --f value -c Name | grep -q "^manila-service-image$"; then
        openstack image create --file $service_image_name \
            $service_image_params --container-format bare --public \
            manila-service-image
    fi

    if ! nova flavor-show manila-service-image-flavor; then
        nova flavor-create manila-service-image-flavor 100 512 0 1
    fi

    if ! nova secgroup-list-rules manila-service; then
        nova secgroup-create $sec_group "$sec_group description"
        nova secgroup-add-rule $sec_group icmp -1 -1 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 22 22 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 2049 2049 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 20000 65535 0.0.0.0/0
        nova secgroup-add-rule $sec_group udp 2049 2049 0.0.0.0/0
        nova secgroup-add-rule $sec_group udp 445 445 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 445 445 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 137 139 0.0.0.0/0
        nova secgroup-add-rule $sec_group udp 137 139 0.0.0.0/0
        nova secgroup-add-rule $sec_group tcp 111 111 0.0.0.0/0
        nova secgroup-add-rule $sec_group udp 111 111 0.0.0.0/0
    fi

    service_vm_status="`openstack server show --f value -c status manila-service`"
    if [ "$service_vm_status" = "ACTIVE" ] || [ "$service_vm_status" = "SHUTOFF" ] ; then
        if [ "$service_vm_status" = "SHUTOFF" ]; then
            # We're upgrading. Restart existing instance as it was shutdown during
            # the upgrade
            timeout 10m nova start manila-service
        fi
        manila_service_vm_uuid=`manila_service_instance_get_uuid`
        manila_tenant_vm_ip=`manila_service_instance_get_floating_ip`
    else
        fixed_net_id=`neutron net-show fixed -f value -c id`
        timeout 10m nova boot --poll --flavor 100 --image manila-service-image \
            --security-groups $sec_group,default \
            --nic net-id=$fixed_net_id manila-service

        [ $? != 0 ] && complain 43 "nova boot for manila failed"

        # manila tempest tests use the floating IP to export the shares. So create
        # a floating IP for the manila instance and add it to the VM
        manila_tenant_vm_ip=`openstack ip floating create floating -f value -c ip`
        openstack ip floating add $manila_tenant_vm_ip manila-service

        [ $? != 0 ] && complain 44 "adding a floating ip to the manila service VM failed"
    fi
    # check that the service VM is pingable. otherwise manila tempest tests will fail later
    wait_for 300 1 "nc -z $manila_tenant_vm_ip 22" \
        "manila service VM booted and ssh port open" \
        "echo \"ERROR: manila service VM not listening on ssh port. manila tests will fail!\""
}

function oncontroller_magnum_service_setup
{
    # (mjura): https://bugs.launchpad.net/magnum/+bug/1622468
    # Magnum functional tests have hardcoded swarm as coe backend, until then this will
    # not be fixed, we are going to have our own integration tests with SLES Magnum image
    local service_image_name=magnum-service-image.qcow2
    local service_image_url=http://clouddata.cloud.suse.de/images/$arch/other/$service_image_name
    local service_sles_image_name=SLE12SP1-JeOS-k8s-magnum.x86_64.qcow2
    local service_sles_image_url=http://download.suse.de/ibs/Devel:/Docker:/Images:/SLE12SP1-JeOS-k8s-magnum/images/$service_sles_image_name

    if ! openstack image list --f value -c Name | grep -q "^magnum-service-image$"; then
        local ret=$(wget -N --progress=dot:mega "$service_image_url" 2>&1 >/dev/null)
        if [[ $ret =~ "200 OK" ]]; then
            echo $ret
        elif [[ $ret =~ "Not Found" ]]; then
            complain 73 "magnum image not found: $ret"
        else
            complain 74 "failed to retrieve magnum image: $ret"
        fi

        . ~/.openrc

        # TODO(toabctl): when replacing the Fedora image, also replace the
        # os-distro property
        openstack image create --file $service_image_name \
            --disk-format qcow2 --container-format bare --public \
            --property os_distro=fedora-atomic magnum-service-image
    fi

    if ! openstack image list --f value -c Name | grep -q "^SLE12SP1-JeOS-k8s-magnum$"; then
        local ret=$(wget -N --progress=dot:mega "$service_sles_image_url" 2>&1 >/dev/null)
        if [[ $ret =~ "200 OK" ]]; then
            echo $ret
        elif [[ $ret =~ "Not Found" ]]; then
            complain 73 "SLES magnum image not found: $ret"
        else
            complain 74 "failed to retrieve SLES magnum image: $ret"
        fi

        . ~/.openrc

        openstack image create --file $service_sles_image_name \
            --disk-format qcow2 --container-format bare --public \
            --property os_distro=opensuse SLE12SP1-JeOS-k8s-magnum
    fi

    # create magnum flavors used by tempest
    if ! openstack flavor show m2.smaller; then
        openstack flavor create --ram 1024 --disk 8 --vcpus 1 m2.smaller
    fi

    if ! openstack flavor show m1.smaller; then
        openstack flavor create --ram 512 --disk 8 --vcpus 1 m1.smaller
    fi

    # default key is used by magnum tempest test
    if ! openstack keypair show default; then
        openstack keypair create --public-key /root/.ssh/id_rsa.pub default
    fi
}

function nova_services_up
{
    if iscloudver 7plus; then
        test $(nova service-list | fgrep -cv -- \ up\ ) -lt 5
    else
        test $(nova-manage service list  | fgrep -cv -- \:\-\)) -lt 2
    fi
}

# code run on controller/dashboard node to do basic tests of deployed cloud
# uploads an image, create flavor, boots a VM, assigns a floating IP, ssh to VM, attach/detach volume
function oncontroller_testsetup
{
    . .openrc
    # 28 is the overhead of an ICMP(ping) packet
    [[ $want_mtu_size ]] && iscloudver 5plus && safely ping -M do -c 1 -s $(( want_mtu_size - 28 )) $adminip
    export LC_ALL=C

    if iscloudver 6plus && \
        ! openstack catalog show manila 2>&1 | grep -q "service manila not found" && \
        ! manila type-list | grep -q "[[:space:]]default[[:space:]]" ; then
        manila type-create default false || complain 79 "manila type-create failed"
    fi

    # prepare test image with the -test packages containing functional tests
    if iscloudver 6plus && [[ $cloudsource =~ (devel|newton|suse)cloud ]]; then
        local mount_dir="/var/lib/Cloud-Testing"
        rsync_iso "$CLOUDSLE12DISTPATH" "$CLOUDSLE12TESTISO" "$mount_dir"
        zypper -n ar --refresh -c -G -f "$mount_dir" cloud-test
        zypper_refresh

        ensure_packages_installed python-novaclient-test python-manilaclient-test
    fi

    if [[ $deployswift ]] ; then
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

    # Run Horizon integration test if configure to do so
    integrationret=0
    if [ "$want_horizon_integration_test" = "1" ]; then
        # Horizon / Dashboard is installed in the controller node
        oncontroller_run_integration_test
        integrationret=$?
    fi

    nova list
    openstack image list

    local image_name="jeos"
    local flavor="m1.smaller"
    local ssh_user="root"

    if ! glance_image_exists $image_name ; then
        if [[ $wanthyperv ]] ; then
            mount $clouddata:/srv/nfs/ /mnt/
            zypper -n in virt-utils
            qemu-img convert -O vpc /mnt/images/SP3-64up.qcow2 /tmp/SP3.vhd
            openstack image create --public --disk-format vhd --container-format bare --property hypervisor_type=hyperv --file /tmp/SP3.vhd $image_name | tee glance.out
            rm /tmp/SP3.vhd ; umount /mnt
        elif [[ $wantxenpv ]] ; then
            curl -s \
                http://$clouddata/images/jeos-64-pv.qcow2 | \
                openstack image create --public --disk-format qcow2 \
                --container-format bare --property hypervisor_type=xen \
                --property vm_mode=xen  $image_name | tee glance.out
        else
            curl -s \
                http://$clouddata/images/$arch/SLES12-SP1-JeOS-SE-for-OpenStack-Cloud.$arch-GM.qcow2 | \
                openstack image create --public --property hypervisor_type=kvm \
                --disk-format qcow2 --container-format bare $image_name | tee glance.out
        fi
    fi

    #test for Glance scrubber service, added after bnc#930739
    if iscloudver 6plus || [[ $cloudsource =~ (devel|newton)cloud ]]; then
        configargs="--config-dir /etc/glance"
        iscloudver 6plus && configargs=""
        su - glance -s /bin/sh -c "/usr/bin/glance-scrubber $configargs" \
            || complain 113 "Glance scrubber doesn't work properly"
        grep -v glance_store /var/log/glance/scrubber.log | grep ERROR \
            && complain 114 "Unexpected errors in glance-scrubber logs"
    fi

    if [ $want_docker = 1 ] ; then
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

    if [ -n "$want_s390" ] ; then
        image_name="s390x-SLES12SP1-cloud-init"
        flavor="m1.small"
        ssh_user="root"
        if ! glance_image_exists $image_name ; then
            curl -s \
                http://$clouddata/images/s390x/xCAT-SLES12SP1-ECKD.img | \
            openstack image create --public --container-format bare \
                --disk-format raw --property hypervisor_type=zvm  \
                --property architecture=s390x \
                --property image_file_name=0100.img \
                --property image_type_xcat=linux  \
                --property os_name=Linux \
                --property os_version=sles12.1 \
                --property provisioning_method=netboot \
                $image_name | tee glance.out
        fi
    fi

    # wait for image to finish uploading
    imageid=$(glance_image_get_id $image_name)
    if ! [[ $imageid ]]; then
        complain 37 "Image ID for $image_name not found"
    fi
    wait_image_active "$image_name" testsetup

    if [[ $want_ldap = 1 ]] ; then
        openstack user show bwiedemann | grep -q 82608 || complain 103 "LDAP not working"
    fi

    # wait for nova-manage to be successful
    wait_for 200 1 nova_services_up "Nova services to be up and running"

    nova flavor-delete m1.smaller || :
    nova flavor-create m1.smaller 11 512 8 1
    nova delete testvm  || :
    nova keypair-add --pub-key /root/.ssh/id_rsa.pub testkey
    nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0
    nova secgroup-add-rule default tcp 1 65535 0.0.0.0/0
    nova secgroup-add-rule default udp 1 65535 0.0.0.0/0
    timeout 10m nova boot --poll --image $image_name --flavor $flavor --key-name testkey testvm | tee boot.out
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

    if iscloudver 7plus ; then
        wait_for 40 5 "timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $ssh_target curl -s http://169.254.169.254/openstack/latest/vendor_data.json|grep -q custom-key" "Custom vendordata not accessable from VM"
    fi

    local volumecreateret=0
    local volumeattachret=0
    local volumeresult=""
    local portresult=0

    # do volume tests for non-docker scenario only
    if [ $want_docker -ne 1 ] ; then
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

    # run tests for Magnum bay deployment
    if iscloudver 7plus && [[ $want_magnum = 1 ]]; then
        if ! magnum baymodel-show susek8sbaymodel > /dev/null 2>&1; then
            safely magnum baymodel-create --name susek8sbaymodel \
                --image-id SLE12SP1-JeOS-k8s-magnum \
                --keypair-id default \
                --external-network-id floating \
                --flavor-id m1.smaller \
                --master-flavor-id m2.smaller \
                --docker-volume-size 5 \
                --network-driver flannel \
                --coe kubernetes \
                --tls-disabled
        fi

        if ! magnum bay-show susek8sbay > /dev/null 2>&1; then
            safely magnum bay-create --name susek8sbay --baymodel susek8sbaymodel --node-count 1
            wait_for 500 3 'magnum bay-show susek8sbay | grep -q "status.*CREATE_COMPLETE"' "Creating Magnum bay for Kubernetes" "complain 130 'Magnum bay could not be created'"

            echo "Finished creating Magnum bay"
            safely magnum bay-show susek8sbay

            # cleanup Magnum deployment
            safely magnum bay-delete susek8sbay
            wait_for 300 3 'magnum bay-show susek8sbay > /dev/null 2>&1; [[ $? == 1 ]]' "Removing Magnum bay" "complain 131 'Magnum bay could not be removed'"
            safely magnum baymodel-delete susek8sbaymodel;
            wait_for 300 3 'magnum baymodel-show susek8sbaymodel > /dev/null 2>&1; [[ $? == 1 ]]' "Removing Magnum baymodel" "complain 131 'Magnum baymodel could not be removed'"
        fi
    fi

    if iscloudver 6plus ; then
        # check that no port is in binding_failed state
        for p in $(neutron port-list -f csv -c id --quote none | grep -v id); do
            if neutron port-show $p -f value | grep -qx binding_failed; then
                echo "binding for port $p failed.."
                portresult=1
            fi
        done
    fi

    echo "RadosGW Tests: $radosgwret"
    echo "Tempest: $tempestret"
    echo "Volume in VM: $volumeresult"
    echo "Ports in binding_failed: $portresult"

    test $tempestret = 0 -a $volumecreateret = 0 -a $volumeattachret = 0 \
        -a $radosgwret = 0 -a $portresult = 0 || exit 102
}


function oncontroller
{
    cd /root
    scp -r $SCRIPTS_DIR $mkcconf $novacontroller:
    ssh $novacontroller "export deployswift=$deployswift ; export deployceph=$deployceph ; export wanttempest=$wanttempest ;
        export tempestoptions=\"$tempestoptions\" ; export ostestroptions=\"$ostestroptions\" ;
        export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ;
        export wantradosgwtest=\"$wantradosgwtest\" ; export cloudsource=\"$cloudsource\" ;
        export libvirt_type=\"$libvirt_type\" ;
        export cloud=$cloud ; export TESTHEAD=$TESTHEAD ;
        . ./$(basename $SCRIPTS_DIR)/qa_crowbarsetup.sh ;  source .openrc; onadmin_set_source_variables; $@"
    return $?
}

function install_suse_ca
{
    # trust build key - workaround https://bugzilla.opensuse.org/show_bug.cgi?id=935020
    wget -O build.suse.de.key.pgp http://$susedownload/ibs/SUSE:/CA/SLE_12/repodata/repomd.xml.key
    safely sha1sum -c <<EOF
ee896d59206e451d563fcecef72608546bf10ad6  build.suse.de.key.pgp
EOF
    rpm --import build.suse.de.key.pgp

    onadmin_set_source_variables # for $slesdist
    zypper ar --refresh http://$susedownload/ibs/SUSE:/CA/$slesdist/SUSE:CA.repo
    safely zypper -n in ca-certificates-suse
}

function onadmin_testsetup
{
    pre_hook $FUNCNAME

    local numdnsservers=$(crowbar dns proposal show default | rubyjsonparse "puts j['deployment']['dns']['elements']['dns-server'].length")
    if [ "$want_multidnstest" = 1 ] && [ "$numdnsservers" -gt 1 ] && iscloudver 5plus; then
        for machine in $(get_all_suse_nodes); do
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
    if [[ $deployceph ]]; then
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
            rpm -Uvh http://$susedownload/ibs/SUSE:/SLE-12:/GA/standard/noarch/python-nose-1.3.0-8.4.noarch.rpm
        else
            if ! rpm -q python-nose &> /dev/null; then
                zypper ar http://$susedownload/ibs/Devel:/Cloud:/Shared:/11-SP3:/Update/standard/Devel:Cloud:Shared:11-SP3:Update.repo
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
    if iscloudver 5 && [ -n "$want_sles12" ] && [ $want_docker = 1 ] ; then
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
        if [ -n "$ostestroptions" ]; then
            scp $novacontroller:/var/lib/openstack-tempest-test/ostestr.log .
        fi
    fi
    exit $ret
}

function onadmin_addupdaterepo
{
    pre_hook $FUNCNAME

    local UPR=
    if iscloudver 7plus; then
        UPR=$tftpboot_repos12sp2_dir/PTF
    elif iscloudver 6plus ; then
        UPR=$tftpboot_repos12sp1_dir/PTF
    else
        UPR=$tftpboot_repos_dir/Cloud-PTF
    fi
    mkdir -p $UPR

    if [[ $UPDATEREPOS ]]; then
        local repo
        for repo in ${UPDATEREPOS//+/ } ; do
            safely wget --progress=dot:mega \
                -r --directory-prefix $UPR \
                --no-check-certificate \
                --no-parent \
                --no-clobber \
                --accept $arch.rpm,noarch.rpm \
                $repo
        done
        onadmin_setup_local_zypper_repositories
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

function onadmin_runupdate
{
    onadmin_repocleanup

    pre_hook $FUNCNAME

    # We need to set the correct MTU here since we haven't done any
    # proper network configuration yet.
    [[ $host_mtu ]] && ip link set mtu $host_mtu dev eth0

    zypper_patch

    if iscloudver 6plus ; then
        # The crowbar service might have been restarted during the zypper patch.
        # Wait for it to answer queries again to not break any further mkcloud
        # steps that might be executed after "runupdate".
        if systemctl --quiet is-enabled crowbar.service; then
            wait_for 20 10 "onadmin_is_crowbar_api_available" "crowbar service to restart"
        fi
    fi
}

function get_proposal_role_elements
{
    local proposal=$1
    local role=$2
    local element=$(crowbar $proposal proposal show default | \
        rubyjsonparse "
            puts j['deployment']['$proposal']['elements']['$role'];")
    echo $element
}

function get_neutron_server_node
{
    local element=$(crowbar neutron proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['neutron']\
                        ['elements']['neutron-server'][0];")
    NEUTRON_SERVER=`resolve_element_to_hostname "$element"`
}

function onneutron_wait_for_neutron
{
    get_neutron_server_node

    wait_for 300 3 "ssh $NEUTRON_SERVER 'rcopenstack-neutron status' |grep -q running" "neutron-server service running state"
    wait_for 200 3 " ! ssh $NEUTRON_SERVER '. .openrc && neutron --insecure agent-list -f csv --quote none'|tail -n+2 | grep -q -v ':-)'" "neutron agents up"

    ssh $NEUTRON_SERVER '. .openrc && neutron --insecure agent-list'
    ssh $NEUTRON_SERVER 'ping -c1 -w1 8.8.8.8' > /dev/null
    if [ "x$?" != "x0" ]; then
        complain 14 "ping to 8.8.8.8 from $NEUTRON_SERVER failed."
    fi
}

function power_cycle_and_wait
{
    local machine=$1

    ssh $machine "reboot"

    # "crowbar machines list" returns FQDNs but "crowbar node_state status"
    # only hostnames. Get hostname part of FQDN
    m_hostname=$(echo $machine | cut -d '.' -f 1)
    wait_for 400 1 'crowbar node_state status | grep -q -P "$m_hostname\s*Power"' \
        "node $m_hostname to power cycle"
}

function complain_if_problem_on_reboot
{
    if crowbar node_state status | grep ^d | grep -i "problem$"; then
        complain 17 "Some nodes rebooted with state Problem."
    fi
}

function reboot_controller_clusters
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
function onadmin_rebootcloud
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
function oncontroller_waitforinstance
{
    . .openrc
    safely nova list
    nova start testvm || complain 28 "Failed to start VM"
    safely nova list
    addfloatingip testvm
    local vmip=`nova show testvm | perl -ne 'm/ fixed.network [ |]*[0-9.]+, ([0-9.]+)/ && print $1'`
    [[ $vmip ]] || complain 12 "no IP found for instance"
    wait_for 100 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm to boot up"
}

function onadmin_rebootneutron
{
    pre_hook $FUNCNAME
    get_neutron_server_node
    echo "Rebooting neutron server: $NEUTRON_SERVER ..."

    ssh $NEUTRON_SERVER "reboot"
    wait_for 100 1 " ! netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to go down"
    wait_for 200 3 "netcat -z $NEUTRON_SERVER 22 >/dev/null" "node $NEUTRON_SERVER to be back online"

    onneutron_wait_for_neutron
}

# This will adapt Cloud6 admin server repositories to Cloud7 ones
function onadmin_prepare_cloudupgrade_repos_6_to_7
{
    test -z "$upgrade_cloudsource" && {
        complain 15 "upgrade_cloudsource is not set"
    }

    export cloudsource=$upgrade_cloudsource

    export_tftpboot_repos_dir

    # change CLOUDSLE11DISTISO/CLOUDSLE11DISTPATH according to the new cloudsource
    onadmin_set_source_variables

    # prepare installation repositories for nodes
    onadmin_prepare_sles12sp2_repos
    onadmin_prepare_sles12plus_cloud_repos

    if [[ $hacloud = 1 ]]; then
        add_ha12sp2_repo
    fi

    if [ -n "$deployceph" ] && iscloudver 5plus; then
        add_suse_storage_repo
    fi

    # recreate the SUSE-Cloud Repo with the latest iso
    onadmin_prepare_cloud_repos
    onadmin_add_cloud_repo

    # create skeleton for PTF repositories
    # during installation, this would be done by install-suse-cloud
    mkdir -p $tftpboot_repos12sp2_dir/PTF
    ensure_packages_installed createrepo
    safely createrepo $tftpboot_repos12sp2_dir/PTF

    # change system repositories to SP2
    zypper rr sles12sp1
    zypper rr sles12sp1up
    onadmin_setup_local_zypper_repositories
}

function onadmin_prepare_cloudupgrade
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

function onadmin_cloudupgrade_1st
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

function onadmin_cloudupgrade_2nd
{
    # Allow vender changes for packages as we might be updating an official
    # Cloud release to something form the Devel:Cloud projects. Note: For the
    # client nodes this is needs to happen after the updated provisioner
    # proposal is applied (see below).
    ensure_packages_installed crudini
    crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true

    # Upgrade Admin node
    zypper --non-interactive up --no-recommends -l
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

function onadmin_cloudupgrade_clients
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

function onadmin_cloudupgrade_reboot_and_redeploy_clients
{
    local barclamp=""
    local proposal=""
    local applied_proposals=""
    # reboot client nodes
    echo 'y' | suse-cloud-upgrade reboot-nodes

    # Give it some time and wait for the nodes to be back
    sleep 60
    waitnodes nodes

    onadmin_reapply_openstack_proposals

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

function onadmin_reapply_openstack_proposals
{
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
}

function onadmin_prepare_crowbar_upgrade
{
    if iscloudver 4; then
        complain 11 "This upgrade path is only supported for Cloud 5+"
    elif iscloudver 5; then
        # using the API, due to missing crowbar cli integration
        # move nodes to upgrade mode
        safely crowbar_api_request POST $crowbar_api /installer/upgrade/prepare.json
    else
        if crowbarctl upgrade prechecks --format plain | grep "false" ; then
            complain 11 "Some necessary check before the upgrade has failed"
        fi

        if crowbarctl upgrade repocheck crowbar --format plain | grep "missing" ; then
            complain 11 "Some repository is missing on admin server. Cannot upgrade."
        fi
        # FIXME: crowbarctl command can time out easily
        # Do not use it until https://bugzilla.novell.com/show_bug.cgi?id=997293 is fixed
        # safely crowbarctl upgrade prepare
        safely crowbar_api_request POST $crowbar_api /installer/upgrade/prepare.json
    fi
}

function onadmin_check_admin_server_upgraded
{
    if ! [ -e $crowbar_lib_dir/install/admin-server-upgraded-ok ]; then
        complain 99 "$crowbar_lib_dir/install/admin-server-upgraded-ok is missing"
    fi
}

function onadmin_upgrade_admin_server
{
    if iscloudver 5minus; then
        complain 11 "This upgrade path is only supported for Cloud 6+"
    else
        safely crowbarctl upgrade crowbar
    fi
}

function onadmin_crowbarbackup
{
    pre_hook $FUNCNAME
    local backupmode=$1
    local btarballname=backup-crowbar
    local btarball=${btarballname}.tar.gz
    rm -f /tmp/$btarball

    if iscloudver 6plus ; then
        safely crowbarctl backup create $btarballname
        pushd /tmp
        # temporary workaround, as crowbarctl does not support to lookup by name yet
        local bid=`crowbarctl backup  list --plain | grep ${btarballname} | cut -d" " -f1`
        safely crowbarctl backup download $bid
        popd
        [[ -e /tmp/$btarball ]] || complain 12 "Backup tarball not created: /tmp/$btarball"
    elif iscloudver 5 && [[ $backupmode = "with_upgrade" ]] ; then
        # using the API, due to missing crowbarctl integration
        safely curl -s $crowbar_api_digest $crowbar_api/installer/upgrade/file > /tmp/$btarball
    else
        AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
            safely bash -x /usr/sbin/crowbar-backup backup /tmp/$btarball
    fi
}

function onadmin_crowbarpurge
{
    pre_hook $FUNCNAME
    if iscloudver 6plus ; then
        complain 3 "crowbarpurge is not implemented for Cloud 6+ (maybe not needed)"
    fi

    # Purge files to pretend we start from a clean state
    cp -a $crowbar_lib_dir/cache/etc/resolv.conf /etc/resolv.conf

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

# parameters
#  1:  method  GET|POST
#  2:  api     schema://hostname.tld
#  3:  apipath /path/to/request
#  4:  curlopts options to curl command (like -d"something")
#  5+: headers additional headers
function crowbar_api_request
{
    local method=${1:-GET}
    local api=${2:-$crowbar_api}
    local api_path=${3:-/}
    local curl_opts=${4:-}
    shift ; shift ; shift ; shift
    local outfile=crowbar-api-request.txt
    rm -f $outfile
    local http_code=`curl --max-time 300 -X $method $curl_opts "${@/#/-H}" -s -o $outfile -w '%{http_code}' $api$api_path`
    if [[ $http_code = 000 ]]; then
        echo "Cannot reach $api$api_path: http code 000"
        return 1
    fi
    if ! [[ $http_code =~ [23].. ]]; then
        cat $outfile
        echo "Request to $api$api_path returned http code: $http_code"
        return 1
    else
        return 0
    fi
}

function onadmin_is_crowbar_api_available
{
    local api_path=$crowbar_api_installer_path/status.json
    iscloudver 5minus && api_path=
    crowbar_api_request GET "$crowbar_api" "$api_path" "$crowbar_api_digest"
}

function onadmin_is_crowbar_init_api_available
{
    crowbar_api_request GET $crowbar_init_api "/status" "" "$crowbar_api_v2_header"
}

function onadmin_crowbarrestore
{
    pre_hook $FUNCNAME
    local restoremode=$1
    local btarballname=backup-crowbar
    local btarball=${btarballname}.tar.gz
    zypper --non-interactive in --auto-agree-with-licenses -t pattern cloud_admin

    if iscloudver 6plus ; then
        systemctl start crowbar.service
        wait_for 20 10 "onadmin_is_crowbar_api_available" "crowbar service to start"
        case $restoremode in
            with_upgrade)
                # restore after upgrade has different workflow (missing APIs) than
                #   a restore from a backup of the same cloud release
                safely crowbar_api_request POST $crowbar_api /installer/upgrade/start.json "-F file=@/tmp/$btarball"
            ;;
            *)
                # crowbarctl needs --anonymous to workaround a crowbarctl issue which leads to two api requests
                # per call (auth + actual request) which fails when running crowbarctl directly on the admin node
                safely crowbarctl backup upload /tmp/$btarball --anonymous
                safely crowbarctl backup restore $btarballname --anonymous --yes
            ;;
        esac

        # first wait until the restore process is no longer running
        wait_for 360 10 "crowbar_restore_status | grep -q '\"restoring\": *false'" "crowbar to be restored" "crowbar_restore_status ; complain 11 'crowbar restore failed'"
        # then check the actual status
        if ! crowbar_restore_status | grep -q '"success": *true' ; then
            crowbar_restore_status
            complain 37 "Crowbar restore from backup failed."
        fi
    else
        do_set_repos_skip_checks

        AGREEUNSUPPORTED=1 CB_BACKUP_IGNOREWARNING=1 \
            safely bash -x /usr/sbin/crowbar-backup restore /tmp/$btarball
    fi
}

function onadmin_crowbar_nodeupgrade
{
    local endpoint
    local http_code
    for endpoint in services backup nodes; do
        safely crowbar_api_request POST $crowbar_api /installer/upgrade/${endpoint}.json
    done
    wait_for 360 10 "crowbar_nodeupgrade_status | grep -q '\"left\": *0'" "crowbar to finish the nodeupgrade"
    if ! crowbar_nodeupgrade_status | grep -q '"failed": *0' ; then
        crowbar_nodeupgrade_status
        complain 38 "Crowbar nodeupgrade failed."
    fi
}

function onadmin_qa_test
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

# Run cct tests
# By default all tests specified in $cct_tests will be run + all functional tests
# $cct_tests           -> mandatory, typical value is features:base
# $cct_git_url         -> optional, cct git repo url, default is https://github.com/SUSE-Cloud/cct.git
# $cct_checkout_branch -> optional, pick git branch to be tested, default is master
# $cct_skip_func_tests -> optional, functional tests will be skipped if value is 1, default is 0
function onadmin_run_cct
{
    local ret=0
    if iscloudver 5plus && [[ $cct_tests ]]; then
        # - install cct dependencies
        addcctdepsrepo
        ensure_packages_installed git-core gcc make ruby2.1-devel

        if [[ $cct_tests =~ ":ui:" ]]; then
            ensure_packages_installed libqt4-devel libQtWebKit-devel xorg-x11-server xorg-x11-server-extra zlib-devel
        fi

        local checkout_branch=master
        local git_url=${cct_git_url:-https://github.com/SUSE-Cloud/cct.git}
        local skip_func_tests=${cct_skip_func_tests:-0}

        if [ -n "$cct_checkout_branch" ] ; then
            checkout_branch=$cct_checkout_branch
        else
            # checkout branches if needed, otherwise use master
            case "$cloudsource" in
                develcloud5|GM5|GM5+up)
                    checkout_branch=cloud5
                    ;;
                develcloud6|GM6|GM6+up)
                    checkout_branch=cloud6
                    ;;
            esac
        fi

        if iscloudver 6plus && [ "$skip_func_tests" == 0 ]; then
            # 2016-03-29: manila functional tests are hitting frequently a timeout, disable for now
            for test in "nova-disabled" "manila-disabled" ; do
                if crowbarctl proposal list $test &> /dev/null; then
                    cct_tests+="+test:func:${test}client"
                fi
            done
        fi

        # prepare CCT checkout
        local ghdir=/root/github.com/SUSE-Cloud
        mkdir -p $ghdir
        pushd $ghdir
        git clone $git_url -b $checkout_branch
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
        if [[ $cct_tests =~ ":ui:" ]]; then
            # Once bundler is in version >=1.10 the next line must be extended by: --with ui_tests
            bundle install
            cct_ui_tests=true
        else
            bundle install --without ui_tests
        fi

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

function onadmin_devsetup
{
    # install dev setup dependencies
    add_sdk_repo
    ensure_packages_installed git make gcc ruby2.1-devel sqlite3-devel libxml2-devel libopenssl-devel postgresql-devel

    # create development folders
    mkdir -p /opt/crowbar/crowbar_framework/db /opt/crowbar/barclamps

    # copy existing database
    ln -sf /opt/dell/crowbar_framework/db/production.sqlite3 /opt/crowbar/crowbar_framework/db/development.sqlite3

    # clone git repos
    local crowbar_git_dir=/opt/crowbar/git/crowbar
    git clone https://github.com/crowbar/crowbar.git $crowbar_git_dir
    for component in core openstack ceph ha; do
        git clone https://github.com/crowbar/crowbar-$component.git $crowbar_git_dir/barclamps/$component
    done

    # install development gems and generate dir tree
    pushd $crowbar_git_dir
    bundle install --path /opt/crowbar
    GUARD_SYNC_HOST=localhost bundle exec guard
    popd

    # install crowbar gems
    pushd /opt/crowbar/crowbar_framework
    bundle install --path /opt/crowbar
    su -s /bin/sh - crowbar sh -c "RAILS_ENV=development bundle exec rake db:create db:migrate"
    popd

    # install barclamps
    local components=$(find /opt/crowbar/barclamps -mindepth 1 -maxdepth 1 -type d)
    CROWBAR_DIR=/opt/crowbar RAILS_ENV=development /opt/crowbar/bin/barclamp_install.rb $components
}

# Set the aliases for nodes.
# This is usually needed before batch step, so batch can refer
# to node aliases in the scenario file.
function onadmin_setup_aliases
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

function onadmin_batch
{
    pre_hook $FUNCNAME

    if iscloudver 5plus; then
        sed -i "s/##hypervisor_ip##/$admingw/g" ${scenario}
        if iscloudver 6plus; then
            safely crowbar batch --exclude manila --timeout 2400 build ${scenario}
            if grep -q "barclamp: manila" ${scenario}; then
                get_novacontroller
                safely oncontroller oncontroller_manila_generic_driver_setup
                get_manila_service_instance_details
                sed -i "s/##manila_instance_name_or_id##/$manila_service_vm_uuid/g; \
                        s/##service_net_name_or_ip##/$manila_tenant_vm_ip/g; \
                        s/##tenant_net_name_or_ip##/$manila_tenant_vm_ip/g" \
                        ${scenario}
                safely crowbar batch --include manila --timeout 2400 build ${scenario}
            fi
        else
            safely crowbar batch --timeout 2400 build ${scenario}
        fi
        return $?
    else
        complain 116 "crowbar batch is only supported with cloudversions 5plus"
    fi
}

# deactivate proposals and forget cloud nodes
# can be useful for faster testing cycles
function onadmin_teardown
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
    for node in $(get_all_discovered_nodes); do
        if iscloudver 6plus; then
            safely crowbarctl node delete $node
        else
            safely crowbar machines delete $node
        fi
    done
}

function onadmin_runlist
{
    for cmd in "$@" ; do
        local TIMEFORMAT="timing for qa_crowbarsetup function 'onadmin_$cmd' real=%R user=%U system=%S"
        time onadmin_$cmd || complain $? "$cmd failed with code $?"
    done
}

#--

ruby=/usr/bin/ruby
iscloudver 5plus && ruby=/usr/bin/ruby.ruby2.1
export_tftpboot_repos_dir
set_proposalvars
