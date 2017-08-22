#!/usr/bin/python
#
# This script introduces a new network named ceph. This script assumes that
# the networking mode has been set to team and that the third and fourth
# interface cards exist and are available for use.

import json
import sys

# save parameters
netfile = sys.argv[1]
subnet = sys.argv[2]
vlan = int(sys.argv[3])

# load file
with open(netfile) as f:
    j = json.load(f)

# add conduit to both conduit maps
conduit = 'intf3'
dirty1 = False
conmap1_pattern = 'team/1/crowbar'
team1_conlist_element = {
    conduit: {
        'if_list': [
            '?1g1'
        ]
    }
}
dirty = False
conmap_pattern = 'team/.*/.*'
team_conlist_element = {
    conduit: {
        'if_list': [
            '1g3',
            '1g4'
        ]
    }
}

for conmap_el in j['attributes']['network']['conduit_map']:
    if not dirty1 and conmap_el['pattern'] == conmap1_pattern:
        conmap_el['conduit_list'].update(team1_conlist_element)
        dirty1 = True
    elif not dirty and conmap_el['pattern'] == conmap_pattern:
        conmap_el['conduit_list'].update(team_conlist_element)
        dirty = True
if not dirty1:
    raise Exception(
        "Failed to add conduit %s to map '%s'" % (conduit, conmap1_pattern)
    )
if not dirty:
    raise Exception(
        "Failed to add conduit %s to map '%s'" % (conduit, conmap_pattern)
    )

# add network
ceph_network = {
    'ceph': {
        'conduit': conduit,
        'vlan': vlan,
        'use_vlan': True,
        'add_bridge': False,
        'mtu': 1500,
        'subnet': '%s.0' % subnet,
        'netmask': '255.255.255.0',
        'broadcast': '%s.255' % subnet,
        'ranges': {
            'host': {
                'start': '%s.10' % subnet,
                'end': '%s.239' % subnet
            }
        }
    }
}
j['attributes']['network']['networks'].update(ceph_network)

# update file
with open(netfile, 'w') as f:
    json.dump(j, f, indent=2, sort_keys=True)
