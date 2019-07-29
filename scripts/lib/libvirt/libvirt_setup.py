from __future__ import print_function

import glob
import itertools as it
import os
import re
import string
import xml.etree.ElementTree as ET

import libvirt

TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')


def libvirt_connect():
    return libvirt.open("qemu:///system")


def readfile(fname):
    with open(os.path.join(os.path.dirname(__file__), fname)) as f:
        ret = f.read()
    return ret


def remove_files(files):
    for f in glob.glob(files):
        print("removing {0}".format(f))
        os.remove(f)


def cpuflags(pcipassthrough=False):
    cpu_template = "cpu-default.xml"
    cpu_info = readfile("/proc/cpuinfo")
    if re.search("^CPU architecture.* 8", cpu_info, re.MULTILINE):
        cpu_template = "cpu-arm64.xml"
    elif re.search("^vendor_id.*GenuineIntel", cpu_info, re.MULTILINE):
        cpu_template = get_intel_cputemplate(pcipassthrough)
    elif re.search("^vendor_id.*AuthenticAMD", cpu_info, re.MULTILINE):
        cpu_template = "cpu-amd.xml"
    elif re.search("^vendor_id.*IBM/S390", cpu_info, re.MULTILINE):
        cpu_template = "cpu-s390x.xml"

    return readfile(os.path.join(TEMPLATE_DIR, cpu_template))


def get_intel_cputemplate(pcipassthrough=False):
    cpu_template = "cpu-intel.xml"
    if pcipassthrough:
        cpu_template = "cpu-intel-pcipassthrough.xml"
    return cpu_template


def hypervisor_has_virtio(libvirt_type):
    return libvirt_type == "kvm"


def get_config(values, fin):
    template = string.Template(readfile(fin))
    return template.substitute(values)


def get_machine_arch():
    return os.uname()[4]


def get_os_loader(firmware_type=None):
    path = None
    template = "<loader readonly='yes' type='pflash'>%s</loader>"
    if 'aarch64' in get_machine_arch():
        path = "/usr/share/qemu/aavmf-aarch64-code.bin"
    elif 'x86_64' in get_machine_arch() and firmware_type == "uefi":
        path = "/usr/share/qemu/ovmf-x86_64-ms-code.bin"
    return template % path if path else ""


def get_video_devices():
    if 'aarch64' in get_machine_arch():
        return ''

    if 's390x' in get_machine_arch():
        return ''

    return readfile(os.path.join(TEMPLATE_DIR, 'video-default.xml'))


# to workaround bnc#946020+bnc#946068+bnc#997358+1064517 we use the 2.1
# machine type if it is available
def get_default_machine(emulator):
    if 'aarch64' in get_machine_arch():
        return "virt"
    elif 's390x' in get_machine_arch():
        return "s390-ccw-virtio"
    else:
        machine = "pc-i440fx-2.1"
        if os.system("%(emulator)s -machine help | grep -q %(machine)s" % ({
                     'emulator': emulator, 'machine': machine})) != 0:
            return "pc-0.14"
        return machine


def get_console_type():
    if 's390x' in get_machine_arch():
        return 'sclp'
    return 'serial'


def get_memballoon_type():
    if 's390x' in get_machine_arch():
        return """    <memballoon model='virtio' autodeflate='on'>
    </memballoon>"""

    return """    <memballoon model='virtio' autodeflate='on'>
      <address type='pci' bus='0x02' slot='0x01'/>
    </memballoon>"""


def get_serial_device():
    if 's390x' in get_machine_arch():
        return ''

    return """    <serial type='pty'>
      <target port='0'/>
    </serial>"""


def get_mainnic_address(index):
    mainnicaddress = "<address type='pci' bus='0x01' slot='%s'/>" % \
        (hex(index + 0x1))
    if 's390x' in get_machine_arch():
        mainnicaddress = "<address type='ccw' cssid='0xfe' ssid='0x0' " \
            "devno='%s'/>" % \
            (hex(index + 0x1))
    return mainnicaddress


def get_maindisk_address():
    maindiskaddress = "<address type='pci' slot='0x04'/>"

    if 's390x' in get_machine_arch():
        maindiskaddress =  \
            "<address type='ccw' cssid='0xfe' ssid='0x0' devno='0x2'/>"

    return maindiskaddress


def _get_localrepomount_config(args):
    # add xml snippet to be able to mount a local dir via 9p in a VM
    localrepomount = ""
    if args.localreposrc and args.localrepotgt:
        local_repo_template = string.Template(readfile(
            "{0}/local-repository-mount.xml".format(TEMPLATE_DIR)))
        local_repo_values = dict(localreposdir_src=args.localreposrc,
                                 localreposdir_target=args.localrepotgt)
        localrepomount = local_repo_template.substitute(local_repo_values)
    return localrepomount


def admin_config(args, cpu_flags=cpuflags()):
    # add xml snippet to be able to mount a local dir via 9p in a VM
    localrepomount = _get_localrepomount_config(args)

    values = dict(
        cloud=args.cloud,
        consoletype=get_console_type(),
        admin_node_memory=args.adminnodememory,
        adminvcpus=args.adminvcpus,
        cpuflags=cpu_flags,
        emulator=args.emulator,
        march=get_machine_arch(),
        machine=get_default_machine(args.emulator),
        osloader=get_os_loader(firmware_type=args.firmwaretype),
        memballoon=get_memballoon_type(),
        maindiskaddress=get_maindisk_address(),
        mainnicaddress=get_mainnic_address(0),
        admin_node_disk=args.adminnodedisk,
        videodevices=get_video_devices(),
        serialdevice=get_serial_device(),
        local_repository_mount=localrepomount)

    return get_config(values, os.path.join(TEMPLATE_DIR, "admin-node.xml"))


def get_net_for_nic(args, index):
    return 'ironic' if index == args.ironicnic else 'admin'


def net_interfaces_config(args, nicmodel):
    nic_configs = []
    bootorderoffset = 2
    nicdriver = ''

    if 'virtio' in nicmodel:
        nicdriver = '<driver name="vhost" queues="2"/>'

    for index, mac in enumerate(args.macaddress):
        mainnicaddress = get_mainnic_address(index)
        values = dict(
            cloud=args.cloud,
            nodecounter=args.nodecounter,
            nicindex=index,
            net=get_net_for_nic(args, index),
            macaddress=mac,
            nicdriver=nicdriver,
            nicmodel=nicmodel,
            bootorder=bootorderoffset + (index * 10),
            mainnicaddress=mainnicaddress)
        nic_configs.append(
            get_config(values, os.path.join(TEMPLATE_DIR,
                                            "net-interface.xml")))
    return "\n".join(nic_configs)


def net_config(args):
    template_file = "%s-net.xml" % args.network
    if args.ipv6:
        template_file = "%s-net-v6.xml" % args.network
    values = {
        'cloud': args.cloud,
        'bridge': args.bridge,
        'gateway': args.gateway,
        'netmask': args.netmask,
        'cloudfqdn': args.cloudfqdn,
        'hostip': args.hostip,
        'forwardmode': args.forwardmode
    }

    return get_config(values, os.path.join(TEMPLATE_DIR, template_file))


def merge_dicts(d1, d2):
    return dict(it.chain(d1.items(), d2.items()))


def compute_config(args, cpu_flags=cpuflags()):
    # add xml snippet to be able to mount a local dir via 9p in a VM
    localrepomount = _get_localrepomount_config(args)

    libvirt_type = args.libvirttype
    alldevices = it.chain(it.chain(string.ascii_lowercase[1:]),
                          it.product(string.ascii_lowercase,
                                     string.ascii_lowercase))

    configopts = {
        'nicmodel': 'e1000',
        'emulator': args.emulator,
        'vdisk_dir': args.vdiskdir,
        'memballoon': get_memballoon_type(),
    }

    if hypervisor_has_virtio(libvirt_type):
        targetdevprefix = "vd"
        configopts['nicmodel'] = 'virtio'
        configopts['target_bus'] = 'virtio'
        if 's390x' in get_machine_arch():
            target_address = \
                "<address type='ccw' cssid='0xfe' ssid='0x0' devno='{0}'/>"
        else:
            target_address = "<address type='pci' slot='{0}'/>"
    else:
        targetdevprefix = "sd"
        configopts['target_bus'] = 'ide'
        configopts['memballoon'] = "    <memballoon model='none' />"
        target_address = "<address type='drive' controller='0' " \
            "bus='{0}' target='0' unit='0'/>"

    # override nic model for ironic setups
    if args.ironicnic >= 0 and not args.pcipassthrough:
        configopts['nicmodel'] = 'e1000'

    controller_raid_volumes = args.controller_raid_volumes
    if args.nodecounter > args.numcontrollers:
        controller_raid_volumes = 0
        nodememory = args.computenodememory
    else:
        nodememory = args.controllernodememory

    raidvolume = ""
    # a valid serial is defined in libvirt-1.2.18/src/qemu/qemu_command.c:
    serialcloud = re.sub("[^A-Za-z0-9-_]", "_", args.cloud)
    for i in range(1, controller_raid_volumes):
        raid_template = string.Template(
            readfile(os.path.join(TEMPLATE_DIR, "extra-volume.xml")))
        raidvolume += "\n" + raid_template.substitute(merge_dicts({
            'volume_serial': "{0}-node{1}-raid{2}".format(
                serialcloud,
                args.nodecounter,
                i),
            'source_dev': "{0}/{1}.node{2}-raid{3}".format(
                args.vdiskdir,
                args.cloud,
                args.nodecounter,
                i),
            'target_dev': targetdevprefix + ''.join(next(alldevices)),
            'target_address': target_address.format(hex(0x10 + i)),
        }, configopts))

    cephvolume = ""
    if args.cephvolumenumber and args.cephvolumenumber > 0:
        for i in range(1, args.cephvolumenumber + 1):
            ceph_template = string.Template(
                readfile(os.path.join(TEMPLATE_DIR, "extra-volume.xml")))
            cephvolume += "\n" + ceph_template.substitute(merge_dicts({
                'volume_serial': "{0}-node{1}-ceph{2}".format(
                    serialcloud,
                    args.nodecounter,
                    i),
                'source_dev': "{0}/{1}.node{2}-ceph{3}".format(
                    args.vdiskdir,
                    args.cloud,
                    args.nodecounter,
                    i),
                'target_dev': targetdevprefix + ''.join(next(alldevices)),
                'target_address': target_address.format(hex(0x16 + i)),
            }, configopts))

    drbdvolume = ""
    if args.drbdserial:
        drbd_template = string.Template(
            readfile(os.path.join(TEMPLATE_DIR, "extra-volume.xml")))
        drbdvolume = drbd_template.substitute(merge_dicts({
            'volume_serial': args.drbdserial,
            'source_dev': "{0}/{1}.node{2}-drbd".format(
                args.vdiskdir,
                args.cloud,
                args.nodecounter),
            'target_dev': targetdevprefix + ''.join(next(alldevices)),
            'target_address': target_address.format('0x1f')},
            configopts))

    machine = ""
    machine = get_default_machine(args.emulator)
    pciecontrollers = ""
    iommudevice = ""
    extravolume = ""
    if args.pcipassthrough and not args.drbdserial:
        volume_template = string.Template(
            readfile(os.path.join(TEMPLATE_DIR, "extra-volume.xml")))
        extravolume = volume_template.substitute(merge_dicts({
            'volume_serial': "{0}-node{1}-extra".format(
                args.cloud,
                args.nodecounter),
            'source_dev': "{0}/{1}.node{2}-extra".format(
                args.vdiskdir,
                args.cloud,
                args.nodecounter),
            'target_dev': targetdevprefix + ''.join(next(alldevices)),
            'target_address': target_address.format('0x1d')},
            configopts))
        iommudevice = readfile(os.path.join(
            TEMPLATE_DIR, 'iommu-device-default.xml'))
        machine = "q35"
        pciecontrollers = readfile(os.path.join(
            TEMPLATE_DIR, 'pcie-root-bridge-default.xml'))

    if args.ipmi and not args.pcipassthrough:
        values = dict(
          nodecounter=args.nodecounter
        )
        ipmi_config = get_config(values,
                                 os.path.join(TEMPLATE_DIR, "ipmi-device.xml"))
    else:
        ipmi_config = ''

    if not hypervisor_has_virtio(libvirt_type) and not args.pcipassthrough:
        target_address = target_address.format('0')
        # map virtio addr to ide:
        raidvolume = raidvolume.replace("bus='0x17'", "bus='1'")
        cephvolume = cephvolume.replace("bus='0x17'", "bus='1'")
        drbdvolume = drbdvolume.replace("bus='0x17'", "bus='1'")

    values = dict(
        cloud=args.cloud,
        nodecounter=args.nodecounter,
        nodememory=nodememory,
        vcpus=args.vcpus,
        march=get_machine_arch(),
        machine=machine,
        osloader=get_os_loader(firmware_type=args.firmwaretype),
        cpuflags=cpu_flags,
        consoletype=get_console_type(),
        raidvolume=raidvolume,
        cephvolume=cephvolume,
        drbdvolume=drbdvolume,
        pciecontrollers=pciecontrollers,
        extravolume=extravolume,
        iommudevice=iommudevice,
        nics=net_interfaces_config(args, configopts["nicmodel"]),
        maindiskaddress=get_maindisk_address(),
        videodevices=get_video_devices(),
        target_dev=targetdevprefix + 'a',
        serialdevice=get_serial_device(),
        ipmidevice=ipmi_config,
        target_address=target_address.format('0x0a'),
        bootorder=args.bootorder,
        local_repository_mount=localrepomount)

    return get_config(merge_dicts(values, configopts),
                      os.path.join(TEMPLATE_DIR, "compute-node.xml"))


def domain_cleanup(dom):
    if dom.isActive():
        print("destroying {0}".format(dom.name()))
        dom.destroy()

    print("undefining {0}".format(dom.name()))
    try:
        dom.undefineFlags(flags=libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)
    except Exception:
        try:
            dom.undefine()
        except Exception:
            print("failed to undefine {0}".format(dom.name()))


# Incredibly, libvirt's API offers no way to quietly look up a domain
# by name without risking an exception *and* an error message being
# spewed to STDERR if the domain doesn't exist.  And we need to avoid
# the error message, because it would generate false positives for
# anything which scans output for errors, such as the Jenkins Log
# Parser plugin.  So we use our own wrapper here, which hacks around
# the limited API by instead using the less risky listAllDomains().
# It returns the domain object if a domain is found with the requested
# name, otherwise None.
def get_domain_by_name(conn, name):
    return next((domain for domain in conn.listAllDomains()
                 if domain.name() == name),
                None)


def cleanup_one_node(args):
    conn = libvirt_connect()
    domain = get_domain_by_name(conn, args.nodename)
    if domain:
        domain_cleanup(domain)
    else:
        print("no domain found with the name {0}".format(args.nodename))


def cleanup(args):
    conn = libvirt_connect()
    domains = [i for i in conn.listAllDomains()
               if i.name().startswith(args.cloud + "-")]

    for dom in domains:
        domain_cleanup(dom)

    for network in conn.listAllNetworks():
        if network.name() in (args.cloud + "-admin", args.cloud + "-ironic"):
            print("Cleaning up network {0}".format(network.name()))
            if network.isActive():
                network.destroy()
            network.undefine()

    remove_files("/tmp/{0}-*.xml".format(args.cloud))
    remove_files("/var/run/libvirt/qemu/{0}-*.xml".format(args.cloud))
    remove_files("/var/lib/libvirt/network/{0}-*.xml".format(args.cloud))
    remove_files("/etc/sysconfig/network/ifcfg-{0}.{1}".format(
        args.cloudbr, args.vlan_public))


def xml_get_value(path, attrib):
    tree = ET.parse(path)
    return tree.find(attrib).text


def net_start(args):
    conn = libvirt_connect()
    netpath = args.netpath
    netname = xml_get_value(args.netpath, "name")
    print("defining network from {0}".format(netname))
    # Get the names of active and inactive network domains.
    networks = [network.name() for network in conn.listAllNetworks()]
    # If network domain exists
    if netname not in networks:
        print("defining network from {0}".format(netpath))
        xml = readfile(netpath)
        conn.networkDefineXML(xml)


def vm_start(args):
    conn = libvirt_connect()
    vmpath = args.vmpath
    vmname = xml_get_value(vmpath, "name")
    # cleanup old domain
    print("cleaning up {0}".format(vmname))
    dom = get_domain_by_name(conn, vmname)
    if dom:
        domain_cleanup(dom)
    else:
        print("no domain for {0} active".format(vmname))

    xml = readfile(vmpath)
    print("defining VM from {0}".format(vmpath))
    conn.defineXML(xml)
    # Contrary to the above lookup, if this one fails, something has
    # gone badly wrong so we *want* an exception and ugly error
    # message.
    dom = conn.lookupByName(vmname)
    print("booting {0} VM".format(vmname))
    dom.create()
