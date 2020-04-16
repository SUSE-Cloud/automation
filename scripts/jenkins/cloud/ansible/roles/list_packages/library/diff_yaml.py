#!/usr/bin/env python3
#
# (c) Copyright 2020 SUSE LLC
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


from __future__ import print_function

from re import findall

from ansible.module_utils.basic import AnsibleModule

from deepdiff import DeepDiff

import yaml

DOCUMENTATION = '''
---
module: diff_yaml
short_description: do a diff of yaml data
description: |
  Module will compare 2 given yaml files and return
  structured diff. All is done on local machine
author: SUSE Linux GmbH
options:
  file1:
    description: Path to the file
  file2:
    description: Path to the file
  output:
    description: Name of file to write diff into
'''

EXAMPLES = '''
- diff_yaml:
    file1: path/to/yaml/file
    file2: path/to/yaml/file
    output: path/to/diff/file
  register: _result
'''


def loadFiles(file1, file2):
    with open(file1) as f:
        firstFile = yaml.safe_load(f)
    with open(file2) as f:
        secondFile = yaml.safe_load(f)
    return (firstFile, secondFile)


def addToDict(dictItems, valueObj, keyObj, action):
    packageName = keyObj[0]
    attribute = keyObj[-1]
    attrValue = valueObj
    dictItems.setdefault(action, {})
    dictItems[action].setdefault(packageName, {})
    if action == "values_changed":
        dictItems[action][packageName][attribute] = attrValue


def main():
    try:
        dictItems = {}

        argument_spec = dict(
            file1=dict(type='str', required=True),
            file2=dict(type='str', required=True),
            output=dict(type='str', required=True)
        )
        module = AnsibleModule(argument_spec=argument_spec,
                               supports_check_mode=False)
        file1 = module.params['file1']
        file2 = module.params['file2']
        output = module.params['output']
        (dataMap1, dataMap2) = loadFiles(file1, file2)
        # do the diff
        diffik = DeepDiff(dataMap1, dataMap2)
        for action, actionItems in diffik.items():
            if action == "values_changed":
                # values_changed returns dict
                for item in sorted(actionItems):
                    valueObj = diffik[action][item]
                    keyObj = findall(r"\['(.*?)'\]", item)
                    addToDict(dictItems, valueObj, keyObj, action)
            elif (action == "dictionary_item_removed" or
                  action == "dictionary_item_added"):
                # dictionary_items return set
                for item in sorted(actionItems):
                    valueObj = item
                    keyObj = findall(r"\['(.*?)'\]", item)
                    addToDict(dictItems, valueObj, keyObj, action)

        with open(output, 'w') as f:
            yaml.dump(dictItems, f)
    except Exception as err:
        module.fail_json(msg="diff_yaml.py: %s" % err)
    module.exit_json(rc=0, changed=False, diff_yaml=dictItems)


if (__name__ == "__main__"):
    main()
