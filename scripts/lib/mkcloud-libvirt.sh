function libvirt_cleanup()
{
    allnodenames=$(seq --format="node%.0f" 1 $(($nodenumber + 20)))
    for name in admin $allnodenames ; do
        local vm=$cloud-$name
        if LANG=C virsh domstate $vm 2>/dev/null | grep -q running ; then
            safely virsh destroy $vm
        fi
        if virsh domid $vm >/dev/null 2>&1; then
            safely virsh undefine $vm
        fi
        local machine=qemu-$vm
        if test -x /usr/bin/machinectl && machinectl status $machine 2>/dev/null ; then
            safely machinectl terminate $machine # workaround bnc#916518
        fi
    done

    local net=$cloud-admin
    if virsh net-uuid $net >/dev/null 2>&1; then
        virsh net-destroy $net
        safely virsh net-undefine $net
    fi

    rm -f /var/run/libvirt/qemu/$cloud-*.xml /var/lib/libvirt/network/$cloud-*.xml \
            /etc/sysconfig/network/ifcfg-$cloudbr.$public_vlan
}

function libvirt_onhost_cpuflags_settings()
{ # used for admin and compute nodes
    cpuflags="<cpu match='minimum'>
            <model>qemu64</model>
            <feature policy='require' name='fxsr_opt'/>
            <feature policy='require' name='mmxext'/>
            <feature policy='require' name='lahf_lm'/>
            <feature policy='require' name='sse4a'/>
            <feature policy='require' name='abm'/>
            <feature policy='require' name='cr8legacy'/>
            <feature policy='require' name='misalignsse'/>
            <feature policy='require' name='popcnt'/>
            <feature policy='require' name='pdpe1gb'/>
            <feature policy='require' name='cx16'/>
            <feature policy='require' name='3dnowprefetch'/>
            <feature policy='require' name='cmp_legacy'/>
            <feature policy='require' name='monitor'/>
        </cpu>"
    grep -q "flags.* npt" /proc/cpuinfo || cpuflags=""

    if grep -q "vendor_id.*GenuineIntel" /proc/cpuinfo; then
        cpuflags="<cpu mode='custom' match='exact'>
            <model fallback='allow'>core2duo</model>
            <feature policy='require' name='vmx'/>
        </cpu>"
    fi
}

function libvirt_onhost_create_adminnode_config()
{
    local file=/tmp/$cloud-admin.xml
    libvirt_onhost_cpuflags_settings
    onhost_local_repository_mount

    cat > $file <<EOLIBVIRT
  <domain type='kvm'>
    <name>$cloud-admin</name>
    <memory>$admin_node_memory</memory>
    <currentMemory>$admin_node_memory</currentMemory>
    <vcpu>$adminvcpus</vcpu>
    <os>
      <type arch='x86_64' machine='pc-0.14'>hvm</type>
      <boot dev='hd'/>
    </os>
    <features>
      <acpi/>
      <apic/>
      <pae/>
    </features>
    $cpuflags
    <clock offset='utc'/>
    <on_poweroff>preserve</on_poweroff>
    <on_reboot>restart</on_reboot>
    <on_crash>restart</on_crash>
    <devices>
      <emulator>$emulator</emulator>
      <disk type='block' device='disk'>
        <driver name='qemu' type='raw' cache='unsafe'/>
        <source dev='$admin_node_disk'/>
        <target dev='vda' bus='virtio'/>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
      </disk>
      <interface type='network'>
        <mac address='52:54:00:77:77:70'/>
        <source network='$cloud-admin'/>
        <model type='virtio'/>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
      </interface>
      <serial type='pty'>
        <target port='0'/>
      </serial>
      <console type='pty'>
        <target type='serial' port='0'/>
      </console>
      <input type='mouse' bus='ps2'/>
      <graphics type='vnc' port='-1' autoport='yes'/>
      <video>
        <model type='cirrus' vram='9216' heads='1'/>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
      </video>
      <memballoon model='virtio'>
        <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
      </memballoon>
      $local_repository_mount
    </devices>
  </domain>
EOLIBVIRT
}

function libvirt_onhost_create_computenode_config()
{
    libvirt_onhost_cpuflags_settings
    nodeconfigfile=$1
    nodecounter=$2
    macaddress=$3
    cephvolume="$4"
    drbdvolume="$5"
    nicmodel=virtio
    hypervisor_has_virtio || nicmodel=e1000
    nodememory=$compute_node_memory
    [ "$nodecounter" = "1" ] && nodememory=$controller_node_memory

    cat > $nodeconfigfile <<EOLIBVIRT
<domain type='kvm'>
  <name>$cloud-node$nodecounter</name>
  <memory>$nodememory</memory>
  <currentMemory>$nodememory</currentMemory>
  <vcpu>$vcpus</vcpu>
  <os>
    <type arch='x86_64' machine='pc-0.14'>hvm</type>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  $cpuflags
  <clock offset='utc'/>
  <on_poweroff>preserve</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>$emulator</emulator>
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='unsafe'/>
      <source dev='$vdisk_dir/$cloud.node$nodecounter'/>
      <target dev='vda' bus='virtio'/>
      <boot order='2'/>
    </disk>
    $cephvolume
    $drbdvolume
    <interface type='network'>
      <mac address='$macaddress'/>
      <source network='$cloud-admin'/>
      <model type='$nicmodel'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
      <boot order='1'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes'/>
    <video>
      <model type='cirrus' vram='9216' heads='1'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
    </video>
  </devices>
</domain>
EOLIBVIRT

    if ! hypervisor_has_virtio ; then
        sed -i -e "s/<target dev='vd\([^']*\)' bus='virtio'/<target dev='sd\1' bus='ide'/" $nodeconfigfile
    fi
}

function libvirt_onhost_create_admin_network_config()
{
    local file=/tmp/$cloud-admin.net.xml
    # dont specify range
    # this allows to use the same network for cloud-nodes that get DHCP from crowbar
    # doc: http://libvirt.org/formatnetwork.html
    cat > $file <<EOLIBVIRTNET
  <network>
    <name>$cloud-admin</name>
    <bridge name='$cloudbr' stp='off' delay='0' />
    <mac address='52:54:00:AB:B1:77'/>
    <ip address='$admingw' netmask='$adminnetmask'>
      <dhcp>
        <host mac="52:54:00:77:77:70" name="crowbar.$cloudfqdn" ip="$adminip"/>
      </dhcp>
    </ip>
    <forward mode='$forwardmode'>
    </forward>
  </network>
EOLIBVIRTNET
}

function libvirt_modprobe_kvm()
{
    modprobe kvm-amd
    if [ ! -e /etc/modprobe.d/80-kvm-intel.conf ] ; then
        echo "options kvm-intel nested=1" > /etc/modprobe.d/80-kvm-intel.conf
        rmmod kvm-intel
    fi
    modprobe kvm-intel
}

# Returns success if the config was changed
function libvirt_configure_libvirtd()
{
    chkconfig libvirtd on

    local changed=

    # needed for HA/STONITH via libvirtd:
    confset /etc/libvirt/libvirtd.conf listen_tcp 1            && changed=y
    confset /etc/libvirt/libvirtd.conf listen_addr '"0.0.0.0"' && changed=y
    confset /etc/libvirt/libvirtd.conf auth_tcp '"none"'       && changed=y

    [ -n "$changed" ]
}

function libvirt_start_daemon()
{
    if libvirt_configure_libvirtd; then # config was changed
        service libvirtd stop
    fi
    safely service libvirtd start
    wait_for 300 1 '[ -S /var/run/libvirt/libvirt-sock ]' 'libvirt startup'
}

function libvirt_net_start()
{
    local network=$1
    if ! virsh net-dumpxml $network > /dev/null 2>&1; then
        virsh net-define /tmp/${network}.net.xml
    fi
    virsh net-start $network
}

function libvirt_vm_start()
{
    local vm=$1
    virsh destroy $vm 2>/dev/null
    virsh undefine $vm 2>/dev/null
    if ! virsh define /tmp/${vm}.xml ; then
        echo "=====================================================>>"
        complain 76 "Could not define VM for: $vm"
    fi
    if ! virsh start $vm ; then
        echo "=====================================================>>"
        complain 76 "Could not start VM for: $vm"
    fi
}

function libvirt_setupadmin()
{
    libvirt_create_adminnode_config
    libvirt_onhost_create_admin_network_config
    libvirt_modprobe_kvm
    libvirt_start_daemon
    libvirt_net_start $cloud-admin
    libvirt_vm_start $cloud-admin
}
