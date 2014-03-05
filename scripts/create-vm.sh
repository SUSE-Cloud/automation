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
DEFAULT_USE_CPU_HOST=true
DEFAULT_CACHE_MODE=none

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
  -n, --no-cpu-host      Don´t use the option --cpu host for virt-install [$DEFAULT_USE_CPU_HOST]
  -d, --cache-mode MODE  Cache mode for disk
EOF
    exit "$exit_code"
}

parse_args () {
    hypervisor="$DEFAULT_HYPERVISOR"
    vm_disk_size="${DEFAULT_FSSIZE}G"
    vm_vcpus="$DEFAULT_CPUS"
    use_cpu_host=$DEFAULT_USE_CPU_HOST
    cache_mode="$DEFAULT_CACHE_MODE"

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
                vm_vcpus="$2"
                shift 2
                ;;
            -n|--no-cpu-host)
                use_cpu_host=false
                shift 1
                ;;
            -d|--cache-mode)
                cache_mode="$2"
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
    LANG=C virsh -c "$hypervisor" "$@"
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
    #     -d qcow2:$vm_disk,xvda,disk,w,0,cachemode=$cache_mode \
    #     -e \
    #     --nic bridge=$vbridge,model=virtio \
    #     --keymap en-us

    vm_cpu=""
    for plat in amd intel ; do
        if grep -i $plat /proc/cpuinfo ; then
            if [ `id -u` == 0 ] ; then
                echo "Running as root, invoking modprobe kvm_$plat."
                if [ $plat = "intel" ] ; then
                    if ! grep -q nested /etc/modprobe.d/99-local.conf ; then
                        echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/99-local.conf
                        modprobe -r kvm_intel
                    fi
                fi
                modprobe kvm_$plat
            fi
            if grep -q kvm_$plat /proc/modules && egrep -q "[Y1]" /sys/module/kvm_$plat/parameters/nested && $use_cpu_host; then
                echo "Host CPU ($plat) supports nested virtualization and kvm_$plat module is loaded with nested=1, adding --cpu host"
                vm_cpu="--cpu host"
            fi
        fi
    done

    virt-install \
        --connect "$hypervisor" \
        --virt-type kvm \
        --name "$vm_name" \
        --ram 2048 \
        --vcpus $vm_vcpus \
        $vm_cpu \
        "${opts[@]}" \
        --disk path="$vm_disk,format=qcow2,cache=$cache_mode" \
        --os-type=linux \
        --os-variant=sles11 \
        --network bridge="$vbridge" \
        --graphics vnc
}

main "$@"
