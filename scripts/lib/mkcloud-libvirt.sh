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

    boot_mkcloud=/etc/init.d/boot.mkcloud
    boot_mkcloud_d="$boot_mkcloud.d"
    boot_mkcloud_d_cloud="$boot_mkcloud_d/$cloud"

    if [ -z "$NOSETUPPORTFORWARDING" ] ; then
        # FIXME: hardcoded assumptions about admin net host range
        nodehostips=$(seq -s ' ' 81 $((80 + $nodenumber)))

        : ${cloud_port_offset:=1100}
        mosh_start=$(( $cloud_port_offset + 60001 ))
        mosh_end=$((   $cloud_port_offset + 60010 ))

        mkdir -p $boot_mkcloud_d
        cat > $boot_mkcloud_d_cloud <<EOS
#!/bin/bash
# Auto-generated from $0 on `date`

iptables_unique_rule () {
    # First argument must be chain
    if iptables -C "\$@" 2>/dev/null; then
        echo "iptables rule already exists: \$*"
    else
        iptables -I "\$@"
        echo "iptables -I \$*"
    fi
}

# Forward ports to admin server
for port in 22 80 443 3000 4000 4040; do
    iptables_unique_rule PREROUTING -t nat -p tcp \\
        --dport \$(( $cloud_port_offset + \$port )) \\
        -j DNAT --to-destination $adminip:\$port
done

# Connect to admin server with mosh (if installed) via:
#   mosh -p $mosh_start --ssh="ssh -p $(( $cloud_port_offset + 22 ))" `hostname -f`
iptables_unique_rule PREROUTING -t nat -p udp \\
    --dport $mosh_start:$mosh_end \\
    -j DNAT --to-destination $adminip

# Forward ports to non-admin nodes
for port in 22 80 443 5000 7630; do
    for host in $nodehostips; do
        # FIXME: hardcoded assumptions about admin net host range
        offset=80
        host_port_offset=\$(( \$host - \$offset ))
        iptables_unique_rule PREROUTING -t nat -p tcp \\
            --dport \$(( $cloud_port_offset + \$port + \$host_port_offset )) \\
            -j DNAT --to-destination $net_admin.\$host:\$port
    done
done

iptables_unique_rule PREROUTING -t nat -p tcp --dport 6080 \\
    -j DNAT --to-destination $net_public.2

iptables_unique_rule FORWARD -d $net_admin.0/24 -j ACCEPT
iptables_unique_rule FORWARD -d $net_public.0/24 -j ACCEPT

echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
EOS
        chmod +x $boot_mkcloud_d_cloud
        if ! grep -q "boot\.mkcloud\.d" /etc/init.d/boot.local ; then
            cat >> /etc/init.d/boot.local <<EOS

# --v--v--  Automatically added by mkcloud on `date`
for f in $boot_mkcloud_d/*; do
    if [ -x "\$f" ]; then
        \$f
    fi
done
# --^--^--  End of automatically added section from mkcloud
EOS
        fi
    fi

    # Kept for backwards compatibility and for hand-written setups
    # on mkch*.cloud.suse.de hosts.
    if [ -x "$boot_mkcloud" ]; then
        $boot_mkcloud
    fi

    for f in $boot_mkcloud_d/*; do
        if [ -x "$f" ]; then
            $f
        fi
    done
}

function libvirt_prepare()
{
    # libvirt
    libvirt_modprobe_kvm
    libvirt_start_daemon

    # network
    ${mkcloud_lib_dir}/libvirt/net-config $cloud $cloudbr $admingw $adminnetmask $cloudfqdn $adminip $forwardmode > /tmp/$cloud-admin.net.xml
    ${mkcloud_lib_dir}/libvirt/net-start /tmp/$cloud-admin.net.xml || exit $?
    libvirt_net_start
}

function libvirt_setupadmin()
{
    ${mkcloud_lib_dir}/libvirt/admin-config $cloud $admin_node_memory $adminvcpus $emulator $admin_node_disk "$localreposdir_src" "$localreposdir_target" > /tmp/$cloud-admin.xml
    ${mkcloud_lib_dir}/libvirt/vm-start /tmp/$cloud-admin.xml || exit $?
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
}
