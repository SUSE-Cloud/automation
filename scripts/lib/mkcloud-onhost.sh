function get_emulator
{
    local emulator=/usr/bin/qemu-system-$arch
    if [ -x /usr/bin/qemu-kvm ] && file /usr/bin/qemu-kvm | grep -q ELF; then
        # on SLE11, qemu-kvm is preferred, since qemu-system-x86_64 is
        # some rotten old stuff without KVM support
        emulator=/usr/bin/qemu-kvm
    fi
    echo $emulator
}

function onhost_setup_portforwarding
{
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
        $sudo tee $boot_mkcloud_d_cloud >/dev/null <<EOS
#!/bin/bash
# Auto-generated from $0 on `date`

iptables_unique_rule () {
    # First argument must be chain
    if ! iptables -C "\$@" 2>/dev/null; then
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

# Forward VNC port
iptables_unique_rule PREROUTING -t nat -p tcp --dport \$(( $cloud_port_offset + 6080 )) \\
    -j DNAT --to-destination $net_public.2

# need to delete+insert on top to make sure our ACCEPT comes before libvirt's REJECT
for x in D I ; do
    iptables -\$x FORWARD -d $net_admin.0/24 -j ACCEPT
    iptables -\$x FORWARD -d $net_public.0/24 -j ACCEPT
done

echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
EOS
        $sudo chmod +x $boot_mkcloud_d_cloud
        if ! grep -q "boot\.mkcloud\.d" /etc/init.d/boot.local ; then
            $sudo tee -a /etc/init.d/boot.local >/dev/null <<EOS

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

    # $boot_mkcloud is for backwards compatibility and for setups
    # on mkch*.cloud.suse.de hosts.
    local f
    for f in "$boot_mkcloud" $boot_mkcloud_d/*; do
        if [ -x "$f" ]; then
            $sudo "$f"
        fi
    done
}

function onhost_deploy_image
{
    ${mkclouddriver}_do_onhost_deploy_image "$@"
}

function onhost_prepareadmin
{
    onhost_deploy_image "admin" $(get_admin_node_dist) "$admin_node_disk"
}

function onhost_cacheclouddata
{
    [[ "$cache_clouddata" = 1 ]] || return

    common_set_versions

    local include=$(mktemp)
    (
        local a
        for a in $architectures; do
            local suffix
            # Mirror SLES/HA/SOC update + pool repos
            for suffix in Pool Updates; do
                echo "repos/$a/SLES$slesversion-$suffix/***"
                [[ $hacloud = 1 ]] && echo "repos/$a/SLE$slesversion-HA-$suffix/***"
                echo "repos/$a/SUSE-OpenStack-Cloud-$cloudrepover-$suffix/***"
                echo "repos/$a/SUSE-Enterprise-Storage-$sesversion-$suffix/***"
                echo "repos/$a/SLE12-Module-Adv-Systems-Management-$suffix/***"
            done
            echo "repos/$a/SLES$slesversion-LTSS-Updates/***"
            [[ $want_test_updates = 1 ]] && {
                echo "repos/$a/SLES$slesversion-Updates-test/***"
                [[ $hacloud = 1 ]] && echo "repos/$a/SLE$slesversion-HA-Updates-test/***"
                echo "repos/$a/SUSE-Enterprise-Storage-$sesversion-Updates-test/***"
            }
            echo "install/suse-$suseversion/$a/install/***"

            # Determine which cloudsource based media to mirror
            suffix="official"
            if [[ $cloudsource =~ (develcloud) ]]; then
                suffix="devel"
                [ -n "$TESTHEAD" ] && suffix+="-staging"
            fi
            echo "repos/$a/SUSE-OpenStack-Cloud-$cloudrepover-$suffix/***"

            # Now the various test images
            # NOTE: looks like these images are only availabe on x86_64
            if [ "${a}" == "x86_64" ] ; then
                echo "images/$a/other/magnum-service-image.qcow2"
                echo "images/$a/other/manila-service-image.qcow2"
                # these are the real ones, the above are just symlinks
                echo "images/$a/other/Fedora-Atomic-26.qcow2"
                echo "images/$a/other/manila-service-image.x86_64-0.13.0-Build14.1.qcow2"
                # need for the testsetup step
                echo "images/$a/SLES12-SP1-JeOS-SE-for-OpenStack-Cloud.x86_64-GM.qcow2"
            fi

            # now cache the admin image
            admin_image_name=$(dist_to_image_name $(get_admin_node_dist))
            echo "images/${a}/${admin_image_name}"
        done

        echo "images/SLES11-SP3-x86_64-cfntools.qcow2"
    ) > $include

    echo "----------------"
    cat $include
    echo "----------------"

    local rsync_options="-mavHP --delete --ignore-errors"
    rsync $rsync_options --include-from=$include --include="*/" --exclude="*" $reposerver::cloud $cache_dir
    rm -f $include
}
