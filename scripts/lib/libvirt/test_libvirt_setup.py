#!/usr/bin/env python
import os
import tempfile
import unittest

import libvirt_setup

FIXTURE_DIR = os.path.join(os.path.dirname(__file__), 'fixtures')
TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')


# helper class to pass arguments
class Arguments(object):
    pass


class TestLibvirtHelpers(unittest.TestCase):

    def test_readfile(self):
        ret = libvirt_setup.readfile(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR))
        self.assertIs(type(ret), str)

    def test_remove_files(self):
        tmpfile = tempfile.NamedTemporaryFile(suffix=".unittest", delete=False)
        libvirt_setup.remove_files("/tmp/tmp*.unittest")
        self.assertFalse(os.access("/tmp/{0}".format(tmpfile.name), os.X_OK))

    def test_get_config(self):
        fin = "{0}/admin-net.xml".format(TEMPLATE_DIR)
        values = dict(
            cloud="cloud",
            cloudbr="cloudbr",
            admingw="192.168.124.1",
            adminnetmask="255.255.248.0",
            cloudfqdn="unittest.suse.de",
            adminip="192.168.124.10",
            forwardmode="nat")
        is_config = libvirt_setup.get_config(values, fin)
        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR))
        self.assertTrue(type(is_config), str)
        self.assertEqual(is_config, should_config)

    def test_cpuflags(self):
        ret = libvirt_setup.cpuflags()
        self.assertIs(type(ret), str)
        self.assertIsNot(ret, None)

    def test_hypervisor_has_virtio(self):
        ret = libvirt_setup.hypervisor_has_virtio("kvm")
        self.assertTrue(ret, "Hypervisor has virtio")
        for libvirt_type in ["xen", "hyperv"]:
            ret = libvirt_setup.hypervisor_has_virtio(libvirt_type)
            self.assertFalse(ret, "Hypervisor has no virtio")

    def test_xml_get_value(self):
        ret = libvirt_setup.xml_get_value(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR), "name")
        self.assertEqual(ret, "cloud-admin")


class TestLibvirtNetConfig(unittest.TestCase):

    def test_net_config(self):
        args = Arguments()
        args.cloud = "cloud"
        args.cloudbr = "cloudbr"
        args.admingw = "192.168.124.1"
        args.adminnetmask = "255.255.248.0"
        args.cloudfqdn = "unittest.suse.de"
        args.adminip = "192.168.124.10"
        args.forwardmode = "nat"

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.net_config(args)
        self.assertEqual(is_config, should_config)


class TestLibvirtAdminConfig(unittest.TestCase):

    def test_admin_config(self):
        args = Arguments()
        args.cloud = "cloud"
        args.adminnodememory = 2097152
        args.adminvcpus = 1
        args.emulator = "/usr/bin/qemu-system-x86_64"
        args.adminnodedisk = "/dev/cloud/cloud.admin"
        args.localreposrc = ""
        args.localrepotgt = ""
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.admin_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)


class TestLibvirtComputeConfig(unittest.TestCase):

    def test_compute_config(self):
        args = Arguments()
        args.cloud = "cloud"
        args.nodecounter = 1
        args.macaddress = "52:54:01:77:77:01"
        args.controller_raid_volumes = 0
        args.cephvolumenumber = 1
        args.computenodememory = 2097152
        args.controllernodememory = 5242880
        args.libvirttype = "kvm"
        args.vcpus = 1
        args.emulator = "/usr/bin/qemu-system-x86_64"
        args.vdiskdir = "/dev/cloud"
        args.drbdserial = ""
        args.bootorder = 3
        args.numcontrollers = 1
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)

    def test_xen_compute_config(self):
        args = Arguments()
        args.cloud = "cloud"
        args.nodecounter = 1
        args.macaddress = "52:54:01:77:77:01"
        args.controller_raid_volumes = 0
        args.cephvolumenumber = 1
        args.computenodememory = 2097152
        args.controllernodememory = 5242880
        args.libvirttype = "xen"
        args.vcpus = 1
        args.emulator = "/usr/bin/qemu-system-x86_64"
        args.vdiskdir = "/dev/cloud"
        args.drbdserial = ""
        args.bootorder = 3
        args.numcontrollers = 1
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))
        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1-xen.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)

    # add extra disk for raid and 2 volumes for ceph
    def test_compute_config_with_raid(self):
        args = Arguments()
        args.cloud = "cloud"
        args.nodecounter = 1
        args.macaddress = "52:54:01:77:77:01"
        args.controller_raid_volumes = 2
        args.cephvolumenumber = 2
        args.computenodememory = 2097152
        args.controllernodememory = 5242880
        args.libvirttype = "kvm"
        args.vcpus = 1
        args.emulator = "/usr/bin/qemu-system-x86_64"
        args.vdiskdir = "/dev/cloud"
        args.drbdserial = ""
        args.bootorder = 3
        args.numcontrollers = 1
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1-raid.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)


if __name__ == '__main__':
    unittest.main()
