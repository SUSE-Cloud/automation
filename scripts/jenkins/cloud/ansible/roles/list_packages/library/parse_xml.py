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


import xml.sax
from io import StringIO
from sys import version_info

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = '''
---
module: parse_xml
short_description: parse xml and get specific data
description: |
  Module will parse xml data file (or from ansible variable)
  given by zypper (extract name and repository of origin
  or from rpm (version infos, disturl)
author: SUSE Linux GmbH
options:
  path:
    description: Path to the file
  schema:
    description: |
      Schema which will be use - zypper(repo of origin) or rpm
      (disturl, version infos)
'''

EXAMPLES = '''
- parse_xml:
    path: path/to/xml/file
    schema: zypper
  register: _result
- parse_xml:
    path: {{ ansible_variable_containing_xml }}
    schema: zypper
  register: _result
- debug: msg="{{ _result.parse_xml }}"
'''


class RepoHandler(xml.sax.ContentHandler):
    def __init__(self, packages, attributes_to_show, scheme_skeleton):
        self.current_data = ''
        self.title = ''
        self.repo = ''
        self.packages = packages
        self.def_attributes_to_show = attributes_to_show
        self.attributes_to_show = attributes_to_show
        self.scheme_skeleton = scheme_skeleton
        self.package_name = ''

    # Call when an element starts

    def startElement(self, tag, attributes):
        self.current_data = tag
        if tag == 'solvable':
            # set value with new row
            self.package_name = attributes['name']
            for key, value in self.def_attributes_to_show.items():
                # if name of the package in key is already present -
                # add attribut value into repository key as list
                if self.package_name in self.packages:
                    # to keep current value in place and add a new
                    # one(multiple repos)
                    self.attributes_to_show.setdefault(key, [])
                    self.attributes_to_show[key].append(attributes[key])
                else:
                    self.attributes_to_show[key] = [attributes[key]]
            self.packages[self.package_name] = dict(self.attributes_to_show)


def defineSchema(xmlScheme, attributes_to_show, scheme_skeleton):
    if xmlScheme == 'zypper':
        scheme_skeleton['zypper'] = 'solvable'
        attributes_to_show['repository'] = ''
    if xmlScheme == 'rpm':
        scheme_skeleton['rpm'] = 'solvable'
        attributes_to_show['version'] = ''
        attributes_to_show['release'] = ''
        attributes_to_show['disturl'] = ''


def main():
    try:
        attributes_to_show = {}
        scheme_skeleton = {}
        packages = {}

        argument_spec = dict(
            path=dict(type='str', required=True),
            schema=dict(type='str', required=True, choices=['rpm', 'zypper'])
        )
        module = AnsibleModule(argument_spec=argument_spec,
                               supports_check_mode=False)
        xml_path = module.params['path']
        if version_info[0] < 3:
            xml_path = xml_path.decode('utf-8')
        xmlScheme = module.params['schema']
        defineSchema(xmlScheme, attributes_to_show, scheme_skeleton)

        parser = xml.sax.make_parser()
        # turn off namepsaces
        parser.setFeature(xml.sax.handler.feature_namespaces, 0)
        # override the default ContextHandler
        Handler = RepoHandler(packages, attributes_to_show, scheme_skeleton)
        parser.setContentHandler(Handler)
        # parse xml
        parser.parse(StringIO(xml_path))
    except Exception as err:
        module.fail_json(msg="parse_xml.py: %s" % err)
    module.exit_json(rc=0, changed=False, parse_xml=packages)


if (__name__ == "__main__"):
    main()
