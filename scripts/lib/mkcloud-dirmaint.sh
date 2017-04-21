# mkcloud driver implementation using SMAPI and DirMaint
#
# For more information,
# see http://www.vm.ibm.com/related/dirmaint/overview.html

. ~/.lxccfg

shutdowntime=60
zvmname=$(vmcp q userid | sed 's/ .*//')

function dirmaint_do_sanity_checks()
{
    if [ ! -e ~/.lxccfg ] ; then
        complain 1 "This script needs lxc configured and ~/.lxccfg to work correctly"
    fi
}

# unit with 3390 would be a cylinder, with 9336 it would be 512 Byte
function unit_to_byte()
{
    # each 3390 cylinder has 849960 bytes according to documentation
    if [ "$1" == "3390" ]; then
        echo $(($2 * 849960))
        return 0
    fi
    if [ "$1" == "9336" ]; then
        echo $(($2 * 512))
        return 0
    fi
    return 1
}

# unit with 3390 would be a cylinder, with 9336 it would be 512 Byte
function byte_to_unit()
{
    # $1 is device type (3390 or 9336)
    # $2 is number of bytes
    # I guess we want to round up...
    # each 3390 cylinder has 849960 bytes according to documentation
    if [ "$1" == "3390" ]; then
        carry=$(($2 % 849960))
        if [ $carry -ne 0 ]; then
            carry=1
        fi
        echo $(($2 / 849960 + $carry))
        return 0
    fi
    if [ "$1" == "9336" ]; then
        carry=$(($2 % 512))
        if [ $carry -ne 0 ]; then
            carry=1
        fi
        echo $(($1 / 512 + $carry))
        return 0
    fi
    return 1
}

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

function dirmaint_user_deleted()
{
    # HCP003E says invalid option. This means, the user does not exist.
    vmcp q $1 2> /dev/null | grep -q HCPCQV003E
    return $?
}

function dirmaint_do_shutdowncloud()
{
    for i in $(nodes ids all); do
        # skip user, if it is logged off or if it does not exist
        local usrname=$(printf "${cloud}n%02d" $i)
        vmcp q $usrname 2> /dev/null |\
            grep -q -e "HCPCQU045E" -e "HCPCQV003E" && continue
        sigcmd="cp sig shut $usrname within $shutdowntime"
        forcecmd="cp force $usrname IMMED"
        $lxc -c "$sigcmd" || lxc -c "$forcecmd"
    done
    # if a guest is logged on, query to the name has status 0
    vmcp q ${cloud}adm >& /dev/null && $lxc -c "cp force ${cloud}adm IMMED"
    vmcp q ${cloud}adm >& /dev/null && wait_for 60 1 "! vmcp q ${cloud}adm" "admin node ${cloud}adm to log off"
    # finally remove cloud administration guest from directory:
    $lxc -c "dirm for ${cloud}adm purge"
    # wait until the directory entry is deleted
    # to improve performance, we might want to remove the disk from the admin node first and purge then.
    wait_for 120 1 "dirmaint_user_deleted ${cloud}adm" "admin node ${cloud}adm to be purged (disk deletion)"
}

function dirmaint_do_cleanup()
{
    local vdev="0a${cloudidx}0"
    echo "cleaning up for locally linked minidisk $vdev"
    # cleanup if copy of image to admin node or dasdfmt aborted failed
    cat /proc/dasd/devices | grep "0.0.$vdev"  && chccwdev -d 0.0.$vdev
    vmcp q v $vdev >& /dev/null && vmcp detach $vdev
    # now we can proceed to try and cleanup the rest
    dirmaint_do_shutdowncloud

    killproc -p /var/run/mkcloud/dnsmasq-$cloud.pid /usr/sbin/dnsmasq
    rm -f /var/run/mkcloud/dnsmasq-$cloud.pid /etc/dnsmasq-$cloud.conf

    ndev=1${cloudidx}00
    if [ -f /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/if_name ]; then
        devname=$(cat /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/if_name)

        # take network down for this cloud
        ip link set $devname down
        # use system script to take down the device
        qeth_configure -l 0.0.1${cloudidx}00 0.0.1${cloudidx}01 0.0.1${cloudidx}02 0
        $lxc -c "cp for $zvmname cmd detach nic ${ndev}"
    fi
    # and finally delete the vswitch
    $lxc -c "cp q vswitch ${cloud}" >& /dev/null && $lxc -c "cp detach vswitch ${cloud}"

    echo "Cleanup done"
}

function dirmaint_do_prepare()
{
    onhost_add_etchosts_entries

    if ! vmcp q vswitch ${cloud}; then
        # create new vswitch for cloud networks
        $lxc -c "cp define vswitch ${cloud} qdio local nouplink ethernet vlan unaware"
        # create nic on the host, and plug it into that switch
        ndev=1${cloudidx}00
        $lxc -c "cp for $zvmname cmd define nic ${ndev} type qdio"
        $lxc -c "cp for $zvmname cmd set nic ${ndev} macid 0${cloudidx}7700"
        $lxc -c "cp set vswitch ${cloud} grant $zvmname"
        $lxc -c "cp for $zvmname cmd couple ${ndev} to system ${cloud}"

        # use system script to bring up the device
	qeth_configure -l 0.0.1${cloudidx}00 0.0.1${cloudidx}01 0.0.1${cloudidx}02 1
        devname=$(cat /sys/bus/ccwgroup/drivers/qeth/0.0.${ndev}/if_name)

        ip addr add $admingw/24 dev $devname
        ip link set up dev $devname
    fi


    # setup dnsmasq
    # get MACPREFIX for this z/VM:
    macprefix=$(vmcp q vmlan | grep "USER Prefix" | awk '{ print $6 }')
    macprefix=$(sed -e 's/.\{2\}/&:/g;s/.$//' <<<$macprefix)
    macprefix=${macprefix,,}
    echo "Setting MACPREFIX to: $macprefix"
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

    # test if user exists and is logged off.
    vmcp q $ruser 2>/dev/null | grep HCPCQU045E || \
        complain 193 "$ruser is not logged off or does not exist."

    # Derive the link target from $cloudidx to avoid races when doing
    # for multiple mkcloud runs in parallel
    local vdev="0a${cloudidx}0"
    local ccw="0.0.$vdev"

    # added OPTION LNKNOPAS to the local machine. Thus no password needed
    safely vmcp link to $ruser 0100 as $vdev mr
    # enable the disk on the admin node
    chccwdev -e $ccw
    wait_for 10 1 "[ -r /dev/disk/by-path/ccw-$ccw ]" "disk to show up"

    # low level format
    echo "Performing low level format of $ccw"
    lsdasd $ccw -l | grep -q "status:.*active" || {
        dasdfmt -b 4096 -y -m 500 /dev/disk/by-path/ccw-$ccw
    }

    # For the following I would recommend a slightly different procedure. I
    # don't know if this is doable in openstack:
    # I would add a number of disks to the admin machine that serve as
    # container for images. Instead of /tmp/$image, there would be a certain
    # disk with $ccw that contains the image. The actual cloning would then be
    # done with a command like the following:
    # lxc -h s390cld015 -u ladmin -P lin390 -c "dirm for $ruser clonedisk 0100 $zvmname $ccw"
    # note, that the disk must be detached from $zvmname after the image has
    # been copied there. The big advantage would be, that dirmaint would use
    # flashcopy if available.
    # After the copy, you would wait until the disk is not linked
    # anymore with a command like:
    # lxc -h s390cld015 -u ladmin -P lin390 -c "cp q l $ccw"
    echo "Cloning $role node vdisk from /tmp/$image to /dev/disk/by-path/ccw-$ccw..."
    safely qemu-img convert -t none -O raw -S 0 -p /tmp/$image /dev/disk/by-path/ccw-$ccw
    # make sure the data is not in cache anymore...
    sync
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
    echo "Setting up admin user"

    local admuser=${cloud}adm
    local cloudbr=${cloud}
    # default directory entry for this user:
    cat <<EOF > $HOME/${admuser^^}.DIRECT
USER $admuser cldpaswd 2G 4G G
  INCLUDE LNXDFLT
  COMMAND SET SECUSER OPERATOR
  IPL 100 PARM AUTOCR
  OPTION LNKNOPAS
  NICDEF 1000 TYPE QDIO LAN SYSTEM $cloudbr MACID 0${cloudidx}7700
EOF

    # now, lets add this user to the directory:
    $lxc -c "dirm add $admuser"
    # the user does not have a disk yet, we might want to add one at virtual
    # address 100:
    # FIXME: this is CKD (3390) only, also fixed size of 10015 cylinders
    # FIXME: for FBA, the type would be 9336, and counting would be 512 byte
    # blocks.
    disksize=$(byte_to_unit 3390 8512349400) # this is just the 10015 cylinders
    $lxc -c "dirm for $admuser amdisk 0100 3390 autog $disksize CLD9 mr"
    # other modifications also would work with similar commands
    # now deploy the standard image to the boot disk:
    dirmaint_do_onhost_deploy_image admin SLES12-SP2-ECKD.qcow2 0100

    # I don't see how the following can happen, but it doesn't hurt anyways
    vmcp q $admuser 2> /dev/null && complain 192 "$admuser is not logged off"

    # grant access rights to the vswitch:
    $lxc -c "cp set vswitch $cloudbr gra $admuser"
    $lxc -c "cp set vswitch $cloudbr gra $admuser prom"
    # start the node
    $lxc -c "cp xautolog $admuser sync" || exit $?
}

function dirmaint_add_node()
{
	# assuming that there has been added a CLDPROT PROTODIR entry to
	# dirmaint that sets common defaults.
	# The prototype contains default disk and network. If different defaults
	# are desired, we can also add several prototypes or finalize a user
	# later on.
	local node=$1
	# FIXME: I guess, for production, we would use AUTOONLY as password.
	$lxc -c "cms dirm add $node like CLDPROT PW lin390"
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
		dirmaint_add_node $lonely_node
		# while this is not a bad thing as it is, we could improve the
		# situation by preparing a number of disks that hold default images.
		# in that case, dirmaint could be used to clone the respective disk.
        _dirmaint_link_and_write_disk $lonely_node SLES12-SP2-ECKD.qcow2

        # grant access rights to the vswitch:
        safely $lxc -c "cp set vswitch $cloudbr gra $lonely_node"
        safely $lxc -c "cp set vswitch $cloudbr gra $lonely_node prom"
        # start the node
        safely $lxc -c "vmcp xautolog $lonely_node sync"
    done
}

function dirmaint_do_macfunc()
{
    local nodenumber=$1
    local nicnumber=${2:-"1"}
    printf "$macprefix:0${cloudidx}:%02x:%02x" $nicnumber $nodenumber
}
