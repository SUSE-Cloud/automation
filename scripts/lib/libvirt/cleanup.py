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
        print("removing {}".format(f))
        os.remove(f)

def main():
    devnull = open(os.devnull, "w")
    allnodenames = ["admin"]
    allnodenames.extend("node%s"%i for i in range(1, args.nodenumber+20))

    try:
        for nodename in allnodenames:
            vm = "{}-{}".format(args.cloud, nodename)
            dom = conn.lookupByName(vm)
            if dom.isActive():
                print("destroying {}".format(dom.name()))
                dom.destroy()
            if dom.ID():
                print("undefining {}".format(dom.name()))
                dom.undefine()

            machine = "{}-{}".format("qemu", vm)
            machinectl = os.access("/usr/bin/machinectl". os.X_OK)
            machine_status = subprocess.call(["machinectl", "status", machine], stdout=devnull, stderr=subprocess.STDOUT)
            if (machinectl == 0 and machine_status == 0):
                subprocess.call(["machinectl", "terminate", machine]) # workaround bnc#916518
    except Exception:
        print("...skipping undefined domains")

    try:
        net_name = "{}-admin".format(args.cloud)
        network = conn.networkLookupByName(net_name)
        print("destroying {}".format(net_name))
        network.destroy()
        print("undefining {}".format(net_name))
        network.undefine()
    except Exception:
        print("...skipping undefined network")

    remove_files("/var/run/libvirt/qemu/{}-*.xml".format(args.cloud))
    remove_files("/var/lib/libvirt/network/{}-*.xml".format(args.cloud))
    remove_files("/etc/sysconfig/network/ifcfg-{}.{}".format(args.cloudbr, args.public_vlan))

if __name__ == "__main__":
    main()
