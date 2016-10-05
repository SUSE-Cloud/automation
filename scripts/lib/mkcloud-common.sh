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

sshopts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=2"
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

function nodes
{
    local query=${1:number}
    local type=${2:all}
    local start_id=1
    local end_id=$(($nodenumber + $nodenumberlonelynode))
    case $type in
        normal|pxe)
            end_id=$nodenumber
        ;;
        lonely|preinstalled)
            start_id=$(($nodenumber + 1))
        ;;
        all)
        ;;
    esac

    case $query in
        ids) echo `seq $start_id $end_id`
        ;;
        number) echo $(( 1 + $end_id - $start_id ))
        ;;
    esac
}

: ${macprefix:=52:54:77}
function macfunc
{
    ${mkclouddriver}_do_macfunc $1
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

# Returns success if a change was made
function confset
{
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^$key *= *$value" "$file"; then
        return 1 # already set correctly
    fi

    local new_line="$key = $value"
    if grep -q "^$key[ =]" "$file"; then
        # change existing value
        sed -i "s/^$key *=.*/$new_line/" "$file"
    elif grep -q "^# *$key[ =]" "$file"; then
        # uncomment existing setting
        sed -i "s/^# *$key *=.*/$new_line/" "$file"
    else
        # add new setting
        echo "$new_line" >> "$file"
    fi

    return 0
}

# ---- START: functions related to repos and distribution settings

function getcloudver
{
    if   [[ $cloudsource =~ ^.*(cloud|GM)3(\+up)?$ ]] ; then
        echo -n 3
    elif [[ $cloudsource =~ ^.*(cloud|GM)4(\+up)?$ ]] ; then
        echo -n 4
    elif [[ $cloudsource =~ ^.*(cloud|GM)5(\+up)?$ ]] ; then
        echo -n 5
    elif [[ $cloudsource =~ ^.*(cloud|GM)6(\+up)?$ ]] ; then
        echo -n 6
    elif [[ $cloudsource =~ ^(.+7|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM7?(\+up)?)$ ]] ; then
        echo -n 7
    else
        complain 11 "unknown cloudsource version"
    fi
}

# return if cloudsource is referring a certain SUSE Cloud version
# input1: version - 6plus refers to version 6 or later ; only a number refers to one exact version
function iscloudver
{
    [[ $cloudsource ]] || return 1
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
        if [[ $ver -eq $v ]] && [[ $cloudsource =~ ^M[0-9]+$ ]] ; then
            [ "${cloudsource#*M}" $operator "$milestone" ]
            return $?
        fi
    fi
    [ "$ver" $operator "$v" ]
    return $?
}

function get_admin_node_dist
{
    # echo the name of the current dist for the admin node
    local dist=
    case $(getcloudver) in
        7)  dist=SLE12SP2
            [[ $want_sles12sp1_admin ]] && dist=SLE12SP1
            ;;
        6)  dist=SLE12SP1 ;;
        5)  dist=SLE11    ;;
        *)  dist=SLE11    ;;
    esac
    echo "$dist"
}

# ---- END: functions related to repos and distribution settings
