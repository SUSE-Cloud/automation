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


class ArdanaSudoInShellCommandRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0014'
    shortdesc = 'Using sudo in shell command'
    description = 'Using sudo while executing a command'
    tags = ['formatting']

    _commands = ['command', 'shell']
    _modules = {'sudo': 'sudo'}

    def matchtask(self, file, task):
        if sys.modules['ardana_noqa'].skip_match(file):
            return False
        if task["action"]["module"] in self._commands:
            executable = task["action"]["module_arguments"][0]
            return executable in self._modules


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_sudo_in_shell_command_rule(ArdanaSudoInShellCommandRule):
    pass
