function libvirt_modprobe_kvm()
{
    modprobe kvm-amd
    if [ ! -e /etc/modprobe.d/80-kvm-intel.conf ] ; then
        echo "options kvm-intel nested=1" > /etc/modprobe.d/80-kvm-intel.conf
        rmmod kvm-intel
    fi
    modprobe kvm-intel
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

    if [ -z "$NOSETUPPORTFORWARDING" ] ; then
        nodehostips=$(seq -s ' ' 81 $((80 + $nodenumber)))
        cat > /etc/init.d/boot.mkcloud <<EOS
#!/bin/bash

iptables -t nat -F PREROUTING
for i in 22 80 443 3000 4000 4040 ; do
    iptables -I FORWARD -p tcp --dport \$i -j ACCEPT
    for host in 10 $nodehostips ; do
        offset=80
        [ "\$host" = 10 ] && offset=10
        iptables -t nat -I PREROUTING -p tcp --dport \$((\$i + \$host - \$offset + 1100)) -j DNAT --to-destination $net_admin.\$host:\$i
    done
done
iptables -t nat -I PREROUTING -p tcp --dport 6080 -j DNAT --to-destination $net_public.2
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
EOS
        if ! grep -q "boot.mkcloud" /etc/init.d/boot.local ; then
            cat >> /etc/init.d/boot.local <<EOS

# --v--v--  Automatically added by mkcloud on `date`
/etc/init.d/boot.mkcloud
# --^--^--  End of automatically added section from mkcloud
EOS
        fi
    fi
    if [ -e "/etc/init.d/boot.mkcloud" ]; then
        chmod +x /etc/init.d/boot.mkcloud
        /etc/init.d/boot.mkcloud
    fi
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
