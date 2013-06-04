#!/bin/bash
#
# Creates a fresh KVM VM via libvirt.  This can be used to create both
# the Crowbar admin node VM and subsequent PXE-booting Crowbar nodes.
#
# FIXME: ideally this would eventually be replaced by one or more
# Vagrantfiles.

usage () {
    # Call as: usage [EXITCODE] [USAGE MESSAGE]
    exit_code=1
    if [[ "$1" == [0-9] ]]; then
        exit_code="$1"
        shift
    fi
    if [ -n "$1" ]; then
        echo >&2 "$*"
        echo
    fi

    me=`basename $0`

    cat <<EOF >&2
Usage: $me [options] VM-NAME VM-QCOW2-DISK VBRIDGE [FILESYSTEM-PATH]

If VM-QCOW2-DISK does not already exist, it will be created.

FILESYSTEM-PATH should be a directory on the host which you want
share to the guest via a 9p virtio passthrough mount.

Options:
  -h, --help     Show this help and exit
EOF
    exit "$exit_code"
}

parse_args () {
    if [ "$1" == '-h' ] || [ "$1" == '--help' ]; then
        usage 0
    fi

    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        usage
    fi

    vm_name="$1"
    vm_disk="$2"
    vbridge="$3"
    filesystem="$4"
}

main () {
    # if [ `id -u` != 0 ]; then
    #     echo "Please run as root." >&2
    #     exit 1
    # fi

    parse_args "$@"

    if ! /sbin/brctl show | egrep -q "^${vbridge}[[:space:]]"; then
        usage "$vbridge is not a valid bridge device name"
    fi

    if [ -e "$vm_disk" ]; then
        opts=(
            --import
            # virt-install doesn't support "readonly=true"
        )
    else
        echo "Creating $vm_disk as qcow2 image ..."
        qemu-img create -f qcow2 "$vm_disk" 4G
        opts=( --pxe )
    fi

    if [ -n "$filesystem" ]; then
        opts=(
            ${opts[@]}
            --filesystem $filesystem,install
        )
    fi

    # vm-install \
    #     -n $vm_name \
    #     -o sles11 \
    #     -c4 \
    #     -m2048 -M2048 \
    #     -d qcow2:$vm_disk,xvda,disk,w,0,cachemode=none \
    #     -e \
    #     --nic bridge=$vbridge,model=virtio \
    #     --keymap en-us

    virt-install \
        --connect qemu:///system \
        --virt-type kvm \
        --name $vm_name \
        --ram 2048 \
        --vcpus 4 \
        ${opts[@]} \
        --disk path=$vm_disk,format=qcow2,cache=none \
        --os-type=linux \
        --os-variant=sles11 \
        --network bridge=$vbridge \
        --graphics vnc
}

main "$@"
