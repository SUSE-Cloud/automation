function ipmi_cleanup
{
    for node in $(seq $nodenumber) ; do
        if ip link show v${cloud}${node}-x >/dev/null ; then
            ip link del dev v${cloud}${node}-x
        fi
        screen -X -S $cloud-node$node-bmc-lan quit
    done
}

function mkveth
{
    local nodenumber=$1
    local bmc_addr=$2
    local iface=v$cloud$nodenumber
    ip link add dev $iface-x type veth peer name $iface-y
    ip link set dev $iface-x up
    ip link set dev $iface-y up
    ip addr add ${bmc_addr}/${adminnetmask} dev $iface-x
    brctl addif $cloudbr $iface-y
}

function generate_lan_config()
{
    local nodenumber=$1
    local user=$2
    local password=$3
    local listenaddr=$4
    local nodename=$cloud-node$nodenumber
    local lanconfig=/tmp/ipmi-lan-$nodename.conf
    cat > $lanconfig <<EOF
name "$nodename"
set_working_mc 0x20
  startlan 1
    addr $listenaddr 623
    allowed_auths_admin md5
    guid deadbeefdeadbeefdeadbeefdeadbeef
    lan_config_program "$SCRIPTS_DIR/lib/ipmi/ipmi_sim_lancontrol v${cloud}${nodenumber}-x"
  endlan
  serial 15 0.0.0.0 623${nodenumber} codec VM
  startcmd "virsh start $nodename"
  startnow false
  user 2 true  "${user}" "${password}" admin 10 md5
EOF
}
