#!/usr/bin/env python
import os
import re
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
            network="admin",
            cloud="cloud",
            bridge="cloudbr",
            gateway="192.168.124.1",
            netmask="255.255.248.0",
            cloudfqdn="unittest.suse.de",
            hostip="192.168.124.10",
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

    def net_config_common_arguments(self):
        args = Arguments()
        args.network = "admin"
        args.cloud = "cloud"
        args.bridge = "cloudbr"
        args.cloudfqdn = "unittest.suse.de"
        args.forwardmode = "nat"
        return args

    def test_net_config(self):
        args = self.net_config_common_arguments()
        args.ipv6 = False
        args.gateway = "192.168.124.1"
        args.netmask = "255.255.248.0"
        args.hostip = "192.168.124.10"

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.net.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.net_config(args)
        self.assertEqual(is_config, should_config)

    def test_ipv6_net_config(self):
        args = self.net_config_common_arguments()
        args.ipv6 = True
        args.gateway = "fd00::1"
        args.netmask = "112"
        args.hostip = "fd00::10"

        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.netv6.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.net_config(args)
        self.assertEqual(is_config, should_config)


def filter_vm_xml(xmlstr):
    """filter libvirt VM instance xml to drop host-specific parts"""
    xmlstr = re.sub("machine='[^']*'>", "machine='pc-0.14'>", xmlstr)
    return xmlstr


def default_test_args(args):
    args.cloud = "cloud"
    args.nodecounter = 1
    args.macaddress = ["52:54:01:77:77:01"]
    args.ironicnic = -1
    args.controller_raid_volumes = 0
    args.cephvolumenumber = 1
    args.computenodememory = 2097152
    args.controllernodememory = 5242880
    args.libvirttype = "kvm"
    args.vcpus = 1
    args.emulator = "/bin/false"
    args.vdiskdir = "/dev/cloud"
    args.drbdserial = ""
    args.bootorder = 3
    args.numcontrollers = 1
    args.firmwaretype = "bios"
    args.localreposrc = None
    args.localrepotgt = None
    args.ipmi = False


class TestLibvirtAdminConfig(unittest.TestCase):

    def setUp(self):
        self.args = Arguments()
        self.args.cloud = "cloud"
        self.args.adminnodememory = 2097152
        self.args.adminvcpus = 1
        self.args.emulator = "/bin/false"
        self.args.adminnodedisk = "/dev/cloud/cloud.admin"
        self.args.firmwaretype = ""
        self.args.localreposrc = ""
        self.args.localrepotgt = ""
        self.cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

    def test_admin_config(self):
        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.admin_config(self.args, self.cpu_flags)
        self.assertEqual(is_config, should_config)

    def test_admin_config_uefi(self):
        self.args.firmwaretype = "uefi"
        should_config = libvirt_setup.readfile(
            "{0}/cloud-admin-uefi.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.admin_config(self.args, self.cpu_flags)
        self.assertEqual(is_config, should_config)


class TestLibvirtComputeConfig(unittest.TestCase):

    def setUp(self):
        self.args = Arguments()
        default_test_args(self.args)
        self.cpu_flags = libvirt_setup.readfile(
            "{0}/cpu-intel.xml".format(TEMPLATE_DIR))

    def _compare_configs(self, args, xml_format):
        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1-{1}.xml".format(FIXTURE_DIR, xml_format))
        is_config = libvirt_setup.compute_config(args, self.cpu_flags)
        self.assertEqual(filter_vm_xml(is_config), should_config)

    def test_compute_config(self):
        should_config = libvirt_setup.readfile(
            "{0}/cloud-node1.xml".format(FIXTURE_DIR))
        is_config = libvirt_setup.compute_config(self.args, self.cpu_flags)
        self.assertEqual(filter_vm_xml(is_config), should_config)

    # add test for UEFI boot of compute node image
    def test_uefi_compute_config(self):
        args = self.args
        args.firmwaretype = "uefi"
        self._compare_configs(args, "uefi")

    def test_xen_compute_config(self):
        args = self.args
        args.libvirttype = "xen"
        self._compare_configs(args, "xen")

    # add extra disk for raid and 2 volumes for ceph
    def test_compute_config_with_raid(self):
        args = self.args
        args.controller_raid_volumes = 2
        args.cephvolumenumber = 2
        self._compare_configs(args, "raid")

    def test_compute_config_with_9pnet_virtio_mount(self):
        args = self.args
        args.localreposrc = '/var/cache/mkcloud/cloud'
        args.localrepotgt = '/repositories'
        self._compare_configs(args, '9pnet-mount')


if __name__ == '__main__':
    unittest.main()
