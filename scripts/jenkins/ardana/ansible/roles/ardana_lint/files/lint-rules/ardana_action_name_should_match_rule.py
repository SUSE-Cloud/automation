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

import os
import sys

from ansiblelint import AnsibleLintRule


class ArdanaActionNameShouldMatchRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0006'
    shortdesc = 'Action name should match $role | $task | description'
    description = 'Action name should match $role | $task | description'
    tags = ['formatting']

    def matchtask(self, file, task):
        if sys.modules['ardana_noqa'].skip_match(file):
            return False
        if 'name' in task:
            filename = file['path']
            # ignore handlers
            if 'handlers' in filename:
                return False
            if 'role' in filename:
                task_name = os.path.splitext(os.path.basename(filename))[0]
                dirs = filename.split('/')
                role = dirs[len(dirs) - 3]
                return not task['name'].startswith("%s | %s" % (role,
                                                                task_name))
            return False


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_action_name_should_match_rule(ArdanaActionNameShouldMatchRule):
    pass
