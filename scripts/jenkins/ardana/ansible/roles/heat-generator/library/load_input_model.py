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

import os
from collections import OrderedDict

from ansible.module_utils.basic import AnsibleModule

import yaml

DOCUMENTATION = '''
---
module: load_input_model
short_description: Load an Ardana input model
description: |
  Load an Ardana input model from a given path
author: SUSE Linux GmbH
options:
  path:
    description: Root path where the input model files are located
'''

EXAMPLES = '''
- load_input_model:
    path: path/to/input/model
  register: _result
- debug: msg="{{ _result.input_model }}"
'''


def merge_input_model(data, input_model):
    for key, value in data.iteritems():
        if key in input_model and isinstance(input_model[key], list) and value:
            input_model[key] += value
        else:
            input_model[key] = value


def load_input_model_file(file_name, input_model):
    if file_name.endswith('.yml') or file_name.endswith('.yaml'):
        with open(file_name, 'r') as data_file:
            data = yaml.load(data_file.read())
            merge_input_model(
                data,
                input_model)
    return input_model


def load_input_model(input_model_path):
    input_model = OrderedDict()

    if os.path.exists(input_model_path):
        if os.path.isdir(input_model_path):
            for root, dirs, files in os.walk(input_model_path):
                for f in files:
                    file_name = os.path.join(root, f)
                    input_model = load_input_model_file(
                        file_name,
                        input_model)
        else:
            input_model = load_input_model_file(
                input_model_path,
                input_model)

    return input_model


def main():

    argument_spec = dict(
        path=dict(type='str', required=True)
    )
    module = AnsibleModule(argument_spec=argument_spec,
                           supports_check_mode=False)
    input_model_path = module.params['path']

    try:
        input_model = load_input_model(input_model_path)
    except Exception as e:
        module.fail_json(msg=e.message)
    module.exit_json(rc=0, changed=False, input_model=input_model)


if __name__ == '__main__':
    main()
