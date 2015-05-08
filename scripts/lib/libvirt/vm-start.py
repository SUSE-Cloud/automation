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
        print("cleaning up {}".format(vm))
        dom = conn.lookupByName(vm)
        if dom.isActive():
            print("destroying {} vm".format(dom.name()))
            dom.destroy()
        if dom.ID():
            print("undefining {} vm".format(dom.name()))
            dom.undefine()
    except:
        print("no domain for {} active".format(vm))

    xml = open("/tmp/{}.xml".format(vm)).read()
    print("defining {} vm".format(vm))
    conn.defineXML(xml)
    if not "dom" in locals():
        dom = conn.lookupByName(vm)
    print("booting {} vm".format(vm))
    dom.create()

if __name__ == "__main__":
    main()
