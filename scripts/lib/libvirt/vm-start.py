#!/usr/bin/env python

from __future__ import print_function
import libvirt
import sys
import argparse

conn = libvirt.open("qemu:///system")
if conn == None:
    print("Failed to open connection to the hypervisor")
    sys.exit(1)

parser = argparse.ArgumentParser(description="Start a Virtual Machine.")
parser.add_argument("vm", type=str, help="Name of the vm")

args = parser.parse_args()

def main():
    vm = args.vm
    try:
        print("cleaning up {0}".format(vm))
        dom = conn.lookupByName(vm)
        if dom.isActive():
            print("destroying {0} vm".format(dom.name()))
            dom.destroy()
        if dom.ID():
            print("undefining {0} vm".format(dom.name()))
            dom.undefine()
    except:
        print("no domain for {0} active".format(vm))

    xml = open("/tmp/{0}.xml".format(vm)).read()
    print("defining {0} vm".format(vm))
    conn.defineXML(xml)
    if not "dom" in locals():
        dom = conn.lookupByName(vm)
    print("booting {0} vm".format(vm))
    dom.create()

if __name__ == "__main__":
    main()
