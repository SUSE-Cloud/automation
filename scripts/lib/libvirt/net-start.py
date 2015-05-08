#!/usr/bin/env python

from __future__ import print_function
import libvirt
import sys
import argparse

conn = libvirt.open("qemu:///system")
if not conn:
    print("Failed to open connection to the hypervisor")
    sys.exit(1)

parser = argparse.ArgumentParser(description="Start a Virtual Network.")
parser.add_argument("net", type=str, help="Name of the network")

args = parser.parse_args()

def main():
    net = args.net
    print("defining {} network".format(net))
    networks = conn.listNetworks()
    if net not in networks:
        print("defining {} network".format(net))
        xml = open("/tmp/{}.net.xml".format(net)).read()
        conn.networkDefineXML(xml)
    print("starting {} network".format(net))
    dom = conn.networkLookupByName(net)
    dom.create()


if __name__ == "__main__":
    main()
