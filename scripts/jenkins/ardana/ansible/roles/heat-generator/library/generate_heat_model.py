#!/usr/bin/python
#
# (c) Copyright 2018 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
from collections import OrderedDict
from copy import deepcopy

from ansible.module_utils.basic import AnsibleModule

from netaddr import IPAddress, IPNetwork

DOCUMENTATION = '''
---
module: generate_heat_model
short_description: Generate heat template structure from input model
description: |
  Take an input model as input and generate a data structure
  describing a heat orchestration template and an updated input
  model with NIC mappings corresponding to the virtual setup described
  by the generated heat orchestration template.

author: SUSE Linux GmbH
options:
  input_model:
    description: Input model data structure
  virt_config:
    description: Virtual configuration descriptor (images, flavors, disk sizes)
output:
  heat_template:
    description: Heat orchestration template descriptor
  input_model:
    description: Updated input model data structure
'''

EXAMPLES = '''
- generate_heat_model:
    input_model: '{{ input_model }}'
    virt_config: '{{ virt_config }}'
  register: _result
- debug: msg="{{ _result.heat_template }} {{ _result.input_model }}"
'''


configuration_data_foreign_key = {
    'type': list,
    'target': [
        'configuration-data'
    ]
}

service_group_foreign_keys = {
    'configuration-data': configuration_data_foreign_key,
    'server-role': {
        'type': list,
        'target': [
            'server-roles'
        ]
    }
}

"""
The input model schema describes the main objects (elements) that the input
model is comprised of, their key attributes and the foreign key relationships
established between different elements.

This schema is used to enhance the input model structure by replacing the
subelement lists and foreign key attributes with element maps and direct
references. The schema describing an element is structured as follows:

  <element list name>: {
      'key': <name of attribute representing the key (default: name)>
      'foreign-keys': {
          <foreign key attribute>: {
              'type': <foreign key atrribute data type: list|basestring>,
              'target': [
                  <name of root element to which the key points>,
                  [<name of root element to which the key points>,]
                  ...
              ],
              'reverse-ref-attr': <name of attribute to create in the
                                   target element(s) to store the map
                                   of elements referencing it (default is
                                   the <element list name> value)>
          },
          ...
      },
      'elements': <dictionary with sub elements schema>
  }


"""
input_model_schema = {
    'elements': {
        'control-planes': {
            'foreign-keys': {
                'configuration-data': configuration_data_foreign_key,
            },
            'elements': {
                'clusters': {
                    'foreign-keys': service_group_foreign_keys,
                    },
                'resources': {
                    'foreign-keys': service_group_foreign_keys,
                },
                'load-balancers': {}
            }
        },
        'configuration-data': {},
        'server-roles': {
            'foreign-keys': {
                'disk-model': {
                    'type': basestring,
                    'target': [
                        'disk-models'
                    ]
                },
                'interface-model': {
                    'type': basestring,
                    'target': [
                        'interface-models'
                    ]
                }
            }
        },
        'disk-models': {},
        'interface-models': {
            'elements': {
                'network-interfaces': {
                    'foreign-keys': {
                        'network-groups': {
                            'type': list,
                            'target': [
                                'network-groups'
                            ],
                            'reverse-ref-attr': 'network-interfaces'
                        },
                        'forced-network-groups': {
                            'type': list,
                            'target': [
                                'network-groups'
                            ],
                            'reverse-ref-attr': 'network-interfaces'
                        }
                    }
                }
            }
        },
        'networks': {
            'foreign-keys': {
                'network-group': {
                    'type': basestring,
                    'target': [
                        'network-groups'
                    ]
                }
            }
        },
        'network-groups': {},
        'nic-mappings': {},
        'servers': {
            'key': 'id',
            'foreign-keys': {
                'role': {
                    'type': basestring,
                    'target': [
                        'server-roles'
                    ]
                },
                'nic-mapping': {
                    'type': basestring,
                    'target': [
                        'nic-mappings'
                    ]
                },
                'server-group': {
                    'type': basestring,
                    'target': [
                        'server-groups'
                    ]
                }
            }
        },
        'server-groups': {
            'foreign-keys': {
                'networks': {
                    'type': list,
                    'target': [
                        'networks'
                    ]
                },
                'network-groups': {
                    'type': list,
                    'target': [
                        'server-groups'
                    ]
                }
            }
        },
        'firewall-rules': {}
    }
}


def convert_element_list_to_map(element, list_attr_name,
                                foreign_key_attr='name'):
    """
    Convert an attribute representing a list of elements into a dictionary
    indexed by the element's key.

    E.g. from (yaml):

        input_model:
            networks:
                - name: MANAGEMENT
                  cidr: 192.168.1.1/24
                  ...
                - name: ARDANA
                  cidr: 192.168.2.1/24
                  ...

    to:

        input_model:
            networks:
                MANAGEMENT:
                  - name: MANAGEMENT
                    cidr: 192.168.1.1/24
                    ...
                ARDANA:
                  - name: ARDANA
                    cidr: 192.168.2.1/24
                    ...

    :param element: the element being modified
    :param list_attr_name: list attribute name
    :param foreign_key_attr: foreign key attribute name (default: 'name')
    :return: the new dictionary attribute value
    """
    if list_attr_name in element:
        element[list_attr_name] = OrderedDict(
            [(item[foreign_key_attr], item,)
             for item in element[list_attr_name]])
    else:
        element[list_attr_name] = OrderedDict()
    return element[list_attr_name]


def map_list_attrs(element, element_schema):
    """
    Does a recursive walk through the supplied input model elements
    and through the indicated input model schema, in parallel, and converts
    attributes indicated by the schema as representing sub-element lists into
    sub-element maps (dictionaries) indexed by their respective element key
    values.

    :param element: input model element
    :param element_schema: input model element schema
    :return:
    """
    schema_sub_elements = element_schema.get('elements', {})
    for sub_element_name, sub_element_schema in schema_sub_elements.items():
        input_model_subelements = element.get(sub_element_name, {})
        convert_element_list_to_map(
            element, sub_element_name,
            sub_element_schema.get('key', 'name'))
        for input_model_element in input_model_subelements:
            map_list_attrs(input_model_element, sub_element_schema)


def link_elements(element, target_element,
                  ref_list_attr=None, target_element_key=None):
    if ref_list_attr:
        if target_element_key:
            element.setdefault(
                ref_list_attr,
                OrderedDict())[target_element_key] = target_element
        else:
            element.setdefault(
                ref_list_attr,
                []).append(target_element)
    element['is-referenced'] = True


def link_elements_by_foreign_key(element, foreign_key_attr, target_element_map,
                                 ref_list_attr, element_key=None):
    foreign_key = element.setdefault(foreign_key_attr)
    if isinstance(foreign_key, basestring) and \
            foreign_key in target_element_map:
        foreign_element = target_element_map[foreign_key]
        element[foreign_key_attr] = foreign_element
        link_elements(foreign_element, element,
                      ref_list_attr, element_key)


def link_elements_by_foreign_key_list(element, foreign_key_list_attr,
                                      target_element_map, ref_list_attr,
                                      element_key=None):
    foreign_key_list = element.setdefault(foreign_key_list_attr, [])
    for idx, foreign_key in enumerate(foreign_key_list):
        if isinstance(foreign_key, basestring) and \
                foreign_key in target_element_map:
            foreign_element = target_element_map[foreign_key]
            foreign_key_list[idx] = foreign_element
            link_elements(foreign_element, element,
                          ref_list_attr, element_key)


def map_foreign_keys(root_element, element_name,
                     element, element_schema, parent_key=''):
    """
    Does a recursive walk through the supplied input model elements
    and through the indicated input model schema, in parallel, and
    replaces foreign keys with actual element references.

    :param root_element: input model root - used to resolve foreign key
    targets
    :param element_name: name of the current input model element
    :param element: input current model element
    :param element_schema: input model element schema
    :param parent_key: the key of the parent element - used to compute
    relative keys
    :return:
    """
    foreign_keys = element_schema.get('foreign-keys', {})
    schema_sub_elements = element_schema.get('elements', {})
    element_key_attr = element_schema.get('key', 'name')
    element_key = element.get(element_key_attr)
    if element_key and parent_key:
        element_key = "-".join([parent_key, element_key])

    for attr_name, foreign_key in foreign_keys.iteritems():
        for target in foreign_key['target']:
            ref_list_attr_name = foreign_key.get(
                'reverse-ref-attr',
                element_name)
            # Mark the foreign element in the schema as needing pruning
            input_model_schema['elements'][target]['prune'] = True
            if foreign_key['type'] == list:

                if isinstance(element.get(attr_name), basestring):
                    element[attr_name] = [element[attr_name]]
                link_elements_by_foreign_key_list(
                    element, attr_name,
                    root_element[target],
                    ref_list_attr_name,
                    element_key)

            elif foreign_key['type'] == basestring:
                link_elements_by_foreign_key(
                    element, attr_name,
                    root_element[target],
                    ref_list_attr_name,
                    element_key)

    for sub_element_name, sub_element_schema in schema_sub_elements.items():
        for input_model_element in element[sub_element_name].values():
            map_foreign_keys(
                root_element, sub_element_name,
                input_model_element, sub_element_schema, element_key)


def prune_input_model(element, element_schema):
    """
    Does a recursive walk through the supplied input model elements
    and through the indicated input model schema, in parallel, and
    removes un-referenced elements from the input model.

    :param element: input model element
    :param element_schema: input model element schema
    :return:
    """
    schema_sub_elements = element_schema.get('elements', {})
    for sub_element_name, sub_element_schema in schema_sub_elements.items():
        if sub_element_schema.get('prune'):
            element[sub_element_name] = dict(filter(
                lambda el_rec: el_rec[1].get('is-referenced'),
                element[sub_element_name].items()))
        for input_model_element in element[sub_element_name].values():
            prune_input_model(input_model_element, sub_element_schema)


def enhance_input_model(input_model):
    """
    Uses the input model schema to enhance the input model data structure,
    in order to make it easier to navigate:
      - replaces sub-element lists with key-indexed sub-element maps (to
      simplify lookup operations)
      - replaces attributes representing foreign keys with direct references to
      foreign elements (to simplify lookup and dereference operations)
      - deletes unused elements from the input models (e.g. server roles that
      aren't referenced by any control plane)

    Processes neutron configuration data, network group tags and routes and
    extends the input model data structure with information pertaining to
    identified neutron networks.

    :param input_model: original input model, as loaded from disk
    :return: enhanced input model data structure
    """

    input_model = deepcopy(input_model)

    map_list_attrs(input_model, input_model_schema)

    map_foreign_keys(
        input_model, 'input-model',
        input_model, input_model_schema)

    prune_input_model(input_model, input_model_schema)

    # Assume there is at most one neutron configuration data
    neutron_config_data = filter(
        lambda config_data: 'neutron' in config_data['services'],
        input_model['configuration-data'].values())
    neutron_config_data = \
        input_model['neutron-config-data'] = \
        neutron_config_data[0] if neutron_config_data else None

    # Collect all network group tags in a single map,
    # indexed by neutron group name
    neutron_network_tags = dict()
    # Collect all neutron provider/external networks in a single map,
    # indexed by network name
    neutron_networks = input_model['neutron-networks'] = dict()

    def add_neutron_network_tags(network_group_name, tags):
        tag = neutron_network_tags.setdefault(
            network_group_name,
            {'network-group': network_group_name})
        link_elements_by_foreign_key(
            tag, 'network-group',
            input_model['network-groups'],
            ref_list_attr='neutron-tags',
            # Use a null key_attr value
            # to create a list of references
            element_key=None)
        tag.setdefault('tags', []).extend(tags)

    if neutron_config_data:
        # Starting in SUSE OpenStack Cloud 8, network tags may be defined
        # as part of a Neutron configuration-data object rather than as part
        # of a network-group object.
        for network_tag in neutron_config_data.get('network-tags', []):
            add_neutron_network_tags(
                network_tag['network-group'],
                network_tag['tags'])

        external_networks = convert_element_list_to_map(
            neutron_config_data['data'],
            'neutron_external_networks')
        provider_networks = convert_element_list_to_map(
            neutron_config_data['data'],
            'neutron_provider_networks')
        neutron_networks.update(external_networks)
        neutron_networks.update(provider_networks)
        for network in external_networks.itervalues():
            network['external'] = True
        for network in provider_networks.itervalues():
            network['external'] = False

    for network_group in input_model['network-groups'].itervalues():
        if neutron_config_data and 'tags' in network_group:
            add_neutron_network_tags(
                network_group['name'],
                network_group['tags'])
        link_elements_by_foreign_key_list(
            network_group, 'routes',
            input_model['network-groups'],
            ref_list_attr='network-group-routes')
        link_elements_by_foreign_key_list(
            network_group, 'routes',
            neutron_networks,
            ref_list_attr='network-group-routes')

    # Based on the collected neutron networks and network tags, identify
    # which network group is linked to which neutron network, by looking
    # at the provider physical network settings
    neutron_physnets = dict()
    for neutron_network in neutron_networks.itervalues():
        # The only neutron network without a provider is the external
        # "bridge" network.
        # Assume a default 'external' physnet value for this network.
        if 'provider' not in neutron_network:
            if neutron_network['external']:
                physnet = 'external'
            else:
                continue
        else:
            physnet = neutron_network['provider'][0]['physical_network']
        neutron_physnets[physnet] = neutron_network
    for network_tag in neutron_network_tags.itervalues():
        for tag in network_tag['tags']:
            if isinstance(tag, dict):
                tag = tag.values()[0]
            # The only relevant tag without a provider is the external
            # "bridge" network.
            # Assume a default 'external' physnet value for this network.
            if 'provider-physical-network' not in tag:
                if tag == 'neutron.l3_agent.external_network_bridge':
                    physnet = 'external'
                else:
                    continue
            else:
                physnet = tag['provider-physical-network']
            if physnet not in neutron_physnets:
                continue

            # Create a 'neutron-networks' attribute in the network group
            # element as a map of neutron networks indexed by physical
            # network name
            network_tag['network-group'].setdefault(
                'neutron-networks',
                dict())[physnet] = neutron_physnets[physnet]
            # Create a 'network-groups' attribute in the neutron network
            # element as a map of neutron groups indexed by network group name
            neutron_physnets[physnet].setdefault(
                'network-groups',
                dict())[network_tag['network-group']['name']] = \
                network_tag['network-group']

    return input_model


def generate_heat_model(input_model, virt_config):
    """
    Create a data structure that more or less describes the heat resources
    required to deploy the input model. The data structure can then later
    be used to generate a heat orchestration template.

    :param input_model: enhanced input model data structure
    :param virt_config: additional information regarding the virtual setup
    (images, flavors, disk sizes)
    :return: dictionary describing heat resources
    """
    heat_template = dict(
        description='Template for deploying Ardana {}'.format(
            input_model['cloud']['name'])
    )

    clm_cidr = IPNetwork(input_model['baremetal']['subnet'],
                         input_model['baremetal']['netmask'])
    clm_network = None
    heat_networks = heat_template['networks'] = dict()

    # First, add L2 neutron provider networks defined in the input
    # model's neutron configuration
    for neutron_network in input_model['neutron-networks'].itervalues():
        heat_network = dict(
            name=neutron_network['name'],
            is_mgmt=False,
            external=neutron_network['external']
        )
        if neutron_network.get('cidr'):
            heat_network['cidr'] = neutron_network['cidr']
        if neutron_network.get('gateway'):
            heat_network['gateway'] = neutron_network['gateway']
        if neutron_network.get('provider'):
            provider = neutron_network['provider'][0]
            if provider['network_type'] == 'vlan':
                if not provider.get('segmentation_id'):
                    # Neutron network is incompletely defined (VLAN tag is
                    # dynamically allocated), so it cannot be defined as an
                    # individual heat network
                    continue
                heat_network['vlan'] = provider['segmentation_id']
            elif provider['network_type'] not in ['flat', 'vlan']:
                # Only layer 2 neutron provider networks are considered
                continue
        heat_networks[heat_network['name']] = heat_network

    # Collect all the routers required by routes configured in the input model,
    # as pairs of networks
    routers = set()

    # Next, add global networks
    for network in input_model['networks'].itervalues():
        cidr = None
        vlan = network['vlanid'] if network.get('tagged-vlan') else None
        gateway = IPAddress(
            network['gateway-ip']) if network.get('gateway-ip') else None
        if network.get('cidr'):
            cidr = IPNetwork(network['cidr'])

        heat_network = dict(
            name=network['name'],
            is_mgmt=False,
            external=False
        )
        if cidr:
            heat_network['cidr'] = str(cidr)
        if gateway:
            heat_network['gateway'] = str(gateway)

        # There is the special case of global networks being used to implement
        # flat neutron provider networks. For these networks, we need to
        # create a heat network based on the global network parameters
        # (i.e. VLAN) and a heat subnet based on the neutron network
        # parameters
        for neutron_network in network['network-group'].get(
                'neutron-networks', {}).itervalues():
            heat_neutron_network = heat_networks.get(neutron_network['name'])
            if not heat_neutron_network or heat_neutron_network.get('vlan'):
                # Ignore neutron networks that:
                #   - were not already considered at the previous step (i.e.
                #   are not fully defined or are not layer 2 based)
                #   - have a vlan (i.e. are not flat)
                continue

            # Replace the heat neutron network with this global network
            # This is the same as updating the heat global network with subnet
            # attributes taken from the neutron network
            del heat_networks[neutron_network['name']]
            heat_network = heat_neutron_network
            heat_network['name'] = network['name']

            # Only one flat neutron provider network can be associated with a
            # global network
            break

        if vlan:
            heat_network['vlan'] = vlan

        # For each route, track down the target network
        for route in network['network-group']['routes']:
            if route == 'default':
                # The default route is satisfied by adding the network to the
                # external router
                heat_network['external'] = True
            else:
                routers.add((heat_network['name'], route['name'],))

        if cidr and cidr in clm_cidr:
            clm_network = heat_network
            heat_network['external'] = heat_network['is_mgmt'] = True

            # Create an address pool range that excludes the list of server
            # static IP addresses
            fixed_ip_addr_list = \
                [IPAddress(server['ip-addr'])
                 for server in input_model['servers'].itervalues()]
            if gateway:
                fixed_ip_addr_list.append(gateway)
            start_addr = cidr[1]
            end_addr = cidr[-2]
            for fixed_ip_addr in sorted(list(set(fixed_ip_addr_list))):
                if start_addr <= fixed_ip_addr <= end_addr:
                    if fixed_ip_addr-start_addr < end_addr-fixed_ip_addr:
                        start_addr = fixed_ip_addr+1
                    else:
                        end_addr = fixed_ip_addr-1
            heat_network['allocation_pools'] = \
                [[str(start_addr), str(end_addr)]]

        heat_networks[network['name']] = heat_network

    heat_template['routers'] = []
    for network1, network2 in routers:
        if network1 not in heat_template['networks'] or \
           network2 not in heat_template['networks']:
            continue
        network1 = heat_template['networks'][network1]
        network2 = heat_template['networks'][network2]
        # Re-use the external router, if at least one of the networks is
        # already attached to it
        if network1['external'] or network2['external']:
            network1['external'] = network2['external'] = True
        else:
            heat_template['routers'].append([network1['name'],
                                             network2['name']])

    heat_interface_models = heat_template['interface_models'] = dict()

    for interface_model in input_model['interface-models'].itervalues():
        heat_interface_model = \
            heat_interface_models[interface_model['name']] = \
            dict(
                name=interface_model['name'],
                ports=[]
            )
        ports = dict()
        clm_ports = dict()
        for interface in interface_model['network-interfaces'].itervalues():
            devices = interface['bond-data']['devices'] \
                if 'bond-data' in interface \
                else [interface['device']]
            for device in devices:
                port_list = ports
                port = dict(
                    name=device['name'],
                    networks=[]
                )
                if 'bond-data' in interface:
                    port['bond'] = interface['device']['name']
                    port['primary'] = \
                        (device['name'] ==
                         interface['bond-data']['options'].get('primary',
                                                               device['name']))

                for network_group in \
                    interface.get('network-groups', []) + \
                        interface.get('forced-network-groups', []):

                    port['networks'].extend([network['name'] for network in
                                             network_group[
                                                 'networks'].itervalues()])

                    # Attach the port only to those neutron networks that have
                    # been validated during the previous steps
                    port['networks'].extend([network['name'] for network in
                                             network_group.get(
                                                 'neutron-networks',
                                                 dict()).itervalues() if
                                             network['name'] in heat_networks])

                    if clm_network['name'] in network_group['networks']:
                        # if the CLM port is a bond port, then only the
                        # primary is considered if configured
                        if not clm_ports and port.get('primary', True):
                            # Collect the CLM port separately, to put it at
                            # the top of the list and to mark it as the
                            # "management" port - the port to which the
                            # server's management IP address is assigned
                            port_list = clm_ports

                port_list[device['name']] = port

        # Add a port for each device, starting with those ports attached to
        # the CLM network while at the same time preserving the order of the
        # original ports. Ultimately, the port names will be re-aligned to
        # those in the input model by an updated NIC mappings input model
        # configuration
        heat_interface_model['ports'] = [p[1] for _, p in enumerate(
            sorted(clm_ports.items()) + sorted(ports.items()))]

    # Generate storage setup (volumes)
    #
    # General strategy:
    #  - one volume for each physical volume specified in the disk model
    #  - the size of each volume cannot be determined from the input model,
    #  so this information needs to be supplied separately (TBD)

    heat_disk_models = heat_template['disk_models'] = dict()
    disks = virt_config['disks']

    for disk_model in input_model['disk-models'].itervalues():
        heat_disk_model = heat_disk_models[disk_model['name']] = dict(
            name=disk_model['name'],
            volumes=[]
        )
        devices = []
        for volume_group in disk_model.get('volume-groups', []):
            devices += volume_group['physical-volumes']
        for device_group in disk_model.get('device-groups', []):
            devices += [device['name'] for device in device_group['devices']]
        for device in sorted(list(set(devices))):
            if device.endswith('da_root'):
                continue
            device = device.replace('/dev/sd', '/dev/vd')
            volume_name = device.replace('/dev/', '')

            size = virt_config['disk_size']
            # Check if disk size is configured explicitly for the disk model
            if disk_model['name'] in disks:
                size = disks[disk_model['name']]
                if isinstance(size, dict):
                    # Use the disk size specified for the volume name, or
                    # the disk model default, or the global default
                    size = size.get(volume_name) or \
                        size.get('default') or \
                        virt_config['disk_size']
            heat_disk_model['volumes'].append(dict(
                name=volume_name,
                mountpoint=device,
                size=size
            ))

    # Generate VM setup (servers)
    #
    # General strategy:
    #  - one server for each server specified in the disk model
    #  - the CLM server is special:
    #    - identification: server hosting the lifecycle-manager
    #    service component
    #    - the floating IP is associated with the "CLM" port attached to it
    #  - the image and flavor used for the server cannot be determined from
    #  the input model so this information needs to be supplied separately

    heat_servers = heat_template['servers'] = []
    images = virt_config['images']
    flavors = virt_config['flavors']

    clm_server = None
    for server in input_model['servers'].itervalues():
        distro_id = server.get('distro-id', virt_config['sles_distro_id'])

        image = None
        # Check if image is configured explicitly
        # for the server or for the role
        if server['id'] in images:
            image = images[server['id']]
        elif server['role']['name'] in images:
            image = images[server['role']['name']]
        if isinstance(image, dict):
            # Use the image specified for the distribution, or
            # the global default
            image = image.get(distro_id)
        if not image:
            image = virt_config['sles_image']
            if distro_id == virt_config['rhel_distro_id']:
                image = virt_config['rhel_image']

        flavor = None
        # Check if image is configured explicitly
        # for the server or for the role
        if server['id'] in flavors:
            flavor = flavors[server['id']]
        elif server['role']['name'] in flavors:
            flavor = flavors[server['role']['name']]

        heat_server = dict(
            name=server['id'],
            ip_addr=server['ip-addr'],
            role=server['role']['name'],
            interface_model=server['role']['interface-model']['name'],
            disk_model=server['role']['disk-model']['name'],
            image=image,
            flavor=flavor,
            is_admin=False,
            is_controller=False,
            is_compute=False
        )
        # Figure out which server is the CLM host, which are controllers
        # and which are computes. This information is used e.g. to determine
        # the reboot order during the MU workflow and to identify flavors
        # unless explicitly specified for each server or server role
        service_groups = server['role'].get('clusters', {}).values()
        service_groups += server['role'].get('resources', {}).values()
        for service_group in service_groups:
            # The CLM server is the first server hosting the lifecycle-manager
            # service component.
            # Compute nodes host the nova-compute service component
            if 'nova-compute' in service_group['service-components']:
                heat_server['is_compute'] = True
                if not heat_server['flavor']:
                    heat_server['flavor'] = virt_config['compute_flavor']
            # Every server that is not a compute node and hosts service
            # components other than those required by the CLM is considered
            # a controller node
            else:
                ctrl_service_components = filter(
                    lambda sc: sc not in virt_config['clm_service_components'],
                    service_group['service-components'])
                if ctrl_service_components:
                    heat_server['is_controller'] = True
                    if not heat_server['flavor']:
                        heat_server['flavor'] = \
                            virt_config['controller_flavor']
            if not clm_server and \
                    'lifecycle-manager' in service_group['service-components']:
                clm_server = heat_server
                heat_server['is_admin'] = True
                if not heat_server['flavor']:
                    heat_server['flavor'] = virt_config['clm_flavor']

        heat_servers.append(heat_server)

    return heat_template


def update_input_model(input_model, heat_template):
    """
    Updates the input model structure with the correct values required to
    reflect the virtual setup defined in the generated heat template model:
      - generate new NIC mappings
      - update the selected servers to use the new NIC mappings

    :param input_model:
    :param heat_template:
    :return:
    """
    for server in input_model['servers']:
        heat_server = filter(lambda s: server['id'] == s['name'],
                             heat_template['servers'])
        if not heat_server:
            # Skip servers that have been filtered out
            # by the heat template generator
            continue
        server['nic-mapping'] = \
            "HEAT-{}".format(heat_server[0]['interface_model'])

    for interface_model in heat_template['interface_models'].itervalues():
        mapping_name = "HEAT-{}".format(interface_model['name'])
        physical_ports = []
        nic_mapping = {
            'name': mapping_name,
            'physical-ports': physical_ports
        }
        for port_idx, port in enumerate(interface_model['ports']):
            physical_ports.append({
                'logical-name': port['name'],
                'type': 'simple-port',
                'bus-address': "0000:00:{:02x}.0".format(port_idx+3)
            })

        # Overwrite the mapping, if it's already defined
        existing_mapping = filter(lambda mapping:
                                  mapping[1]['name'] == mapping_name,
                                  enumerate(input_model['nic-mappings']))
        if existing_mapping:
            input_model['nic-mappings'][existing_mapping[0][0]] = nic_mapping
        else:
            input_model['nic-mappings'].append(nic_mapping)

    return input_model


def main():

    argument_spec = dict(
        input_model=dict(type='dict', required=True),
        virt_config=dict(type='dict', required=True)
    )
    module = AnsibleModule(argument_spec=argument_spec,
                           supports_check_mode=False)
    input_model = module.params['input_model']
    virt_config = module.params['virt_config']
    try:
        enhanced_input_model = enhance_input_model(input_model)
        heat_template = generate_heat_model(enhanced_input_model, virt_config)
        input_model = update_input_model(input_model, heat_template)
    except Exception as e:
        module.fail_json(msg=e.message)
    module.exit_json(rc=0, changed=False,
                     heat_template=heat_template,
                     input_model=input_model)


if __name__ == '__main__':
    main()
