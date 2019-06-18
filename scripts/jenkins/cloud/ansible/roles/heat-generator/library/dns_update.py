#!/usr/bin/python
#
# (c) Copyright 2019 SUSE
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

from traceback import format_exc

from ansible.module_utils.basic import AnsibleModule

import yaml

ANSIBLE_METADATA = {
    'metadata_version': '1.1',
    'status': ['preview'],
    'supported_by': 'community'
}

DOCUMENTATION = '''
---
module: dns_update

short_description: Update DNS information in input model

description: |
    - Update the DNS information such as DNS and NTP servers in the
      specified cloudConfig.yml file.

options:
    dns_servers:
        description:
            - A list of DNS servers
        required: false
    ntp_servers:
        description:
            - A list of NTP servers
        required: false
    cloud_config:
        description:
            - The path to the cloudConfig.yml input model
              configuration file

author:
    - SUSE
'''

EXAMPLES = '''
- name: Update DNS data
  dns_update:
    ntp_servers:
      - 10.0.0.1
      - 10.0.0.2
    dns_servers:
      - 1.1.1.1
      - 8.8.8.8
    cloud_config: /path/to/cloudConfig.yml
'''

RETURN = '''
msg:
    description: A messages describing the result of the DNS update
    type: str
    returned: always
'''


def run_module():
    module_args = dict(
        dns_servers=dict(type='list', required=False, default=[]),
        ntp_servers=dict(type='list', required=False, default=[]),
        cloud_config=dict(type='str', required=False,
                          default='cloudConfig.yml')
    )

    result = dict(
        changed=False
    )

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=True
    )

    if module.check_mode:
        module.exit_json(**result)

    try:
        with open(module.params['cloud_config']) as f:
            data = yaml.load(f.read(), Loader=yaml.SafeLoader)

            if len(set(data['cloud']['dns-settings']['nameservers']) ^
                   set(module.params['dns_servers'])) != 0:
                result['changed'] = True

            data['cloud']['dns-settings'] = dict(
                nameservers=module.params['dns_servers'])
            data['cloud']['ntp-servers'] = module.params['ntp_servers']

            with open(module.params['cloud_config'], 'w') as f:
                f.write(yaml.safe_dump(data, default_flow_style=False))

    except Exception:
        module.fail_json(msg="dns_update.py:\n%s" % format_exc(), **result)

    module.exit_json(msg='Successfully updated DNS data', **result)


def main():
    run_module()


if __name__ == '__main__':
    main()
