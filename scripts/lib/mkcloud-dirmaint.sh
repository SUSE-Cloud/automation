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
    : Sanity is doing the same thing over and over again and seeing no difference
}

function dirmaint_do_cleanup()
{
    echo "FIXME: do_cleanup"
}

function dirmaint_do_prepare()
{
    onhost_add_etchosts_entries
    onhost_prepareadmin
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

    local admuser=mkcldadm
    # FIXME kill the machine
    vmcp q $admuser && complain 193 "$admuser is not logged off"

    vmcp force $admuser || :
    # FIXME
    local vdev="a100"
    local ccw="0.0.$vdev"

    safely vmcp link to $admuser 0100 as $vdev mw pass=linux

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

    vmcp det v $vdev
}

function dirmaint_do_setupadmin()
{
    # FIXME
    echo "NEED TO SETUP ADMIN PROTOTYPE"

    # FIXME stop hardcoding
    local admuser=mkcldadm
    local cloudbr=mkcld

    vmcp q $admuser && complain 192 "$admuser is not logged off"

    vmcp s vswitch $cloudbr gra $admuser
    vmcp xautolog $admuser sync || exit $?
}
