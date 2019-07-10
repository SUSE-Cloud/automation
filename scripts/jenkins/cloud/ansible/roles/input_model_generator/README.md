# Ardana Input Model Generator

Being able to generate an input model on the fly by manipulating a reduced set of input parameters is a more flexible
alternative than having to choose from a set of fully defined input models, such as those stored in the
`ardana-input-model` repository. The input model generator is able to generate a large variety of valid input models by
combining a set of predefined, parameterized template modules, each of them controlling how a different part of the input model
is configured (services, networks, disks, interfaces).

Main advantages over the traditional method of storing individual input model definitions for development, QA, CI etc.
purposes:

* hardware separation - this is one of the first requirements that led to the development of this mechanism. It enables
the service aspects of an input model (service components, clusters, resources) to be defined and varied independently
from the available hardware infrastructure (servers, networks, interface attachments, disks)
* eliminates duplicated information - most of the input models stored in the `ardana-input-model` repository are very
similar to each other and can be easily templated. Moreover, instead of having to add yet another slightly modified copy
of one of the existing input models whenever a new input model is needed which has a slightly different configuration
(e.g. like a different number of compute nodes), the generator's approach is to just use a different parameter value
for an existing template.
* better usability - it's simpler to change a set of template parameters, which are guaranteed to generate a valid input model
than to define a new input model from scratch
* better QA - parameterization offers a larger base of available scenarios that can be used for validation, that would otherwise
be very difficult to cover through individually defined input models


## Usage

To generate an input model, choose one of the scenario templates already defined under `roles/ardana_input_model_generator/vars/templates`,
or define a new one. The scenario template needs to be passed as a parameter to the `generate-input-model.yml` playbook. If the target
is a virtual deployment, the optional `virt_config_file` parameter also needs to be supplied to point to the generated virtual
configuration file accepted as input by the heat generator.

Example:

```
    ansible-playbook generate-input-model.yml \
      -e scenario_name=standard \
      -e input_model_path=/path/to/input-model
      -e virt_config_file=/path/to/virt-config.yml
```

NOTE: optionally, provide a `cloudsource` value (defaults to `stagingcloud9`) to control which version specific services
and features are activated and an `cloud_env` value (defaults to `localhost`) to change how the generated items are named:

    ansible-playbook generate-input-model.yml \
      -e scenario_name=standard \
      -e input_model_dir=/path/to/input-model
      -e virt_config_file=/path/to/virt-config.yml
      -e cloudsource=GM8+up \
      -e cloud_env=my_dev_env

The input model described by the `roles/ardana_input_model_generator/vars/templates/standard.yml` scenario template will
be generated in the `/path/to/input-model` output path.

In addition to the mentioned parameters and to those specific for each scenario template, there are also
a few [global parameters](#global-parameters) that can be used to further customize the generated input model.

## Input Model Templates

This section describes the template categories that the input model generator combines to create an input model:

### Scenario templates

The scenario template is a top-level template which defines the general input model configuration parameters as well as
references all the other template modules required to define a complete input model, along with their input parameter values:

* a _service template_
* a _network template_
* an _interface template_
* a _disk template_

Scenario templates are located in the `roles/ardana_input_model_generator/vars` directory.

The following example taken from `roles/input_model_generator/vars/standard.yml` defines a scenario that can be used
to generate the `standard`, `std-3cp`, `std-3cm`, `std-min`, `dac-3cp` and `dac-min` input models in the
`ardana-input-model` repository and many more, by simply varying the input parameters:

```
# Scenario parameters and default values
controllers: 3
computes: 3
rhel_computes: 0
swobj_devices: 3

scenario:
  name: standard
  cloud_name: standard
  description: >
    Standard scenario with all services enabled, {{ clm_model }} CLM node, {{ controllers }} controller nodes,
    {{ computes }} SLES compute nodes and {{ rhel_computes }} RHEL compute nodes.
  audit_enabled: False
  use_cinder_volume_disk: False
  use_glance_cache_disk: False

  service_template: standard
  network_template: standard
  disk_template: compact
  interface_template: standard

```

The last section of this template shows how the scenario includes the `standard` service template,
the `standard` network template, the `compact` disk template and the `standard` interface template. The parameters
defined at the beginning of the scenario template can be used to fine-tune various aspects of the input model, such
as the number of controller and compute nodes, by overriding then with group variables, host variables, or by passing
their values directly to the `generate-input-model.yml` playbook.

The input model generator uses the global information in the service template to generate the `cloud` input model
element configuration and the `cloudConfig.yml` file:


To generate the `std-min` input model, for example, the `generate-input-model.yml` playbook may be called with the
following parameters:

```
    ansible-playbook generate-input-model.yml \
      -e scenario_name=standard \
      -e input_model_dir=/path/to/input-model \
      -e controllers=2 \
      -e computes=1 \
      -e clm_model=standalone
```

### Service templates

A service template defines the way that service components in a control plane are grouped into _service groups_ -
the _service group_ being a more general term that covers both clusters and resources, differentiated by the
`type` attribute value.
Defined service templates are located under `roles/ardana_input_model_generator/vars/templates/service`.

The service template uses a set of macros representing groups of service components. These macros are defined in
`roles/input_model_generator/defaults/main.yml`. The list of available macros can be extended by adding new macros
to that file, if needed.

The structure of the service template is a compacted version of that used for the `control-planes` element in the input model.
The attributes that can be configured for a service group are a mixture of those that can be configured for the `clusters`,
`resources` and `servers` input model configuration elements.

The `CLM` service component group is special: it marks the service group designated as deployer and is conditionally
listed twice in the service template: depending on the `clm_model` [global parameter](#global-parameters) value, only
one `CLM` occurrence will be considered by the input model generator, while the other one will be ignored, which
allows a single service template to be used to implement both integrated and standalone deployer scenarios.

The following example taken from `roles/input_model_generator/vars/templates/service/standard.yml` defines the service
template included by the `standard` scenario template:

```
service_groups:
  - name: clm
    type: cluster
    prefix: c0
    heat_flavor_id: cloud-ardana-job-compute
    member_count: '{{ (clm_model == "standalone") | ternary(1, 0) }}'
    service_components:
      - CLM
  - name: controller
    type: cluster
    prefix: c1
    heat_flavor_id: cloud-ardana-job-controller
    member_count: '{{ controllers|default(3) }}'
    service_components:
      - '{{ (clm_model == "integrated") | ternary("CLM", '') }}'
      - CORE
      - LMM
      - DBMQ
      - SWPAC
      - NEUTRON
      - SWOBJ
  - name: compute
    type: resource
    prefix: sles-comp
    heat_flavor_id: cloud-ardana-job-compute
    member_count: '{{ computes|default(1) }}'
    min_count: 0
    service_components:
      - COMPUTE
  - name: rhel-compute
    type: resource
    prefix: rhel-comp
    distro_id: rhel75-x86_64
    heat_image_id: centos75
    heat_flavor_id: cloud-ardana-job-compute
    member_count: '{{ rhel_computes|default(1) }}'
    min_count: 0
    service_components:
      - RHEL_COMPUTE

```

The input model generator uses the information in the service template to generate the following input model elements:

* the `control-planes` element: clusters and resources are generated from the listed service groups
* the `servers` elements: a number of servers equal to the configured `member_count` value is generated for every
service group
* the `server-roles` elements: a server role is generated for every service group

The virtual configuration consumed by the heat template generator, indicating which openstack image and flavor needs
to be used for each server is also generated from the optional information present in the service template (note the
`heat_image_id` and `heat_flavor_id` attributes).

### Network templates

The network template defines the networks (including neutron networks) and network groups together in a single, compact format,
based on the assumption that there is a one-to-one relationship between a network and a network group (see Limitations).
Network templates are located under `roles/ardana_input_model_generator/vars/templates/network`

The network template uses a set of predefined macros as component endpoint values, encoding groups of component endpoints,
load balancers, neutron network tags or networks playing a special role in the input model:

* _CLM_: represents the network and network group that will be used to provision the OS onto the nodes and to perform the
inital OS configuration. This macro expands into the lifecycle manager component endpoints. This network will also be
used to generate the IP addresses configured for the servers input model elements.
* _MANAGEMENT_: identifies the network and network group that will be used to for management traffic within the cloud. It is used
as a default by all component-endpoints, which means that it already includes component endpoints covered by other macros.
* _EXTERNAL-API_: marks the network and network group that services will use to access the internal API endpoints.
Specifying this macro adds the external load-balancer to the network group.
* _INTERNAL-API_: identifies the network and network group that services will use to access the internal API endpoints.
Specifying this macro adds the internal load-balancer to the network group.
* _SWIFT_: represents the network and network group that will be used for Swift back-end traffic between proxy, container,
account and object servers. This macro expands into the swift component endpoints.
* _NEUTRON-EXT_: configures the network group as a Neutron flat external network that will be used to provide external access
to VMs (via floating IP Addresses). When this macro is specified as a component endpoint, the generated network group
will be tagged with `neutron.l3_agent.external_network_bridge` or `neutron.networks.flat`, depending on the `enable_external_network_bridge`
global parameter value, and a `neutron_external_networks` entry is generated and added to the Neutron configuration data corresponding to this network.
* _NEUTRON-VLAN_: configures the network group as a Neutron VLAN provider network. When this macro is specified as a
component endpoint, the generated network group will be tagged with `neutron.networks.vlan` and a VLAN `neutron_provider_networks`
entry is generated and added to the Neutron configuration data corresponding to this network. A route is also configured
between the generated Neutron VLAN provider network and the _MANAGEMENT_ network, to provide for maximum flexibility.
The Neutron VLAN provider network generated for the first _NEUTRON-VLAN_ tagged network group in the list is also the
one configured for Octavia.
* _NEUTRON-VXLAN_: configures the network group as a Neutron VXLAN provider network. When this macro is specified as a
component endpoint, the generated network group will be tagged with `neutron.networks.vxlan`.

The following example taken from `roles/input_model_generator/vars/templates/network/standard.yml` defines the network
template included by the `standard` scenario template:

```
network_groups:
  - name: CONF
    hostname_suffix: conf
    tagged_vlan: false
    component_endpoints:
      - CLM

  - name: MANAGEMENT
    hostname_suffix: mgmt
    tagged_vlan: false
    component_endpoints:
      - MANAGEMENT
      - INTERNAL-API
      - NEUTRON-VLAN
    routes:
      - default

  - name: EXTERNAL-API
    hostname_suffix: extapi
    tagged_vlan: true
    component_endpoints:
      - EXTERNAL-API

  - name: EXTERNAL-VM
    hostname_suffix: extvm
    tagged_vlan: false
    component_endpoints:
      - NEUTRON-EXT

  - name: TENANT-VLAN
    hostname_suffix: tvlan
    tagged_vlan: false
    component_endpoints:
      - NEUTRON-VLAN

  - name: GUEST
    hostname_suffix: guest
    tagged_vlan: true
    component_endpoints:
      - NEUTRON-VXLAN

  - name: SWIFT
    hostname_suffix: swift
    tagged_vlan: true
    component_endpoints:
      - SWIFT

  - name: STORAGE
    hostname_suffix: storage
    tagged_vlan: true
    component_endpoints: []
```

The input model generator uses the information in the network template to generate the following input model elements:

* the `network-groups` element: a network group input model element is generated corresponding to each network group listed in
the network template, with the component endpoint macros properly expanded into their corresponding component endpoints,
load balancers, routes and neutron network tags. Routes can be configured explicitly using the optional `routes` list attribute
* the `networks` elements: a network input model element is generated for each network group listed in the network
template. The subnet and gateway values are generated.
* the Neutron `configuration-data`: external neutron networks and provider networks are generated according to the
`NEUTRON-VLAN` and `NEUTRON-EXT` markers
* the Octavia `configuration-data`: the Neutron provider network used by the Octavia is set to the first `NEUTRON-VLAN`
marked network group

### Disk templates

TBD

### Interface templates

TBD

### Hardware templates

TBD

### Hardware templates

## Global parameters

The following optional parameters may be supplied as ansible external variables to control various
aspects of the generated input model:

* `clm_model` : can be used to switch between an integrated deployer scenario (the deployer node also hosts
other services in addition to the lifecycle manager services) and a standalone deployer (the deployer node
only hosts the lifecycle manager services). May be set to either `standalone` (default) or `integrated`.
* `designate_backend` : controls the designate backend configured for the input model. May be set to
either `bind` (default) or `powerdns`.
* `disabled_services` : can be used to selectively exclude service components or entire service component
groups from the generated input model. Accepts a regular expression as value (e.g. `freezer.*|logging.*`),
which is used to filter out matching service components and service component groups.
* `enable_external_network_bridge`: can be used to switch between using the deprecated `external_network_bridge`
input model option to configure an external network and configuring a flat provider network to represent
the external network.

# Limitations

The input model generator cannot yet be used to generate input models with the following characteristics:

* more than one control plane
* more compact disk models (e.g. where all consumers use a single block device). Currently, every disk consumer group
has a dedicated device associated with it
* customized service configuration data. Currently, the configuration data for various services is hard-coded into
the ansible template files and cannot be varied via input parameters
* disk models and interface models differentiated over servers tied to the same server role. Currently, all servers
that are associated with the same server role are modeled to have the same interface attachment and disk layout
* two or more networks referencing the same network group, associated with different availability zones
