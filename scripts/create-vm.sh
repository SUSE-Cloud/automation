#!/bin/bash
#
# Creates a fresh KVM VM via libvirt.  This can be used to create both
# the Crowbar admin node VM and subsequent PXE-booting Crowbar nodes.
#
# FIXME: ideally this would eventually be replaced by one or more
# Vagrantfiles.

DEFAULT_HYPERVISOR="qemu:///system"
DEFAULT_FSSIZE="24"
DEFAULT_CPUS=4

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
  -c URI, --connect URI  Connect to hypervisor at URI [$DEFAULT_HYPERVISOR]
  -h, --help             Show this help and exit
  -s, --disksize XX      Size of VM-QCOW2-DISK (in GB) [$DEFAULT_FSSIZE]
  -C, --cpus XX          Number of virtual CPUs to assign [$DEFAULT_CPUS]
EOF
    exit "$exit_code"
}

parse_args () {
    hypervisor="$DEFAULT_HYPERVISOR"
    vm_disk_size="${DEFAULT_FSSIZE}G"
    vm_cpus="$DEFAULT_CPUS"

    while [ $# != 0 ]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -c|--connect)
                hypervisor="$2"
                shift 2
                ;;
            -s|--disksize)
                vm_disk_size="${2}G"
                shift 2
                ;;
            -C|--cpus)
                vm_cpus="$2"
                shift 2
                ;;
            -*)
                usage "Unrecognised option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        usage
    fi

    vm_name="$1"
    vm_disk="$2"
    vbridge="$3"
    filesystem="$4"
}

run_virsh () {
    virsh -c "$hypervisor" "$@"
}

valid_bridge () {
    local vbridge="$1"
    #/sbin/brctl show | egrep -q "^${vbridge}[[:space:]]"
    for net in $( run_virsh net-list | awk '/active/ {print $1}' ); do
        if run_virsh net-info "$net" | grep -qE "^Bridge:[[:space:]]+$vbridge\$"; then
            echo "Bridge is associated with '$net' network."
            return 0
        fi
    done
    return 1
}

main () {
    # if [ `id -u` != 0 ]; then
    #     echo "Please run as root." >&2
    #     exit 1
    # fi

    parse_args "$@"

    if ! valid_bridge "$vbridge"; then
        usage "$vbridge is not a valid bridge device name"
    fi

    if [ -e "$vm_disk" ]; then
        opts=(
            --import
            # virt-install doesn't support "readonly=true"
        )
    else
        echo "Creating $vm_disk with size $vm_disk_size as qcow2 image ..."
        qemu-img create -f qcow2 "$vm_disk" "$vm_disk_size"
        opts=(
            --pxe
            --boot network,hd,menu=on
        )
    fi

    if [ -n "$filesystem" ]; then
        opts+=(
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
        --connect "$hypervisor" \
        --virt-type kvm \
        --name "$vm_name" \
        --ram 2048 \
        --vcpus $vm_cpus \
        --cpu core2duo,+vmx \
        "${opts[@]}" \
        --disk path="$vm_disk,format=qcow2,cache=none" \
        --os-type=linux \
        --os-variant=sles11 \
        --network bridge="$vbridge" \
        --graphics vnc
}

main "$@"
