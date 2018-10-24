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


class ArdanaRegVarsEndInResultRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0009'
    shortdesc = ('Registered variables must end in _result '
                 'unless prefixed with ardana_notify')
    description = ('Registered variables must end in _result\n'
                   '\te.g. foo_result\n'
                   'or be prefixed with "ardana_notify_"\n'
                   '\te.g. ardana_notify_foo')
    tags = ['formatting']

    @staticmethod
    def validate_variable(var):
        return (not var.endswith('_result') and
                not var.startswith('ardana_notify_'))

    def matchtask(self, file, task):
        if sys.modules['ardana_noqa'].skip_match(file):
            return False
        if 'register' in task:
            if isinstance(task['register'], list):
                for item in task['register']:
                    if self.validate_variable(item):
                        return True
                return False
            else:
                return self.validate_variable(task['register'])


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_reg_vars_end_in_result_rule(ArdanaRegVarsEndInResultRule):
    pass
