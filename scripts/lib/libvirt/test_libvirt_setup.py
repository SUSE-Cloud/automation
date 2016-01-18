#!/usr/bin/env python

import argparse
import os
import tempfile
import unittest

import libvirt_setup

FIXTURE_DIR = os.path.join(os.path.dirname(__file__), 'fixtures')
TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), 'templates')


# helper method to create argparse object
def arg_parse(args):
    parser = argparse.ArgumentParser("ArgParser")
    for arg in args:
        key, argtype, value = arg
        parser.add_argument(key, type=argtype)
    values = [arg[2] for arg in args]
    return parser.parse_args(values)


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
        args = arg_parse(
            [("cloud", str, "cloud"),
             ("cloudbr", str, "cloudbr"),
             ("admingw", str, "192.168.124.1"),
             ("adminnetmask", str, "255.255.248.0"),
             ("cloudfqdn", str, "unittest.suse.de"),
             ("adminip", str, "192.168.124.10"),
             ("forwardmode", str, "nat")])

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.net_config(args)
        self.assertEqual(is_config, should_config)


class TestLibvirtAdminConfig(unittest.TestCase):

    def test_admin_config(self):
        args = arg_parse(
            [("cloud", str, "cloud"),
             ("adminnodememory", str, "2097152"),
             ("adminvcpus", str, "1"),
             ("emulator", str, "/usr/bin/qemu-system-x86_64"),
             ("adminnodedisk", str, "/dev/cloud/cloud.admin"),
             ("localreposrc", str, ""),
             ("localreposgt", str, "")])
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.admin_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)


class TestLibvirtComputeConfig(unittest.TestCase):

    def test_compute_config(self):
        args = arg_parse(
            [("cloud", str, "cloud"),
             ("nodecounter", int, "1"),
             ("macaddress", str, "52:54:01:77:77:01"),
             ("controller_raid_volumes", int, "0"),
             ("cephvolumenumber", str, "1"),
             ("drbdserial", str, ""),
             ("computenodememory", str, "2097152"),
             ("controllernodememory", str, "5242880"),
             ("libvirttype", str, "kvm"),
             ("vcpus", str, "1"),
             ("emulator", str, "/usr/bin/qemu-system-x86_64"),
             ("vdiskdir", str, "/dev/cloud"),
             ("bootorder", str, "3"),
             ("numcontrollers", int, "1")])
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)

    # add extra disk for raid and 2 volumes for ceph
    def test_compute_config_with_raid(self):
        args = arg_parse(
            [("cloud", str, "cloud"),
             ("nodecounter", int, "1"),
             ("macaddress", str, "52:54:01:77:77:01"),
             ("controller_raid_volumes", int, "2"),
             ("cephvolumenumber", str, "2"),
             ("drbdserial", str, ""),
             ("computenodememory", str, "2097152"),
             ("controllernodememory", str, "5242880"),
             ("libvirttype", str, "kvm"),
             ("vcpus", str, "1"),
             ("emulator", str, "/usr/bin/qemu-system-x86_64"),
             ("vdiskdir", str, "/dev/cloud"),
             ("bootorder", str, "3"),
             ("numcontrollers", int, "1")])
        cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1-raid.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(args, cpu_flags)
        self.assertEqual(is_config, should_config)

if __name__ == '__main__':
    unittest.main()
