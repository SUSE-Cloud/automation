# mkcloud driver implementation using SMAPI and DirMaint
#
# For more information,
# see http://www.vm.ibm.com/related/dirmaint/overview.html

function dirmaint_do_setuphost()
{
    vmcp q cplevel || complain 191 "Something is wrong with the CP link"
}

function dirmaint_do_sanity_checks()
{
    # This assumes $cloud is named "mkcl<single-hex-digit>"
    if [[ ${cloud} =~ ^mkcl[0-9a-f]$ ]]; then
        cloudidx=${cloud: -1}
    else
        complain 93 "Invalid cloud name. " \
            "\$cloud (currently: \"${cloud}\") needs to match \"mkcl[0-9a-f]\". Exiting."
    fi
}

function dirmaint_do_shutdowncloud()
{
    for i in $(nodes ids all); do
        vmcp sig shut $(printf "${cloud}n%02d" $i)
    done
    vmcp sig shut ${cloud}adm
    wait_for 60 1 "! vmcp q ${cloud}adm" "admin node ${cloud}adm to log off"
}

function dirmaint_do_cleanup()
{
    dirmaint_do_shutdowncloud

    killproc -p /var/run/mkcloud/dnsmasq-$cloud.pid /usr/sbin/dnsmasq
    rm -f /var/run/mkcloud/dnsmasq-$cloud.pid /etc/dnsmasq-$cloud.conf

    ndev=1${cloudidx}00
    devname=$(cat /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/if_name)

    # take network down for this cloud
    ip link set $devname down
    echo 0 > /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/online
    vmcp uncouple ${ndev}
    vmcp detach nic ${ndev}
    vmcp set nic ${ndev} macid system

    # and finally delete the vswitch
    vmcp detach vswitch ${cloud}

    echo "Cleanup done"
}

function dirmaint_do_prepare()
{
    onhost_add_etchosts_entries
    onhost_prepareadmin

    if ! vmcp q vswitch ${cloud}; then
        # create new vswitch for cloud networks
        vmcp define vswitch ${cloud} qdio local nouplink ethernet vlan unaware

        # create nic on the host, and plug it into that switch
        ndev=1${cloudidx}00
        vmcp set nic ${ndev} macid 0${cloudidx}7777
        vmcp define nic ${ndev} type qdio
        vmcp set vswitch ${cloud} grant mkcldhst
        vmcp couple ${ndev} to system ${cloud}

        # bring nic up
        echo "0.0.1${cloudidx}00,0.0.1${cloudidx}01,0.0.1${cloudidx}02" > /sys/bus/ccwgroup/drivers/qeth/group
        echo 1 > /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/online
        devname=$(cat /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/if_name)

        ip addr add $admingw/24 dev $devname
        ip link set up dev $devname
    fi


    # setup dnsmasq
    mkdir -p /var/run/mkcloud
    cat <<EOF > /etc/dnsmasq-$cloud.conf
strict-order
pid-file=/var/run/mkcloud/dnsmasq-$cloud.pid
except-interface=lo
bind-interfaces
listen-address=$admingw
dhcp-range=$admingw,static
dhcp-no-override
dhcp-host=$macprefix:0$cloudidx:77:00,${admingw}0
EOF
    startproc -p /var/run/mkcloud/dnsmasq-$cloud.pid /usr/sbin/dnsmasq \
        --conf-file=/etc/dnsmasq-$cloud.conf

    onhost_setup_portforwarding
}

function _dirmaint_link_and_write_disk()
{
    local ruser=$1
    local image=$2

    vmcp q $ruser && complain 193 "$ruser is not logged off"

    # FIXME kill the machine
    # vmcp force $ruser || :
    # FIXME

    # Derive the link target from $cloudidx to avoid races when doing
    # for multiple mkcloud runs in parallel
    local vdev="0a${cloudidx}0"
    local ccw="0.0.$vdev"

    safely vmcp link to $ruser 0100 as $vdev mw pass=linux

    chccwdev -e $ccw
    wait_for 10 1 "[ -r /dev/disk/by-path/ccw-$ccw ]" "disk to show up"

    # low level format
    lsdasd $ccw -l | grep -q "status:.*active" || {
        dasdfmt -b 4096 -y /dev/disk/by-path/ccw-$ccw
    }

    echo "Cloning $role node vdisk from $image ..."
    safely qemu-img convert -t none -O raw -S 0 -p /tmp/$image /dev/disk/by-path/ccw-$ccw

    chccwdev -d $ccw
    wait_for 10 1 "[ ! -r /dev/disk/by-path/ccw-$ccw ]" "disk to disappear"

    safely vmcp det v $vdev
}

function dirmaint_do_onhost_deploy_image()
{
    local role=$1
    local image=SLES12-SP2-ECKD.qcow2
    local disk=$3

    [[ $clouddata ]] || complain 108 "clouddata IP not set - is DNS broken?"
    pushd /tmp
    safely wget --progress=dot:mega -N \
        http://$clouddata/images/$arch/$image
    popd

    _dirmaint_link_and_write_disk ${cloud}adm $image
}

function dirmaint_do_setupadmin()
{
    # FIXME
    echo "NEED TO SETUP ADMIN PROTOTYPE"

    local admuser=${cloud}adm
    local cloudbr=${cloud}

    vmcp q $admuser && complain 192 "$admuser is not logged off"

    vmcp s vswitch $cloudbr gra $admuser
    vmcp s vswitch $cloudbr gra $admuser prom
    vmcp xautolog $admuser sync || exit $?
}

function dirmaint_do_setuplonelynodes()
{
    local i

    for i in $(nodes ids lonely) ; do
        local mac=$(macfunc $i)
        local lonely_node
        local cloudbr=${cloud}
        lonely_node=$(printf "${cloud}n%02d" $i)

        # FIXME push user directory entry
        _dirmaint_link_and_write_disk $lonely_node SLES12-SP2-ECKD.qcow2

        safely vmcp s vswitch $cloudbr gra $lonely_node
        safely vmcp s vswitch $cloudbr gra $lonely_node prom

        safely vmcp xautolog $lonely_node sync
    done
}

function dirmaint_do_macfunc()
{
    printf "$macprefix:0${cloudidx}:77:%02x" $1
}
