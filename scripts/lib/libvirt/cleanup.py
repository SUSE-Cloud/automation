#!/usr/bin/env python

from __future__ import print_function
import libvirt
import sys
import os
import glob
import subprocess
import argparse

conn = libvirt.open("qemu:///system")
if not conn:
    print("Failed to open connection to the hypervisor")
    sys.exit(1)

parser = argparse.ArgumentParser(description="Cleanup libvirt resources.")
parser.add_argument("cloud", type=str, help="Name of the cloud")
parser.add_argument("nodenumber", type=int, help="Number of nodes")
parser.add_argument("cloudbr", type=str, help="Name of the virtual bridge")
parser.add_argument("public_vlan", type=str, help="Name of the public vlan")

args = parser.parse_args()


def remove_files(files):
    for f in glob.glob(files):
        print("removing {0}".format(f))
        os.remove(f)


def main():
    devnull = open(os.devnull, "w")
    allnodenames = ["admin"]
    allnodenames.extend("node%s" % i for i in range(1, args.nodenumber + 20))

    for nodename in allnodenames:
        try:
            vm = "{0}-{1}".format(args.cloud, nodename)
            dom = conn.lookupByName(vm)
            if dom.isActive():
                print("destroying {0}".format(dom.name()))
                dom.destroy()
            if dom.ID():
                print("undefining {0}".format(dom.name()))
                dom.undefine()

            machine = "{0}-{1}".format("qemu", vm)
            machinectl = os.access("/usr/bin/machinectl", os.X_OK)
            if machinectl:
                machine_status = subprocess.call(
                    ["machinectl", "status", machine],
                    stdout=devnull, stderr=subprocess.STDOUT)
                if machine_status == 0:
                    # workaround bnc#916518
                    subprocess.call(["machinectl", "terminate", machine])
        except libvirt.libvirtError:
            print("...skipping undefined domains")

    try:
        net_name = "{0}-admin".format(args.cloud)
        network = conn.networkLookupByName(net_name)
        print("destroying {0}".format(net_name))
        network.destroy()
        print("undefining {0}".format(net_name))
        network.undefine()
    except libvirt.libvirtError:
        print("...skipping undefined network")

    remove_files("/var/run/libvirt/qemu/{0}-*.xml".format(args.cloud))
    remove_files("/var/lib/libvirt/network/{0}-*.xml".format(args.cloud))
    remove_files("/etc/sysconfig/network/ifcfg-{0}.{1}".format(
        args.cloudbr, args.public_vlan))


if __name__ == "__main__":
    main()
