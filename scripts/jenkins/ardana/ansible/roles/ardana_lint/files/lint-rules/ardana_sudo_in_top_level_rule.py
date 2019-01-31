#
# (c) Copyright 2015-2016 Hewlett Packard Enterprise Development LP
# (c) Copyright 2017 SUSE LLC
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

import sys

from ansiblelint import AnsibleLintRule


# only need to look for 'become' as sudo is deprecated so
# an error will be generated to catch use of sudo
class ArdanaSudoInTopLevelRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0016'
    shortdesc = 'WARNING - become in a top level play affects performance.'
    description = 'Using become in a top level play affects performance.'
    tags = ['formatting', 'warning']

    def match(self, file, line):
        if sys.modules['ardana_noqa'].skip_match(file, line):
            return False
        if 'roles/' not in file['path']:
            return 'become: yes' in line


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_sudo_in_top_level_rule(ArdanaSudoInTopLevelRule):
    pass
