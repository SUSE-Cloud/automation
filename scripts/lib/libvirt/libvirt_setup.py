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


def cpuflags():
    cpu_template = "cpu-default.xml"
    cpu_info = readfile("/proc/cpuinfo")
    if re.search("^CPU architecture.* 8", cpu_info, re.MULTILINE):
        cpu_template = "cpu-arm64.xml"
    if re.search("^vendor_id.*GenuineIntel", cpu_info, re.MULTILINE):
        cpu_template = "cpu-intel.xml"

    if re.search("flags.* npt", cpu_info):
        return ""

    return readfile(os.path.join(TEMPLATE_DIR, cpu_template))


def hypervisor_has_virtio(libvirt_type):
    return libvirt_type == "kvm"


def get_config(values, fin):
    template = string.Template(readfile(fin))
    return template.substitute(values)


def get_machine_arch():
    return os.uname()[4]


def get_default_machine():
    if 'aarch64' in get_machine_arch():
        return "virt"
    else:
        return "pc-0.14"


def admin_config(args, cpu_flags=cpuflags()):
    # add xml snippet to be able to mount a local dir via 9p in a VM
    localrepomount = ""
    if args.localreposrc and args.localrepotgt:
        local_repo_template = string.Template(readfile(
            "{0}/local-repository-mount.xml".format(TEMPLATE_DIR)))
        local_repo_values = dict(localreposdir_src=args.localreposrc,
                                 localreposdir_target=args.localrepotgt)
        localrepomount = local_repo_template.substitute(local_repo_values)

    values = dict(
        cloud=args.cloud,
        admin_node_memory=args.adminnodememory,
        adminvcpus=args.adminvcpus,
        cpuflags=cpu_flags,
        emulator=args.emulator,
        march=get_machine_arch(),
        machine=get_default_machine(),
        admin_node_disk=args.adminnodedisk,
        local_repository_mount=localrepomount)

    return get_config(values, os.path.join(TEMPLATE_DIR, "admin-node.xml"))


def net_config(args):
    cloud = args.cloud
    values = dict(
        cloud=cloud,
        cloudbr=args.cloudbr,
        admingw=args.admingw,
        adminnetmask=args.adminnetmask,
        cloudfqdn=args.cloudfqdn,
        adminip=args.adminip,
        forwardmode=args.forwardmode)

    return get_config(values, os.path.join(TEMPLATE_DIR, "admin-net.xml"))


def compute_config(args, cpu_flags=cpuflags(), machine=None):
    if not machine:
        machine = get_default_machine()

    libvirt_type = args.libvirttype
    alldevices = it.chain(it.chain(string.lowercase[1:]),
                          it.product(string.lowercase, string.lowercase))

    if hypervisor_has_virtio(libvirt_type):
        nicmodel = "virtio"
        targetdevprefix = "vd"
        targetbus = "virtio"
    else:
        nicmodel = "e1000"
        targetdevprefix = "sd"
        targetbus = "ide"
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
        raid_template = string.Template(readfile(
            "{0}/extra-volume.xml".format(TEMPLATE_DIR)))
        raid_values = {
            'volume_serial': "{0}-node{1}-raid{2}".format(
                serialcloud,
                args.nodecounter,
                i),
            'source_dev': "{0}/{1}.node{2}-raid{3}".format(
                args.vdiskdir,
                args.cloud,
                args.nodecounter,
                i),
            'target_dev': targetdevprefix + ''.join(alldevices.next()),
            'target_bus': targetbus
        }
        raidvolume += "\n" + raid_template.substitute(raid_values)

    cephvolume = ""
    if args.cephvolumenumber and args.cephvolumenumber > 0:
        for i in range(1, args.cephvolumenumber+1):
            ceph_template = string.Template(readfile(
                "{0}/extra-volume.xml".format(TEMPLATE_DIR)))
            ceph_values = dict(
                volume_serial="{0}-node{1}-ceph{2}".format(
                    serialcloud,
                    args.nodecounter,
                    i),
                source_dev="{0}/{1}.node{2}-ceph{3}".format(
                    args.vdiskdir,
                    args.cloud,
                    args.nodecounter,
                    i),
                target_dev=targetdevprefix + ''.join(alldevices.next()),
                target_bus=targetbus)
            cephvolume += "\n" + ceph_template.substitute(ceph_values)

    drbdvolume = ""
    if args.drbdserial:
        drbd_template = string.Template(readfile(
            "{0}/extra-volume.xml".format(TEMPLATE_DIR)))
        drbd_values = dict(
            volume_serial=args.drbdserial,
            source_dev="{0}/{1}.node{2}-drbd".format(
                args.vdiskdir,
                args.cloud,
                args.nodecounter),
            target_dev=targetdevprefix + ''.join(alldevices.next()),
            target_bus=targetbus)
        drbdvolume = drbd_template.substitute(drbd_values)

    values = dict(
        cloud=args.cloud,
        nodecounter=args.nodecounter,
        nodememory=nodememory,
        vcpus=args.vcpus,
        march=get_machine_arch(),
        machine=machine,
        cpuflags=cpu_flags,
        emulator=args.emulator,
        vdisk_dir=args.vdiskdir,
        raidvolume=raidvolume,
        cephvolume=cephvolume,
        drbdvolume=drbdvolume,
        macaddress=args.macaddress,
        nicmodel=nicmodel,
        target_dev=targetdevprefix + 'a',
        target_bus=targetbus,
        bootorder=args.bootorder)

    return get_config(values, os.path.join(TEMPLATE_DIR, "compute-node.xml"))


def domain_cleanup(dom):
    if dom.isActive():
        print("destroying {0}".format(dom.name()))
        dom.destroy()

    print("undefining {0}".format(dom.name()))
    dom.undefineFlags(flags=libvirt.VIR_DOMAIN_UNDEFINE_NVRAM)


def cleanup_one_node(args):
    conn = libvirt_connect()
    try:
        domain = conn.lookupByName(args.nodename)
        domain_cleanup(domain)
    except libvirt.libvirtError:
        print("no domain found with the name {0}".format(args.nodename))


def cleanup(args):
    conn = libvirt_connect()
    domains = [i for i in conn.listAllDomains()
               if i.name().startswith(args.cloud+"-")]

    for dom in domains:
        domain_cleanup(dom)

    for network in conn.listAllNetworks():
        if network.name() == args.cloud + "-admin":
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
    try:
        print("cleaning up {0}".format(vmname))
        dom = conn.lookupByName(vmname)
        domain_cleanup(dom)
    except libvirt.libvirtError:
        print("no domain for {0} active".format(vmname))

    xml = readfile(vmpath)
    print("defining VM from {0}".format(vmpath))
    conn.defineXML(xml)
    dom = conn.lookupByName(vmname)
    print("booting {0} VM".format(vmname))
    dom.create()
