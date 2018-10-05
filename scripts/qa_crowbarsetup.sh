#!/bin/bash
# based on https://github.com/SUSE/cloud/wiki/SUSE-Cloud-Installation-Manual

# This has only been tested on aarch64, x86_64 and s390x so far

shopt -s extglob

mkcconf=mkcloud.config
if [ -z "$testfunc" ] && [ -e $mkcconf ]; then
    source $mkcconf
fi

: ${SCRIPTS_DIR:=$(dirname $(readlink -e $BASH_SOURCE))}
scripts_lib_dir=${SCRIPTS_DIR}/lib
common_scripts="mkcloud-common.sh qa_crowbarsetup-help.sh"
for script in $common_scripts; do
    source ${scripts_lib_dir}/$script
done

# not being sourced from mkcloud is a feature
is_onhost && complain 9 "qa_crowbarsetup.sh should not be sourced within mkcloud. Shared functions are in files in scripts/lib/: eg. mkcloud-common.sh or qa_crowbarsetup-help.sh."

# this needs to be after mkcloud.config got sourced
if [[ $debug_qa_crowbarsetup = 1 ]] ; then
    set -x
    PS4='+(${BASH_SOURCE##*/}:${LINENO}) ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

# defaults
: ${cinder_backend:=''}
: ${cinder_netapp_storage_protocol:=iscsi}
: ${cinder_netapp_login:=openstack}
: ${cinder_netapp_password:=''}
: ${want_separate_ceph_network:=0}
: ${crowbar_networkingmode:=single}
: ${crowbar_name:=crowbar}
: ${want_rootpw:=linux}
: ${want_raidtype:="raid1"}
: ${want_ipmi_username:=root}
: ${want_ipmi_pxeextraopts:=options=persistent}
: ${want_multidnstest:=1}
: ${want_tempest:=1}
: ${want_s390:=''}
: ${want_horizon_integration_test:=''}
: ${want_batch_dir:="${SCRIPTS_DIR}/scenarios"}
if iscloudver 8plus; then
    : ${want_cinder_rbd_flatten_snaps:=1}
    : ${want_clustered_rabbitmq:=1}
else
    : ${want_cinder_rbd_flatten_snaps:=0}
    : ${want_clustered_rabbitmq:=0}
fi

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
clusternodesrabbit=
clusternamedata="data"
clusternameservices="services"
clusternamenetwork="network"
clusternamerabbit="data" # default to database nodes
wanthyperv=
crowbar_api=http://localhost:3000
crowbar_api_installer_path=/installer/installer
crowbar_api_digest="--digest -u crowbar:crowbar"
crowbar_install_log=/var/log/crowbar/install.log
crowbar_init_api=http://localhost:4567/api
crowbar_lib_dir=/var/lib/crowbar
crowbar_api_v2_header="Accept: application/vnd.crowbar.v2.0+json"
declare -a unclustered_nodes
export magnum_k8s_image_name=openstack-magnum-k8s-image

export nodenumber=${nodenumber:-2}
if iscloudver 7plus; then
    export tempestoptions=${tempestoptions:---smoke}
else
    export tempestoptions=${tempestoptions:--t -s}
fi
export nodes=
export cinder_backend
export cinder_netapp_storage_protocol
export cinder_netapp_login
export cinder_netapp_password
export localreposdir_target
export want_ipmi=${want_ipmi:-}
[ "$libvirt_type" = hyperv ] && export wanthyperv=1
[ "$libvirt_type" = xen ] && export wantxenpv=1 # xenhvm is broken anyway

export CROWBAR_EXPERIMENTAL=true
export CROWBAR_VERIFY_SSL=false
# export crowbar timeout to have the new timeout also in GM without updates
export CROWBAR_TIMEOUT=3600

[ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

export ZYPP_LOCK_TIMEOUT=120

function onadmin_help
{
    # The help moved to lib/qa_crowbarsetup-help.sh
    # because it needs to be usable from mkcloud as well.
    # This function is here only for backwards compatibility.
    qacrowbarsetup_help
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
    set_noproxyvar
    test -n "$pre" && eval "$pre"
    echo $func >> /root/qa_crowbarsetup.steps.log
}

function mount_localreposdir_target
{
    if [ -z "$localreposdir_target" ]; then
        return
    fi
    if mountpoint -q -- "$localreposdir_target" ; then
        echo "$localreposdir_target is already mounted"
        return
    fi
    mkdir -p $localreposdir_target
    if ! grep -q "$localreposdir_target\s\+$localreposdir_target" /etc/fstab ; then
        echo 'force_drivers+="9pnet_virtio"' > /etc/dracut.conf.d/03-libvirt.conf
        dracut -f
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
# input1: path       - path within the specified reposerver
# input2: targetdir  - where to mount (usually in /srv/tftpboot/repos/DIR )
# input3(optional):  zypper_alias - if set, this dir is added as a local repo for zypper
function add_mount
{
    local path="$1"
    local targetdir="$2"
    local zypper_alias="$3"

    local localreposdir_path

    nfssrc="$nfsserver_ip:$nfsserver_base_path/$path"
    localreposdir_path="$localreposdir_target/$path"

    if [ -n "$localreposdir_target" ]; then
        # localreposdir_src holds a mirror of clouddata
        if [ -z "$localreposdir_path" ]; then
            complain 34 "IBS builds are not supported in local mode"
        fi

        add_bind_mount "$localreposdir_path" "$targetdir"
    else
        if [ -z "$nfssrc" ]; then
            complain 50 "BUG: add_mount() called with empty nfssrc parameter" \
                "(targetdir=$targetdir alias=$zypper_alias)\n" \
                "This will break for those using NFS."
        fi
        add_nfs_mount "$nfssrc" "$targetdir"
    fi

    if [ -n "${zypper_alias}" ]; then
        $zypper rr "${zypper_alias}"
        safely $zypper ar -f "${targetdir}" "${zypper_alias}"
    fi
}

function issusenode
{
    local machine=$1
    [[ $machine =~ ^${crowbar_name}\. ]] && return 0
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
export MAGNUMCLIENT_INSECURE=true
# Extra environment variable because of https://launchpad.net/bugs/1535284
export manilaclient_INSECURE=true
export MANILACLIENT_INSECURE=true
export MISTRALCLIENT_INSECURE=true
export TROVECLIENT_INSECURE=true

function isrepoworking
{
    local repo=$1
    curl -s $reposerver_url/disabled | egrep -q "^$repo" && {
        echo "WARNING: The repo $repo is marked as broken"
        return 1
    }
    return 0
}

function export_tftpboot_dirs
{
    tftpboot_suse_dir=/srv/tftpboot/suse-$suseversion
    tftpboot_repos_dir=$tftpboot_suse_dir/$arch/repos
}

function addslestestupdates
{
    if isrepoworking SLES$slesversion-Updates-test ; then
        add_mount "repos/$arch/SLES$slesversion-Updates-test/" \
            "$tftpboot_repos_dir/SLES$slesversion-Updates-test/" "slestup"
    fi
}

function addcloudmaintupdates
{
    add_mount "repos/$arch/SUSE-OpenStack-Cloud-$cloudrepover-Updates/" \
        "$tftpboot_repos_dir/SUSE-OpenStack-Cloud-$cloudrepover-Updates/" \
        "cloudmaintup"
}

function addcloudtestupdates
{
    add_mount "repos/$arch/SUSE-OpenStack-Cloud-$cloudrepover-Updates-test/" \
        "$tftpboot_repos_dir/SUSE-OpenStack-Cloud-$cloudrepover-Updates-test/" "cloudtup"
}

function addcloudpool
{
    add_mount "repos/$arch/SUSE-OpenStack-Cloud-$cloudrepover-Pool/" \
        "$tftpboot_repos_dir/SUSE-OpenStack-Cloud-$cloudrepover-Pool/" \
        "cloudpool"
}

function add_salt_repo
{
    local suffix
    for suffix in Pool Updates; do
        add_mount "repos/$arch/SLE12-Module-Adv-Systems-Management-$suffix/" \
            "$tftpboot_repos_dir/SLE12-Module-Adv-Systems-Management-$suffix/" "salt-$suffix"
    done
}

function add_sdk_repo
{
    local sdk_repo_priority
    sdk_repo_priority=199

    export_tftpboot_dirs

    local suffix
    for suffix in Pool Updates; do
        add_mount "repos/$arch/SLE$slesversion-SDK-$suffix/" \
            "$tftpboot_repos_dir/SLE$slesversion-SDK-$suffix/" "SDK-$suffix"
    done

    if [[ "$want_test_updates" = 1 ]] && isrepoworking SLE$slesversion-SDK-Updates-test ; then
        add_mount "repos/$arch/SLE$slesversion-SDK-Updates-test/" \
            "$tftpboot_repos_dir/SLE$slesversion-SDK-Updates-test/" "SDK-Updates-test"
    fi
}

function add_continuousdelivery_repo
{
    local stage=
    [[ $TESTHEAD ]] && stage=":/Staging"
    # priority required to overwrite the default cloud6 packages
    $zypper ar -p 92 -f http://$susedownload/ibs/Devel:/Cloud:/6:/SAP${stage}/SLE_12_SP1/ dc6cd
}

function add_ha_repo
{
    local repo
    for repo in SLE$slesversion-HA-{Pool,Updates}; do
        # Note no zypper alias parameter here since we don't want to
        # zypper addrepo on the admin node.
        add_mount "repos/$arch/$repo" \
            "$tftpboot_repos_dir/$repo"
    done
    if [[ $want_test_updates = 1 ]] && isrepoworking SLE$slesversion-HA-Updates-test ; then
        add_mount "repos/$arch/SLE$slesversion-HA-Updates-test/" \
            "$tftpboot_repos_dir/SLE$slesversion-HA-Updates-test/"
    fi
}

function add_suse_storage_repo
{
    # Note no zypper alias parameter here since we don't want
    # to zypper addrepo on the admin node.
    local repo
    if [ -n "$deployceph" ] || [[ $want_external_ceph = 1 ]]; then
        for repo in SUSE-Enterprise-Storage-$sesversion-{Pool,Updates}; do
            add_mount "repos/$arch/$repo" "$tftpboot_repos_dir/$repo"
        done

        if [[ "$want_test_updates" = 1 ]] ; then
            if isrepoworking SUSE-Enterprise-Storage-$sesversion-Updates-test ; then
                add_mount "repos/$arch/SUSE-Enterprise-Storage-$sesversion-Updates-test/" \
                    "$tftpboot_repos_dir/SUSE-Enterprise-Storage-$sesversion-Updates-test/"
            fi
        fi
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
    safely crowbarctl node list --no-meta --plain | LC_ALL=C sort
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
    iscloudver 7 && target="suse-12.2"
    iscloudver 8 && target="suse-12.3"
    iscloudver 9plus && target="suse-12.4"

    local sles12plusnodes=($(knife search node "target_platform:$target AND \
        NOT crowbar_admin_node:true" -a name | grep ^name: | cut -d : -f 2 | \
        sort | sed 's/\s//g'))
    if [[ $hacloud = 1 ]]; then
        # This basically does an intersection of the lists in sles12plusnode and unclustered_node
        # i.e. pick all sles12plus nodes that are not part of a cluster
        sles12plusnodes=($(comm -1 -2 <(printf "%s\n" ${sles12plusnodes[@]}) \
            <(printf "%s\n" ${unclustered_nodes[@]})))
    fi
    echo ${sles12plusnodes[@]}
}

function show_crowbar_nodes_to_upgrade
{
    crowbarctl upgrade status nodes --plain | grep not_upgraded | cut -d ' ' -f 2 | cut -d '.' -f 1 | \
    sort | tr '\n' ','| sed 's/,$//' | xargs printf 'Upgrading nodes: %s\r'
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
                [[ $group =~ "+rabbit" ]]   && clusternamerabbit=$clustername
            ;;
            services)
                clusternodesservices="$nodes"
                [[ $group =~ "+data" ]]     && clusternamedata=$clustername
                [[ $group =~ "+network" ]]  && clusternamenetwork=$clustername
                [[ $group =~ "+rabbit" ]]   && clusternamerabbit=$clustername
            ;;
            network)
                clusternodesnetwork="$nodes"
                [[ $group =~ "+data" ]]     && clusternamedata=$clustername
                [[ $group =~ "+services" ]] && clusternameservices=$clustername
                [[ $group =~ "+rabbit" ]]   && clusternamerabbit=$clustername
            ;;
            rabbit)
                clusternamerabbit="$clustername" # defaults to data cluster
                clusternodesrabbit="$nodes"
                [[ $group =~ "+services" ]] && clusternameservices=$clustername
                [[ $group =~ "+network" ]]  && clusternamenetwork=$clustername
                [[ $group =~ "+data" ]]     && clusternamedata=$clustername
            ;;
        esac
    done
    if [[ $clusternamerabbit = data ]]; then
        clusternodesrabbit=$clusternodesdata
    fi
    unclustered_nodes=($nodesavailable)

    echo "............................................................"
    echo "The cluster node assignment (for your information):"
    echo "data cluster:"
    printf "   %s\n" $clusternodesdata
    echo "network cluster:"
    printf "   %s\n" $clusternodesnetwork
    echo "services cluster:"
    printf "   %s\n" $clusternodesservices
    echo "rabbitmq cluster:"
    printf "   %s\n" $clusternodesrabbit
    echo "other non-clustered nodes (free for compute / storage):"
    printf "   %s\n" ${unclustered_nodes[@]}
    echo "............................................................"
}

function wget_iso_and_unpack_to
{
    local isourl="$1"
    local distiso="$2"
    local targetdir="$3"
    mkdir -p /mnt/cloud "$targetdir"
    (
        cd "$targetdir"
        wget --progress=dot:mega -r -np -nc -e robots=off -A "$distiso" http://$isourl \
        || complain 71 "iso not found"
        local cloudiso=$(ls $isourl/*.iso | tail -1)
        if [ -z "$cloudiso" ]; then
            complain 75 "failed to download $distiso from http://$isourl"
        fi
        safely mount -o loop,ro -t iso9660 $cloudiso /mnt/cloud
        safely rsync -av --delete-after /mnt/cloud/ .
        safely umount /mnt/cloud
        echo $cloudiso > isoversion
    )
}

function onadmin_prepare_sles12sp1_repos
{
    onadmin_prepare_sles_installmedia
    onadmin_prepare_sles12sp1_other_repos
}

function onadmin_prepare_sles12plus_cloud_repos
{
    #  create empty repository when there is none yet
    ensure_packages_installed createrepo

    for repo in SUSE-OpenStack-Cloud-$cloudrepover-{Pool,Updates}; do
        if [ ! -e "$tftpboot_repos_dir/$repo/repodata/" ] ; then
            mkdir -p "$tftpboot_repos_dir/$repo"
            safely createrepo "$tftpboot_repos_dir/$repo"
        fi
    done
}

function onadmin_prepare_sles_installmedia
{
    local a
    for a in $architectures; do
        local sles_mount="$tftpboot_suse_dir/$a/install"
        add_mount "install/suse-$suseversion/$a/install" "$sles_mount"

        if [ ! -d "$sles_mount/media.1" ] ; then
            complain 34 "We do not have suse-$suseversion install media - giving up"
        fi
    done
}

function onadmin_prepare_sles12sp1_other_repos
{
    for repo in SLES12-SP1-{Pool,Updates,LTSS-Updates}; do
        add_mount "repos/$arch/$repo" "$tftpboot_repos_dir/$repo"
        if [[ $want_s390 ]] ; then
            add_mount "repos/s390x/$repo" \
                "$tftpboot_suse12sp1_dir/s390x/repos/$repo"
        fi
    done
}

function onadmin_prepare_sles_other_repos
{
    for repo in SLES$slesversion-{Pool,Updates}; do
        add_mount "repos/$arch/$repo" "$tftpboot_repos_dir/$repo"
    done
    # FIXME LTSS repo empty for SLE12-SP3/SP4, do not add it as zypper does not like empty repos
    if iscloudver 7minus ; then
        add_mount "repos/$arch/SLES$slesversion-LTSS-Updates" "$tftpboot_repos_dir/SLES$slesversion-LTSS-Updates"
    fi
}

function onadmin_prepare_cloud_repos
{
    local targetdir="$tftpboot_repos_dir/Cloud"
    mkdir -p $targetdir

    if [ -n "${localreposdir_target}" ]; then
        add_mount "repos/$arch/${CLOUDLOCALREPOS}/" \
                "$targetdir"
    else
        wget_iso_and_unpack_to "$CLOUDISOURL" "$CLOUDISONAME" "$targetdir"
        if [[ $want_s390 ]] ; then
            wget_iso_and_unpack_to "$CLOUDISOURL" "${CLOUDISONAME/$arch/s390x}" "${targetdir/$arch/s390x}"
        fi
    fi

    if [ ! -e "$targetdir/media.1" ] ; then
        complain 35 "We do not have cloud install media in $targetdir - giving up"
    fi

    case "$cloudsource" in
        GM6)
            addcloudpool
            ;;
        GM6+up)
            addcloudpool
            addcloudmaintupdates
            ;;
        GM7)
            addcloudpool
            ;;
        GM7+up)
            addcloudpool
            addcloudmaintupdates
            ;;
        GM8)
            addcloudpool
            ;;
        GM8+up)
            addcloudpool
            addcloudmaintupdates
            ;;
    esac

    if [[ "$want_test_updates" = 1 ]] ; then
        case "$cloudsource" in
            GM6)
                addslestestupdates
                ;;
            GM6+up)
                addslestestupdates
                addcloudtestupdates
                ;;
            GM7)
                addslestestupdates
                ;;
            GM7+up)
                addslestestupdates
                addcloudtestupdates
                ;;
            GM8)
                addslestestupdates
                ;;
            GM8+up)
                addslestestupdates
                addcloudtestupdates
                ;;
            develcloud6)
                addslestestupdates
                ;;
            develcloud7)
                addslestestupdates
                ;;
            develcloud8)
                addslestestupdates
                ;;
            *cloud9|M?|Beta*|RC*|GMC*)
                addslestestupdates
                ;;
            *)
                complain 26 "no test update repos defined for cloudsource=$cloudsource"
                ;;
        esac
    fi
}


function onadmin_add_cloud_repo
{
    local targetdir="$tftpboot_repos_dir/Cloud/"

    $zypper rr Cloud
    safely $zypper ar -f $targetdir Cloud

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
    echo -n "This cloud was installed from: "
    cat /etc/cloudversion
    echo
    ) >> /etc/motd
}

function onadmin_write_cloud_info
{
    (
    echo -n "This cloud was installed on: "
    cat ~/cloud
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
}


function do_set_repos_skip_checks
{
    # We don't use the proper pool/updates repos when using a devel build
    if iscloudver 5plus && [[ $cloudsource =~ (develcloud|GM5$|GM6$) ]]; then
        export REPOS_SKIP_CHECKS+=" SUSE-Cloud-$cloudrepover-Pool SUSE-Cloud-$cloudrepover-Updates"
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
        case "$repo_name" in
            SLES*)
                echo "      features: ['os']"
                ;;
            *HA*)
                echo "      features: ['ha']"
                ;;
            *Storage*)
                echo "      features: ['ceph']"
                ;;
            *OpenStack*)
                echo "      features: ['openstack']"
                ;;
        esac

    done
}

function create_repos_yml
{
    local repos_yml="/etc/crowbar/repos.yml"
    local tmp_yml=$(mktemp).yml
    local additional_repos=

    echo --- > $tmp_yml

    common_set_versions

    # Clone test updates from admin node
    local baseurl=http://${crowbar_name}.$cloudfqdn:8091/

    grep -q SLES$slesversion-Updates-test /etc/fstab && \
        additional_repos+=" SLES$slesversion-Updates-test=$baseurl/suse-$suseversion/$arch/repos/SLES$slesversion-Updates-test"
    # FIXME LTSS repo empty for SLE12-SP3/SP4, do not add it as zypper does not like empty repos
    if iscloudver 7minus ; then
        grep -q SLES$slesversion-LTSS-Updates /etc/fstab && \
            additional_repos+=" SLES$slesversion-LTSS-Updates=$baseurl/suse-$suseversion/$arch/repos/SLES$slesversion-LTSS-Updates"
    fi
    grep -q SLE$slesversion-HA-Updates-test /etc/fstab && \
        additional_repos+=" SLE$slesversion-HA-Updates-test=$baseurl/suse-$suseversion/$arch/repos/SLE$slesversion-HA-Updates-test"
    grep -q SUSE-OpenStack-Cloud-$cloudrepover-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-OpenStack-Cloud-$cloudrepover-Updates-test=$baseurl/suse-$suseversion/$arch/repos/SUSE-OpenStack-Cloud-$cloudrepover-Updates-test"
    grep -q SUSE-Enterprise-Storage-$sesversion-Updates-test /etc/fstab && \
        additional_repos+=" SUSE-Enterprise-Storage-$sesversion-Updates-test=$baseurl/suse-$suseversion/$arch/repos/SUSE-Enterprise-Storage-$sesversion-Updates-test"

    if iscloudver 6; then
        for devel_repo in ${want_devel_repos//,/ }; do
            case "$devel_repo" in
                storage)
                    additional_repos+=" Devel-Storage=http://$susedownload/ibs/Devel:/Storage:/2.1/SLE12_SP1/"
                    ;;
                virt)
                    additional_repos+=" Devel-Virt=http://$susedownload/ibs/Devel:/Virt:/SLE-12-SP1/SUSE_SLE-12-SP1_Update_standard/"
                    ;;
            esac
        done
    fi

    if iscloudver 7; then
        for devel_repo in ${want_devel_repos//,/ }; do
            case "$devel_repo" in
                storage)
                    additional_repos+=" Devel-Storage=http://$susedownload/ibs/Devel:/Storage:/4.0/SLE12_SP2/"
                    ;;
                virt)
                    additional_repos+=" Devel-Virt=http://$susedownload/ibs/Devel:/Virt:/SLE-12-SP2/SUSE_SLE-12-SP2_GA_standard/"
                    ;;
            esac
        done
    fi

    create_repos_yml_for_platform "suse-$suseversion" "$arch" "$tftpboot_repos_dir" \
        $additional_repos \
        >> $tmp_yml

    mv $tmp_yml $repos_yml
}


function onadmin_set_source_variables
{
    case "$cloudsource" in
        develcloud6)
            CLOUDISOURL=${want_cloud6_iso_url:="$susedownload/ibs/Devel:/Cloud:/6/images/iso"}
            [ -n "$TESTHEAD" ] && CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/6:/Staging/images/iso"
            CLOUDISONAME=${want_cloud6_iso:="SUSE-OPENSTACK-CLOUD-6-${arch}-Media1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-devel"
        ;;
        develcloud7)
            CLOUDISOURL=${want_cloud7_iso_url:="$susedownload/ibs/Devel:/Cloud:/7/images/iso"}
            [ -n "$TESTHEAD" ] && CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/7:/Staging/images/iso"
            CLOUDISONAME=${want_cloud7_iso:="SUSE-OPENSTACK-CLOUD-7-${arch}-Media1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-devel"
        ;;
        develcloud8)
            CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/8/images/iso"
            [ -n "$TESTHEAD" ] && CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/8:/Staging/images/iso"
            CLOUDISONAME="SUSE-OPENSTACK-CLOUD-CROWBAR-8-${arch}-Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-Crowbar-8-devel"
        ;;
        develcloud9)
            CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/9/images/iso"
            [ -n "$TESTHEAD" ] && CLOUDISOURL="$susedownload/ibs/Devel:/Cloud:/9:/Staging/images/iso"
            CLOUDISONAME="SUSE-OPENSTACK-CLOUD-CROWBAR-9-${arch}-Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-Crowbar-9-devel"
        ;;
        susecloud9)
            CLOUDISOURL="$susedownload/ibs/SUSE:/SLE-12-SP4:/Update:/Products:/Cloud9/images/iso/"
            CLOUDISONAME="SUSE-OPENSTACK-CLOUD-CROWBAR-9-${arch}*Media1.iso"
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-Crowbar-9-official"
        ;;
        GM6|GM6+up)
            cs=$cloudsource
            [[ $cs =~ GM6 ]] && cs=GM
            CLOUDISOURL="${want_cloud6_iso_url:=$reposerver/install/SLE-12-SP1-Cloud6-$cs/}"
            CLOUDISONAME=${want_cloud6_iso:="SUSE-OPENSTACK-CLOUD-6-${arch}*1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-6-official"
        ;;
        GM7|GM7+up)
            cs=$cloudsource
            [[ $cs =~ GM7 ]] && cs=GM
            CLOUDISOURL="${want_cloud7_iso_url:=$reposerver/install/SLE-12-SP2-Cloud7-$cs/}"
            CLOUDISONAME=${want_cloud7_iso:="SUSE-OPENSTACK-CLOUD-7-${arch}*1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-7-official"
        ;;
        GM8|GM8+up)
            cs=$cloudsource
            [[ $cs =~ GM8 ]] && cs=GM
            # TODO: Switch to clouddata when released
            CLOUDISOURL="${want_cloud8_iso_url:=$reposerver/install/SLE-12-SP3-Cloud8-$cs/}"
            CLOUDISONAME=${want_cloud8_iso:="SUSE-OPENSTACK-CLOUD-8-${arch}*1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-8-official"
        ;;
        GMC*|M?|RC?)
            cs=$cloudsource
            CLOUDISOURL="${want_cloud9_iso_path:=$susedownload/install/SLE-12-SP4-Cloud9-$cs/}"
            CLOUDISONAME=${want_cloud9_iso:="SUSE-OPENSTACK-CLOUD-CROWBAR-9-${arch}*1.iso"}
            CLOUDLOCALREPOS="SUSE-OpenStack-Cloud-Crowbar-9-official"
        ;;
        *)
            complain 76 "You must set environment variable cloudsource=develcloud6|develcloud7|develcloud8|develcloud9|Mx|GM6|GM7"
        ;;
    esac

    if [ -n "$TESTHEAD" ] && [[ $cloudsource =~ (develcloud) ]]; then
        CLOUDLOCALREPOS="$CLOUDLOCALREPOS-staging"
    fi

    common_set_versions
}

# replace zypper repos from the image with user-specified ones
# because the reposerver might not be reachable from where this runs
function onadmin_setup_local_zypper_repositories
{
    local localrepos_base
    # Delete all repos except PTF repo, because this could
    # be called after the addupdaterepo step.
    $zypper lr -e - | sed -n '/^name=/ {s///; /ptf/! p}' | \
        xargs -r zypper rr

    [ -n "${localreposdir_target}" ] && mount_localreposdir_target
    mkdir -p /hostmirror
    for repo in SLES$slesversion-{Pool,Updates}; do
        add_mount "repos/$arch/$repo" "/hostmirror/$repo" $repo
    done
}

# setup network/DNS, add repos and install crowbar packages
function onadmin_prepareinstallcrowbar
{
    pre_hook $FUNCNAME
    [[ $forcephysicaladmin ]] || lsmod | grep -q ^virtio_blk || complain 25 "this script should be run in the crowbar admin VM"
    [[ $want_ssl_keys ]] && ! [[ -e /root/cloud-keys/ ]] && rsync -a "$want_ssl_keys/" /root/cloud-keys/
    [[ $want_rootpw = linux ]] || echo -e "$want_rootpw\n$want_rootpw" | passwd
    echo configure static IP and absolute + resolvable hostname ${crowbar_name}.$cloudfqdn gw:$net.1
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
    echo "${crowbar_name}.$cloudfqdn" > /etc/HOSTNAME
    hostname `cat /etc/HOSTNAME`
    # these vars are used by rabbitmq
    export HOSTNAME=`cat /etc/HOSTNAME`
    export HOST=$HOSTNAME
    grep -q "$net.*${crowbar_name}" /etc/hosts || \
        echo $adminip ${crowbar_name}.$cloudfqdn ${crowbar_name} >> /etc/hosts
    rcnetwork restart
    hostname -f # make sure it is a FQDN
    ping -c 1 `hostname -f`
    longdistance=${longdistance:-false}
    if [[ $(ping -q -c1 $reposerver_ip |
            perl -ne 'm{min/avg/max/mdev = (\d+)} && print $1') -gt 100 ]]
    then
        longdistance=true
    fi

    onadmin_set_source_variables
    common_set_versions
    onadmin_setup_local_zypper_repositories

    if iscloudver 6 ; then
        onadmin_prepare_sles12sp1_repos
    else
        onadmin_prepare_sles_installmedia
        onadmin_prepare_sles_other_repos
    fi
    onadmin_prepare_sles12plus_cloud_repos

    if [[ $hacloud = 1 ]]; then
        add_ha_repo
    fi

    [[ $want_cd = 1 ]] && add_continuousdelivery_repo

    if [ -n "$deployceph" ] || [[ $want_external_ceph = 1 ]]; then
        add_suse_storage_repo
    fi

    ensure_packages_installed rsync netcat wget nfs-client

    # setup cloud repos for tftpboot and zypper
    onadmin_prepare_cloud_repos
    onadmin_add_cloud_repo

    zypper_refresh

    # we have potentially new update repos, patch again
    zypper_patch

    # avoid kernel update
    zypper al kernel-default
    local zypperdup="$zypper dup --no-recommends --no-allow-downgrade"
    $zypperdup -r Cloud -r cloudtup || $zypperdup -r Cloud
    $zypper rl kernel-default

    # Workaround chef-solr crashes
    if [ "$arch" = "aarch64" ]; then
        ensure_packages_installed java-1_7_0-openjdk java-1_7_0-openjdk-headless
    fi

    if [ -z "$NOINSTALLCLOUDPATTERN" ] ; then
        safely $zypper in -l -t pattern cloud_admin
        $zypper al kernel-default # dup below breaks for kernel-default so skip it
        # make sure to use packages from PTF repo (needs zypper dup)
        $zypper mr -G -e cloud-ptf && safely $zypper dup --no-recommends --from cloud-ptf
        $zypper rl kernel-default
    fi

    cd /tmp

    local netfile="/etc/crowbar/network.json"

    local netfilepatch=`basename $netfile`.patch
    if [ -e ~/$netfilepatch ]; then
        ensure_packages_installed patch
        patch -p1 $netfile < ~/$netfilepatch
    fi

    # to revert https://github.com/crowbar/barclamp-network/commit/a85bb03d7196468c333a58708b42d106d77eaead
    sed -i.netbak1 -e 's/192\.168\.126/192.168.122/g' $netfile

    sed -i.netbak -e 's/"conduit": "bmc",$/& "router": "192.168.124.1",/' \
        -e "s/192.168.124/$net/g" \
        -e "s/192.168.130/$net_sdn/g" \
        -e "s/192.168.125/$net_storage/g" \
        -e "s/192.168.127/$net_ceph/g" \
        -e "s/192.168.123/$net_fixed/g" \
        -e "s/192.168.122/$net_public/g" \
        -e "s/ 200/ $vlan_storage/g" \
        -e "s/ 600/ $vlan_ceph/g" \
        -e "s/ 300/ $vlan_public/g" \
        -e "s/ 500/ $vlan_fixed/g" \
        -e "s/ [47]00/ $vlan_sdn/g" \
        $netfile

    # set requested networking mode for Crowbar
    /opt/dell/bin/json-edit -a attributes.network.mode -v "$crowbar_networkingmode" $netfile

    if [ "$crowbar_networkingmode" == "team" ]; then
        # special conduit mapping when having a crowbar admin node with a single
        # nic but want bonding for the rest of the nodes
        local conmap_element='{"pattern": "team/1/crowbar",
            "conduit_list": {"intf0": {"if_list"  : ["?1g1"]},
            "intf1": {"if_list": ["?1g1"]},
            "intf2": {"if_list": ["?1g1"]}}
            }'
        # insert the conmap_element as first element to conduit_map list
        local conmap_complete=`python -c "import json; f=open('$netfile'); \
            j=json.load(f);j['attributes']['network']['conduit_map'].insert(0, $conmap_element); \
            print json.dumps(j['attributes']['network']['conduit_map'], indent=4)"`
        # set the modified conduit map
        /opt/dell/bin/json-edit -a attributes.network.conduit_map -r -v "$conmap_complete" $netfile
    fi

    if [[ $want_separate_ceph_network = 1 ]]; then
        python $SCRIPTS_DIR/ceph/create_separate_network.py $netfile $net_ceph $vlan_ceph
        if [ $? != 0 ]; then
            complain 117 "Failed to add a separate ceph network to $netfile"
        fi
    fi

    if [[ $want_ironic = 1 ]] ; then
        local conmap_complete=`
            python - <<EOPYTHON
import json
f=open('$netfile')
j=json.load(f)
conduit_map=j['attributes']['network']['conduit_map']
for item in conduit_map:
    if item['pattern'] == 'single/.*/.*':
        item['conduit_list']['intf3'] = {'if_list': ['?1g2']}
    else:
        item['conduit_list']['intf3'] = item['conduit_list']['intf1']
print json.dumps(conduit_map, indent=4)
EOPYTHON
        `
        /opt/dell/bin/json-edit -a attributes.network.conduit_map -r -v "$conmap_complete" $netfile
        local networks_complete=`python - <<EOPYTHON
import json
f=open('$netfile')
j=json.load(f)
networks=j['attributes']['network']['networks']
ironic_network={
    'conduit': 'intf3',
    'vlan': 100,
    'use_vlan': False,
    'add_bridge': False,
    'add_ovs_bridge': False,
    'bridge_name': 'br-ironic',
    'subnet': '$net_ironic.0',
    'netmask': '$ironicnetmask',
    'broadcast': '$net_ironic.255',
    'router': '$net_ironic.1',
    'router_pref': 50,
    'ranges': {
      'admin': {
        'start': '$net_ironic.10',
        'end': '$net_ironic.11'
      },
      'dhcp': {
        'start': '$net_ironic.21',
        'end': '$net_ironic.254'
      }
    },
    'mtu': 1500
}
networks['ironic']=ironic_network
print json.dumps(networks, indent=4)
EOPYTHON
        `
    /opt/dell/bin/json-edit -a attributes.network.networks -r -v "$networks_complete" $netfile
    fi

    if [[ $cloud =~ ^p[0-9]$ ]] ; then
        local pcloudnum=${cloud#p}
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.netmask -v 255.255.192.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.ranges.dhcp.end -v 44.1$pcloudnum.63.254 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_fixed.broadcast -v 44.1$pcloudnum.63.255 $netfile
    fi
    if [[ $cloud =~ qa ]] ; then
        # QA clouds have too few IP addrs, so smaller subnets are used
        wget -O$netfile http://gate.cloud2adm.qa.suse.de/network.json/${cloud}_dual
        sed -i 's/bc-template-network/template-network/' $netfile
    fi
    if [[ $cloud = p1 ]] ; then
        # floating net is the 2nd half of public net:
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.netmask -v 255.255.254.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.subnet -v $netp.162.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.start -v $netp.162.1 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.end -v $netp.163.253 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.broadcast -v $netp.163.255 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.netmask -v 255.255.252.0 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.broadcast -v $netp.163.255 $netfile
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
    if [[ $cloud = cf1 ]] ; then
        # floating net is the 2nd half of public net:
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.netmask -v 255.255.255.224 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.subnet -v 10.162.211.192 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.start -v 10.162.211.193 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.ranges.host.end -v 10.162.211.222 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.nova_floating.broadcast -v 10.162.211.223 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.netmask -v 255.255.255.128 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.broadcast -v 10.162.211.255 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.subnet -v 10.162.211.128 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.router -v 10.162.211.254 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.ranges.host.start -v 10.162.211.132 $netfile
        /opt/dell/bin/json-edit -a attributes.network.networks.public.ranges.host.end -v 10.162.211.191 $netfile
    fi
    # Setup network attributes for custom MTU
    echo "Setting MTU to: $want_mtu_size"
    local lnet
    for lnet in admin storage os_sdn public nova_floating nova_fixed; do
        /opt/dell/bin/json-edit -a attributes.network.networks.$lnet.mtu -r -v $want_mtu_size $netfile
    done
    if [[ $want_network_json_url ]] ; then
        wget -O$netfile "$want_network_json_url"
    fi

    # to allow integration into external DNS:
    local f=/opt/dell/chef/cookbooks/bind9/templates/default/named.conf.erb
    grep -q allow-transfer $f || sed -i -e "s#options {#&\n\tallow-transfer { 10.0.0.0/8; };#" $f

    create_repos_yml
    return 0
}

function onadmin_activate_repositories
{
    # activate provisioner repos, so that nodes can use them
    safely crowbar_api_request POST $crowbar_api "/utils/repositories/activate_all.json"
}

function onadmin_bootstrapcrowbar
{
    if [[ $hacloud = 1 ]] ; then
        local f=/opt/dell/chef/cookbooks/nfs-server/templates/default/exports.erb
        mkdir -p /var/lib/glance/images
        if ! grep -q /var/lib/glance/images $f; then
            echo "/var/lib/glance/images     <%= @admin_subnet %>/<%= @admin_netmask %>(rw,async,no_root_squash,no_subtree_check)" >> $f
        fi
        mkdir -p /srv/nfs/{database,rabbitmq}
        if ! grep -q /srv/nfs $f; then
            echo "/srv/nfs     <%= @admin_subnet %>/<%= @admin_netmask %>(rw,async,no_root_squash,no_subtree_check)" >> $f
        fi
    fi

    local upgrademode=$1
    if iscloudver 7plus ; then
        systemctl start crowbar-init
        wait_for 100 3 "onadmin_is_crowbar_init_api_available" "crowbar init service to start"
        if [[ $upgrademode = "with_upgrade" ]] ; then
            safely crowbarctl upgrade database new
        else
            safely crowbarctl database create
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

function do_installcrowbar_cloud6plus
{
    if iscloudver 6minus; then
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

    wait_for 9 2 "crowbar_install_status | grep -q '\"installing\": *true'" "crowbar to start installing" "echofailed ; tail -n 500 $crowbar_install_log ; complain 88 'crowbar did not start to install'"
    wait_for 180 10 "crowbar_install_status | grep -q '\"installing\": *false'" "crowbar to finish installing" "echofailed ; tail -n 500 $crowbar_install_log ; complain 89 'crowbar installation failed'"
    if ! crowbar_install_status | grep -q '\"success\": *true' ; then
        echofailed
        tail -n 500 $crowbar_install_log
        crowbar_install_status
        complain 90 "Crowbar installation failed"
    fi
}


function do_installcrowbar
{
    intercept "crowbar-installation"
    pre_hook $FUNCNAME
    do_set_repos_skip_checks

    rpm -Va crowbar\*
    do_installcrowbar_cloud6plus
    rpm -Va crowbar\*

    ## common code - installer agnostic
    [ -e /etc/profile.d/crowbar.sh ] && . /etc/profile.d/crowbar.sh

    if [ -n "$wanthyperv" ] ; then
        # prepare Hyper-V 2012 R2 PXE-boot env and export it via Samba:
        $zypper in samba
        rsync -a $rsyncserver_fqdn::cloud/hyperv-6.3 /srv/tftpboot/
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

    wait_for 30 5 "onadmin_is_crowbar_api_available" "crowbar service to start" "echofailed ; tail -n 90 $crowbar_install_log ; exit 11"

    if ! get_all_nodes | grep -q ${crowbar_name}.$cloudfqdn ; then
        echofailed
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
        crowbar_proposal_commit ntp
    fi

    for proposal in crowbar provisioner dns; do
        update_one_proposal $proposal default
    done

    if ! validate_data_bags; then
        complain 68 "Validation error in default data bags. Aborting."
    fi
}


function onadmin_installcrowbarfromgit
{
    # on SLE11 we dont have update-alternatives for ruby
    # but we need a "ruby" in PATH for various crowbar scripts
    ln -s /usr/bin/ruby.ruby2.1 /usr/bin/ruby
    ln -s /usr/bin/gem.ruby2.1 /usr/bin/gem
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

    wait_for 300 10 "timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $node true" "$node to become sshable"
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

function set_crowbar_ipmi_ip_addrs
{
    local bmc_values=($(
        crowbar network proposal show default | \
        rubyjsonparse "
            networks = j['attributes']['network']['networks']
            puts networks['bmc']['ranges']['host']['start']
            puts networks['bmc']['router']
        "
    ))
    test -n "${bmc_values[1]}" || bmc_values[1]="0.0.0.0"
    ipmi_default_gw=${bmc_values[1]}
    IFS=. read ip1 ip2 ip3 ip4 <<< "${bmc_values[0]}"
    local bmc_net="$ip1.$ip2.$ip3"
    local i
    for i in $(seq 1 $nodenumbertotal); do
        local ip=$bmc_net.$(($ip4 + $i))
        ipmi_ip_addrs="$ipmi_ip_addrs $ip"
    done
}

# Reboot the nodes with ipmi
function reboot_nodes_via_ipmi
{
    do_one_proposal ipmi default
    [[ $ipmi_ip_addrs ]] || set_crowbar_ipmi_ip_addrs
    local ip
    local i=0
    for ip in $ipmi_ip_addrs ; do
        let i++
        # want_ipmi_extraopts might be useful as "-I lanplus"...
        local ipmicmd="ipmitool -H $ip -U $want_ipmi_username $want_ipmi_extraopts"
        local pw
        for pw in 'cr0wBar!' $extraipmipw ; do
            if timeout 5 $ipmicmd -P $pw mc info ; then
                ipmicmd+=" -P $pw"
                break
            fi
        done
        safely timeout 5 $ipmicmd mc info

        if [[ $i -gt $nodenumber ]]; then
            # power off extra nodes
            $ipmicmd power off
            wait_for 30 2 "$ipmicmd power status | grep -q 'is off'" "node ($ip) to power off"
        else
            if [[ $ipmi_default_gw ]] ; then
                $ipmicmd lan set 1 defgw ipaddr "$ipmi_default_gw"
                wait_for 30 2 \
                    "$ipmicmd lan print | grep 'Default Gateway IP' | grep -q $ipmi_default_gw" \
                    "default gateway to be active in bmc"
            fi

            $ipmicmd chassis bootdev pxe ${want_ipmi_pxeextraopts}
            $ipmicmd power off
            wait_for 30 2 "timeout 5 $ipmicmd power status | grep -q 'is off'" "node ($ip) to power off"
            $ipmicmd power on
            wait_for 30 2 "timeout 5 $ipmicmd power status | grep -q 'is on'" "node ($ip) to power on"
        fi
    done
}

function onadmin_allocate
{
    pre_hook $FUNCNAME

    if [[ $want_ipmi = 1 ]] ; then
        reboot_nodes_via_ipmi
    fi

    [[ $nodenumber -gt 0 ]] && wait_for 50 10 'test $(get_all_discovered_nodes | wc -l) -ge 1' "first node to be discovered"
    wait_for 100 10 '[[ $(get_all_discovered_nodes | wc -l) -ge $nodenumber ]]' "all nodes to be discovered"
    local n
    for n in `get_all_discovered_nodes` ; do
        wait_for 100 2 "knife node show -a state $n | grep -q 'discovered\|ready'" \
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

    local controllernodes=($(get_all_discovered_nodes | head -n 2))

    common_set_versions
    controller_os="suse-$suseversion"

    echo "Setting first node to controller..."
    set_node_role_and_platform ${controllernodes[0]} "controller" $controller_os

    if iscloudver 7plus && [[ $want_monasca_proposal = 1 ]]; then
        echo "Setting 2nd node to monitoring..."
        set_node_role_and_platform ${controllernodes[1]} "monitoring" $controller_os
    fi

    # setup RAID for all controller nodes
    if [[ $controller_raid_volumes -gt 1 ]] ; then
        local controllernode
        for controllernode in ${controllernodes[@]} ; do
            set_node_raid $controllernode $want_raidtype $controller_raid_volumes
        done
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
            local nodes=("${unclustered_nodes[@]}")
        else
            local nodes=($(get_all_discovered_nodes))
            nodes=("${nodes[@]:1}") #remove the 1st node, it's the controller
        fi
        local nodes_count=${#nodes[@]}

        if [ -n "$deployceph" ] && iscloudver 6 ; then
            storage_os="suse-12.1"
            for n in $(seq 0 1); do
                echo "Setting node ${nodes[$n]} to Storage... "
                set_node_role_and_platform ${nodes[$n]} "storage" ${storage_os}
            done
        fi
        if [ -n "$deployceph" ] && iscloudver 7 ; then
            storage_os="suse-12.2"
            # we need 3 ceph nodes: at least 2 for osd (can be mixed with mons) and 1 for mds
            for n in $(seq 0 2); do
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
        cat >> ~/.ssh/config <<EOF
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
        "timeout -k 2 2 tftp $adminip 69 -c get /discovery/x86_64/bios/pxelinux.cfg/default /tmp/default" \
        "tftpd server ready"
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
        cluster_node_assignment

        local clusternodes_var=$(echo clusternodes${clusternameservices})
        local node
        # create glance user with fixed uid/gid so they can work on the same NFS share
        for node in ${!clusternodes_var}; do
            ssh $node "getent group glance >/dev/null ||\
                groupadd -r glance -g 450"
            ssh $node "getent passwd glance >/dev/null || \
                useradd -r -g glance -u 450 -d /var/lib/glance -s /sbin/nologin -c \"OpenStack glance Daemon\" glance"
        done

        if [[ $want_sbd = 1 ]] ; then
            $zypper -p http://download.opensuse.org/repositories/devel:/languages:/python/$slesdist/ install python-sh
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

function lonely_node_sshkey
{
    local lonely_ip=$1
    wait_for 150 10 "ping -q -c 1 -w 1 $lonely_ip >/dev/null" "ping to return from ${cloud}-lonelynode" "complain 82 'could not ping lonely-node VM ($lonely_ip)'"

    # wait a bit for sshd.service on ${cloud}-lonelynode
    wait_for 10 10 "ssh_password $lonely_ip 'echo'" "ssh to be running on ${cloud}-lonelynode" "complain 82 'sshd is not responding on ($lonely_ip)'"

    local pubkey=`cat /root/.ssh/id_rsa.pub`
    ssh_password $lonely_ip "mkdir -p /root/.ssh; echo '$pubkey' >> /root/.ssh/authorized_keys"
}

function add_dns_record
{
    local name=$1
    local ip=$2
    local pfile=`get_proposal_filename dns default`
    crowbar dns proposal show default |
        rubyjsonparse "
            j['attributes']['dns']['records']['$name']={};
            j['attributes']['dns']['records']['$name']['type']='A';
            j['attributes']['dns']['records']['$name']['values']=['$ip'];
            puts JSON.pretty_generate(j)" > $pfile
    crowbar dns proposal --file=$pfile edit default
    crowbar_proposal_commit dns
}

function onadmin_setup_nfs_server
{
    local nfsservermac=$1
    wait_for 150 10 "onadmin_get_ip_from_dhcp '$nfsservermac'" "node to get an IP from DHCP" "exit 78"
    local nfs_server_node_ip=`onadmin_get_ip_from_dhcp "$nfsservermac"`

    lonely_node_sshkey "$nfs_server_node_ip"

    add_dns_record "nfsserver" "$nfs_server_node_ip"

    local uri_base=$reposerver_url
    local sle_pool="$uri_base/$arch/SLES$slesversion-Pool/ SLES-$slesversion-Pool"
    local sle_updates="$uri_base/$arch/SLES$slesversion-Updates/ SLES-$slesversion-Updates"

    inject="
        set -x
        zypper ar $sle_pool
        zypper ar $sle_updates
        zypper -n in nfs-kernel-server
        mkdir -p /srv/nfs/cinder
        chmod 0777 /srv/nfs/cinder
        mkdir -p /srv/nfs/glance
        chmod 0777 /srv/nfs/glance
        mkdir -p /srv/nfs/rabbitmq
        chown -R 91:91 /srv/nfs/rabbitmq
        mkdir -p /srv/nfs/database
        chown -R 26:26 /srv/nfs/database
        echo '/srv/nfs *(rw,async,no_root_squash,no_subtree_check)' >> /etc/exports
        systemctl enable nfs-server
        systemctl start nfs-server
    "
    $ssh $nfs_server_node_ip "$inject"
}

# register a new node with crowbar_register
function onadmin_crowbar_register
{
    pre_hook $FUNCNAME
    wait_for 150 10 "onadmin_get_ip_from_dhcp '$lonelymac'" "node to get an IP from DHCP" "exit 78"
    local crowbar_register_node_ip=`onadmin_get_ip_from_dhcp "$lonelymac"`

    [ -n "$crowbar_register_node_ip" ] || complain 84 "Could not get IP address of crowbar_register_node"

    lonely_node_sshkey $crowbar_register_node_ip

    # uninstall cloud-init, its dependecies break the installation of openstack
    $ssh $crowbar_register_node_ip "zypper --non-interactive rm -u cloud-init"

    # call crowbar_register on the lonely node
    local inject

    if iscloudver 6 ; then
        image="suse-12.1/x86_64/"
    elif iscloudver 7; then
        image="suse-12.2/$arch/"
    elif iscloudver 8; then
        image="suse-12.3/$arch/"
    elif iscloudver 9plus; then
        image="suse-12.4/$arch/"
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

    $ssh $crowbar_register_node_ip "$inject"

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
                wait_for 500 1 "netcat -w 3 -z $onenode 22 || netcat -w 3 -z $onenode 3389" "node $onenode to be accessible"
                echo "node $onenode ready"
            done
            ;;
        proposal)
            echo -n "Waiting for proposal $proposal($proposaltype) to get successful: "
            local proposalstatus=''
            wait_for 800 1 "proposalstatus=\`onadmin_get_proposalstatus $proposal $proposaltype\` ; [[ \$proposalstatus =~ success|failed ]]" "proposal to be successful"
            if [[ $proposalstatus = failed ]] ; then
                echofailed
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
    local pfile=`get_proposal_filename "$service" default`
    if ! grep -q generate_certs $pfile ; then
        echo "Cannot enable ssl for $service - not supported in this cloud version"
        return
    fi
    case $service in
        crowbar)
            if iscloudver 7plus ; then
                $p "$a['apache']['ssl']" true
                $p "$a['apache']['generate_certs']" true
                $p "$a['apache']['insecure']" true
            fi
            return
        ;;
        database)
            if iscloudver 7plus && [[ "$want_database_sql_engine" == "mysql" ]] ; then
                $p "$a['mysql']['ssl']['enabled']" true
                $p "$a['mysql']['ssl']['generate_certs']" true
                $p "$a['mysql']['ssl']['insecure']" true
            fi
            return
        ;;
        swift|rabbitmq)
            $p "$a['ssl']['enabled']" true
        ;;
        nova)
            $p "$a['ssl']['enabled']" true
            $p "$a['novnc']['ssl']['enabled']" true
            if iscloudver 7 ; then
                $p "$a['ec2-api']['ssl']['enabled']" true
                $p "$a['ec2-api']['ssl']['generate_certs']" true
                $p "$a['ec2-api']['ssl']['insecure']" true
            fi
        ;;
        horizon|nova_dashboard)
            $p "$a['apache']['ssl']" true
            $p "$a['apache']['generate_certs']" true
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
        proposal_set_value pacemaker "$clustername" \
            "['deployment']['pacemaker']['elements']['$role']" "$nodes"
    done

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
            rabbit)   cnodes="$clusternodesrabbit"   ;;
        esac
        hacloud_configure_cluster_members $clustername "$cnodes"
    fi

    if [[ $want_sbd = 1 ]] ; then
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['mode']" "'sbd'"
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['sbd']['watchdog_module']" "'softdog'"
    elif [[ $mkclouddriver = "libvirt" && $want_ipmi != 1 ]]; then
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['mode']" "'libvirt'"
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['libvirt']['hypervisor_ip']" "'$admingw'"
    elif [[ $want_ipmi = 1 ]] ; then
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['mode']" "'ipmi_barclamp'"
    else
        proposal_set_value pacemaker "$clustername" \
            "['attributes']['pacemaker']['stonith']['mode']" "'manual'"
    fi
    proposal_modify_value pacemaker "$clustername" \
        "['description']" "'Clustername: $clustername, type: $clustertype ; '" "+="
}

function hacloud_configure_data_cluster
{
    if iscloudver 6minus || [[ "$want_database_sql_engine" == "postgresql" ]] ; then
        proposal_set_value pacemaker $clusternamedata "['attributes']['pacemaker']['drbd']['enabled']" true
    fi
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
        crowbar|database|rabbitmq|keystone|glance|neutron|cinder|swift|ceph|nova|horizon|nova_dashboard|heat|manila|aodh|barbican|ceilometer)
            if [[ $want_all_ssl = 1 ]] || eval [[ \$want_${proposal}_ssl = 1 ]] ; then
                enable_ssl_generic $proposal
            fi
    esac

    case "$proposal" in
        keystone|glance|neutron|cinder|swift|nova|horizon|nova_dashboard|sahara|murano|aodh)
            if [[ $want_all_debug = 1 ]] || eval [[ \$want_${proposal}_debug = 1 ]] ; then
                enable_debug_generic $proposal
            fi
        ;;
    esac

    local adminfqdn=`get_crowbar_node`
    local controllernode=($(get_all_discovered_nodes | head -n 1))

    case "$proposal" in
        nfs_client)
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
            if [[ $want_database_sql_engine ]] ; then
                proposal_set_value database default "['attributes']['database']['sql_engine']" "'$want_database_sql_engine'"
            fi
            # For SOC7 we introduced transitional role called mysql-server that's gonna be used during the upgrade
            # Users deploying SOC7 with MariaDB must use this one and not database-server
            # However to not break GM deployments, we should check if the role is actually present.
            if iscloudver 7 && [ -e "/opt/dell/chef/data_bags/crowbar/migrate/database/109_separate_db_roles.rb" ]; then
                # In this branch, if want_database_sql_engine is not set, mysql is the default
                if [[ $hacloud = 1 ]] ; then
                    if [[ "$want_database_sql_engine" != "postgresql" ]] ; then
                        proposal_set_value database default "['deployment']['database']['elements']['mysql-server']" "['cluster:$clusternamedata']"
                    else
                        # default backend is DRBD for postgresql - and attributes are at different place when 109 migration is present
                        proposal_set_value database default "['attributes']['database']['postgresql']['ha']['storage']['mode']" "'drbd'"
                        proposal_set_value database default "['attributes']['database']['postgresql']['ha']['storage']['drbd']['size']" "$drbd_database_size"
                        proposal_set_value database default "['deployment']['database']['elements']['database-server']" "['cluster:$clusternamedata']"
                        proposal_set_value database default "['deployment']['database']['elements']['mysql-server']" "[]"
                    fi
                else
                    # non-HA case might need some value for database-server role, otherwise database_service model picks mysql as default
                    if [[ "$want_database_sql_engine" == "postgresql" ]] ; then
                        proposal_set_value database default "['deployment']['database']['elements']['database-server']" "['$controllernode']"
                        proposal_set_value database default "['deployment']['database']['elements']['mysql-server']" "[]"
                    fi
                fi
            # DRBD is default for postgresql based deployments
            elif [[ $hacloud = 1 ]] ; then
                # ForSOC7 without 109_separate_db_roles.rb, default is postgresql
                if [[ "$want_database_sql_engine" != "mysql" ]] ; then
                    proposal_set_value database default "['attributes']['database']['ha']['storage']['mode']" "'drbd'"
                    proposal_set_value database default "['attributes']['database']['ha']['storage']['drbd']['size']" "$drbd_database_size"
                fi
            fi
        ;;
        rabbitmq)
            if [[ $hacloud = 1 ]]; then
                # In Cloud 8, clustering is enabled by default, so we don't
                # need to setup shared storage; in SOC 7, it is available in an
                # update but disabled by default.
                if iscloudver 6minus || ( iscloudver 7plus && [[ $want_clustered_rabbitmq = 0 ]] ); then
                    if iscloudver 6minus || [[ "$want_database_sql_engine" == "postgresql" ]] ; then
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['mode']" "'drbd'"
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['drbd']['size']" "$drbd_rabbitmq_size"
                    else
                        local nfs_server=$adminfqdn
                        if ping -c1 -w1 nfsserver > /dev/null ; then
                            nfs_server="nfsserver"
                        fi
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['shared']['device']" "'$nfs_server:/srv/nfs/rabbitmq'"
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['shared']['fstype']" "'nfs'"
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['ha']['storage']['shared']['options']" "'rw,async,nofail'"
                    fi
                    if iscloudver 7plus && grep -q cluster /opt/dell/chef/data_bags/crowbar/template-rabbitmq.json; then
                        proposal_set_value rabbitmq default "['attributes']['rabbitmq']['cluster']" false
                    fi
                fi
                if iscloudver 7plus && [[ $want_clustered_rabbitmq = 1 ]]; then
                    proposal_set_value rabbitmq default "['attributes']['rabbitmq']['cluster']" true
                fi
                proposal_set_value rabbitmq default "['deployment']['rabbitmq']['elements']['rabbitmq-server']" "['cluster:$clusternamerabbit']"
            fi

            if ! iscloudver 9plus && ! [[ $want_trove_proposal = 0 ]]; then
                proposal_set_value rabbitmq default "['attributes']['rabbitmq']['trove']['enabled']" true
            fi

            if iscloudver 7plus && ! [[ $want_ceilometer_proposal = 0 ]]; then
                if crowbar rabbitmq proposal show default | grep -q enable_notifications; then
                    proposal_set_value rabbitmq default "['attributes']['rabbitmq']['client']['enable_notifications']" true
                fi
            fi
        ;;
        dns)
            [ "$want_multidnstest" = 1 ] || return 0
            local cmachines=$(get_all_suse_nodes | head -n 3)
            local dnsnodes=`echo \"$cmachines\" | sed 's/ /", "/g'`
            proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']" "{}"
            # We could do the usual "if iscloudver 6plus ; then", but this
            # would break mkcloud when installing Cloud 6 without updates
            if grep -q CNAME /opt/dell/crowbar_framework/app/helpers/barclamp/dns_helper.rb; then
                proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']['type']" "'A'"
                proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']['values']" "['10.11.12.13']"
            else
                proposal_set_value dns default "['attributes']['dns']['records']['multi-dns']['ips']" "['10.11.12.13']"
            fi
            proposal_set_value dns default "['deployment']['dns']['elements']['dns-server']" "[$dnsnodes]"
        ;;
        ipmi)
            if [[ $want_ipmi = 1 ]] ; then
                if [[ $want_ipmi_dhcp = 1 ]] ; then
                    proposal_set_value ipmi default "['attributes']['ipmi']['use_dhcp']" true
                fi
                proposal_set_value ipmi default "['attributes']['ipmi']['bmc_enable']" true
                proposal_set_value ipmi default "['attributes']['ipmi']['debug']" true
                proposal_set_value ipmi default "['attributes']['ipmi']['bmc_user']" "'$bmc_user'"
                proposal_set_value ipmi default "['attributes']['ipmi']['bmc_password']" "'$bmc_password'"
            fi
        ;;
        keystone)
            # set a custom region name
            proposal_set_value keystone default "['attributes']['keystone']['api']['region']" "'CustomRegion'"
            # speedup the deployment
            if iscloudver 8M3plus ; then
                proposal_set_value keystone default "['attributes']['keystone']['identity']['password_hash_rounds']" "4"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value keystone default "['deployment']['keystone']['elements']['keystone-server']" "['cluster:$clusternameservices']"
            fi
            if [[ $want_ldap = 1 ]] ; then
                local machine
                for machine in $(get_all_discovered_nodes); do
                    run_on "$machine" install_suse_ca
                done
                local p="proposal_set_value keystone default"
                local l="['attributes']['keystone']['ldap']"
                if iscloudver 7plus ; then
                    $p "['attributes']['keystone']['domain_specific_drivers']" true
                    l="['attributes']['keystone']['domain_specific_config']['ldap_users']['ldap']"
                    $p "$l['group_members_are_ids']" "true"
                elif iscloudver 6; then
                    $p "['attributes']['keystone']['identity']['driver']" "'hybrid'"
                    $p "['attributes']['keystone']['assignment']['driver']" "'hybrid'"
                else
                    $p "['attributes']['keystone']['identity']['driver']" "'keystone.identity.backends.hybrid.Identity'"
                    $p "['attributes']['keystone']['assignment']['driver']" "'keystone.assignment.backends.hybrid.Assignment'"
                fi
                $p "$l['url']" "'ldaps://ldap.suse.de'"
                $p "$l['suffix']" "'dc=suse,dc=de'"
                $p "$l['user_tree_dn']" "'ou=accounts,dc=suse,dc=de'"
                $p "$l['user_objectclass']" "'posixAccount'"
                $p "$l['user_id_attribute']" "'uid'"
                $p "$l['user_name_attribute']" "'uid'"
                $p "$l['group_tree_dn']" "'ou=accounts,dc=suse,dc=de'"
                $p "$l['group_objectclass']" "'posixGroup'"
                $p "$l['group_id_attribute']" "'gidNumber'"
                $p "$l['group_name_attribute']" "'cn'"
                $p "$l['group_member_attribute']" "'memberUid'"
                $p "$l['use_tls']" "false"
                $p "$l['tls_cacertdir']" "'/etc/ssl/certs'"
                $p "$l['tls_req_cert']" "'demand'"
                $p "$l['use_pool']" "true"
            fi
            if [[ $want_keystone_v3 ]] ; then
                proposal_set_value keystone default "['attributes']['keystone']['api']['version']" "'3'"
            fi
            if iscloudver 7plus; then
                # The default of 8 is a bit too much for our default virtual setup
                [[ $cloudsource =~ devel ]] && proposal_set_value keystone default "['attributes']['keystone']['api']['processes']" "2"
                if [[ $want_keystone_token_type ]]; then
                    proposal_set_value keystone default "['attributes']['keystone']['signing']['token_format']" "'$want_keystone_token_type'"
                fi
            fi
        ;;
        glance)
            if [[ $deployceph ]]; then
                proposal_set_value glance default "['attributes']['glance']['default_store']" "'rbd'"
            fi
            if [[ $hacloud = 1 ]] ; then
                if [[ $deployswift ]]; then
                    proposal_set_value glance default "['attributes']['glance']['default_store']" "'swift'"
                fi
                proposal_set_value glance default "['deployment']['glance']['elements']['glance-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        manila)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value manila default "['deployment']['manila']['elements']['manila-server']" "['cluster:$clusternameservices']"
            fi

            if [ -n "$deployceph" ] && iscloudver 7plus; then
                # deploy cephfs
                proposal_set_value manila default "['attributes']['manila']['default_share_type']" "'ceph'"
                proposal_set_value manila default "['attributes']['manila']['shares']" "[{}]"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['cephfs']" "j['attributes']['manila']['share_defaults']['cephfs']"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_driver']" "'cephfs'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_name']" "'cephfs-backend'"
            else
                # deploy generic driver
                proposal_set_value manila default "['attributes']['manila']['default_share_type']" "'default'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_driver']" "'generic'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['backend_name']" "'backend1'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_user']" "'root'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_password']" "'linux'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['share_volume_fstype']" "'ext3'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_instance_name_or_id']" "'$manila_service_vm_uuid'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['service_net_name_or_ip']" "'$manila_tenant_vm_ip'"
                proposal_set_value manila default "['attributes']['manila']['shares'][0]['generic']['tenant_net_name_or_ip']" "'$manila_tenant_vm_ip'"
            fi
        ;;
        ceph)
            proposal_set_value ceph default "['attributes']['ceph']['disk_mode']" "'all'"
            # don't deploy calamari by default on SOC7. calamari needs a postgres DB on localhost
            # and get's confused if it is deployed on the controller where a postgres DB is already running
            # see https://bugzilla.suse.com/show_bug.cgi?id=1008331
            proposal_set_value ceph default "['deployment']['ceph']['elements']['ceph-calamari']" "[]"
        ;;
        magnum)
            proposal_set_value magnum default "['attributes']['magnum']['trustee']['domain_name']" "'magnum'"
            proposal_set_value magnum default "['attributes']['magnum']['trustee']['domain_admin_name']" "'magnum_domain_admin'"

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value magnum default "['deployment']['magnum']['elements']['magnum-server']" "['cluster:$clusternameservices']"
            fi
            ;;

        monasca)
            if [[ $hacloud = 1 ]] ; then
                echo "Warning: Monasca currently is not HA ready"
            fi
            ;;

        barbican)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value barbican default "['deployment']['barbican']['elements']['barbican-controller']" "['cluster:$clusternameservices']"
            fi
            ;;
        nova)
            # custom nova config of libvirt
            [[ $libvirt_type = hyperv ]] || proposal_set_value nova default "['attributes']['nova']['libvirt_type']" "'$libvirt_type'"
            proposal_set_value nova default "['attributes']['nova']['use_migration']" "true"
            [[ $libvirt_type = xen ]] && sed -i -e "s/nova-compute-$libvirt_type/nova-compute-xxx/g; s/nova-compute-kvm/nova-compute-$libvirt_type/g; s/nova-compute-xxx/nova-compute-kvm/g" $pfile


            if iscloudver 7plus; then
                # create (and test) the trusted flavors
                proposal_set_value nova default "['attributes']['nova']['trusted_flavors']" "true"
            fi

            if iscloudver 7; then
                if [[ $hacloud = 1 ]] ; then
                    proposal_set_value nova default "['deployment']['nova']['elements']['ec2-api']" "['cluster:$clusternameservices']"
                else
                    local ec2node="${unclustered_nodes[0]}"
                    proposal_set_value nova default "['deployment']['nova']['elements']['ec2-api']" "['$ec2node']"
                fi
            fi

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-controller']" "['cluster:$clusternameservices']"

                # only use remaining nodes as compute nodes, keep cluster nodes dedicated to cluster only
                local novanodes=("${unclustered_nodes[@]}")

                # make sure we do not pick SP1 nodes on cloud7 (or SP2 for cloud 8)
                if [ -n "$deployceph" ] && iscloudver 7plus ; then
                    novanodes=("${unclustered_sles12plusnodes[@]}")
                fi

                if [[ ${#novanodes[@]} -eq 0 ]]; then
                    complain 105 "No suitable node(s) for nova-compute-${libvirt_type} found."
                fi
                novanodes_json=$(printf "\"%s\"," ${novanodes[@]})
                novanodes_json="[ ${novanodes_json%,} ]"
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-compute-${libvirt_type}']" "$novanodes_json"
            fi

            if [[ $nova_shared_instance_storage = 1 ]] ; then
                proposal_set_value nova default "['attributes']['nova']['use_shared_instance_storage']" "true"
            fi
            # set some custom vendordata for the metadata server
            if iscloudver 7plus ; then
                proposal_set_value nova default "['attributes']['nova']['metadata']['vendordata']['json']" "'{\"custom-key\": \"custom-value\"}'"
            fi

            if iscloudver 7plus && [[ $want_ironic = 1 ]] ; then
                get_novacontroller
                proposal_set_value nova default "['deployment']['nova']['elements']['nova-compute-ironic']" "['$novacontroller']"
            fi
        ;;
        horizon|nova_dashboard)
            [[ $want_ldap = 1 ]] && iscloudver 7plus && proposal_set_value $proposal default "['attributes']['$proposal']['multi_domain_support']" "true"
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value $proposal default "['deployment']['$proposal']['elements']['$proposal-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        heat)
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value heat default "['deployment']['heat']['elements']['heat-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        aodh)
            if [[ $hacloud = 1 ]] && ( iscloudver 7 || iscloudver 8 ) ; then
                proposal_set_value aodh default "['deployment']['aodh']['elements']['aodh-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        ceilometer)
            local ceilometerservice="ceilometer-cagent"
            ceilometerservice="ceilometer-central"
            if [[ $cloudsource = GM6 ]] ; then
                ceilometerservice="ceilometer-polling"
            fi
            if [[ $hacloud = 1 ]] ; then
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-server']" "['cluster:$clusternameservices']"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['$ceilometerservice']" "['cluster:$clusternameservices']"

                if iscloudver 7minus ; then
                    # disabling mongodb, because if in one cluster mode the requirements of drbd and mongodb ha conflict:
                    #   drbd can only use 2 nodes max. <> mongodb ha requires 3 nodes min.
                    # this should be adapted when NFS mode is supported for data cluster
                    proposal_set_value ceilometer default "['attributes']['ceilometer']['use_mongodb']" "false"
                fi

                local ceilometernodes=("${unclustered_nodes[@]}")
                # make sure we do not pick SP1 nodes on cloud7 (or SP2 for cloud 8)
                if [ -n "$deployceph" ] && iscloudver 7plus ; then
                    ceilometernodes=("${unclustered_sles12plusnodes[@]}")
                fi
                if [[ ${#ceilometernodes[@]} -eq 0 ]]; then
                    complain 105 "No suitable node(s) for ceilometer-agent found."
                fi
                ceilometernodes_json=$(printf "\"%s\"," ${ceilometernodes[@]})
                ceilometernodes_json="[ ${ceilometernodes_json%,} ]"
                proposal_set_value ceilometer default "['deployment']['ceilometer']['elements']['ceilometer-agent']" "$ceilometernodes_json"
            fi
        ;;
        murano)
            if [[ $hacloud = 1 ]] && ( iscloudver 7 || iscloudver 8 ) ; then
                proposal_set_value murano default "['deployment']['murano']['elements']['murano-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        neutron)
            if iscloudver 7plus; then
                [[ $networkingplugin = linuxbridge && $networkingmode = gre ]] && networkingmode=vlan
            else
                [[ $networkingplugin = linuxbridge ]] && networkingmode=vlan
            fi
            proposal_set_value neutron default "['attributes']['neutron']['use_lbaas']" "true"

            if [ $networkingplugin = openvswitch ] ; then
                if [[ $networkingmode = vxlan ]] || iscloudver 6plus; then
                    proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers']" "['gre','vxlan','vlan']"
                    if [[ $want_dvr = 1 ]]; then
                        proposal_set_value neutron default "['attributes']['neutron']['use_dvr']" "true"
                        # Enable L2 population, because for mkcloud we enable all ml2_type_drivers
                        #     'ml2_type_drivers' = ['gre','vxlan','vlan']
                        # DVR with GRE or VXLAN requires L2 population
                        proposal_set_value neutron default "['attributes']['neutron']['use_l2pop']" "true"
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
            else
                complain 106 "networkingplugin '$networkingplugin' not yet covered in mkcloud"
            fi
            proposal_set_value neutron default "['attributes']['neutron']['networking_plugin']" "'ml2'"
            proposal_set_value neutron default "['attributes']['neutron']['ml2_mechanism_drivers']" "['$networkingplugin']"
            if [ -n "$networkingmode" ] ; then
                proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_provider_network']" "'$networkingmode'"
                proposal_set_value neutron default "['attributes']['neutron']['ml2_type_drivers_default_tenant_network']" "'$networkingmode'"
            fi

            # assign neutron-network role to one of SLE12 nodes
            if [[ $hacloud && $want_neutronsles12 ]] && iscloudver 5plus ; then
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

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value sahara default "['deployment']['sahara']['elements']['sahara-server']" "['cluster:$clusternameservices']"
            fi
        ;;
        swift)
            [[ $nodenumber -lt 3 ]] && {
                proposal_set_value swift default "['attributes']['swift']['zones']" "1"
                # This should be set for C6 and C5 as well, but currently the swift barclamp
                # is broken there..
                if iscloudver 7plus ; then
                    proposal_set_value swift default "['attributes']['swift']['replicas']" "1"
                fi
            }
            proposal_set_value swift default "['attributes']['swift']['allow_versions']" "true"
            proposal_set_value swift default "['attributes']['swift']['keystone_delay_auth_decision']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['crossdomain']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['formpost']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['staticweb']['enabled']" "true"
            proposal_set_value swift default "['attributes']['swift']['middlewares']['tempurl']['enabled']" "true"

            if [[ $hacloud = 1 ]] ; then
                proposal_set_value swift default "['deployment']['swift']['elements']['swift-proxy']" "['cluster:$clusternameservices']"
            fi
        ;;
        cinder)
            proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['${cinder_backend}']" "j['attributes']['cinder']['volume_defaults']['${cinder_backend}']"
            proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['backend_driver']" "'${cinder_backend}'"
            if [[ $deployceph && $want_cinder_rbd_flatten_snaps = 1 ]] && iscloudver 7plus ; then
                proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['${cinder_backend}']['flatten_volume_from_snapshot']" "true"
            fi
            case "$cinder_backend" in
                netapp)
                    cinder_netapp_proposal_configuration "0"
                    ;;
                nfs)
                    proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['backend_name']" "'backend_nfs'"
                    proposal_set_value cinder default "['attributes']['cinder']['volumes'][0]['nfs']['nfs_shares']" "'nfsserver:/srv/nfs/cinder'"
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
                local cinder_volume=("${unclustered_nodes[@]}")
                if [[ "$deployceph" || $cinder_backend = "nfs" ]] && iscloudver 7plus ; then
                    cinder_volume=("cluster:$clusternameservices")
                fi
                if [[ ${#cinder_volume[@]} -eq 0 ]]; then
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
            if [[ "$deployceph" ]] && iscloudver 7plus ; then
                # cephfs is deployed
                proposal_set_value tempest default "['attributes']['tempest']['manila']['enable_cert_rules_for_protocols']" "''"
                proposal_set_value tempest default "['attributes']['tempest']['manila']['enable_ip_rules_for_protocols']" "''"
                proposal_set_value tempest default "['attributes']['tempest']['manila']['run_consistency_group_tests']" "false"
                proposal_set_value tempest default "['attributes']['tempest']['manila']['run_snapshot_tests']" "false"
                proposal_set_value tempest default "['attributes']['tempest']['manila']['enable_protocols']" "'cephfs'"
                proposal_set_value tempest default "['attributes']['tempest']['manila']['storage_protocol']" "'CEPHFS'"
            else
                # generic driver
                proposal_set_value tempest default "['attributes']['tempest']['manila']['image_password']" "'linux'"
            fi
            # magnum options
            if iscloudver 7plus ; then
                proposal_set_value tempest default "['attributes']['tempest']['magnum']['flavor_id']" "'m1.smaller'"
                proposal_set_value tempest default "['attributes']['tempest']['magnum']['master_flavor_id']" "'m2.smaller'"
            fi
        ;;
        provisioner)
            # set default password
            proposal_set_value provisioner default "['attributes']['provisioner']['root_password_hash']" "\"$(openssl passwd -1 $want_rootpw)\""
            # set discovery root password too
            proposal_set_value provisioner default "['attributes']['provisioner']['discovery']['append']" "\"DISCOVERY_ROOT_PASSWORD=$want_rootpw\""

            if [[ $keep_existing_hostname = 1 ]] ; then
                proposal_set_value provisioner default "['attributes']['provisioner']['keep_existing_hostname']" "true"
            fi
        ;;
        ironic)
            proposal_set_value ironic default "['attributes']['ironic']['enabled_drivers']" "['pxe_ipmitool', 'pxe_ssh']"
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
    # F1: cloud8 no longer defaults to ceph, even if the nodenumbers allow it
    # background: starting with cloud8 the ceph nodes can not have openstack roles
    # this complicates the nodenumber counting.
    # And since the release of mariadb as default database in SOC7, the default number
    # of nodes changed as well: 3 nodes are required for galera and there's usually not much
    # left for separate ceph nodes.
    if iscloudver 8plus || ( iscloudver 7 && [[ $hacloud = 1 ]] ); then
        deployceph=
        if [[ $nodenumber -gt 1 ]]; then
            deployswift=1
        fi
    fi

    # F2: hyperV only without swift and ceph
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
    case "$want_external_ceph" in
        0)  ;;
        *)  deployceph= ;;
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
    # C5: Do not deploy ceph with 4 or less nodes setup
    # (ceph would take 3 SP2 nodes and we want more then one SP3 node for OpenStack)
    if iscloudver 8 && [[ $nodenumber -lt 5 ]] ; then
        deployceph=
    fi

    ### FINAL swift and ceph check
    if [[ $deployswift && $deployceph ]] ; then
        complain 89 "Can not deploy ceph and swift at the same time."
    fi
    ### do NOT set/change deployceph or deployswift below this line!

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

function set_noproxyvar
{
    [[ $http_proxy ]] || [[ $https_proxy ]] || return 0
    [[ $no_proxy =~ "localhost" ]] || no_proxy="127.0.0.1,localhost,$no_proxy"
    [[ ! $adminip ]] || [[ $no_proxy =~ "$adminip" ]] || no_proxy="$adminip,$no_proxy"
    [[ ! $cloudfqdn ]] || [[ $no_proxy =~ "$cloudfqdn" ]] || no_proxy="$cloudfqdn,$no_proxy"
    export no_proxy="${no_proxy%,}";
    if [[ ! $net_public ]] || [[ $no_proxy =~ $net_public ]] ; then
        return 0 # only apply this once
    fi
    local ips
    printf -v ips '%s,' $net_public.{1..254}
    no_proxy="$ips$no_proxy"
    no_proxy="${no_proxy%,}";
}

# commit a proposal, but use crowbarctl from cloud6 on
function crowbar_proposal_commit
{
    local proposal="$1"
    local proposaltype="${2:-default}"
    safely crowbarctl proposal commit "$proposal" "$proposaltype"
}

# configure and commit one proposal
function update_one_proposal
{
    local proposal=$1
    local proposaltype=${2:-default}
    local proposaltypemapped=$proposaltype
    proposaltype=${proposaltype%%+*}

    prop_start=$(date +%s)
    echo "Starting proposal $proposal($proposaltype) at: $(date -d@$prop_start)"
    # hook for changing proposals:
    custom_configuration $proposal $proposaltypemapped
    crowbar_proposal_commit "$proposal" $proposaltype

    local ret=$?
    echo "Commit exit code: $ret"
    if [ "$ret" = "0" ]; then
        waitnodes proposal $proposal $proposaltype
        ret=$?
        echo "Proposal exit code: $ret"
        sleep 10
    fi
    prop_end=$(date +%s)
    echo "Finished proposal $proposal($proposaltype) at: $(date -d@$prop_end)"
    log_timing "$prop_start" "$prop_end" "proposal" "$proposal($proposaltype)"
    if [ $ret != 0 ] ; then
        echofailed
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
    local batchfile=$want_batch_dir/$proposal-batch.yaml
    if [[ -e $batchfile ]] ; then
        crowbar batch build "$batchfile"
        return 0
    fi
    crowbar "$proposal" proposal create $proposaltype
    if [[ $? != 0 ]] && [[ $want_reapply_proposal = 0 ]] ; then
        return
    fi
    update_one_proposal "$proposal" "$proposaltypemapped"
}

function prepare_proposals
{
    pre_hook $FUNCNAME
    waitnodes nodes

    update_one_proposal dns default

    local ptfchannel="PTF"
    for machine in $(get_all_nodes); do
        ssh $machine "zypper mr -G -p 90 $ptfchannel"
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

    # generic skip for proposals
    local want_var="want_${proposal}_proposal"
    if [[ ${!want_var} = 0 ]] ; then
        echo "Skipping proposal for $proposal because \$$want_var was set to 0"
        return 0
    fi

    # proposal filter
    case "$proposal" in
        barbican)
            # Barbican is for magnum and PM does not want magnum to be on s390x, so..
            if [[ $arch = "s390x" ]]; then
                return
            fi
            if ! iscloudver 7plus; then
                echo "Barbican is SOC 7+ only. Skipping"
                return
            fi
            ;;
        heat)
            get_novacontroller
            safely oncontroller heat_image_setup
            ;;

        nfs_client)
            # nfs client (used by glance) is needed for ha setups but only when
            # neither swift nor ceph are deployed
            [[ $hacloud = 1 && -z "$deployceph"  && -z "$deployswift" ]] || return
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
            if iscloudver 7plus ; then
                get_novacontroller
                safely oncontroller magnum_service_setup
            fi
            ;;
        manila)
            # PM does not want to support manila on non-x86
            if [[ $arch != "x86_64" ]]; then
                return
            fi
            get_novacontroller
            safely oncontroller manila_generic_driver_setup
            get_manila_service_instance_details
            ;;
        monasca)
            # PM does not want to support monasca for anything non-x86
            if [[ $arch != "x86_64" ]]; then
                return
            fi
            if ! iscloudver 7plus; then
                echo "monasca is SOC 7+ only. Skipping"
                return
            fi
            ;;
        sahara)
            if ! iscloudver 7plus; then
                echo "Sahara is SOC 7+ only. Skipping"
                return
            fi
            ;;
        swift)
            [[ $deployswift ]] || return
            ;;
        tempest)
            [[ $want_tempest = 1 ]] || return
            ;;
        trove)
            if iscloudver 9plus; then
                echo "Trove is SOC 8- only. Skipping"
                return
            fi
            ;;
        aodh)
            if ! ( iscloudver 7 || iscloudver 8 ) ; then
                echo "Aodh is SOC 7 and 8 only. Skipping"
                return
            fi
            ;;
        murano)
            if ! ( iscloudver 7 || iscloudver 8 ) ; then
                echo "Murano is SOC 7 and 8 only. Skipping"
                return
            fi
            ;;
        ironic)
            [[ $want_ironic = 1 ]] || return
            if ! iscloudver 7plus; then
                echo "Warning: Ironic is SOC 7+ only. Skipping"
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
        unclustered_nodes=(`get_all_discovered_nodes`)
    fi

    if [[ $want_ssl_keys ]] ; then
        for m in $(get_all_suse_nodes) ; do
            rsync -a /root/cloud-keys/ $m:/etc/cloud-keys/
        done
    fi
    local proposal
    # Deploy all the proposals up through nova normally
    for proposal in nfs_client pacemaker database rabbitmq keystone swift ceph \
        monasca glance cinder neutron ironic nova ; do
        deploy_single_proposal $proposal
    done
    # Set the $novacontroller global variable so that we
    # can execute actions from the controller
    get_novacontroller

    # use local cache whenever possible
    oncontroller mount_localreposdir

    # Check if there were any HA failures from the proposals so far
    safely oncontroller check_crm_failcounts
    # For all remaining proposals, check for HA failures after each deployment
    for proposal in horizon ceilometer heat manila trove \
        barbican magnum sahara murano aodh tempest; do
        deploy_single_proposal $proposal
        safely oncontroller check_crm_failcounts
    done

    set_dashboard_alias
}

function set_node_alias
{
    local node_name=$1
    local node_alias=$2
    if [[ "$node_name" != "$node_alias" ]]; then
        safely crowbarctl node rename $node_name $node_alias
    fi
}

function set_node_alias_and_role
{
    local node_name=$1
    local node_alias=$2
    local intended_role=$3
    set_node_alias $node_name $node_alias
    crowbar machines role $node_name $intended_role || :
}

function get_first_node_from_cluster
{
    local cluster=$1
    crowbar pacemaker proposal show $cluster | \
        rubyjsonparse "
                    puts j['deployment']['pacemaker']\
                        ['elements']['pacemaker-cluster-member'].first"
}

function get_all_nodes_from_cluster
{
    local cluster=$1
    crowbarctl proposal show pacemaker $cluster --json | \
        rubyjsonparse "
                    puts j['deployment']['pacemaker']\
                        ['elements']['pacemaker-cluster-member']"
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

function get_cluster_name
{
    local element=`crowbarctl show nova default --json| \
        rubyjsonparse "
                    puts j['deployment']['nova']\
                        ['elements']['nova-controller']"`
    local cluster=${element#cluster:}
    echo $cluster
}

function get_novacontroller
{
    local element=`crowbar nova proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['nova']\
                        ['elements']['nova-controller']"`
    novacontroller=`resolve_element_to_hostname "$element"`
}

function get_horizon
{
    local element=`crowbar horizon proposal show default | \
        rubyjsonparse "
                    puts j['deployment']['horizon']\
                        ['elements']['horizon-server']"`
    horizonserver=`resolve_element_to_hostname "$element"`
    horizonservice=`resolve_element_to_hostname "$element" service`
}

function get_ceph_nodes
{
    if [[ $deployceph ]]; then
        cephmons=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-mon']"`
        for machine in $cephmons; do
            temp_output="`crowbar machines show $machine`"
            net_name="`echo $temp_output | rubyjsonparse "puts j['ceph']['client_network']"`"
            hostname="`echo $temp_output | rubyjsonparse "puts j['hostname']"`"
            if [[ $net_name == "admin" ]]
            then
                cephmons_names+="$hostname "
            else
                cephmons_names+="$net_name.$hostname "
            fi
        done
        cephosds=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-osd']"`
        cephradosgws=`crowbar ceph proposal show default | rubyjsonparse "puts j['deployment']['ceph']['elements']['ceph-radosgw']"`
    else
        cephmons=
        cephosds=
        cephradosgws=
    fi
}

function oncontroller_get_network_id
{
    openstack network show fixed -f value -c id
}

function oncontroller_manila_service_instance_get_uuid
{
    local vm_uuid=`openstack --os-project-name manila-service server show manila-service -f value -c id`
    test -n "$vm_uuid" || complain 91 "uuid from manila-service instance not available"
    echo $vm_uuid
}

function oncontroller_manila_service_instance_get_floating_ip
{
    local vm_uuid=`oncontroller_manila_service_instance_get_uuid`
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
    if iscloudver 7plus; then
        floatingip=$(openstack floating ip create floating -f value -c floating_ip_address)
        openstack server add floating ip $instanceid $floatingip
    else
        nova floating-ip-create | tee floating-ip-create.out
        floatingip=$(perl -ne "if(/\d+\.\d+\.\d+\.\d+/){print \$&}" floating-ip-create.out)
        nova add-floating-ip "$instanceid" "$floatingip"
    fi
}

function ha_services_failover_test
{
    #Get cluster name
    local cluster=`get_cluster_name`
    read -a nodes <<< `get_all_nodes_from_cluster "$cluster"`
    #ssh to first node kill services nova-api ,glance-api,pkill mysql
    ssh ${nodes[0]} 'pkill nova-api; pkill glance-api; pkill mysql'
    #Start rally tests
    run_rally_test
    #ssh to nodes check that services running
    for((i=1; i<${#nodes[@]}; i++)) ;do
        ssh ${nodes[$i]} 'pgrep nova-api; pgrep glance-api; pgrep mysql'
        echo $?
    done
    #Check that services recovered
    ssh ${nodes[0]} 'pgrep nova-api; pgrep glance-api; pgrep mysql'
    local ret=$?
    if [ "$ret" = "0" ]; then
        echo "Services recovered succesfully"
    else
        echo "Services fail to recover"
    fi
}

function run_rally_test
{
    #Get network id
    get_novacontroller
    local net_id=`oncontroller get_network_id`
    . scripts/jenkins-support.sh
    #Pass parameters to rally server
    echo -e "cloud=$cloud \nnetid=$net_id \nimage_name=$image_name \ntask=$task" > setenv
    scp setenv root@$rally_server:/root/
    #Connect rally server execute tests
    connect_rally_server_run_test
}

function oncontroller_nova_evacuate
{
    local num_controllers=$1

    # Test nova evacuate
    local vm_name=NovaEvacuate

    # JSON parser with python
    local PJSON='import json,sys; field=json.load(sys.stdin)'

    # Get hypervisor hostname
    local hypervisors=$(openstack hypervisor list -c 'Hypervisor Hostname' --format json)
    local hypervisor_host_fqdn=$(echo $hypervisors | python -c "$PJSON; print field[0]['Hypervisor Hostname']")
    local hypervisor_host=$(echo $hypervisor_host_fqdn | cut -d '.' -f 1)

    # Create instance on specific hypervisor
    # image always exist after tempest run (cirros-0.3.4-x86_64-tempest-machine)
    nova boot --image cirros-0.3.4-x86_64-tempest-machine --flavor tempest-stuff --availability-zone nova:$hypervisor_host $vm_name
    # Create floating ip assign to instance
    addfloatingip $vm_name
    local floatingip=$(openstack server show -c addresses --format value $vm_name | cut -d " " -f 2)
    # Update security group for icmp
    if iscloudver 8plus; then
        local projectid=$(openstack project show -c id --format value $OS_PROJECT_NAME)
        local secgroupid=$(openstack security group list -c ID -c Project --format value | grep $projectid | cut -d " " -f 1)
        openstack security group rule create --protocol icmp $secgroupid &> /dev/null
    else
        nova secgroup-add-rule default icmp -1 -1 0.0.0.0/0 &> /dev/null
    fi

    # Check if instance is ACTIVE and Running
    ping -c 10 $floatingip >/dev/null 2>&1
    local ping_result=$?
    local status=$(openstack server show -c status --format value $vm_name)
    echo "Instance status: $status"
    if [[ $status = ACTIVE && $ping_result = 0 ]]; then
        echo "Instance launched successfully"
    else
        echo "Instance launch failed"
        exit 1
    fi

    # Simulate failure of hypervisor node
    kill_pacemaker_remote $hypervisor_host_fqdn $floatingip $num_controllers

    # Check that instance evacuated to working hypervisor host
    local ret=0
    local hypervisor_evacuate_host=$(openstack server show -c OS-EXT-SRV-ATTR:hypervisor_hostname --format value $vm_name)
    if [[ $hypervisor_evacuate_host != $hypervisor_host ]]; then
        echo "Instance evacuated"
    else
        echo "Evacuate fail, instance remains on failed host"
        ret=20
    fi

    # NOTE(gosipyan) because of bsc#1025230 the compute node is fenced
    # (shutdown in real hardware, and rebooted w/out network in VM) and can't
    # be recovered, but because this is the last test and the environment is
    # not needed anymore, we can do the recovery later.

    exit $ret
}

function kill_pacemaker_remote
{
    echo "Killing pacemaker..."

    local hypervisor_fqdn=$1
    local floatingip=$2
    local num_controllers=$3

    # Simulate failure of hypervisor node
    ssh -T $hypervisor_fqdn "killall -9 pacemaker_remoted"

    local ret=1
    local n=120
    # Check for nova-evacute log on all cluster nodes
    while [[ $n -gt 0 && $ret != 0 ]]; do
        for((i=1; i<=$num_controllers; i++)) ; do
            ssh controller$i 'grep -q "Completed evacuation of" /var/log/messages'
            ret=$?
            [[ $ret != 0 ]] && break
        done
        sleep 1
        n=$(expr $n - 1)
    done
    # Wait to instance be up
    wait_for 100 1 "ping -q -c 1 -w 1 $floatingip >/dev/null" "Instance to be up"
}

function glance_image_exists
{
    glance_image_get_id $1
    return $?
}

function glance_image_get_id
{
    local id=""
    #due to https://bugs.launchpad.net/python-openstackclient/+bug/1501362
    #images cannot be found by name over glance v2 api
    if iscloudver 6minus; then
        eval $(openstack --os-image-api-version 1 image show -f shell "$1")
    else
        eval $(openstack image show -f shell "$1")
    fi
    echo "$id"
    [[ $id ]] # set return code
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
    tempest cleanup --delete-tempest-conf-objects
}

function oncontroller_run_tempest
{
    pushd /var/lib/openstack-tempest-test
    sysctl -e kernel.sysrq=1 net.ipv4.neigh.default.gc_thresh1=0
    local tempestret

    tempest cleanup --init-saved-state
    if iscloudver 7plus; then
        tempest run $tempestoptions 2>&1 | tee tempest.log
        tempestret=${PIPESTATUS[0]}
    else
        ./run_tempest.sh -N $tempestoptions 2>&1 | tee tempest.log
        tempestret=${PIPESTATUS[0]}
    fi

    # tempest returns 0 also if no tests were executed - so use "testr last"
    # to verify that some tests were executed
    if [ "$tempestret" -eq 0 ]; then
        testr last || complain 96 "Tempest run succeeded but something is wrong"
        # output the slowest tests from the latest run
        testr slowest
    fi
    testr last --subunit > tempest.subunit.log

    oncontroller_tempest_cleanup
    popd
    return $tempestret
}

function oncontroller_upload_defcore
{
    pushd /var/lib/openstack-tempest-test
    # get the test list
    wget "https://refstack.openstack.org/api/v1/guidelines/2018.02/tests" -O defcore-with-id.txt
    # remove the id in [] or tempest will complain on incorrect regex
    sed -e 's/\[[^][]*\]//g' defcore-with-id.txt > defcore.txt
    # run only the specified tests
    tempest run --whitelist-file defcore.txt
    source /root/.openrc
    wget https://raw.githubusercontent.com/testing-cabal/subunit/master/filters/subunit-2to1
    testr last --subunit | python subunit-2to1 > tempest.subunit_1.log
    test -d refstack-client || safely git clone https://github.com/openstack/refstack-client
    yes | refstack-client/refstack-client upload-subunit --keystone-endpoint $OS_AUTH_URL --url https://10.86.0.98 --insecure tempest.subunit_1.log
    popd
}

function onadmin_upload_defcore
{
    get_novacontroller
    oncontroller upload_defcore
}

function oncontroller_run_integration_test()
{
    # Install Mozilla Firefox < 47 to work with Selenium.
    safely $zypper in 'MozillaFirefox<47'

    # Add Devel:Languages:Python repo (no GPG checks) to install Selenium
    local dlp="http://download.opensuse.org/repositories/devel:/languages:/python/$slesdist/"
    $zypper ar --no-gpgcheck --refresh $dlp python
    safely $zypper in python-selenium
    safely $zypper in python-nose
    safely $zypper in python-xvfbwrapper

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

function oncontroller_heat_image_setup()
{
    local image_filename=SLES11-SP3-x86_64-cfntools.qcow2
    local image_url=$imageserver_url/$image_filename
    # this is the standard name we use in the tempest barclamp. If you change the name
    # you may also want to set the new name in the barclamp
    local image_name="heat-cfntools-image"
    local local_image_path=""
    [[ -n "${localreposdir_target}" ]] && local_image_path=$localreposdir_target/images/$image_filename

    . .openrc

    # Upload a Heat-enabled image
    if ! glance_image_exists $image_name; then
        if [ -n "${local_image_path}" -a -f "${local_image_path}" ] ; then
            openstack image create \
                --public --disk-format qcow2 --container-format bare \
                --property hypervisor_type=kvm \
                --file $local_image_path $image_name | tee glance.out
        else
            curl -s \
                $image_url | \
                openstack image create \
                    --public --disk-format qcow2 --container-format bare \
                    --property hypervisor_type=kvm \
                    $image_name | tee glance.out
        fi
    fi
}

function oncontroller_manila_generic_driver_setup()
{
    if [[ $wantxenpv ]] ; then
        local service_image_url=$imageserver_url/$arch/other/manila-service-image-xen.raw
        local service_image_name=manila-service-image-xen.raw
        local service_image_params="--disk-format raw --property hypervisor_type=xen --property vm_mode=xen"
    elif [[ $wanthyperv ]] ; then
        local service_image_url=$imageserver_url/$arch/other/manila-service-image.vhd
        local service_image_name=manila-service-image.vhd
        local service_image_params="--disk-format vhd --property hypervisor_type=hyperv"
    else
        local service_image_url=$imageserver_url/$arch/other/manila-service-image.qcow2
        local service_image_name=manila-service-image.qcow2
        local service_image_params="--disk-format qcow2 --property hypervisor_type=kvm"
    fi

    local sec_group="manila-service"
    local neutron_net=$sec_group
    local local_image_path=""
    if [ -n "${localreposdir_target}" ] ; then
        local_image_path=$localreposdir_target/images/$arch/other/$service_image_name
    fi

    if [ -n "${local_image_path}" -a -f "${local_image_path}" ] ; then
        service_image_name=$local_image_path
    else
        local ret=$(wget -N --progress=dot:mega "$service_image_url" 2>&1 >/dev/null)
        if [[ $ret =~ "200 OK" ]]; then
            echo $ret
        elif [[ $ret =~ "Not Found" ]]; then
            complain 73 "manila image not found: $ret"
        else
            complain 74 "failed to retrieve manila image: $ret"
        fi
    fi

    . .openrc

    if ! openstack project show manila-service; then
        manila_service_tenant_id=`openstack project create manila-service -f value -c id`
        openstack role add --project manila-service --user admin admin
    fi
    export OS_TENANT_NAME='manila-service'
    export OS_PROJECT_NAME=$OS_TENANT_NAME

    # using list subcommand because show requires an ID
    if ! openstack image list --format value -c Name | grep -q "^manila-service-image$"; then
        openstack image create --file $service_image_name \
            $service_image_params --container-format bare --public \
            manila-service-image
    fi

    if ! nova flavor-show manila-service-image-flavor 2> /dev/null ; then
        nova flavor-create manila-service-image-flavor 100 512 0 1
    fi

    if iscloudver 8plus; then
        if ! openstack security group show $sec_group 2>/dev/null ; then
            openstack security group create --description "$sec_group description" $sec_group
            openstack security group rule create --protocol icmp $sec_group
            openstack security group rule create --protocol tcp --dst-port 22 $sec_group
            openstack security group rule create --protocol tcp --dst-port 2049 $sec_group
            openstack security group rule create --protocol tcp --dst-port 20000:65535 $sec_group
            openstack security group rule create --protocol udp --dst-port 2049 $sec_group
            openstack security group rule create --protocol udp --dst-port 445 $sec_group
            openstack security group rule create --protocol tcp --dst-port 445 $sec_group
            openstack security group rule create --protocol tcp --dst-port 137:139 $sec_group
            openstack security group rule create --protocol udp --dst-port 137:139 $sec_group
            openstack security group rule create --protocol tcp --dst-port 111 $sec_group
            openstack security group rule create --protocol udp --dst-port 111 $sec_group
        fi
    else
        if ! nova secgroup-list-rules manila-service 2> /dev/null ; then
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
    fi

    service_vm_status="`openstack server show --format value -c status manila-service`"
    if [ "$service_vm_status" = "ACTIVE" ] || [ "$service_vm_status" = "SHUTOFF" ] ; then
        if [ "$service_vm_status" = "SHUTOFF" ]; then
            # We're upgrading. Restart existing instance as it was shutdown during
            # the upgrade
            timeout 10m nova start manila-service
        fi
        manila_service_vm_uuid=`oncontroller_manila_service_instance_get_uuid`
        manila_tenant_vm_ip=`oncontroller_manila_service_instance_get_floating_ip`
    else
        fixed_net_id=`neutron net-show fixed -f value -c id`
        timeout 10m nova --insecure boot --poll --flavor 100 --image manila-service-image \
            --security-groups $sec_group,default \
            --nic net-id=$fixed_net_id manila-service

        [ $? != 0 ] && complain 43 "nova boot for manila failed"

        # manila tempest tests use the floating IP to export the shares. So create
        # a floating IP for the manila instance and add it to the VM
        oscclient_ver=`rpm -q --queryformat '%{VERSION}' python-openstackclient`
        if [ ${oscclient_ver:0:1} -ge 3 ]; then
            # >= Newton
            manila_tenant_vm_ip=`openstack ip floating create floating -f value -c floating_ip_address`
        else
            manila_tenant_vm_ip=`openstack ip floating create floating -f value -c ip`
        fi
        openstack ip floating add $manila_tenant_vm_ip manila-service

        [ $? != 0 ] && complain 44 "adding a floating ip to the manila service VM failed"
    fi
    # check that the service VM is pingable. otherwise manila tempest tests will fail later
    wait_for 300 1 "nc -w 1 -z $manila_tenant_vm_ip 22" \
        "manila service VM booted and ssh port open" \
        "echo \"ERROR: manila service VM not listening on ssh port. manila tests will fail!\""
}

function oncontroller_magnum_service_setup
{
    local service_image_name="magnum-service-image"
    local service_image_filename=${service_image_name}.qcow2
    local service_image_url=$imageserver_url/$arch/other/$service_image_filename
    local local_image_path=""
    if [ -n "${localreposdir_target}" ] ; then
        local_image_path=$localreposdir_target/images/$arch/other/$service_image_filename
    fi

    if ! openstack image list --format value -c Name | grep -q "^${service_image_name}$"; then
        if [ -n "${local_image_path}" -a -f "${local_image_path}" ] ; then
            service_image_filename=$local_image_path}
        else
            local ret=$(wget -N --progress=dot:mega "$service_image_url" 2>&1 >/dev/null)
            if [[ $ret =~ "200 OK" ]]; then
                echo $ret
            elif [[ $ret =~ "Not Found" ]]; then
                complain 73 "magnum image not found: $ret"
            else
                complain 74 "failed to retrieve magnum image: $ret"
            fi
        fi

        . ~/.openrc

        # TODO(toabctl): when replacing the Fedora image, also replace the
        # os-distro property
        openstack image create --file $service_image_filename \
            --disk-format qcow2 --container-format bare --public \
            --property os_distro=fedora-atomic $service_image_name
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
        test $(openstack compute service list -f value -c State | grep -c down) -eq 0
    else
        test $(nova-manage service list  | fgrep -cv -- \:\-\)) -lt 2
    fi
}

function oncontroller_check_crm_failcounts
{
    if iscloudver 7plus && [[ $hacloud = 1 && ( $1 = "disallowskipfailcount" || $want_crm_failcount_skip != 1 ) ]] ; then
        crm_mon --failcounts -1 | grep "fail-count=" && complain 55 "Cluster resources' failures detected"
    fi
    return 0
}

function oncontroller_mount_localreposdir
{
    # use the local cache if available. This is done by mounting the local
    # repositories from the host machine via 9pnet_virtio.
    [ -n "${localreposdir_target}" ] && mount_localreposdir_target
}

# code run on controller/dashboard node to do basic tests of deployed cloud
# uploads an image, create flavor, boots a VM, assigns a floating IP, ssh to VM, attach/detach volume
function oncontroller_testsetup
{
    . .openrc
    pre_hook $FUNCNAME
    oncontroller_prepare_functional_tests
    oncontroller_check_crm_failcounts disallowskipfailcount
    # 28 is the overhead of an ICMP(ping) packet
    [[ $want_mtu_size ]] && safely ping -M do -c 1 -s $(( want_mtu_size - 28 )) $adminip
    export LC_ALL=C

    if ! openstack catalog show manila 2>&1 | grep -q "service manila not found" && \
        ! manila type-list | grep -q "[[:space:]]default[[:space:]]" ; then
        manila type-create default false || complain 79 "manila type-create failed"
    fi

    if iscloudver 7plus && \
        ! openstack catalog show manila 2>&1 | grep -q "service manila not found" && \
        ! manila type-list | grep -q "[[:space:]]ceph[[:space:]]" ; then
        manila type-create ceph false --snapshot_support false || complain 79 "manila type-create for ceph failed"
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
    if [[ $want_tempest = 1 ]]; then
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
    local local_image_path=""

    if ! glance_image_exists $image_name ; then
        if [[ $wanthyperv ]] ; then
            mount $nfsserver_ip:/srv/nfs/ /mnt/
            $zypper in virt-utils
            qemu-img convert -O vpc /mnt/images/SP3-64up.qcow2 /tmp/SP3.vhd
            openstack image create --public --disk-format vhd --container-format bare --property hypervisor_type=hyperv --file /tmp/SP3.vhd $image_name | tee glance.out
            rm /tmp/SP3.vhd ; umount /mnt
        elif [[ $wantxenpv ]] ; then
            local image_filename="jeos-64-pv.qcow2"
            [[ -n "${localreposdir_target}" ]] && local_image_path="${localreposdir_target}/images/${image_filename}"

            if [ -n "${local_image_path}" -a -f "${local_image_path}" ] ; then
                openstack image create --public --disk-format qcow2 \
                --container-format bare --property hypervisor_type=xen \
                --property vm_mode=xen  \
                --file $local_image_path $image_name | tee glance.out
            else
                curl -s \
                    $imageserver_url/$image_filename | \
                    openstack image create --public --disk-format qcow2 \
                    --container-format bare --property hypervisor_type=xen \
                    --property vm_mode=xen  $image_name | tee glance.out
            fi
        else
            local image_filename="SLES12-SP1-JeOS-SE-for-OpenStack-Cloud.${arch}-GM.qcow2"
            [[ -n "${localreposdir_target}" ]] && local_image_path="${localreposdir_target}/images/x86_64/${image_filename}"

            if [ -n "${local_image_path}" -a -f "${local_image_path}" ] ; then
                openstack image create --public --property hypervisor_type=kvm \
                --disk-format qcow2 --container-format bare \
                --file $local_image_path $image_name | tee glance.out
            else
                curl -s \
                    $imageserver_url/$arch/$image_filename | \
                    openstack image create --public --property hypervisor_type=kvm \
                    --disk-format qcow2 --container-format bare $image_name | tee glance.out
            fi
        fi
    fi

    #test for Glance scrubber service, added after bnc#930739
    if iscloudver 6plus || [[ $cloudsource =~ (devel|newton)cloud ]]; then
        configargs="--config-dir /etc/glance"
        iscloudver 6plus && configargs=""
        su - glance -s /bin/sh -c "/usr/bin/glance-scrubber $configargs" \
            || complain 113 "Glance scrubber doesn't work properly"
        # ERROR_FOR_DIVISION_BY_ZERO is part of MySQL server mode
        # this is logged into glance/scrubber.log if DEBUG is enabled
        grep -v glance_store /var/log/glance/scrubber.log | grep -v ERROR_FOR_DIVISION_BY_ZERO | grep ERROR \
            && complain 114 "Unexpected errors in glance-scrubber logs"
    fi

    if [ -n "$want_s390" ] ; then
        image_name="s390x-SLES12SP1-cloud-init"
        flavor="m1.small"
        ssh_user="root"
        if ! glance_image_exists $image_name ; then
            curl -s \
                $imageserver_url/s390x/xCAT-SLES12SP1-ECKD.img | \
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

    local imageid
    imageid=$(glance_image_get_id $image_name) || \
        complain 37 "Image ID for $image_name not found"
    wait_image_active "$imageid" testsetup

    if [[ $want_ldap = 1 ]] ; then
        if iscloudver 7plus  ; then
            openstack user show bwiedemann --domain ldap_users | grep bwiedemann || complain 103 "LDAP not working"
            openstack group show suse --domain ldap_users | grep suse || complain 103 "LDAP not working"
            openstack group contains user --group-domain ldap_users --user-domain ldap_users suse bwiedemann | grep 'bwiedemann in group suse' || complain 103 "LDAP not working"
        else
            openstack user show bwiedemann | grep -q bwiedemann || complain 103 "LDAP not working"
        fi
    fi

    # wait for nova-manage to be successful
    wait_for 200 1 nova_services_up "Nova services to be up and running"

    if nova flavor-show m1.smaller 2> /dev/null ; then
        nova flavor-delete m1.smaller
    fi
    nova flavor-create m1.smaller 101 512 8 1
    instanceid=`openstack server show testvm -f value -c id`
    if [[ $instanceid ]] ; then
        nova delete $instanceid
        wait_for 10 3 "[[ ! \$(nova show $instanceid) ]]" "testvm to be deleted"
    fi
    nova keypair-add --pub-key /root/.ssh/id_rsa.pub testkey

    if iscloudver 8plus; then
        openstack security group delete testvm || :
        openstack security group create --description testvm testvm
        openstack security group rule create --protocol icmp testvm
        openstack security group rule create --protocol tcp --dst-port 1:65535 testvm
        openstack security group rule create --protocol udp --dst-port 1:65535 testvm
    else
        if nova secgroup-list-rules testvm &>/dev/null ; then
            nova secgroup-delete testvm
        fi
        nova secgroup-create testvm testvm
        nova secgroup-add-rule testvm icmp -1 -1 0.0.0.0/0
        nova secgroup-add-rule testvm tcp 1 65535 0.0.0.0/0
        nova secgroup-add-rule testvm udp 1 65535 0.0.0.0/0
    fi

    timeout 10m nova --insecure boot --poll --image $image_name --flavor $flavor --key-name testkey --security-group testvm testvm | tee boot.out
    ret=${PIPESTATUS[0]}
    [ $ret != 0 ] && complain 43 "nova boot failed"
    instanceid=`perl -ne "m/ id [ |]*([0-9a-f-]+)/ && print \\$1" boot.out`
    nova show "$instanceid"
    vmip=`nova show "$instanceid" | perl -ne "m/fixed.network [ |]*([0-9.]+)/ && print \\$1"`
    echo "VM IP address: $vmip"
    if [ -z "$vmip" ] ; then
        echofailed
        tail -n 90 /var/log/nova/*
        complain 38 "VM IP is empty. Exiting"
    fi
    addfloatingip "$instanceid"
    vmip=$floatingip
    wait_for 1000 1 "ping -q -c 1 -w 1 $vmip >/dev/null" "testvm booted and ping returned"
    wait_for 500  1 "netcat -z $vmip 22" "ssh daemon on testvm is accessible"

    local ssh_target="$ssh_user@$vmip"

    wait_for 60 5 "timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $ssh_target true" "SSH key to be copied to VM"

    if ! ssh $ssh_target curl $test_internet_url ; then
        complain 95 could not reach internet
    fi

    # The custom-key value is only set during initial deployment of Cloud7 directly from this script
    # So it is not present when the cloud is upgraded from Cloud6 and we need to skip this test.
    if iscloudver 7plus && grep -q "custom-value" /etc/nova/suse-vendor-data.json 2>/dev/null ; then
        wait_for 40 5 "timeout -k 20 10 ssh -o UserKnownHostsFile=/dev/null $ssh_target curl -s http://169.254.169.254/openstack/latest/vendor_data.json|grep -q custom-key" "Custom vendordata not accessable from VM"
    fi

    local volumecreateret=0
    local volumeattachret=0
    local volumeresult=""
    local portresult=0

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

    # cleanup so that we can run testvm without leaking volumes, IPs etc
    if iscloudver 7plus; then
        openstack server remove floating ip "$instanceid" "$floatingip"
        openstack floating ip delete "$floatingip"
    else
        nova remove-floating-ip "$instanceid" "$floatingip"
        nova floating-ip-delete "$floatingip"
    fi
    nova stop "$instanceid"
    wait_for 100 1 "test \"x\$(nova show \"$instanceid\" | perl -ne 'm/ status [ |]*([a-zA-Z]+)/ && print \$1')\" == xSHUTOFF" "testvm to stop"

    # run tests for Magnum bay deployment
    if iscloudver 7 && [[ $want_magnum_proposal = 1 ]]; then

        # This test will cover simple Kubernetes cluster with TLS disabled and no LoadBalancer
        if ! magnum cluster-template-show k8s_template_tls_lb_off > /dev/null 2>&1; then
            safely magnum cluster-template-create --name k8s_template_tls_lb_off \
                --image-id $magnum_k8s_image_name \
                --keypair-id default \
                --external-network-id floating \
                --flavor-id m1.smaller \
                --master-flavor-id m2.smaller \
                --docker-volume-size 5 \
                --network-driver flannel \
                --coe kubernetes \
                --tls-disabled
        fi

        if ! magnum cluster-show k8s_cluster_one > /dev/null 2>&1; then
            safely magnum cluster-create --name k8s_cluster_one --cluster-template k8s_template_tls_lb_off --master-count 1 --node-count 2
            wait_for 500 3 'magnum cluster-show k8s_cluster_one | grep -q "status.*CREATE_COMPLETE"' "Magnum is creating Kubernetes cluster" "complain 130 'Magnum could not create Kubernetes cluster'"

            echo "Magnum finished creating Kubernetes cluster"
            safely magnum cluster-show k8s_cluster_one

            # cleanup Magnum deployment
            safely magnum cluster-delete k8s_cluster_one
            wait_for 300 3 'magnum cluster-show k8s_cluster_one > /dev/null 2>&1; [[ $? == 1 ]]' "Magnum is removing Kubernetes cluster" "complain 131 'Magnum could not remove Kubernetes cluster'"
            safely magnum cluster-template-delete k8s_template_tls_lb_off;
            wait_for 300 3 'magnum cluster-template-show k8s_template_tls_lb_off > /dev/null 2>&1; [[ $? == 1 ]]' "Magnum is removing Kubernetes cluster template" "complain 131 'Magnum could not remove Kubernetes cluster template'"
        fi

        # This test will cover advanced Kubernetes cluster with TLS enabled and with LoadBalancer for multi master
        if ! magnum cluster-template-show k8s_template_tls_lb_on > /dev/null 2>&1; then
            safely magnum cluster-template-create --name k8s_template_tls_lb_on \
                --image-id $magnum_k8s_image_name \
                --keypair-id default \
                --external-network-id floating \
                --flavor-id m1.smaller \
                --master-flavor-id m2.smaller \
                --docker-volume-size 5 \
                --network-driver flannel \
                --coe kubernetes \
                --floating-ip-enabled \
                --master-lb-enabled
        fi

        if ! magnum cluster-show k8s_cluster_two > /dev/null 2>&1; then
            safely magnum cluster-create --name k8s_cluster_two --cluster-template k8s_template_tls_lb_on --master-count 2 --node-count 1
            wait_for 500 3 'magnum cluster-show k8s_cluster_two | grep -q "status.*CREATE_COMPLETE"' "Magnum is creating Kubernetes cluster" "complain 130 'Magnum could not create Kubernetes cluster'"

            echo "Magnum finished creating Kubernetes cluster"
            safely magnum cluster-show k8s_cluster_two

            # cleanup Magnum deployment
            safely magnum cluster-delete k8s_cluster_two
            wait_for 300 3 'magnum cluster-show k8s_cluster_two > /dev/null 2>&1; [[ $? == 1 ]]' "Magnum is removing Kubernetes cluster" "complain 131 'Magnum could not remove Kubernetes cluster'"
            safely magnum cluster-template-delete k8s_template_tls_lb_on;
            wait_for 300 3 'magnum cluster-template-show k8s_template_tls_lb_on > /dev/null 2>&1; [[ $? == 1 ]]' "Magnum is removing Kubernetes cluster template" "complain 131 'Magnum could not remove Kubernetes cluster template'"
        fi
    fi

    # check that no port is in binding_failed state
    for p in $(neutron port-list -f csv -c id --quote none | grep -v id); do
        if neutron port-show $p -f value | grep -qx binding_failed; then
            echo "binding for port $p failed.."
            portresult=1
        fi
    done

    echo "RadosGW Tests: $radosgwret"
    echo "Tempest: $tempestret"
    echo "Volume in VM: $volumeresult"
    echo "Ports in binding_failed: $portresult"

    test $tempestret = 0 -a $volumecreateret = 0 -a $volumeattachret = 0 \
        -a $radosgwret = 0 -a $portresult = 0 || exit 102
}


function run_on
{
    local remote=$1 ; shift
    cd /root
    scp -r $SCRIPTS_DIR $mkcconf "$remote:"
    ssh "$remote" "export deployswift=$deployswift ; export deployceph=$deployceph ;
        export tempestoptions=\"$tempestoptions\" ;
        export cephmons=\"$cephmons\" ; export cephosds=\"$cephosds\" ;
        export cephmons_names=\"$cephmons_names\" ;
        export cephradosgws=\"$cephradosgws\" ; export wantcephtestsuite=\"$wantcephtestsuite\" ;
        export wantradosgwtest=\"$wantradosgwtest\" ; export cloudsource=\"$cloudsource\" ;
        export libvirt_type=\"$libvirt_type\" ;
        export cloud=$cloud ; export TESTHEAD=$TESTHEAD ;
        export is_oncontroller=yes ; export want_ceph_ssl=$want_ceph_ssl ;
        export want_all_ssl=$want_all_ssl ;
        . ./$(basename $SCRIPTS_DIR)/qa_crowbarsetup.sh ;  source .openrc; onadmin_set_source_variables; $@"
    return $?
}

function oncontroller
{
    local func=$1 ; shift
    run_on "$novacontroller" "oncontroller_$func $@"
}

function install_suse_ca
{
    # trust build key - workaround https://bugzilla.opensuse.org/show_bug.cgi?id=935020
    wget -O- http://$susedownload/ibs/SUSE:/CA/SLE_12/repodata/repomd.xml.key | gpg --import
    gpg --export -a 0xFEAB502539D846DB2C0961CA70AF9E8139DB7C82 > build.suse.de.key.pgp
    safely rpm --import build.suse.de.key.pgp

    onadmin_set_source_variables # for $slesdista
    local caurl=http://$susedownload/ibs/SUSE:/CA/$slesdist/SUSE:CA.repo
    # 2018-09-01: SP4 repo not yet enabled, try SP3 repo for now
    if ! curl -s -f $caurl > /dev/null; then
        caurl=${caurl/SLE_12_SP4/SLE_12_SP3}
    fi
    $zypper ar --refresh $caurl
    safely $zypper in ca-certificates-suse
}

function ceph_testsuite_configure_storage3
{
    # this is the configuration for the tests from the storage3 branch
    yaml_osds=`echo $cephosds | sed "s/ /\n/g" | sed "s/\..*//g" | sort -ru`
    osds=""
    for node in $yaml_osds; do
        nodename=(vda1 vdb1 vdc1 vdd1 vde1)
        for i in $(seq $cephvolumenumber); do
            osds="$osds $node:${nodename[$i]}"
        done
    done

    ./update_template ${cephmons_names}
    ./update_template --nodes-type osd --user root --yaml-file templates/template.yml.new $osds
    export YAMLDATA_FILE=templates/template.yml.new
}

function oncontroller_prepare_functional_tests
{
    local mount_dir="/var/lib/Cloud-Testing"
    local repo_name="cloud-test"

    if ! [[ $CLOUDTESTISONAME ]]; then
        echo "Warning: Testing ISO for $cloudsource is not defined, functional tests are not available"
    else
        if ! $zypper lr "$repo_name" ; then
            wget_iso_and_unpack_to "$CLOUDISOURL" "$CLOUDTESTISONAME" "$mount_dir"
            $zypper ar --refresh -c -G -f "$mount_dir" "$repo_name"
            zypper_refresh
            ensure_packages_installed python-novaclient-test python-manilaclient-test
        fi
    fi
}

# use admin node as empty scratch VM to test our setuphost code
function onadmin_test_setuphost
{
    set -x
    if ! test -e /root/loop ; then
        dd if=/dev/zero of=/root/loop bs=1M seek=150000 count=1
        losetup /dev/loop1 /root/loop
    fi
    export cloudpv=/dev/loop1
    # to not need lvm.conf patches
    export SHAREDVG=1
    export debug_mkcloud=1
    # must be different from our admin net
    # and in a private range to make libvirt happy
    export net_admin=172.27.176
    export admin_node_memory=1048576
    unset adminip
    rm -f $mkcconf
    onadmin_setup_local_zypper_repositories
    safely $SCRIPTS_DIR/mkcloud setuphost cleanup prepare setupadmin
}

function oncontroller_test_keystone_password
{
    safely openstack token issue
}

function update_keystone_password
{
    local old_password=$(crowbar keystone proposal show default | rubyjsonparse "puts j['attributes']['keystone']['admin']['password']")
    local updated_password='barcrow'
    crowbar batch export keystone | ruby -ryaml -e "
y = YAML.load(ARGF)
y['proposals'].first['attributes']['admin'] ||= {}
y['proposals'].first['attributes']['admin']['password'] = '$updated_password'
puts y.to_yaml" > /root/keystone-test-pw-update.yaml
    safely crowbar batch --timeout 1500 build < /root/keystone-test-pw-update.yaml
    safely oncontroller test_keystone_password
    cat /root/keystone-test-pw-update.yaml | ruby -ryaml -e "
y = YAML.load(ARGF)
y['proposals'].first['attributes']['admin']['password'] = '$old_password'
puts y.to_yaml" > /root/keystone-test-pw-reset.yaml
    safely crowbar batch --timeout 1500 build < /root/keystone-test-pw-reset.yaml
}

function onadmin_have_salt_barclamp
{
    test -e /opt/dell/crowbar_framework/barclamps/salt.yml
}

function onadmin_setupsalt
{
    onadmin_have_salt_barclamp || return 0
    add_salt_repo
    do_one_proposal salt default
}

function onadmin_testsalt
{
    onadmin_have_salt_barclamp || return 0
    test -e /etc/salt/roster || onadmin_setupsalt
    salt-ssh \* test.ping | tee /tmp/salt.test.log
    # compare successful pings to node number (+1 for crowbar)
    # FIX ME #jdsn please add the correct distiction between virtual and
    # physical nodes in the function nodes
    # test $((1 + $(nodes number all))) = $(grep "^  *True$" /tmp/salt.test.log | wc -l)
    test $(crowbar machines list | wc -l) = $(grep "^  *True$" /tmp/salt.test.log | wc -l)
}

function ceph_test_suite
{
    local cephret=0
    # dependency for the test suite
    ensure_packages_installed git-core python-PyYAML python-setuptools

    rpm -Uvh http://$susedownload/ibs/SUSE:/SLE-12:/GA/standard/noarch/python-nose-1.3.0-8.4.noarch.rpm

    if test -d qa-automation; then
        pushd qa-automation
        git reset --hard
        git pull
    else
        install_suse_ca
        safely git clone https://gitlab.suse.de/ceph/qa-automation.git
        safely pushd qa-automation
    fi

    # configure and run the testsuite
    if iscloudver 7plus; then
        # there is no storage4 branch and storage team uses storage3 branch
        # for SES3 and SES4
        git checkout storage3
        ceph_testsuite_configure_storage3
        nosetests testsuites/test_validate.py
        cephret=$?
    fi
    return $cephret
}

function radoswg_s3_test
{
    s3radosgwret=0
    # test S3 access using python API
    radosgw=`echo $cephradosgws | sed "s/ .*//g" | sed "s/\..*//g"`
    if [ "$want_ceph_ssl" == 1 -o "$want_all_ssl" == 1 ] ; then
        local radosgwport=8081
        local is_secure=True
    else
        local radosgwport=8080
        local is_secure=False
    fi
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
    port = $radosgwport,
    is_secure=$is_secure,
    calling_format = boto.s3.connection.OrdinaryCallingFormat()
)
bucket = conn.create_bucket("test-s3-bucket")
EOF

    # check if test bucket exists using radosgw-admin API
    if ! ssh $radosgw radosgw-admin bucket list|grep -q test-s3-bucket ; then
        echo "test-s3-bucket not found"
        s3radosgwret=1
    fi
    return $s3radosgwret
}

function onadmin_testsetup
{
    pre_hook $FUNCNAME
    safely onadmin_testsalt

    local numdnsservers=$(crowbar dns proposal show default | rubyjsonparse "puts j['deployment']['dns']['elements']['dns-server'].length")
    if [ "$want_multidnstest" = 1 ] && [ "$numdnsservers" -gt 1 ]; then
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

    if iscloudver 7plus; then
        update_keystone_password
    fi

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
        local mons=($cephmons)
        run_on ${mons[0]} ceph_test_suite
        cephret=$?
    fi

    s3radosgwret=0
    if [ "$wantradosgwtest" == 1 ] ; then
        run_on ${cephradosgws[0]} radoswg_s3_test
    fi

    # use local cache whenever possible
    oncontroller mount_localreposdir

    oncontroller testsetup
    ret=$?

    echo "Tests on controller: $ret"
    echo "Ceph Tests: $cephret"
    echo "RadosGW S3 Tests: $s3radosgwret"

    if [ $ret -eq 0 ]; then
        test $s3radosgwret -eq 0 || ret=105
        test $cephret -eq 0 || ret=104
    fi

    if [[ $want_tempest = 1 ]]; then
        scp $novacontroller:/var/lib/openstack-tempest-test/tempest.log .
        scp $novacontroller:/var/lib/openstack-tempest-test/tempest.subunit.log .
        scp $novacontroller:.openrc .
    fi
    exit $ret
}

function ping_fips
{
    local fips
    if iscloudver 7plus; then
        fips=$(openstack floating ip list -f value -c 'Floating IP Address')
    else
        fips=$(openstack ip floating list -f value -c IP)
    fi
    for fip in $fips; do
        ping -c 1 -w 60 $fip || complain 120 "cannot reach test VM at $fip."
    done
}

# Use $heat_stack_params to provide parameters to heat template
function oncontroller_testpreupgrade
{
    create_cmd="heat --insecure stack-create upgrade_test -f "
    list_cmd="heat --insecure stack-list"
    if iscloudver 7plus; then
        create_cmd="openstack --insecure stack create upgrade_test -t "
        list_cmd="openstack --insecure stack list"
    fi
    $create_cmd /root/scripts/heat/2-instances-cinder.yaml $heat_stack_params
    wait_for 15 20 "$list_cmd | grep upgrade_test | grep CREATE_COMPLETE" \
             "heat stack for upgrade tests to complete"
    ping_fips && \
    echo "test pre-upgrade successful."
}

function oncontroller_testpostupgrade
{
    # retrieve the ping results
    local fips=$(openstack --insecure floating ip list -f value -c "Floating IP Address")

    # remove manila-service fip from list
    manila_vm=$(openstack --insecure server list --all-projects -f value | grep manila-service | awk '{ print $1 }' )
    if [[ $manila_vm ]]; then
        manila_fip=$(openstack --insecure server show $manila_vm -f value -c addresses | awk '{ print $2 }' )
        fips=( "${fips[@]/$manila_fip}" )
    fi

    for fip in $fips; do
        scp cirros@$fip:/var/log/ping_neighbour.out ping_neighbour.$fip.out
        max=$(sed -n 's/^.* not available for: //p' ping_neighbour.$fip.out | sort -n | tail -n 1)
        echo "Maximum outage while pinging other VM from $fip: $max seconds"

        scp cirros@$fip:/var/log/ping_outside.out ping_outside.$fip.out
        max=$(sed -n 's/^.* not available for: //p' ping_outside.$fip.out | sort -n | tail -n 1)
        echo "Maximum outage while pinging outside IP from $fip: $max seconds"

        scp cirros@$fip:/mnt/cinder_test.out cinder_test.$fip.out
        res=$(awk '$1!=p+1{print $1-p}{p=$1}' cinder_test.$fip.out | tail -n +2 | sort | tail -n 1)
        if [ -z "$res" ]; then
            echo "No cinder volume outage when writing from $fip"
        else
            echo "Maximum cinder volume outage when writing from $fip: $res seconds"
        fi
    done

    openstack --insecure stack delete --yes upgrade_test
    wait_for 15 20 "! openstack --insecure stack show upgrade_test" \
             "heat stack for upgrade tests to be deleted"
    echo "test post-upgrade successful."
}

function check_novacontroller
{
    safely ssh "$novacontroller" true
    echo "openstack nova controller node: $novacontroller"
}

function onadmin_testpreupgrade
{
    get_novacontroller
    check_novacontroller

    oncontroller testpreupgrade
}

function oncontroller_get_fips
{
    # Checking for cloudver might not get correct results here due to the nature of upgrade
    # So let's check the version directly at controller
    if grep -q SP1 /etc/os-release ; then
        echo $(openstack ip floating list -f value -c IP)
    else
        echo $(openstack floating ip list -f value -c "Floating IP Address")
    fi
}

function onadmin_ping_running_instances
{
    get_novacontroller
    local fip
    for fip in $(oncontroller get_fips); do
        bash $SCRIPTS_DIR/ping_forever.sh $fip </dev/null >/dev/null 2>&1 &
    done
}

function onadmin_testpostupgrade
{
    get_novacontroller
    check_novacontroller

    if [[ $want_ping_running_instances = 1 ]]; then
        # retrieve the ping results
        local fip
        for fip in $(oncontroller get_fips); do
            touch /var/lib/crowbar/stop_pinging.$fip
            max=$(sed -n 's/^.* not available for: //p' /var/log/ping_instance.$fip.out | sort -n | tail -n 1)
            echo "Maximum outage while pinging VM at $fip: $max seconds"
        done
    fi
    oncontroller testpostupgrade
}

function onadmin_addupdaterepo
{
    pre_hook $FUNCNAME

    local repos=$UPDATEREPOS
    local extra_repos=${1}
    local UPR=$tftpboot_repos_dir/PTF
    mkdir -p $UPR

    # Extra repos can be fetched on demand to the ptf repo
    # From the variable $UPDATEREPOS_EXTRA the first 'n' repos are added, where n is the parameter to this function
    # So addupdaterepo can be called repeatedly. Contents of the extra repos are only added but never removed.
    case $extra_repos in
        all|0)
            repos=$UPDATEREPOS_EXTRA ;;
        upgrade)
            repos=$UPDATEREPOS_UPGRADE ;;
        [1-9]*)
            repos="$(echo $UPDATEREPOS_EXTRA | cut -d+ -f1-${extra_repos//[^0-9]/})" ;;
        '')
            echo "Info: No extra repos will be fetched from \$UPDATEREPOS_EXTRA." ;;
        *)
            complain 13 "Invalid parameter for addupdaterepo. Valid are integers or the string 'all' (0 == all). The value was: $extra_repos" ;;
    esac

    if [[ $repos ]]; then
        local repo
        for repo in ${repos//+/ } ; do
            safely wget --progress=dot:mega \
                -r --directory-prefix $UPR \
                -e robots=off \
                --no-check-certificate \
                --no-parent \
                --no-clobber \
                --accept $arch.rpm,noarch.rpm \
                $repo
        done
        onadmin_setup_local_zypper_repositories
        ensure_packages_installed createrepo
        createrepo-cloud-ptf || createrepo -o $UPR $UPR || exit 8
    fi
    $zypper modifyrepo -e cloud-ptf >/dev/null 2>&1 ||\
        safely $zypper ar $UPR cloud-ptf
    safely $zypper mr -G -p 90 -r cloud-ptf
    safely $zypper ref
    if iscloudver 7minus ; then
        # workaround missing in cloud 6 GM and 7 GM: https://github.com/crowbar/crowbar/pull/2320
        [[ ! -e $UPR/repodata/repomd.xml.key ]] || safely rpmkeys --import $UPR/repodata/repomd.xml.key
    fi
}

function zypper_patch
{
    local zypper_patch_para=
    [[ $1 = "all" ]] && zypper_patch_para="--with-interactive"
    wait_for 30 3 " $zypper ref ; [[ \$? != 4 ]] " "successful zypper run" "exit 9"
    wait_for 30 3 " $zypper patch $zypper_patch_para ; ret=\$?; if [ \$ret == 103 ]; then $zypper patch $zypper_patch_para ; ret=\$?; fi; [[ \$ret != 4 ]] " "successful zypper run" "exit 9"
    wait_for 30 3 " $zypper up --repo cloud-ptf ; [[ \$? != 4 ]] " "successful zypper run" "exit 9"
}

function onadmin_zypper_patch_all
{
    zypper_patch all
}

function onadmin_wait_for_crowbar_api
{
    # The crowbar service might have been restarted during the zypper patch.
    # Wait for it to answer queries again to not break any further mkcloud
    # steps that might be executed after "runupdate".
    if systemctl --quiet is-enabled crowbar.service; then
        wait_for 20 10 "onadmin_is_crowbar_api_available" "crowbar service to restart"
    fi
}

function onadmin_runupdate
{
    pre_hook $FUNCNAME

    # We need to set the correct MTU here since we haven't done any
    # proper network configuration yet.
    [[ $host_mtu ]] && ip link set mtu $host_mtu dev eth0

    zypper_patch
    onadmin_wait_for_crowbar_api
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

    [ -z "$NEUTRON_SERVER" ] && return

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

    crowbarctl node reboot $machine
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
            complain_if_problem_on_reboot
        done
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
        unclustered_nodes=(`get_all_discovered_nodes`)
    fi

    for machine in ${unclustered_nodes[@]}; do
        power_cycle_and_wait $machine
    done

    wait_for 400 5 "! crowbar node_state status | grep ^d | grep -vqiE \"ready$|problem$\"" "nodes are back online"

    complain_if_problem_on_reboot

    onadmin_waitcloud
    onneutron_wait_for_neutron
    oncontroller waitforinstance

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

function oncontroller_suspendallinstances
{
    . .openrc
    for i in `openstack server list --all-projects --status active -f value -c ID`; do
        openstack server suspend $i
    done
    wait_for 300 5 "openstack server list --all-projects|grep -vqe ACTIVE" "waiting for all instance to be suspended"
}

function oncontroller_resumeallinstances
{
    . .openrc
    for i in `openstack server list --all-projects --status suspended -f value -c ID`; do
        openstack server resume $i
    done
    wait_for 300 5 "openstack server list --all-projects|grep -vqe SUSPENDED" "waiting for all instance to be resumed"
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

# if SES was deployed, it needs to be upgraded before Cloud
function onadmin_upgrade_ses_to_4
{
    if [ -z "$deployceph" ] ; then
        echo "ceph not deployed, no upgrade needed"
        return
    fi

    # 1a. find all ceph nodes
    local ceph_nodes=$(knife search node "roles:ceph-*" -a name | \
        grep ^name: | cut -d : -f 2 | sed 's/\s//g')

    # 1b save the search for ceph-mons
    local ceph_mons=$(knife search node "roles:ceph-mon" -a name | \
        grep ^name: | cut -d : -f 2 | sed 's/\s//g')

    # 2. move ceph nodes to crowbar_upgrade state
    crowbar_api_request POST $crowbar_api /utils/ceph_pre_upgrade/prepare.json

    # 3. upgrade ceph nodes
    for node in $ceph_nodes; do
        # Replace SP1 repos with the new ones
        ssh $node "rm /etc/zypp/repos.d/*
zypper ar -f http://$adminip:8091/suse-12.2/x86_64/install SLES12-SP2-12.2-0
zypper ar -f http://$adminip:8091/suse-12.2/x86_64/repos/SLES12-SP2-Updates SLES12-SP2-Updates
zypper ar -f http://$adminip:8091/suse-12.2/x86_64/repos/SLES12-SP2-Pool SLES12-SP2-Pool
zypper ar -f http://$adminip:8091/suse-12.2/x86_64/repos/SUSE-Enterprise-Storage-4-Pool SUSE-Enterprise-Storage-4-Pool
zypper ar -f http://$adminip:8091/suse-12.2/x86_64/repos/SUSE-Enterprise-Storage-4-Updates SUSE-Enterprise-Storage-4-Updates
zypper ref
zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks install ses-upgrade-helper"

        ssh $node "upgrade-ses.sh --non-interactive"
        ssh $node "reboot"
        wait_for 100 3 "! nc -w 1 -z $node 22" "node $node to go down"
        wait_for 200 3 "nc -w 1 -z $node 22" "node $node to be back online"
        # wait for HEALTH_OK or HEALTH_WARN status (WARN might be there because of require_jewel_osds not set yet)
        wait_for 50 5 "local health=\$(ssh $node ceph health); echo \"\$health\" | grep -E 'HEALTH_(OK|WARN)'" \
            "ceph cluster to recover after node upgrade" "exit 12" 'echo "$health"'
    done

    # update the ceph osd configuration to new defaults
    for node in $ceph_mons; do
        ssh $node "ceph osd crush tunables firefly; ceph osd set require_jewel_osds"
    done

    # wait for ceph cluster to recover after the upgrade
    nodes=($ceph_mons)
    wait_for 60 5 "ssh ${nodes[0]} ceph health | grep -q HEALTH_OK" "ceph cluster to recover after upgrade"
}

# This will adapt nodes repositories to the ones with next cloud version
function onadmin_prepare_cloudupgrade_nodes_repos
{
    export_tftpboot_dirs

    # change CLOUDISONAME/CLOUDISOURL according to the new cloudsource
    onadmin_set_source_variables

    # prepare installation repositories for nodes
    onadmin_prepare_sles_installmedia
    onadmin_prepare_sles_other_repos
    onadmin_prepare_sles12plus_cloud_repos

    if [[ $hacloud = 1 ]]; then
        add_ha_repo
    fi

    if [ -n "$deployceph" ]; then
        add_suse_storage_repo
    fi
}

# This will adapt admin server repositories to the ones needed by next product version
function onadmin_prepare_cloudupgrade_admin_repos
{
    export_tftpboot_dirs

    # change CLOUDISONAME/CLOUDISOURL according to the new cloudsource
    onadmin_set_source_variables

    # recreate the SUSE-Cloud Repo with the latest iso
    onadmin_prepare_cloud_repos

    # Pool repositories presence are required for nodes repocheck step during upgrade
    addcloudpool
    addcloudmaintupdates
    onadmin_add_cloud_repo

    # create skeleton for PTF repositories
    # during installation, this would be done by install-suse-cloud
    mkdir -p $tftpboot_repos_dir/PTF
    ensure_packages_installed createrepo
    createrepo-cloud-ptf || createrepo $tftpboot_repos_dir/PTF

    # remove old repositories
    # (so that zypper does not have an option to choose from the old ones)
    if iscloudver 7; then
        $zypper rr SLES12-SP1-Pool
        $zypper rr SLES12-SP1-Updates
    elif iscloudver 8; then
        $zypper rr SLES12-SP2-Pool
        $zypper rr SLES12-SP2-Updates
    fi

    onadmin_setup_local_zypper_repositories
    create_repos_yml
}

function onadmin_prepare_cloudupgrade
{
    # TODO: All running cloud instances should be suspended here

    ### Chef-client could lockj zypper and break upgrade
    # zypper locks do still happen
    # TODO: do we need to stop the client on the nodes too?
    rcchef-client stop

    wait_for_if_running chef-client

    # Update new repo paths
    export_tftpboot_dirs

    # Client nodes need to be up to date
    onadmin_cloudupgrade_clients

    # change CLOUDISONAME/CLOUDISOURL according to the new cloudsource
    onadmin_set_source_variables

    # recreate the SUSE-Cloud Repo with the latest iso
    onadmin_prepare_cloud_repos
    onadmin_add_cloud_repo

    # Applying the updater barclamp (in onadmin_cloudupgrade_clients) triggers
    # a chef-client run on the admin node (even it the barclamp is not applied
    # on the admin node, this is NOT a bug). Let's wait for that to finish
    # before trying to install anything.
    wait_for_if_running chef-client
    zypper_refresh -f
    ensure_packages_installed suse-cloud-upgrade
}

function onadmin_cloudupgrade_1st
{
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
    onadmin_zypper_update
    echo -n "This cloud was upgraded from : " | cat - /etc/cloudversion >> /etc/motd

    echo 'y' | suse-cloud-upgrade upgrade ||\
        complain $? "Upgrade failed with $?"
    crowbar_proposal_commit provisioner

    # Allow vendor changes for packages as we might be updating an official
    # Cloud release to something form the Devel:Cloud projects. Note: On the
    # client nodes this needs to happen after the updated provisioner
    # proposal is applied since crudini is not part of older Cloud releases.
    for node in $(get_all_discovered_nodes) ; do
        echo "Enabling VendorChange on $node"
        timeout 60 ssh $node "zypper --non-interactive --gpg-auto-import-keys --no-gpg-checks install crudini; crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true"
    done
}

function onadmin_zypper_update
{
    $zypper update --no-recommends --auto-agree-with-licenses
}

function onadmin_cloudupgrade_clients
{
    pre_hook $FUNCNAME
    # make sure the api is accessible
    onadmin_wait_for_crowbar_api
    # Upgrade Packages on the client nodes
    safely crowbar updater proposal create default
    safely crowbar updater proposal show default > updater.json
    safely json-edit updater.json -a attributes.updater.zypper.method -v "update"
    safely json-edit updater.json -a attributes.updater.zypper.licenses_agree --raw -v "true"
    safely crowbar updater proposal --file updater.json edit default
    crowbar_proposal_commit updater
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

    # TODO: restart any suspended instance?
}

function onadmin_reapply_openstack_proposals
{
    for barclamp in nfs_client pacemaker database rabbitmq keystone swift ceph glance cinder neutron nova horizon ceilometer heat trove tempest; do
        applied_proposals=$(crowbar "$barclamp" proposal list )
        if test "$applied_proposals" == "No current proposals"; then
            continue
        fi

        for proposal in $applied_proposals; do
            echo "Commiting proposal $proposal of barclamp ${barclamp}..."
            crowbar_proposal_commit "$barclamp" "$proposal"
        done
    done
}

function onadmin_upgrade_prechecks
{
    # always show the prechecks output in the build log
    crowbarctl upgrade prechecks

    if ! crowbarctl upgrade prechecks --format json | rubyjsonparse \
        "exit false if j.any? { |test| test['required'] && test['passed'] == false }"
    then
        complain 11 "Some necessary check before the upgrade has failed"
    fi
}

function onadmin_prepare_crowbar_upgrade
{
    safely crowbarctl upgrade prepare
    wait_for 300 5 "grep current_step $upgrade_progress_file | grep -v prepare" "prepare step to finish"
}

function onadmin_upgrade_admin_backup
{
    if ! safely crowbarctl upgrade backup crowbar ; then
        complain 11 "Creating the backup of admin server database has failed."
    fi
    if ! ls $crowbar_lib_dir/backup/*.gz > /dev/null ; then
        complain 11 "Crowbar backup is not present in $crowbar_lib_dir/backup."
    fi
}

function onadmin_upgrade_admin_repocheck
{
    if safely crowbarctl upgrade repocheck crowbar --format plain | grep "missing" ; then
        complain 11 "Some repository is missing on admin server. Cannot upgrade."
    fi
}

function onadmin_check_admin_server_upgraded
{
    if ! [ -e $crowbar_lib_dir/upgrade/admin-server-upgraded-ok ]; then
        complain 99 "$crowbar_lib_dir/upgrade/admin-server-upgraded-ok is missing"
    fi
}

function onadmin_upgrade_admin_server
{
    safely crowbarctl upgrade admin
}

function onadmin_crowbarbackup
{
    pre_hook $FUNCNAME
    local backupmode=$1
    local btarballname=backup-crowbar
    local btarball=${btarballname}.tar.gz
    rm -f /tmp/$btarball

    safely crowbarctl backup create $btarballname
    pushd /tmp
    # temporary workaround, as crowbarctl does not support to lookup by name yet
    local bid=`crowbarctl backup  list --plain | grep ${btarballname} | cut -d" " -f1`
    safely crowbarctl backup download $bid
    popd
    [[ -e /tmp/$btarball ]] || complain 12 "Backup tarball not created: /tmp/$btarball"
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
    $zypper in --auto-agree-with-licenses -t pattern cloud_admin

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
}


function onadmin_allow_vendor_change_at_nodes
{
    for machine in $(get_all_nodes); do
        ssh $machine "zypper -n in -y crudini; crudini --set /etc/zypp/zypp.conf main solver.allowVendorChange true"
    done
}

function crowbar_nodeupgrade_finished
{
    if ! ls /var/lib/crowbar/upgrade/*-upgrade-running > /dev/null 2>&1 ; then
        echo "'nodes' step finished successfuly"
        return 0
    fi

    if grep -q failed $upgrade_progress_file ; then
        echo "Something has failed during 'nodes' upgrade step."
        return 0
    fi
    return 1
}

function onadmin_crowbar_nodeupgrade
{
    if safely crowbarctl upgrade repocheck nodes --format plain | grep "missing" ; then
        crowbarctl upgrade repocheck nodes
        complain 11 "Some repository for the nodes is missing. Cannot continue with the upgrade."
    fi

    if [[ $want_nodesupgrade ]]; then
        get_novacontroller
        local upgrade_mode="normal"
        if safely crowbarctl upgrade mode | grep -q non_disruptive ; then
            upgrade_mode="non_disruptive"
        fi
        # suspend all active instances on disruptive upgrade
        if [[ "$upgrade_mode" == "normal" ]]; then
            safely oncontroller suspendallinstances
        fi
        safely crowbarctl upgrade services

        wait_for 300 5 "grep current_step $upgrade_progress_file | grep -v services" "services step to finish"

        if grep -q "failed" $upgrade_progress_file ; then
            crowbarctl upgrade status
            complain 12 "'Services' step has failed. Check the upgrade status."
        fi

        safely crowbarctl upgrade backup openstack
        wait_for 300 5 "grep current_step $upgrade_progress_file | grep -v backup_openstack" "backup openstack step to finish"

        safely crowbarctl upgrade nodes all
        wait_for 360 30 "crowbar_nodeupgrade_finished" "'nodes' upgrade step to finish" "complain 13 'Nodes step has failed. Check the upgrade status.'" "show_crowbar_nodes_to_upgrade"

        if grep -q "failed" $upgrade_progress_file ; then
            crowbarctl upgrade status
            complain 13 "'Nodes' step has failed. Check the upgrade status."
        fi
        # resume all suspended instances after disruptive upgrade
        if [[ "$upgrade_mode" == "normal" ]]; then
            safely oncontroller resumeallinstances
        fi
    fi
}

function onadmin_qa_test
{
    pre_hook $FUNCNAME
    $zypper in -y python-{keystone,nova,glance,heat,cinder,ceilometer}client

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
    pre_hook $FUNCNAME
    local ret=0
    if [[ $cct_tests ]]; then
        # - install cct dependencies
        add_sdk_repo
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
            if iscloudver 6; then
                checkout_branch=cloud6
            elif iscloudver 7; then
                checkout_branch=cloud7
            fi
        fi

        if [ "$skip_func_tests" == 0 ]; then
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
    ensure_packages_installed git-core make gcc ruby2.1-devel sqlite3-devel libxml2-devel libopenssl-devel postgresql-devel

    # create development folders
    mkdir -p /opt/crowbar/crowbar_framework/db /opt/crowbar/barclamps

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
    sudo -u crowbar RAILS_ENV=development bundle exec rake db:create db:migrate
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
            for node in ${unclustered_nodes[@]}; do
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

    sed -i "s/##hypervisor_ip##/$admingw/g" ${scenario}

    sed -i "s/##ironic_net_prefix##/$net_ironic/g" ${scenario}
    sed -i "s/##ironic_netmask##/$ironicnetmask/g" ${scenario}

    local exclude="--exclude manila"

    if [[ -z $deployswift ]]; then
        echo "Excluding any swift proposal from batch run"
        exclude="$exclude --exclude swift"
    fi

    if [[ -z $deployceph ]]; then
        echo "Excluding any ceph proposal from batch run"
        exclude="$exclude --exclude ceph"
    fi

    safely crowbar batch $exclude --timeout 2400 build ${scenario}
    if grep -q "barclamp: manila" ${scenario}; then
        get_novacontroller
        safely oncontroller manila_generic_driver_setup
        get_manila_service_instance_details
        sed -i "s/##manila_instance_name_or_id##/$manila_service_vm_uuid/g; \
                s/##service_net_name_or_ip##/$manila_tenant_vm_ip/g; \
                s/##tenant_net_name_or_ip##/$manila_tenant_vm_ip/g" \
                ${scenario}
        safely crowbar batch --include manila --timeout 2400 build ${scenario}
    fi
    return $?
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
    for service in horizon nova glance ceph swift keystone database; do
        crowbar "$service" proposal delete default
        crowbar "$service" delete default
    done

    local node
    for node in $(get_all_discovered_nodes); do
        safely crowbarctl node delete $node
    done
}

function onadmin_runlist
{
    for cmd in "$@" ; do
        local TIMEFORMAT="timing for qa_crowbarsetup function 'onadmin_$cmd' real=%R user=%U system=%S"
        time onadmin_$cmd || complain $? "$cmd failed with code $?"
    done
}

function add_node_to_network
{
    local node=$1
    local network=$2
    echo "Adding $node to $network"
    crowbarctl network hostip allocate default $node $network host
    if [[ $? > 0 ]]
    then
        return 1
    fi
    ssh $node chef-client
}

function retry
{
    $@
    if [[ $? > 0 ]]; then
        safely $@
    fi
}

function onadmin_external_ceph
{
    set -x
    local ceph_cluster=($@)
    local node
    local i=0
    local ip_alloc
    local ses_repo="http://$adminip:8091/suse-$suseversion/$arch/repos/SUSE-Enterprise-Storage-$sesversion"
    for node in ${ceph_cluster[@]}; do
        set_node_alias $node ceph$i
        let "i+=1"
        ssh $node zypper ar -f ${ses_repo}-Pool/ SUSE-Enterprise-Storage-$sesversion-Pool
        ssh $node zypper ar -f ${ses_repo}-Updates/ SUSE-Enterprise-Storage-$sesversion-Updates
        retry add_node_to_network $node storage
        if [ $want_separate_ceph_network -eq 1 ]; then
            retry add_node_to_network $node ceph
        else
            retry add_node_to_network $node public
        fi
    done
    if [ -z $net_storage ]; then
        setcloudnetvars $cloud
    fi
    echo "== Running SES deployment script =="
    if [[ $want_separate_ceph_network -eq 1 ]]; then
        safely ${SCRIPTS_DIR}/build_ses.sh ${net_ceph}.0/24 ${net_storage}.0/24 ${ceph_cluster[@]}
    else
        safely ${SCRIPTS_DIR}/build_ses.sh ${net_public}.0/24 ${net_storage}.0/24 ${ceph_cluster[@]}
    fi
}

#--

common_set_versions
export_tftpboot_dirs
set_proposalvars
set_noproxyvar
handle_service_dependencies || :
