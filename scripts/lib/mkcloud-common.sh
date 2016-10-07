# This file shares common code between mkcloud-${mkclouddriver}.sh files and qa_crowbarsetup.sh

function max
{
    echo $(( $1 > $2 ? $1 : $2 ))
}

function determine_mtu
{
    LC_ALL=C sort -n /sys/class/net/*/mtu | head -n 1
}

function is_suse
{
    grep -qi suse /etc/*release
}

sshopts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
scp="scp $sshopts"
ssh="ssh $sshopts"
function ssh_password
{
    SSH_ASKPASS=/root/echolinux
    cat > $SSH_ASKPASS <<EOSSHASK
#!/bin/sh
echo linux
EOSSHASK
    chmod +x $SSH_ASKPASS
    DISPLAY=dummydisplay:0 SSH_ASKPASS=$SSH_ASKPASS setsid $ssh -oNumberOfPasswordPrompts=1 "$@"
}

function sshtest
{
    timeout 10 $ssh -o NumberOfPasswordPrompts=0 "$@"
}

function onhost_setup_portforwarding()
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

