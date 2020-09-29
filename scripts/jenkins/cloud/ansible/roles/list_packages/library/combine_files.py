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

from re import search

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = '''
---
module: combine_files
short_description: combine files into dictionary
description: |
  Module will combine 2 sources and produce dictionary
author: SUSE Linux GmbH
options:
  filenames1:
    description: Path to the file
  filenames2:
    description: Path to the file
'''

EXAMPLES = '''
- combine_files:
    filenames1: path/to/yaml/file
    filenames2: path/to/yaml/file
  register: _result
'''


def addToDict(dictItems, valueObj, keyObj):
    attribute = keyObj
    dictItems.append({'jobNumber': attribute, 'currentFilename': valueObj})


def main():
    try:
        dictOldJobs = []

        argument_spec = dict(
            filenames1=dict(type='list', required=True),
            filenames2=dict(type='list', required=True)
        )
        module = AnsibleModule(argument_spec=argument_spec,
                               supports_check_mode=False)
        filenames1 = module.params['filenames1']
        filenames2 = module.params['filenames2']

        for item in filenames1:
            splitItem = item.split(':')
            valueObj = splitItem[1]
            keyObj = splitItem[0]

            for item2 in filenames2:
                if (search(item2, valueObj)
                        or search(r'slot*\d{1,3}', valueObj)):
                    addToDict(dictOldJobs, valueObj,
                              keyObj)
    except Exception as err:
        module.fail_json(msg="combine_files.py: %s" % err)

    module.exit_json(rc=0, changed=True, combine_files=dictOldJobs)


if (__name__ == "__main__"):
    main()
