function libvirt_modprobe_kvm()
{
    if [[ $(uname -m) = x86_64 ]]; then
        $sudo modprobe kvm-amd
        if [ ! -e /etc/modprobe.d/80-kvm-intel.conf ] ; then
            echo "options kvm-intel nested=1" | $sudo dd of=/etc/modprobe.d/80-kvm-intel.conf
            $sudo rmmod kvm-intel
        fi
        $sudo modprobe kvm-intel
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
        && $sudo sed -i.orig -e 's/--bind-dynamic/--bindnotthere/g' /usr/lib*/libvirt.so.0
    return $?
}

# Returns success if the config was changed
function libvirt_configure_libvirtd()
{
    $sudo chkconfig libvirtd on

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
        $sudo service libvirtd stop
    fi
    safely $sudo service libvirtd start
    wait_for 300 1 '[ -S /var/run/libvirt/libvirt-sock ]' 'libvirt startup'
}

function libvirt_net_start()
{
    $sudo virsh net-start $cloud-admin
    $sudo sysctl -e net.ipv4.conf.$cloudbr.forwarding=1
    for dev in $cloudbr-nic $cloudbr ; do
        $sudo ip link set mtu 9000 dev $dev
    done

    if [[ $want_ironic ]]; then
        $sudo virsh net-start $cloud-ironic
        $sudo sysctl -e net.ipv4.conf.$ironicbr.forwarding=1
    fi

    onhost_setup_portforwarding
}

function libvirt_prepare()
{
    # libvirt
    libvirt_modprobe_kvm
    libvirt_start_daemon

    # admin network
    ${scripts_lib_dir}/libvirt/net-config 'admin' $cloud $cloudbr $admingw $adminnetmask $forwardmode $cloudfqdn $adminip > /tmp/$cloud-admin.net.xml
    $sudo ${scripts_lib_dir}/libvirt/net-start /tmp/$cloud-admin.net.xml || exit $?
    # ironic network
    if [[ $want_ironic ]]; then
        ${scripts_lib_dir}/libvirt/net-config 'ironic' $cloud $ironicbr $ironicgw $ironicnetmask $forwardmode > /tmp/$cloud-ironic.net.xml
        $sudo ${scripts_lib_dir}/libvirt/net-start /tmp/$cloud-ironic.net.xml || exit $?
    fi
    libvirt_net_start
}

function libvirt_do_setupadmin()
{
    ${scripts_lib_dir}/libvirt/admin-config $cloud $admin_node_memory $adminvcpus $(get_emulator) $admin_node_disk "$localreposdir_src" "$localreposdir_target" "$firmware_type" > /tmp/$cloud-admin.xml
    libvirt_vm_start /tmp/$cloud-admin.xml
}

libvirt_vm_start()
{
    local xml="$1"
    $sudo ${scripts_lib_dir}/libvirt/vm-start "$xml"
}

# run as root
function libvirt_do_setuphost()
{
    local kvmpkg=qemu-kvm
    local extra_packages=
    is_debian && extra_packages="chkconfig"
    if is_suse ; then
        extra_packages=python-xml
        grep -q "SUSE Linux Enterprise Server 11" /etc/os-release && kvmpkg=kvm
        [[ $arch = aarch64 ]] && {
            kvmpkg=qemu-arm
            extra_packages+=" qemu-uefi-aarch64 qemu-ipxe"
        }
        [[ $arch = s390x ]] && {
            kvmpkg=qemu-s390
            # enable KVM
            echo 1 > /proc/sys/vm/allocate_pgste
        }
    fi
    zypper_override_params="--non-interactive" extra_zypper_install_params="--no-recommends" ensure_packages_installed \
        libvirt libvirt-python $kvmpkg $extra_packages \
        lvm2 curl wget bridge-utils \
        dnsmasq netcat-openbsd ebtables iproute2 sudo kpartx rsync

    sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    echo "net.ipv4.conf.all.rp_filter = 0" > /etc/sysctl.d/90-cloudrpfilter.conf
    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
    if [ -n "$needcvol" ] ; then
        safely pvcreate "$cloudpv"
        safely vgcreate "$cloudvg" "$cloudpv"
    fi

    if is_debian ; then
        usermod --groups kvm --append libvirt-qemu
        chkconfig exim4 off
    fi
    # dnsmasq must not be running on the ANY-addr
    # to leave port 53 available to libvirt's dnsmasq
    if ss -ulpn | grep '\*:53.*dnsmasq' ; then
        service dnsmasq stop
        chkconfig dnsmasq off
    fi

    # Start libvirtd and friends
    $sudo service libvirtd status || $sudo service libvirtd start
    if [[ -e /usr/lib/systemd/system/virtlogd.service ]] ; then
        $sudo service virtlogd status || $sudo service virtlogd start
    fi
}

function libvirt_do_sanity_checks()
{
    $sudo vgdisplay "$cloudvg" >/dev/null 2>&1 && needcvol=
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

    $sudo ${scripts_lib_dir}/libvirt/cleanup_one_node ${cloud}-admin
}

function libvirt_do_get_next_pv_device()
{
    if [ -z "$pvlist" ] ; then
        pvlist=`$sudo pvs --sort -Free | awk '$2~/'$cloudvg'/{print $1}'`
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
    $sudo lvcreate -n $lv_name -L ${lv_size}G $lv_vg $lv_pv || \
        safely $sudo lvcreate -n $lv_name -L ${lv_size}G $lv_vg
}

function wipe_volume
{
    local volume=$1
    local size=$2 # in GB
    $sudo dd if=/dev/zero of="$volume" bs=1M count=$(($size * 1024)) conv=fdatasync oflag=nocache
}

# spread block devices over a LVM's PVs so that different VMs
# are likely to use different PVs to optimize concurrent IO throughput
function libvirt_do_create_cloud_lvm()
{
    safely $sudo vgchange -ay $cloudvg # for later boots

    local i n hdd_size

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
        local nodenum
        for nodenum in $(seq 1 $(get_nodenumbercontroller)) ; do
            wipe_volume "/dev/$cloudvg/$cloud.node$nodenum" $controller_hdd_size &
            for n in $(seq 1 $(($controller_raid_volumes-1))) ; do
                hdd_size=${controller_hdd_size}
                onhost_get_next_pv_device
                _lvcreate $cloud.node$nodenum-raid$n $hdd_size $cloudvg $next_pv_device
                wipe_volume "/dev/$cloudvg/$cloud.node$nodenum-raid$n" $hdd_size &
            done
        done
        wait
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
            # clean drbd signatures
            $sudo dd if=/dev/zero of=/dev/$cloudvg/$cloud.node$i-drbd  bs=1M count=1
            $sudo dd if=/dev/zero of=/dev/$cloudvg/$cloud.node$i-drbd  bs=1M count=1 seek=$((($drbd_hdd_size * 1024) - 1))
        done
    fi

    echo "Checking for LVs treated by LVM as valid PV devices ..."
    if [[ $SHAREDVG != 1 ]] &&
        $sudo lvmdiskscan | egrep "/dev/($cloudvg/|mapper/$cloudvg-)"
    then
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

function recursive_remove_holders
{
    local dm=$1
    [[ $dm ]] || return 0
    local dev
    for dev in $(ls /sys/class/block/$dm/holders/) ; do
        recursive_remove_holders $dev
        $sudo dmsetup remove --force /dev/$dev
    done
}

function libvirt_do_cleanup()
{
    # cleanup leftover from last run
    $sudo ${scripts_lib_dir}/libvirt/cleanup $cloud $nodenumber $cloudbr $vlan_public $ironicbr

    if ip link show ${cloudbr}.$vlan_public >/dev/null 2>&1; then
        $sudo ip link set ${cloudbr}.$vlan_public down
    fi
    if ip link show ${cloudbr} >/dev/null 2>&1; then
        $sudo ip link set ${cloudbr} down
        $sudo ip link delete ${cloudbr} type bridge
        $sudo ip link delete ${cloudbr}-nic
    fi
    # 1. remove leftover partition mappings that are still open for this cloud
    local vol
    $sudo dmsetup ls | awk "/^$cloudvg-${cloud}\./ {print \$1}" | while read vol ; do
        $sudo kpartx -dsv /dev/mapper/$vol
    done

    # 2. remove all previous volumes for that cloud; this helps preventing
    # accidental booting and freeing space
    if [ -d $vdisk_dir ]; then
        local lv
        for lv in $(find -L $vdisk_dir -name "$cloud.*" -type b) ; do
            recursive_remove_holders $(basename $(readlink $lv))
            $sudo lvremove --force $lv || complain 104 "lvremove failure"
        done
    fi
    $sudo rm -f /etc/lvm/archive/*

    if [[ $wipe = 1 ]] ; then
        $sudo vgchange -an $cloudvg
        $sudo dd if=/dev/zero of=$cloudpv count=1000
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
    local image=${override_disk_image:-$(dist_to_image_name $2)}
    local disk=$3
    local image_path=$cache_dir/$image

    if [[ ! $want_cached_images = 1 ]] ; then
        safely rsync --compress --progress --inplace --archive --verbose \
            rsync://$rsyncserver_fqdn/$rsyncserver_images_dir/$image $cache_dir/
    else
        # In this case the image has to be supplied by other means than
        # mkcloud (e.g. manual upload). If it doesn't exist we bail.
        if [ ! -f "${image_path}" ] ; then
            # look for the image file in the cache if it is not there in the
            # usual location. Sometimes the image got cache into a different
            # directory.
            found_image_path=$(find $cache_dir -name $image | sed -n 1p | tr -d '\n')
            if [ -n "${found_image_path}" -a -f "${found_image_path}" ] ; then
                image_path=$found_image_path
            else
                complain 19 \
                "No image found on host and want_cached_images was set."
            fi
        fi
    fi

    local qemu_img_extra=""
    test -b $disk && qemu_img_extra="-t none -S 0" # sparse and cache only if it is not a blockdevice
    echo "Cloning $role node vdisk from $image ..."
    safely $sudo qemu-img convert -O raw $qemu_img_extra -p $image_path $disk

    if [[ ${resize_admin_node_partition:-1} = 1 ]]; then
        # resize the last partition only if it has id 83
        local last_part=$(fdisk -l $disk | grep -c "^$disk")
        if $sudo fdisk -l $disk | grep -q "$last_part *\* *.*83 *Linux" ; then
            echo -e "d\n$last_part\nn\np\n$last_part\n\n\na\n$last_part\nw" | $sudo fdisk $disk
            local part=$($sudo kpartx -asv $disk|perl -ne 'm/add map (\S+'"$last_part"') / && print $1')
            test -n "$part" || complain 31 "failed to find partition #$last_part"
            local bdev=/dev/mapper/$part
            safely $sudo fsck -y -f $bdev
            safely $sudo resize2fs $bdev
            time $sudo udevadm settle
            sleep 1 # time for dev to become unused
            safely $sudo kpartx -dsv $disk
        fi
    fi
    # resize partitionless disk with ext2 filesystem
    tune2fs -l $disk > /dev/null 2>&1 && safely resize2fs $disk
    true
}

function libvirt_do_setuplonelynodes()
{
    local i
    for i in $(nodes ids lonely) ; do
        local mac=$(macfunc $i)
        local lonely_node
        lonely_node=$cloud-node$i
        safely ${scripts_lib_dir}/libvirt/compute-config $cloud $i \
               --macaddress $mac \
               --cephvolumenumber "$cephvolumenumber" \
               --drbdserial "$drbdvolume" \
               --computenodememory $compute_node_memory\
               --controllernodememory $controller_node_memory \
               --libvirttype $libvirt_type \
               --vcpus $vcpus \
               --emulator $(get_emulator) \
               --vdiskdir $vdisk_dir \
               --bootorder 1 \
               --numcontrollers 1 \
               --firmwaretype "$firmware_type" > /tmp/$cloud-node$i.xml

        local lonely_disk
        lonely_disk="$vdisk_dir/${cloud}.node$i"

        $sudo lvdisplay "$lonely_disk" || \
            _lvcreate "${cloud}.node$i" "${lonelynode_hdd_size}" "$cloudvg"

        local j
        local lonely_data_disk
        for j in $(seq $cephvolumenumber); do
            lonely_data_disk="${lonely_disk}-ceph$j"
            $sudo lvdisplay "$lonely_data_disk" || \
                _lvcreate "${cloud}.node$i-ceph$j" "${cephvolume_hdd_size}" "$cloudvg"
            # make sure the drive is Zapped and ready for use
            sudo sgdisk -Z $lonely_data_disk
        done

        onhost_deploy_image "lonely" $(get_lonely_node_dist) $lonely_disk
        libvirt_vm_start /tmp/${lonely_node}.xml
    done
}

function libvirt_do_setupironicnodes()
{
    local i
    for i in $(nodes ids ironic) ; do
        # note: for now only one 'ironic' nic is added so $nics is ignored
        local mac_params=" --macaddress $(macfunc $i 1)"

        local ironic_node
        ironic_node=$cloud-node$i
        safely ${scripts_lib_dir}/libvirt/compute-config $cloud $i \
               $mac_params \
               --drbdserial "$drbdvolume" \
               --computenodememory $compute_node_memory\
               --controllernodememory $controller_node_memory \
               --libvirttype $libvirt_type \
               --vcpus $vcpus \
               --emulator $(get_emulator) \
               --vdiskdir $vdisk_dir \
               --bootorder 1 \
               --numcontrollers 0 \
               --ironicnic 0 \
               --firmwaretype "$firmware_type" > /tmp/$cloud-node$i.xml

        local ironic_disk
        ironic_disk="$vdisk_dir/${cloud}.node$i"

        $sudo lvdisplay "$ironic_disk" || \
            _lvcreate "${cloud}.node$i" "${ironicnode_hdd_size}" "$cloudvg"

        libvirt_vm_start /tmp/${ironic_node}.xml
    done
}


function libvirt_do_shutdowncloud()
{
    $sudo virsh shutdown $cloud-admin
    local i
    for i in $(nodes ids all) ; do
        $sudo virsh shutdown $cloud-node$i
    done
}

function libvirt_do_macfunc
{
    local nodenumber=$1
    local nicnumber=${2:-"1"}
    printf "$macprefix:77:%02x:%02x" $nicnumber $nodenumber
}
