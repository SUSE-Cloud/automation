#! /bin/bash
#
# Prepare a host for Crowbar admin node installation.  This takes care
# of making the required repositories available, and performs a few
# other tweaks.
#
# Either scp this script to the host and run it from there, or simply
# take the nuclear detonation approach and pipe it directly to a remote
# bash process:
#
#     cat crowbar-prep.sh | ssh root@$admin_node bash -s -- -d $profile

me=`basename $0`
[ "$me" = bash ] && me=crowbar-prep.sh

# These have to be set prior to parse_opts() since usage()
# depends on them being set.
: ${CLOUD_VERSION_DEFAULT:=4}
: ${HOST_MIRROR_DEFAULT:=/data/install/mirrors}
: ${HOST_MEDIA_MIRROR_DEFAULT=/srv/nfs/media}

# This is run after parse_opts(); see main() for details.
init_variables () {
    : ${CLOUD_VERSION:=$CLOUD_VERSION_DEFAULT}
    set_cloud_version_variables

    : ${ADMIN_IP:=192.168.124.10}
    : ${HOST_IP:=192.168.124.1}

    : ${HOST_MIRROR:=$HOST_MIRROR_DEFAULT}
    : ${HOST_MEDIA_MIRROR:=$HOST_MEDIA_MIRROR_DEFAULT}

    # Product ISO filenames
    : ${SP3_ISO:=SLES-11-SP3-DVD-x86_64-current.iso}
    : ${HAE_ISO:=SLE-HA-11-SP3-DVD-x86_64-current.iso}

    # Subdirectory under $HOST_MEDIA_MIRROR on the VM host which is
    # an NFS export containing the mounted SP3 media.
    : ${SP3_MEDIA_EXPORT_SUBDIR:=sles-11-sp3}

    # Subdirectories under $HOST_MIRROR on the VM host which are
    # NFS exports containing repos
    : ${CLOUD_UPDATES_EXPORT_SUBDIR:=SUSE-Cloud-${CLOUD_CHANNEL_VERSION}-Updates}
    : ${DC_EXPORT_SUBDIR:=Devel:Cloud:$CLOUD_VERSION}
    : ${DC_STAGING_EXPORT_SUBDIR:=${DC_EXPORT_SUBDIR}:Staging}
    : ${DC_SHARED_EXPORT_SUBDIR:=Devel:Cloud:Shared:11-SP3}
    : ${DC_SHARED_UPDATE_EXPORT_SUBDIR:=Devel:Cloud:Shared:11-SP3:Update}

    # Mountpoints within the Crowbar admin node which are required
    # when configuring / running the product (for serving repos via
    # HTTP for autoyast)
    SP3_MOUNTPOINT=/srv/tftpboot/suse-11.3/install
    REPOS_DIR=/srv/tftpboot/repos
    POOL_MOUNTPOINT=$REPOS_DIR/SLES11-SP3-Pool
    SP3_UPDATES_MOUNTPOINT=$REPOS_DIR/SLES11-SP3-Updates
    HAE_POOL_MOUNTPOINT=$REPOS_DIR/SLE11-HAE-SP3-Pool
    HAE_UPDATES_MOUNTPOINT=$REPOS_DIR/SLE11-HAE-SP3-Updates
    CLOUD_MOUNTPOINT=$REPOS_DIR/Cloud
    CLOUD_UPDATES_MOUNTPOINT=$REPOS_DIR/SUSE-Cloud-${CLOUD_VERSION}-Updates
    # Added for SUSE Cloud 5 SLE12
    SLES12_MOUNTPOINT=/srv/tftpboot/suse-12.0/install
    SLES12_POOL=$REPOS_DIR/SLES12-Pool
    SLES12_UPDATES=$REPOS_DIR/SLES12-Updates
    SLE12_SC5_COMPUTE=$REPOS_DIR/SLE12-Cloud-Compute

    # Mountpoints within the Crowbar admin node which are not required
    # by the product, but which are used for accessing local mirrors
    # of repositories providing packages which need to be initially
    # installed on the admin node.
    : ${DC_MOUNTPOINT:=$REPOS_DIR/Devel:Cloud:$CLOUD_VERSION}
    : ${DC_STAGING_MOUNTPOINT:=${DC_MOUNTPOINT}:Staging}
    : ${DC_SHARED_MOUNTPOINT:=$REPOS_DIR/$DC_SHARED_EXPORT_SUBDIR}
    : ${DC_SHARED_UPDATE_MOUNTPOINT:=$REPOS_DIR/$DC_SHARED_UPDATE_EXPORT_SUBDIR}

    # Names of zypper repos within the Crowbar admin node.
    sp3_repo=SLES-11-SP3
    sp3_updates_repo=${sp3_repo}-Updates
    hae_repo=SLE11-HAE-SP3-Pool
    hae_updates_repo=SLE11-HAE-SP3-Updates
    cloud_repo=SUSE-Cloud-$CLOUD_VERSION
    cloud_updates_repo=${cloud_repo}-Updates
    dc_repo=Devel_Cloud_$CLOUD_VERSION
    dc_staging_repo=${dc_repo}_Staging
    dc_shared_repo=Devel_Cloud_Shared_11-SP3
    dc_shared_update_repo=${dc_shared_repo}_Update
}

# This needs to be run both prior to parsing options (so that the
# usage text can refer to the ISO filename), and after (so that
# --product-version affects it correctly).
set_cloud_version_variables () {
    case $CLOUD_VERSION in
        1.0|2.0|3|4|5)
            # valid
            ;;
        *)
            die "Unsupported Cloud version $CLOUD_VERSION!"
            ;;
    esac

    case $CLOUD_VERSION in
        1.0|2.0)
            CLOUD_ISO_VERSION=${CLOUD_ISO_VERSION%.0}
            ;;
        *)
            CLOUD_ISO_VERSION=$CLOUD_VERSION
            ;;
    esac

    case $CLOUD_VERSION in
        3)
            CLOUD_CHANNEL_VERSION=3.0
            ;;
        *)
            CLOUD_CHANNEL_VERSION=$CLOUD_VERSION
            ;;
    esac

    CLOUD_ISO=SUSE-CLOUD-${CLOUD_ISO_VERSION}-x86_64-current.iso
}

fatal () {
    echo "$*" >&2
    exit 1
}

safe_run () {
    if ! "$@"; then
        fatal "$* failed! Aborting." >&2
    fi
}

usage () {
    # Call as: usage [EXITCODE] [USAGE MESSAGE]
    exit_code=1
    if [[ "$1" == [0-9] ]]; then
        exit_code="$1"
        shift
    fi
    if [ -n "$1" ]; then
        echo >&2 "$*"
        echo >&2
    fi

    cat <<EOF >&2
Usage: cat $me | ssh root@ADMIN-NODE bash -s -- [OPTIONS] PROFILE

Profiles:
    nue-host-nfs
        This profile is a hybrid of 'nue-nfs' and 'host-nfs' and is
        probably the best trade-off between convenience and
        flexibility if you are situated in the Nuremberg offices.  It
        takes SLES repos from clouddata, and the SUSE Cloud ISO from
        the VM host ($HOST_IP) via NFS.  This allows you to choose
        which SUSE Cloud build to develop/test against, but eliminates
        the hassle of mirroring SLES repositories.

    nue-nfs
        Mount from clouddata.cloud.suse.de.  This is a no-brainer
        setup which sacrifices flexibility for ease of setup.
        Probably only makes sense if you are within the .nue offices.
        The disadvantage is that you get no choice over which
        SUSE Cloud ISO is used - you just get whatever clouddata
        happens to be serving, and it could change beneath your feet
        without warning :)

    host-nfs
        Mount everything from VM host ($HOST_IP) via NFS (export
        HOST_IP before running if you want to change this IP).  Best
        suited for remote workers and control freaks ;-P  Use this one
        in conjunction with the sync-repos mirroring tool available
        from:

          https://github.com/SUSE/cloud/blob/master/dev-setup/sync-repos

        which by default mirrors to $HOST_MIRROR_DEFAULT, and this
        profile assumes that directory will be NFS-exported to the
        guest (use --nfs-mirror or export HOST_MIRROR to override
        this).  It also assumes that the VM host mounts the SP3 and
        SUSE Cloud installation sources at
        $HOST_MEDIA_MIRROR/$SP3_MEDIA_EXPORT_SUBDIR and
        $HOST_MEDIA_MIRROR/suse-cloud-$CLOUD_VERSION respectively and
        NFS exports both to the guest.

    host-9p
        Similar to 'host-nfs' but mounts from VM host as virtio
        passthrough filesystem.  Assumes that the 9p filesystem is
        exported with the target named 'install', and includes the
        following directories and files (create the .isos as symlinks
        to the real .iso files):

            isos/$SP3_ISO
            isos/$HAE_ISO
            isos/$CLOUD_ISO
            mirrors/SLES11-SP3-Pool/sle-11-x86_64/repodata/repomd.xml
            mirrors/SLES11-SP3-Updates/sle-11-x86_64/repodata/repomd.xml

        Surprisingly, this seems to perform a bit slower than the NFS
        approach.

Also adds an entry to /etc/hosts for $ADMIN_IP; export a new value for
ADMIN_IP to override this.

Options:
  -p, --product-version      Set SUSE Cloud product version [$CLOUD_VERSION_DEFAULT]
  -d, --devel-cloud          zypper addrepo Devel:Cloud:\$version
  -s, --devel-cloud-staging  zypper addrepo Devel:Cloud:\$version:Staging
  -l, --devel-cloud-mirrors  Get Devel:Cloud:* repos from same local mirror
                             as SP3-Pool / SP3-Updates instead of directly from IBS
                             (only with host-nfs profile)
  -n, --nfs-mirror PATH      Set path on host under which repos are NFS-exported
                             [$HOST_MIRROR_DEFAULT]
  -m, --media-mirror PATH    Set path on host under which the SP3 and Cloud media
                             are mounted and NFS exported [$HOST_MEDIA_MIRROR_DEFAULT]
  -h, --help                 Show this help and exit
EOF
    exit "$exit_code"
}

die () {
    echo >&2 "$*"
    exit 1
}

setup_etc_hosts () {
    if ! long_hostname="`cat /etc/HOSTNAME`"; then
        die "Failed to determine hostname"
    fi
    short_hostname="${long_hostname%%.*}"
    if [ "$short_hostname" = "$long_hostname" ]; then
        die "Failed to determine FQDN for hostname ($short_hostname)"
    fi

    if grep -q "^$ADMIN_IP " /etc/hosts; then
        echo "WARNING: Removing $ADMIN_IP entry already in /etc/hosts:" >&2
        grep "^$ADMIN_IP " /etc/hosts >&2 | sed 's/^/  /'
        safe_run sed -i -e "/^$ADMIN_IP /d" /etc/hosts
    fi

    echo "$ADMIN_IP   $long_hostname $short_hostname" >> /etc/hosts
}

common_pre () {
    setup_etc_hosts
    prep_mountpoints
}

prep_mountpoints () {
    mountpoints=(
        $SP3_MOUNTPOINT $POOL_MOUNTPOINT $SP3_UPDATES_MOUNTPOINT
        $HAE_POOL_MOUNTPOINT $HAE_UPDATES_MOUNTPOINT
        $CLOUD_MOUNTPOINT
    )

    if [ "$CLOUD_VERSION" == "5" ]; then
        mountpoints+=(
            $SLES12_MOUNTPOINT $SLES12_POOL $SLES12_UPDATES
            $SLE12_SC5_COMPUTE $SLE12_SC5_COMPUTE
        )
    else
        mountpoints+=($CLOUD_UPDATES_MOUNTPOINT)
    fi
    if [ -n "$ibs_mirror" ]; then
        mountpoints+=($DC_MOUNTPOINT $DC_SHARED_MOUNTPOINT $DC_SHARED_UPDATE_MOUNTPOINT)
        if [ "$ibs_repo" = staging ]; then
            mountpoints+=($DC_STAGING_MOUNTPOINT)
        fi
    fi

    safe_run mkdir -p "${mountpoints[@]}"
}

is_mounted () {
    safe_run mount | grep -q " on $1 "
}

ensure_mount () {
    mountpoint="$1"
    if mount $mountpoint; then
        echo "mounted $mountpoint"
    else
        die "Couldn't mount $mountpoint"
    fi
}

use_hae () {
    case $CLOUD_VERSION in
        1.0|2.0)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

zypper_addrepo () {
    safe_run zypper --gpg-auto-import-keys ar "$@"
}

zypper_set_priority () {
    prio="$1" repo="$2"
    safe_run zypper mr -p "$prio" "$repo"
}

devel_cloud_shared_sp3_repo () {
    case $CLOUD_VERSION in
        2|3|4)
            if [ -z "$local_devel_cloud_repos" ]; then
                url=http://download.suse.de/ibs/Devel:/Cloud:/Shared:/11-SP3/standard/
            else
                url=file://$DC_SHARED_MOUNTPOINT
            fi
            zypper_addrepo $url $dc_shared_repo
            zypper_set_priority 90 $dc_shared_repo
            ;;
    esac
}

devel_cloud_shared_sp3_update_repo () {
    case $CLOUD_VERSION in
        3|4)
            if [ -z "$local_devel_cloud_repos" ]; then
                url=http://download.suse.de/ibs/Devel:/Cloud:/Shared:/11-SP3:/Update/standard/
            else
                url=file://$DC_SHARED_UPDATE_MOUNTPOINT
            fi
            zypper_addrepo $url $dc_shared_update_repo
            zypper_set_priority 90 $dc_shared_update_repo
            ;;
    esac
}

devel_cloud_repo () {
    if [ -z "$local_devel_cloud_repos" ]; then
        url=http://download.suse.de/ibs/Devel:/Cloud:/${CLOUD_VERSION}/SLE_11_SP3/
    else
        url=file://$DC_MOUNTPOINT
    fi
    zypper_addrepo $url $dc_repo
    zypper_set_priority 80 $dc_repo
}

devel_cloud_staging_repo () {
    if [ -z "$local_devel_cloud_repos" ]; then
        url=http://download.suse.de/ibs/Devel:/Cloud:/${CLOUD_VERSION}:/Staging/SLE_11_SP3/
    else
        url=file://$DC_STAGING_MOUNTPOINT
    fi
    zypper_addrepo $url $dc_staging_repo
    zypper_set_priority 70 $dc_staging_repo
}

mount_all_mounts () {
    if [ -n "$mountpoint_9p" ]; then
        is_mounted $mountpoint_9p || ensure_mount $mountpoint_9p
    else
        echo "Not using 9p"
    fi

    got_hae=yep
    for mountpoint in "${mountpoints[@]}"; do
        echo
        if is_mounted $mountpoint; then
            echo "$mountpoint already mounted; umounting ..."
            umount $mountpoint || die "Couldn't umount $mountpoint"
        fi
        case $mountpoint in
            $HAE_POOL_MOUNTPOINT|$HAE_UPDATES_MOUNTPOINT)
                if use_hae && ! mount $mountpoint; then
                    echo -e "WARNING: Couldn't mount $mountpoint; you will have to mount manually if you want cluster support.\n" >&2
                    got_hae=
                fi
                ;;
            *)
                ensure_mount $mountpoint
                ;;
        esac
    done
}

setup_zypper_repos () {
    repos=(
        $sp3_repo $sp3_updates_repo
        $hae_repo $hae_updates_repo
        $cloud_repo $cloud_updates_repo
        $dc_repo $dc_staging_repo
        $dc_shared_repo $dc_shared_update_repo
    )

    for repo in "${repos[@]}"; do
        if zypper lr | grep -q $repo; then
            echo "WARNING: Removing pre-existing $repo repository:" >&2
            safe_run zypper rr $repo
            echo
        fi
    done

    zypper_addrepo file://$SP3_MOUNTPOINT           $sp3_repo
    zypper_addrepo file://$SP3_UPDATES_MOUNTPOINT   $sp3_updates_repo
    zypper_addrepo file://$CLOUD_MOUNTPOINT         $cloud_repo
    if ! [ "$CLOUD_VERSION" == "5" ]; then
        zypper_addrepo file://$CLOUD_UPDATES_MOUNTPOINT $cloud_updates_repo
    fi

    case "$ibs_repo" in
        yes)
            devel_cloud_shared_sp3_repo
            devel_cloud_shared_sp3_update_repo
            devel_cloud_repo
            ;;
        staging)
            devel_cloud_shared_sp3_repo
            devel_cloud_shared_sp3_update_repo
            devel_cloud_repo
            devel_cloud_staging_repo
            ;;
        '')
            ;;
        *)
            die "BUG: unrecognised \$ibs_repo value '$ibs_repo'"
            ;;
    esac
}

common_post () {
    mount_all_mounts

    pattern=cloud_admin
    if zypper -n patterns -i | grep -q $pattern; then
        pattern_already_installed=yes
    fi

    setup_zypper_repos

    # Display this warning after the zypper stuff to make it easier to
    # spot in the terminal output.
    if [ -n "$pattern_already_installed" ]; then
        echo >&2 "WARNING: $pattern pattern already installed!"
        echo >&2 "You will probably need to upgrade existing packages."
        echo >&2
    fi

    if [ -n "$set_sledgehammer_passwd" ]; then
        sledgehammer_passwd_hook
    fi

    cat <<EOF
Now run the following steps in the admin node.  If it is a VM, it is
probably a good idea to snapshot[1] the VM before at least one of the
steps, if not both.

  zypper -n --gpg-auto-import-keys in -l -t pattern $pattern
  screen -L install-suse-cloud

[1] e.g.: virsh snapshot-create-as pebbles-sp3-admin pre-pattern-install
EOF
    if use_hae && [ -z "$got_hae" ]; then
        cat <<'EOF'

WARNING: HAE repo is not set up!  See above for what went wrong.
EOF
    fi
}

append_to_fstab () {
    perl -0777pi -e \
        "s/\n+# Auto-generated by $me.*\n(.*\n)*^# End auto-generated section from $me//m" \
        /etc/fstab

    (
        echo
        echo "# Auto-generated by $me at `date`"
        # Nicely align columns
        cat | column -t
        echo "# End auto-generated section from $me"
    ) >>/etc/fstab
}

nfs_mount () {
    src="$1" dst="$2" read_mode="${3:-ro}"
    echo "$src $dst nfs ${read_mode},rsize=8192,wsize=8192,intr,nolock 0 0"
}

9p_mount () {
    mkdir -p $mountpoint_9p
    echo "install $mountpoint_9p 9p ro,trans=virtio,version=9p2000.L 0 0"
}

iso_mount () {
    src="$1" dst="$2"
    echo "$src $dst iso9660 defaults 0 0"
}

bind_mount () {
    src="$1" dst="$2"
    echo "$src $dst none bind,ro 0 0"
}

# loki_nfs () {
#     loki=loki.suse.de:/vol/euklid/SuSE/zypp-patches.suse.de/x86_64/update/SLE-SERVER
#     nfs_mount $loki/11-SP3-POOL $POOL_MOUNTPOINT
#     nfs_mount $loki/11-SP3      $SP3_UPDATES_MOUNTPOINT
# }

clouddata_sle_repos () {
    repos=clouddata.cloud.suse.de:/srv/nfs/repos
    nfs_mount $repos/SLES11-SP3-Pool       $POOL_MOUNTPOINT
    nfs_mount $repos/SLES11-SP3-Updates    $SP3_UPDATES_MOUNTPOINT
    nfs_mount $repos/SLE11-HAE-SP3-Pool    $HAE_POOL_MOUNTPOINT
    nfs_mount $repos/SLE11-HAE-SP3-Updates $HAE_UPDATES_MOUNTPOINT
    nfs_mount $repos/SLES12-Pool           $SLES12_POOL
    nfs_mount $repos/SLES12-Updates        $SLES12_UPDATES
    nfs_mount $repos/SLE12-Cloud-Compute   $SLE12_SC5_COMPUTE
}

clouddata_sp3_repo () {
    nfs_mount clouddata.cloud.suse.de:/srv/nfs/suse-11.3/install  $SP3_MOUNTPOINT
    if [ "$CLOUD_VERSION" == "5" ]; then
        nfs_mount clouddata.cloud.suse.de:/srv/nfs/suse-12.0/install  $SLES12_MOUNTPOINT
    fi
}

nue_host_nfs () {
    (
        media_mirrors=$HOST_IP:$HOST_MEDIA_MIRROR
        nfs_mount $media_mirrors/suse-cloud-$CLOUD_VERSION $CLOUD_MOUNTPOINT
        clouddata_sp3_repo
        clouddata_sle_repos
    ) | append_to_fstab
}

nue_nfs () {
    (
        nfs_mount clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-$CLOUD_VERSION-devel $CLOUD_MOUNTPOINT
        if ! [ "$CLOUD_VERSION" == "5" ]; then
            nfs_mount clouddata.cloud.suse.de:/srv/nfs/repos/SUSE-Cloud-$CLOUD_VERSION-Updates $CLOUD_UPDATES_MOUNTPOINT
        fi
        clouddata_sp3_repo
        clouddata_sle_repos
    ) | append_to_fstab
}

host_nfs () {
    (
        media_mirrors=$HOST_IP:$HOST_MEDIA_MIRROR
        repo_mirrors=$HOST_IP:$HOST_MIRROR

        nfs_mount $media_mirrors/$SP3_MEDIA_EXPORT_SUBDIR  $SP3_MOUNTPOINT
        nfs_mount $repo_mirrors/SLES11-SP3-Pool/sle-11-x86_64       $POOL_MOUNTPOINT
        nfs_mount $repo_mirrors/SLES11-SP3-Updates/sle-11-x86_64    $SP3_UPDATES_MOUNTPOINT

        nfs_mount $repo_mirrors/SLE11-HAE-SP3-Pool/sle-11-x86_64    $HAE_POOL_MOUNTPOINT
        nfs_mount $repo_mirrors/SLE11-HAE-SP3-Updates/sle-11-x86_64 $HAE_UPDATES_MOUNTPOINT

        nfs_mount $media_mirrors/suse-cloud-$CLOUD_VERSION          $CLOUD_MOUNTPOINT
        nfs_mount $repo_mirrors/$CLOUD_UPDATES_EXPORT_SUBDIR/sle-11-x86_64 \
                                                                    $CLOUD_UPDATES_MOUNTPOINT

        if [ -n "$ibs_mirror" ]; then
            nfs_mount $repo_mirrors/$DC_EXPORT_SUBDIR/sle-11-x86_64         $DC_MOUNTPOINT
            nfs_mount $repo_mirrors/$DC_SHARED_EXPORT_SUBDIR/sle-11-x86_64  $DC_SHARED_MOUNTPOINT
            nfs_mount $repo_mirrors/$DC_SHARED_UPDATE_EXPORT_SUBDIR/sle-11-x86_64 \
                                                                            $DC_SHARED_UPDATE_MOUNTPOINT
            nfs_mount $repo_mirrors/$DC_STAGING_EXPORT_SUBDIR/sle-11-x86_64 $DC_STAGING_MOUNTPOINT
        fi
    ) | append_to_fstab
}

host_9p () {
    mountpoint_9p=/mnt/9p
    (
        9p_mount
        repo_mirrors=$mountpoint_9p/mirrors

        iso_mount  $mountpoint_9p/isos/$SP3_ISO   $SP3_MOUNTPOINT
        bind_mount $repo_mirrors/SLES11-SP3-Pool/sle-11-x86_64       $POOL_MOUNTPOINT
        bind_mount $repo_mirrors/SLES11-SP3-Updates/sle-11-x86_64    $SP3_UPDATES_MOUNTPOINT

        bind_mount $repo_mirrors/SLE11-HAE-SP3-Pool/sle-11-x86_64    $HAE_POOL_MOUNTPOINT
        bind_mount $repo_mirrors/SLE11-HAE-SP3-Updates/sle-11-x86_64 $HAE_UPDATES_MOUNTPOINT

        iso_mount  $mountpoint_9p/isos/$CLOUD_ISO                    $CLOUD_MOUNTPOINT
        bind_mount $repo_mirrors/$CLOUD_UPDATES_EXPORT_SUBDIR/sle-11-x86_64 \
                $CLOUD_UPDATES_MOUNTPOINT

        if [ -n "$ibs_mirror" ]; then
            bind_mount $repo_mirrors/$DC_EXPORT_SUBDIR/sle-11-x86_64         $DC_MOUNTPOINT
            bind_mount $repo_mirrors/$DC_SHARED_EXPORT_SUBDIR/sle-11-x86_64  $DC_SHARED_MOUNTPOINT
            bind_mount $repo_mirrors/$DC_SHARED_UPDATE_EXPORT_SUBDIR/sle-11-x86_64 \
                    $DC_SHARED_UPDATE_MOUNTPOINT
            bind_mount $repo_mirrors/$DC_STAGING_EXPORT_SUBDIR/sle-11-x86_64 $DC_STAGING_MOUNTPOINT
        fi
    ) | append_to_fstab
}

sledgehammer_passwd_hook () {
    mkdir -p /updates/discovering-pre
    hook=/updates/discovering-pre/setpw.hook
    cat >$hook <<EOF
#!/bin/sh
echo "linux" | passwd --stdin root
EOF
    chmod +x $hook
    cat <<EOF

Sledgehammer root password will be set to "linux" to
aid debugging.
EOF
}

parse_opts () {
    ibs_repo=
    set_sledgehammer_passwd=
    local_devel_cloud_repos=

    while [ $# != 0 ]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -p|--product-version)
                CLOUD_VERSION="$2"
                set_cloud_version_variables
                shift 2
                ;;
            -d|--devel-cloud)
                [ -n "$ibs_repo" ] && die "Cannot add multiple IBS repos"
                ibs_repo=yes
                shift
                ;;
            -s|--devel-cloud-staging)
                [ -n "$ibs_repo" ] && die "Cannot add multiple IBS repos"
                ibs_repo=staging
                shift
                ;;
            -l|--local-devel-cloud-repos)
                local_devel_cloud_repos=y
                shift
                ;;
            -r|--sledgehammer-root-pw)
                set_sledgehammer_passwd=y
                shift
                ;;
            -n|--nfs-mirror)
                [ -n "$2" ] || die "--nfs-mirror requires an argument"
                HOST_MIRROR="$2"
                shift 2
                ;;
            -m|--media-mirror)
                [ -n "$2" ] || die "--media-mirror requires an argument"
                HOST_MEDIA_MIRROR="$2"
                shift 2
                ;;
            -*)
                usage "Unrecognised option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# != 1 ]; then
        usage
    fi

    profile="$1"

    ibs_mirror=
    if [ -n "$local_devel_cloud_repos" ]; then
        if [ -z "$ibs_repo" ]; then
            usage "-l is only valid with -d or -s"
        fi

        case "$profile" in
            host-nfs|host-9p)
                ;;
            *)
                usage "-l is only valid with the host-nfs or host-9p profile"
                ;;
        esac
        ibs_mirror=y
    fi
}

main () {
    # Have to invoke parse_opts before init_variables so that
    # $CLOUD_VERSION is correctly propagated when it's specified
    # on the command line (otherwise it's always '3').
    parse_opts "$@"
    init_variables

    case "$profile" in
        nue-nfs|nue-host-nfs|host-nfs|host-9p)
            action="${profile//-/_}"
            ;;
        *)
            usage
            ;;
    esac

    common_pre
    $action
    common_post
}

main "$@"
