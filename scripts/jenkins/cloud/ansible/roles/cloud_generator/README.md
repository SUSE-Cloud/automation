# Cloud Generator

Being able to generate a cloud configuration on the fly by manipulating a reduced set of input parameters is a more flexible
alternative than having to choose from a set of fully defined input models, such as those stored in the
`ardana-input-model` repository, or working with the set of Crowbar batch scenario files stored in the automation
repository. The cloud generator is able to generate a large variety of cloud configurations (Ardana input models or
Crowbar batch scenario files and `mkcloud.config` files to be consumed by the `qa_crowbarsetup.sh` Crowbar automation
script), by combining a set of predefined, parameterized template modules, each of them controlling how a different part
of the cloud deployment is configured (services, networks, interfaces).

Main advantages over the traditional method of storing individual cloud configuration files for development, QA, CI etc.
purposes:

* infrastructure agnostic - this is one of the first requirements that led to the development of this mechanism. It
enables the service aspects of a cloud configuration (services, clusters, networks) to be defined and varied
independently from the underlying infrastructure (servers, networks, interface attachments, disks). This separation
allows a generated cloud configuration to be deployed on either virtual or bare-metal infrastructure.
* eliminates duplicated information - most of the input models stored in the `ardana-input-model` repository and the
Crowbar batch scenario files store in the automation repository are very similar to each other and can be easily
templated. Moreover, instead of having to add yet another slightly modified copy of one of the existing cloud
configuration definitions whenever a slightly different configuration is needed (e.g. like a different number of
compute nodes), the generator's approach is to just use a different parameter value for an existing template.
* better usability - it's simpler to change a set of template parameters, which are guaranteed to generate a valid
cloud configuration than to define a new cloud configuration from scratch
* better QA - parameterization offers a larger base of available scenarios that can be used for validation, that
would otherwise be very difficult to cover through individually defined cloud configurations
* unification - the cloud generator exploits similarities between the patterns identified in Crowbar and Ardana cloud
configuration formats and provides a unified language that can be used for generating both


## Usage

To generate a cloud configuration, choose one of the existing [cloud generator scenarios](#cloud-generator-scenarios)
defined under [roles/cloud_generator/vars/templates](vars/templates) (or define a new one).
The scenario name needs to be passed as a parameter to the [generate-cloud.yml](generate-cloud.yml) playbook.
The playbook generates an input model and, if the `cloud_product` parameter is set to `crowbar`, it also generates a Crowbar
batch scenario and `mkcloud.config` file.

If the target is a virtual deployment, the optional `virt_config_file` parameter also needs to be supplied
to point to the generated virtual configuration file accepted as input by the heat generator.

We recommend placing playbook input parameters in a yaml file (e.g. `input.yml`) and passing that filename
to the playbook:

```bash
ansible-playbook generate-cloud.yml -e @input.yml
```

The following examples will only highlight the contents of the `input.yml` file. The shell command remains unchanged.

Example: generate an Ardana input model using the `standard` scenario:

```yaml
scenario_name: standard
input_model_path: /path/to/input-model
virt_config_file: /path/to/virt-config.yml
cloud_product: ardana
cloudsource: GM8+up
cloud_env: my_dev_env
```

The playbook will generate:
 * an Ardana input model located at `/path/to/input-model`
 * a virtual configuration file located at `/path/to/virt-config.yml`

Example: generate a Crowbar batch scenario file and a `mkcloud.config` configuration file using the `standard` scenario
(in addition to the corresponding Ardana input model):

```yaml
scenario_name: standard
crowbar_batch_file: /path/to/scenario.yml
mkcloud_config_file: /path/to/mkcloud.config
input_model_path: /path/to/input-model
virt_config_file: /path/to/virt-config.yml
cloud_product: crowbar
cloudsource: GM8+up
cloud_env: my_dev_env
```

The playbook will generate:
 * a Crowbar batch scenario file located at `/path/to/scenario.yml`
 * a Crowbar mkcloud.config file located at `/path/to/mkcloud.config`
 * an Ardana input model located at `/path/to/input-model`
 * a virtual configuration file located at `/path/to/virt-config.yml`

The optional `cloudsource` parameter (defaults to `stagingcloud9`) should be used to control which version-specific services
and features are activated and the optional `cloud_env` parameter (defaults to `localhost`) to control the names of the generated
configuration elements (e.g. FQDN, node names, input model elements).

Every scenario has a set of parameters that control various aspects of the generated cloud configuration
(e.g. number of controller, compute nodes etc.). These parameters are documented in the
[cloud generator scenarios](#cloud-generator-scenarios) section. In addition, there are also
a few [global parameters](#global-parameters) that can be used to further customize the generated
cloud configuration.

Example: generate a Crowbar batch scenario file and a `mkcloud.config` configuration file using the `standard` scenario
with 1 controller node and 1 compute node:

```yaml
scenario_name: standard
controllers: 1
computes: 1
crowbar_batch_file: /path/to/scenario.yml
mkcloud_config_file: /path/to/mkcloud.config
input_model_path: /path/to/input-model
virt_config_file: /path/to/virt-config.yml
cloud_product: crowbar
cloudsource: GM8+up
cloud_env: my_dev_env
```


## Cloud Generator Scenarios

This section documents the available cloud generator scenarios.

### The standard Scenario

[This scenario](vars/standard.yml) can be used to generate input models resembling the majority of `ardana-ci` input models defined
in the `ardana-input-model` repository and used for CI and development purposes (e.g. `standard`, `std-min`,
`std-3cp`, `std-3cm`, `dac-min`, `dac-3cp`, `demo`, `deployerincloud`, `deployerincloud-lite`). It has all the
commonalities of those input models: control-plane services deployed in a single cluster, a variable number of
controllers and computes and the option to co-locate the deployer node and the first controller node (only
valid for Ardana configurations).
The Ardana `standard` scenario uses a `standard` network configuration with a fairly spread out network model that
separates the life-cycle management, service management, private and public API traffic types onto different networks and
dedicates one interface for each network, while the Crowbar `standard` scenario uses a `crowbar` network configuration
with management (admin), public, os_sdn and storage networks, all attached to a single interface.

Note that this scenario cannot be used to deploy monasca with Crowbar, because Crowbar requires
a dedicated node for the monasca control-plane services. To enable monasca with Crowbar, use
[the standard-lmm scenario](#the-standard-lmm-scenario) instead.

This scenario can currently only be used to deploy virtual environments.

Scenario parameters:

* `controllers` - number of controller nodes
* `computes` - number of (SLES) compute nodes
* `rhel_computes` - number of RHEL compute nodes (only valid for Ardana configurations)

### The std-lmm Scenario

[This scenario](vars/std-lmm.yml) is a spin-off from [the standard scenario](#the-standard-scenario) that separates
LMM services into a second control-plane service cluster. This separation has the advantage that
the heavy LMM workload does not negatively impact OpenStack and infrastructure services. It also
has the advantage that it allows monasca to be deployed with the Crowbar product, which requires
a dedicated node for the monasca control-plane services. All other aspects (networks, interfaces)
inherited from the [the standard scenario](#the-standard-scenario) are unchanged.

This scenario can currently only be used to deploy virtual environments.

Scenario parameters:

* `controllers` - number of (non-LMM) controller nodes
* `computes` - number of (SLES) compute nodes
* `rhel_computes` - number of RHEL compute nodes (only valid for Ardana configurations)
* `lmm_nodes` - number of nodes in the LMM cluster

IMPORTANT: for Crowbar, where Monasca isn't HA enabled, the `lmm_nodes` parameter must be kept to its default value of `1`

### The std-split Scenario

[The `std-split` scenario](vars/std-split.yml) is another spin-off from [the standard scenario](#the-standard-scenario) and was designed
to generate the `std-split` input model from the `ardana-input-model` git repository. The scenario splits the control
plane into three separate clusters:
* one cluster for the "core" OpenStack services
* one cluster for the LMM services
* one cluster that accommodates the infrastructure services (database, messaging) together with the swift-object services
All other aspects (networks, interfaces) inherited from the [the standard scenario](#the-standard-scenario)
are unchanged.

This scenario can currently only be used to deploy virtual environments.

Scenario parameters:

* `core_nodes` - number of nodes in the OpenStack core services cluster
* `dbmq_nodes` - number of nodes in the infrastructure services (database and rabbitmq) and swift-object services cluster
* `lmm_nodes` - number of nodes in the LMM cluster
* `computes` - number of (SLES) compute nodes
* `rhel_computes` - number of RHEL compute nodes (only valid for Ardana configurations)

IMPORTANT: for Crowbar, where Monasca isn't HA enabled, the `lmm_nodes` parameter must be kept to its default value of `1`

### The entry-scale-kvm Scenario

[The `entry-scale-kvm` scenario](vars/entry-scale-kvm.yml) is designed to generate the `entry-scale-kvm` input model from the `ardana-input-model`
git repository. It is a scenario that better approaches what Ardana and Crowbar customers use in production.
Similarly to [the standard scenario](#the-standard-scenario), the control-plane services are deployed in a
single cluster, with a variable number of controllers and computes and the option to co-locate the deployer
node and the first controller node (only valid for Ardana configurations). The main difference from
[the standard scenario](#the-standard-scenario) is the network configuration. The Ardana `entry-scale-kvm` scenario
uses a `compact` network configuration, with a single network for both lifecycle management and service management
(including swift) traffic types, and only two interfaces: one for management and private/public API traffic and
another one for neutron provider and tenant traffic. The Crowbar `entry-scale-kvm` scenario is the exact equivalent of
the Crowbar [standard scenario](#the-standard-scenario).

Note that this scenario cannot be used to deploy monasca with Crowbar, because Crowbar requires
a dedicated node for the monasca control-plane services. To enable monasca with Crowbar, use
[the entry-scale-kvm-lmm scenario](#the-entry-scale-kvm-lmm-scenario) instead.

This scenario can also be used with Ardana bare-metal environments.

Scenario parameters:

* `controllers` - number of controller nodes
* `computes` - number of (SLES) compute nodes
* `rhel_computes` - number of RHEL compute nodes (only valid for Ardana configurations)

### The entry-scale-kvm-lmm Scenario

[This scenario](vars/entry-scale-kvm-lmm.yml) is a spin-off from [the entry-scale-kvm scenario](#the-entry-scale-kvm-scenario) that separates
LMM services into a second control-plane service cluster. This separation has the advantage that
the heavy LMM workload does not negatively impact OpenStack and infrastructure services. It also
has the advantage that it allows monasca to be deployed with the Crowbar product, which requires
a dedicated node for the monasca control-plane services. All other aspects (networks, interfaces) inherited from
the [the entry-scale-kvm scenario](#the-entry-scale-kvm-scenario) are unchanged.

This scenario can also be used with Ardana bare-metal environments.

Scenario parameters:

* `controllers` - number of (non-LMM) controller nodes
* `computes` - number of (SLES) compute nodes
* `rhel_computes` - number of RHEL compute nodes (only valid for Ardana configurations)
* `lmm_nodes` - number of nodes in the LMM cluster

IMPORTANT: for Crowbar, where Monasca isn't HA enabled, the `lmm_nodes` parameter must be kept to its default value of `1`

### The mid-scale-kvm Scenario

[The `mid-scale-kvm` scenario](vars/mid-scale-kvm.yml) is designed to generate the `mid-scale-kvm` input model from the
`ardana-input-model` git repository. It is a scenario that better approaches what Ardana and Crowbar customers use in production.
This scenario uses a full-spread service model where control plane services are distributed onto several clusters:
* one cluster for the infrastructure services (database, messaging)
* one cluster for the "core" OpenStack services
* one cluster for the Neutron network OpenStack services
* one cluster for the Swift OpenStack services
* one cluster for the LMM services


Similarly to [the standard scenario](#the-standard-scenario), the control-plane services are deployed in a
single cluster, with a variable number of controllers and computes and the option to co-locate the deployer
node and the first controller node (only valid for Ardana configurations). The main difference from
[the standard scenario](#the-standard-scenario) is the network configuration. The Ardana `entry-scale-kvm` scenario
uses a `compact` network configuration, with a single network for both lifecycle management and service management
(including swift) traffic types, and only two interfaces: one for management and private/public API traffic and
another one for neutron provider and tenant traffic. The Crowbar `entry-scale-kvm` scenario is the exact equivalent of
the Crowbar [standard scenario](#the-standard-scenario).


## Global parameters

The following optional parameters may be used as ansible extra variables to control various aspects of the
generated input model:

* `clm_model` (Ardana only): can be used to switch between an integrated deployer scenario (the deployer node also hosts
other services in addition to the lifecycle manager services) and a standalone deployer (the deployer node
only hosts the lifecycle manager services). May be set to either `standalone` (default) or `integrated`.
This parameter is not valid for Crowbar deployments (must be left to its default `standalone` value).
* `disabled_services` : can be used to selectively exclude service components or entire service component
groups from the generated input model. Accepts a regular expression as value (e.g. `freezer.*|logging.*`),
which is used to filter out matching service components, service component groups and Crowbar barclamps.
* `enabled_services` (only used with Crowbar clouds): can be used to select a subset of the available
Crowbar barclamps generated in the Crowbar batch scenario. It accepts a comma separated value list of barclamp
names.
* `ses_enabled` (boolean, defaults to `true`): controls whether SES is used in the generated Glance, Cinder
and Nova service configuration as the back-end. *NOTE*: SES is not a valid back-end for Crowbar versions
7 and 8; it should be explicitly set to `false` for those Crowbar versions.
* `ssl_enabled` (boolean, Crowbar only, defaults to `true`): controls whether SSL is used for services in the
generated crowbar batch scenario.
* `ssl_insecure` (boolean, Crowbar only, defaults to `false`): generate insecure, self-signed certificates for
each Crowbar service if set, otherwise generate a root CA certificate and use a global certificate for all services
* `neutron_networkingplugin` (Crowbar only, defaults to `openvswitch`): selects the Neutron ML2 plugin in Crowbar
deployments. Possible values are `openvswitch` and `linuxbridge`)
* `neutron_networkingmode` (Crowbar only, defaults to `vxlan`): selects the default network type for Neutron
provider and tenant networks in Crowbar deployments. Possible values are `vxlan`, `vlan` `gre`)
* `neutron_use_dvr` (boolean, Crowbar only, defaults to `false`): controls whether the Neutron DVR feature is
enabled in Crowbar deployments.
* `neutron_use_l3_ha` (boolean, Crowbar only, defaults to `false`): controls whether the Neutron HA router
feature is enabled in Crowbar deployments.
* `designate_backend` (Ardana only): controls the designate backend configured for the input model. May be set to
either `bind` (default) or `powerdns`.
* `enable_external_network_bridge` (Ardana only): can be used to switch between using the deprecated `external_network_bridge`
input model option to configure an external network and configuring a flat provider network to represent
the external network.

## Creating Cloud Generator Scenarios

This section describes the structure of a cloud generator scenario and how it can be used to generate
Ardana input models.

### Scenario templates

The scenario template is a top-level template which defines the general input model configuration parameters as well as
references all the other template modules required to define a complete input model, along with their input parameter values:

* a [_service template_](#service-templates)
* a [_network template_](#network-templates)
* an [_interface template_](#interface-templates)

Scenario templates are located in the [roles/cloud_generator/vars](vars/) directory.

The following example taken from [roles/cloud_generator/vars/standard.yml](vars/standard.yml) defines a scenario that can be used
to generate the `standard`, `std-3cp`, `std-3cm`, `std-min`, `dac-3cp` and `dac-min` input models in the
`ardana-input-model` repository and many more, by simply varying the input parameters:

```yaml
# Scenario parameters and default values
controllers: 3
computes: 3
rhel_computes: 0

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
  network_template: "{{ (cloud_product == 'ardana') | ternary('standard', 'crowbar') }}"
  interface_template: "{{ (cloud_product == 'ardana') | ternary('standard', 'crowbar') }}"

```

The last section of this template shows how the scenario includes the `standard` [service template](#service-templates),
the `standard` or `crowbar` [network template](#network-templates) and the `standard` or `crowbar` [interface template](#interface-templates).
The parameters defined at the beginning of the scenario template can be used to fine-tune various aspects of the input model, such
as the number of controller and compute nodes, by overriding them with group variables, host variables, or by passing
their values directly to the [generate-cloud.yml](generate-cloud.yml) playbook.

The cloud generator uses the global information in the service template to generate the `cloud` input model
element configuration and the `cloudConfig.yml` input model file.

### Service templates

A service template defines the way that service components in a control plane are grouped into _service groups_ -
the _service group_ being a more general term that covers both clusters and resources, differentiated by the
`type` attribute value.
Defined service templates are located under [roles/cloud_generator/vars/templates/service](vars/templates/service).

The service template uses a set of macros representing groups of service components. These macros are defined in
[roles/cloud_generator/defaults/main.yml](defaults/main.yml). The list of available macros can be extended by adding new macros
to that file, if needed. The Crowbar barclamp roles associated with every _service component group_ are kept in
the same file, along with some other variables that encode whether a Crowbar role can be clustered or not.

The structure of the service template is a compacted version of that used for the `control-planes` element in the input model.
The attributes that can be configured for a service group are a mixture of those that can be configured for the `clusters`,
`resources` and `servers` input model configuration elements.

The `CLM` service component group is special: it marks the service group designated as deployer and is conditionally
listed twice in the service template: depending on the `clm_model` [global parameter](#global-parameters) value, only
one `CLM` occurrence will be considered by the input model generator, while the other one will be ignored, which
allows a single service template to be used to implement both integrated and standalone deployer scenarios.

The following example taken from [roles/cloud_generator/vars/templates/service/standard.yml](vars/templates/service/standard.yml)
defines the service template included by the `standard` scenario template:

```yaml
service_groups:
  - name: clm
    type: cluster
    prefix: c0
    heat_flavor_id: "{{ vcloud_flavor_name_prefix }}-compute"
    member_count: '{{ (clm_model == "standalone") | ternary(1, 0) }}'
    service_components:
      - CLM
  - name: controller
    type: cluster
    prefix: c1
    heat_flavor_id: "{{ vcloud_flavor_name_prefix }}-controller"
    member_count: '{{ controllers|default(3) }}'
    service_components:
      - '{{ (clm_model == "integrated") | ternary("CLM", '') }}'
      - CORE
      - '{{ (cloud_product == "ardana") | ternary("LMM", '') }}'
      - DBMQ
      - SWPAC
      - NEUTRON
      - SWOBJ
  - name: compute
    type: resource
    prefix: sles-comp
    heat_flavor_id: "{{ vcloud_flavor_name_prefix }}-compute"
    member_count: '{{ computes|default(1) }}'
    min_count: 0
    service_components:
      - COMPUTE
  - name: rhel-compute
    type: resource
    prefix: rhel-comp
    distro_id: "{{ rhel_distro_id }}"
    heat_flavor_id: "{{ vcloud_flavor_name_prefix }}-compute"
    member_count: '{{ rhel_computes|default(1) }}'
    min_count: 0
    service_components:
      - RHEL_COMPUTE

```

The cloud generator uses the information in the service template to generate the following Ardana input model elements:

* the `control-planes` element: clusters and resources are generated from the listed service groups
* the `servers` elements: a number of servers equal to the configured `member_count` value is generated for every
service group
* the `server-roles` elements: a server role is generated for every service group

, the following Crowbar batch scenario elements:

* one pacemaker proposal for each _cluster_ _service group_ that has more than one node member
* the deployment part of each barclamp proposal, based on the _service component groups_ in each _service group_

, and the following Crowbar `mkcloud.confg` variables:

* `nodenumber` is set to the total number of nodes
* `hacloud` is set, if at least one pacemaker cluster is configured
* `clusterconfig` is set to reflect the allocation of nodes to clusters
* `want_node_roles` is set according to the number of members in _cluster_ _service groups_ and _resource_
_service groups_
* `want_node_aliases` is set according to the names used for _service groups_

The virtual configuration consumed by the heat template generator, indicating which openstack image and flavor needs
to be used for each server is also generated from the optional information present in the service template (note the
`heat_image_id` and `heat_flavor_id` attributes).

### Network templates

The network template defines the networks (including neutron networks) and network groups together in a single, compact format,
based on the assumption that there is a one-to-one relationship between a network and a network group (see Limitations).
Network templates are located under [roles/cloud_generator/vars/templates/network](vars/templates/network).

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

The following example taken from [roles/cloud_generator/vars/templates/network/standard.yml](vars/templates/network/standard.yml) defines the network
template included by the `standard` scenario template:

```yaml
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

The cloud generator uses the information in the network template to generate the following Ardana input model elements:

* the `network-groups` element: a network group input model element is generated corresponding to each network group listed in
the network template, with the component endpoint macros properly expanded into their corresponding component endpoints,
load balancers, routes and neutron network tags. Routes can be configured explicitly using the optional `routes` list attribute
* the `networks` elements: a network input model element is generated for each network group listed in the network
template. The subnet and gateway values are generated.
* the Neutron `configuration-data`: external neutron networks and provider networks are generated according to the
`NEUTRON-VLAN` and `NEUTRON-EXT` markers
* the Octavia `configuration-data`: the Neutron provider network used by the Octavia is set to the first `NEUTRON-VLAN`
marked network group

### Interface templates

TBD

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
