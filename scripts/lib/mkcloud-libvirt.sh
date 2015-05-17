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

function libvirt_setupadmin()
{
    ${mkcloud_lib_dir}/libvirt/admin-config $cloud $admin_node_memory $adminvcpus $emulator $admin_node_disk "$localreposdir_src" "$localreposdir_target" > /tmp/$cloud-admin.xml
    ${mkcloud_lib_dir}/libvirt/net-config $cloud $cloudbr $admingw $adminnetmask $cloudfqdn $adminip $forwardmode > /tmp/$cloud-admin.net.xml
    libvirt_modprobe_kvm
    libvirt_start_daemon
    ${mkcloud_lib_dir}/libvirt/net-start /tmp/$cloud-admin.net.xml || exit $?
    ${mkcloud_lib_dir}/libvirt/vm-start /tmp/$cloud-admin.xml || exit $?
}
