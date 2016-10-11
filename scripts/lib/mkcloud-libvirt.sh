function libvirt_modprobe_kvm()
{
    if [[ $(uname -m) = x86_64 ]]; then
        modprobe kvm-amd
        if [ ! -e /etc/modprobe.d/80-kvm-intel.conf ] ; then
            echo "options kvm-intel nested=1" > /etc/modprobe.d/80-kvm-intel.conf
            rmmod kvm-intel
        fi
        modprobe kvm-intel
    fi
}

# return true if the patch was not yet applied
function workaround_bsc928384()
{
    # Allow cloud instances to get responses from dnsmasq
    # by preventing libvirt to tell it to bind only to the bridge interface
    # but bind to the IP-address instead.
    # This is patching a part of libvirt that was added for CVE-2012-3411
    # This change was needed after PR #290
    # For further details see https://bugzilla.suse.com/show_bug.cgi?id=928384
    grep -q -- --bind-dynamic /usr/lib*/libvirt.so.0 \
        && sed -i.orig -e 's/--bind-dynamic/--bindnotthere/g' /usr/lib*/libvirt.so.0
    return $?
}

# Returns success if the config was changed
function libvirt_configure_libvirtd()
{
    chkconfig libvirtd on

    local changed=

    # needed for HA/STONITH via libvirtd:
    confset /etc/libvirt/libvirtd.conf listen_tcp 1            && changed=y
    confset /etc/libvirt/libvirtd.conf listen_addr '"0.0.0.0"' && changed=y
    confset /etc/libvirt/libvirtd.conf auth_tcp '"none"'       && changed=y
    workaround_bsc928384 && changed=y

    [ -n "$changed" ]
}

function libvirt_start_daemon()
{
    if libvirt_configure_libvirtd; then # config was changed
        service libvirtd stop
    fi
    safely service libvirtd start
    wait_for 300 1 '[ -S /var/run/libvirt/libvirt-sock ]' 'libvirt startup'
}

function libvirt_net_start()
{
    virsh net-start $cloud-admin
    echo 1 > /proc/sys/net/ipv4/conf/$cloudbr/forwarding
    for dev in $cloudbr-nic $cloudbr ; do
        ip link set mtu 9000 dev $dev
    done

    onhost_setup_portforwarding
}

function libvirt_prepare()
{
    # libvirt
    libvirt_modprobe_kvm
    libvirt_start_daemon

    # network
    ${scripts_lib_dir}/libvirt/net-config $cloud $cloudbr $admingw $adminnetmask $cloudfqdn $adminip $forwardmode > /tmp/$cloud-admin.net.xml
    ${scripts_lib_dir}/libvirt/net-start /tmp/$cloud-admin.net.xml || exit $?
    libvirt_net_start
}

function libvirt_do_setupadmin()
{
    ${scripts_lib_dir}/libvirt/admin-config $cloud $admin_node_memory $adminvcpus $emulator $admin_node_disk "$localreposdir_src" "$localreposdir_target" > /tmp/$cloud-admin.xml
    ${scripts_lib_dir}/libvirt/vm-start /tmp/$cloud-admin.xml || exit $?
}

function libvirt_do_setuphost()
{
    if is_suse ; then
        export ZYPP_LOCK_TIMEOUT=60
        kvmpkg=kvm
        osloader=
        ipxe=
        [[ $arch = aarch64 ]] && {
            kvmpkg=qemu-arm
            osloader=qemu-uefi-aarch64
            ipxe=qemu-ipxe
        }
        [[ $arch = s390x ]] && kvmpkg=qemu-s390
        zypper --non-interactive in --no-recommends \
            libvirt $kvmpkg $osloader $ipxe lvm2 curl wget bridge-utils \
            dnsmasq netcat-openbsd ebtables libvirt-python
        [ "$?" == 0 -o "$?" == 4 ] || complain 10 "setuphost failed to install required packages"

        # enable KVM
        [[ $arch = s390x ]] && {
            echo 1 > /proc/sys/vm/allocate_pgste
        }
    fi

    sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    echo "net.ipv4.conf.all.rp_filter = 0" > /etc/sysctl.d/90-cloudrpfilter.conf
    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
    if [ -n "$needcvol" ] ; then
        safely pvcreate "$cloudpv"
        safely vgcreate "$cloudvg" "$cloudpv"
    fi

    # Start libvirtd and friends
    sudo service libvirtd status || sudo service libvirtd start
    if [[ -e /usr/lib/systemd/system/virtlogd.service ]] ; then
        sudo service virtlogd status || sudo service virtlogd start
    fi
}

function libvirt_do_sanity_checks()
{
    vgdisplay "$cloudvg" >/dev/null 2>&1 && needcvol=
    if [ -n "$needcvol" ] ; then
        : ${cloudpv:=/dev/vdb}
        if grep -q $cloudpv /proc/mounts ; then
            complain 92 "The device $cloudpv seems to be used. Exiting."
        fi
        if [ ! -e $cloudpv ] ; then
            complain 93 "$cloudpv does not exist." \
                "Please set the cloud volume group to an existing device: export cloudpv=/dev/sdx" \
                "Running 'partprobe' may help to let the device appear."
        fi
    fi
}

function libvirt_enable_ksm
{
    # enable kernel-samepage-merging to save RAM
    [[ -w /sys/kernel/mm/ksm/merge_across_nodes ]] && echo 0 > /sys/kernel/mm/ksm/merge_across_nodes
    [[ -w /sys/kernel/mm/ksm/run ]] && echo 1 > /sys/kernel/mm/ksm/run
    # Don't waste a complete CPU core on low-core count machines
    local ppcpu=64
    # aarch64 machines have high core count but low single-core performance
    [ $(uname -m) = aarch64 ] && ppcpu=4
    local pts=$(($(lscpu -p | grep -vc '^#')*$ppcpu))
    [[ -w /sys/kernel/mm/ksm/pages_to_scan ]] && echo $pts > /sys/kernel/mm/ksm/pages_to_scan

    # huge pages can not be shared or swapped, so do not use them
    [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]] && echo never > /sys/kernel/mm/transparent_hugepage/enabled
}

function libvirt_do_cleanup_admin_node()
{
    # this function is meant to only clean the admin node
    # in order to deploy a new one, while keeping all cloud nodes

    ${scripts_lib_dir}/libvirt/cleanup_one_node ${cloud}-admin
}

function libvirt_do_get_next_pv_device()
{
    if [ -z "$pvlist" ] ; then
        pvlist=`pvs --sort -Free | awk '$2~/'$cloudvg'/{print $1}'`
        pv_cur_device_no=0
    fi
    next_pv_device=`perl -e '$i=shift; $i=$i % @ARGV;  print $ARGV[$i]' $pv_cur_device_no $pvlist`
    pv_cur_device_no=$(( $pv_cur_device_no + 1 ))
}

# create lv device wrapper
function _lvcreate()
{
    lv_name=$1
    lv_size=$2
    lv_vg=$3
    lv_pv=$4

    # first: create on the PV device (spread IO)
    # fallback: create in VG (if PVs with different size exist)
    lvcreate -n $lv_name -L ${lv_size}G $lv_vg $lv_pv || \
        safely lvcreate -n $lv_name -L ${lv_size}G $lv_vg
}

# spread block devices over a LVM's PVs so that different VMs
# are likely to use different PVs to optimize concurrent IO throughput
function libvirt_do_create_cloud_lvm()
{
    safely vgchange -ay $cloudvg # for later boots

    local hdd_size

    onhost_get_next_pv_device
    _lvcreate $cloud.admin $adminnode_hdd_size $cloudvg $next_pv_device
    for i in $(nodes ids all) ; do
        onhost_get_next_pv_device
        hdd_size=${computenode_hdd_size}
        test "$i" = "1" && hdd_size=${controller_hdd_size}
        _lvcreate $cloud.node$i $hdd_size $cloudvg $next_pv_device
    done
    if [ $controller_raid_volumes -gt 1 ] ; then
        # total wipeout of the disks used for RAID, to prevent bsc#966685
        volume="/dev/$cloudvg/$cloud.node1"
        dd if=/dev/zero of=$volume bs=1M count=$(($controller_hdd_size * 1024))
        for n in $(seq 1 $(($controller_raid_volumes-1))) ; do
            onhost_get_next_pv_device
            hdd_size=${controller_hdd_size}
            _lvcreate $cloud.node1-raid$n $hdd_size $cloudvg $next_pv_device
            volume="/dev/$cloudvg/$cloud.node1-raid$n"
            dd if=/dev/zero of=$volume bs=1M count=$(($hdd_size * 1024))
        done
    fi

    if [ $cephvolumenumber -gt 0 ] ; then
        for i in $(nodes ids all) ; do
            for n in $(seq 1 $cephvolumenumber) ; do
                onhost_get_next_pv_device
                hdd_size=${cephvolume_hdd_size}
                test "$i" = "1" -a "$n" = "1" && hdd_size=${controller_ceph_hdd_size}
                _lvcreate $cloud.node$i-ceph$n $hdd_size $cloudvg $next_pv_device
            done
        done
    fi

    # create volumes for drbd
    if [ $drbd_hdd_size != 0 ] ; then
        for i in `seq 1 2`; do
            onhost_get_next_pv_device
            _lvcreate $cloud.node$i-drbd $drbd_hdd_size $cloudvg $next_pv_device
        done
    fi

    echo "Checking for LVs treated by LVM as valid PV devices ..."
    if [[ $SHAREDVG != 1 ]] && lvmdiskscan | egrep "/dev/($cloudvg/|mapper/$cloudvg-)"; then
        error=$(cat <<EOF
Error: your lvm.conf is not filtering out mkcloud LVs.
Please fix by adding the following regular expressions
to the filter value in the devices { } block within your
/etc/lvm/lvm.conf file (Be sure to place them before "a/.*/"):

    "r|/dev/mapper/$cloudvg-|", "r|/dev/$cloudvg/|", "r|/dev/disk/by-id/|"

The filter should also include something like "r|/dev/dm-|" or "r|/dev/dm-1[56]|", but
the exact values depend on your local system setup and could change
over time or have side-effects (on lvm in dm-crypt or lvm in lvm),
so please add/modify it manually.
EOF
)
        complain 94 "$error"
    fi
}

function libvirt_do_cleanup()
{
    # cleanup leftover from last run
    ${scripts_lib_dir}/libvirt/cleanup $cloud $nodenumber $cloudbr $vlan_public

    if ip link show ${cloudbr}.$vlan_public >/dev/null 2>&1; then
        ip link set ${cloudbr}.$vlan_public down
    fi
    if ip link show ${cloudbr} >/dev/null 2>&1; then
        ip link set ${cloudbr} down
        ip link delete ${cloudbr} type bridge
        ip link delete ${cloudbr}-nic
    fi
    # 1. remove leftover partition mappings that are still open for this cloud
    local vol
    dmsetup ls | awk "/^$cloudvg-${cloud}\./ {print \$1}" | while read vol ; do
        kpartx -dsv /dev/mapper/$vol
    done

    # workaround host grabbing guest devices
    for vol in postgresql rabbitmq ; do
        dmsetup remove drbd-$vol
    done
    # 2. remove all previous volumes for that cloud; this helps preventing
    # accidental booting and freeing space
    if [ -d $vdisk_dir ]; then
        find -L $vdisk_dir -name "$cloud.*" -type b | \
            xargs --no-run-if-empty lvremove --force || complain 104 "lvremove failure"
    fi
    rm -f /etc/lvm/archive/*

    if [[ $wipe = 1 ]] ; then
        vgchange -an $cloudvg
        dd if=/dev/zero of=$cloudpv count=1000
    fi
    return 0
}

function libvirt_do_prepare()
{
    libvirt_enable_ksm
    libvirt_do_create_cloud_lvm
    onhost_add_etchosts_entries
    libvirt_prepare
    onhost_prepareadmin
}

function libvirt_do_onhost_deploy_image()
{
    local role=$1
    local image=$(dist_to_image_name $2)
    local disk=$3

    [[ $clouddata ]] || complain 108 "clouddata IP not set - is DNS broken?"
    pushd /tmp
    local wgetcachemode=-N
    [[ $want_cached_images = 1 ]] && wgetcachemode=-nc
    safely wget --progress=dot:mega $wgetcachemode \
        http://$clouddata/images/$arch/$image

    echo "Cloning $role node vdisk from $image ..."
    safely qemu-img convert -t none -O raw -S 0 -p $image $disk
    popd

    # resize the last partition only if it has id 83
    local last_part=$(fdisk -l $disk | grep -c "^$disk")
    if fdisk -l $disk | grep -q "$last_part *\* *.*83 *Linux" ; then
        echo -e "d\n$last_part\nn\np\n$last_part\n\n\na\n$last_part\nw" | fdisk $disk
        local part=$(kpartx -asv $disk|perl -ne 'm/add map (\S+'"$last_part"') / && print $1')
        test -n "$part" || complain 31 "failed to find partition #$last_part"
        local bdev=/dev/mapper/$part
        safely fsck -y -f $bdev
        safely resize2fs $bdev
        time udevadm settle
        sleep 1 # time for dev to become unused
        safely kpartx -dsv $disk
    fi
}

function libvirt_do_setuplonelynodes()
{
    local i
    for i in $(nodes ids lonely) ; do
        local mac=$(macfunc $i)
        local lonely_node
        lonely_node=$cloud-node$i
        safely ${scripts_lib_dir}/libvirt/compute-config $cloud $i $mac 0\
            "$cephvolumenumber" "$drbdvolume" $compute_node_memory\
            $controller_node_memory $libvirt_type $vcpus $emulator $vdisk_dir\
            1 1 > /tmp/$cloud-node$i.xml

        local lonely_disk
        lonely_disk="$vdisk_dir/${cloud}.node$i"

        onhost_deploy_image "lonely" $(get_lonely_node_dist) $lonely_disk
        ${scripts_lib_dir}/libvirt/vm-start /tmp/${lonely_node}.xml
    done
}

function libvirt_do_shutdowncloud()
{
    virsh shutdown $cloud-admin
    for i in $(nodes ids all) ; do
        virsh shutdown $cloud-node$i
    done
}

function libvirt_do_macfunc
{
    printf "$macprefix:77:77:%02x" $1
}
