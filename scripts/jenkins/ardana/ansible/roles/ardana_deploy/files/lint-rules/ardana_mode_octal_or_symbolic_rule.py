#
# (c) Copyright 2016 Hewlett Packard Enterprise Development LP
# (c) Copyright 2017-2018 SUSE LLC
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

import re
import sys

from ansiblelint import AnsibleLintRule


class ArdanaModeOctalOrSymbolicRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0011'
    shortdesc = 'mode must be symbolic, variable or a 4-digit octal'
    description = ('mode must be specified for file, copy and template tasks, '
                   'and it must be either symbolic (e.g. "u=rw,g=r,o=r"), '
                   'a variable (e.g. "{{ mode }}"), '
                   'a 4-digit octal (e.g. 0700, "0700"), '
                   'or a 5-digit octal (e.g. 01770) if sticky bit is set')
    tags = ['formatting']
    _commands = ['file', 'copy', 'template']
    _ignore_states = ['absent', 'link']

    @staticmethod
    def validate_mode(mode):
        def is_octal_string(string):
            return re.match('^0[0-7]+', string)

        def is_valid_octal_mode(string):
             if len(string) == 4:
                 return re.match('^0[0-7]?[0-7]?[0-7]?$', string)
             else:
                 # If this is not a 4-digit octal, we are assuming user
                 # is specifying the sticky bit.
                 # The second number must be 1 for sticky bit
                 return re.match('^01[0-7]?[0-7]?[0-7]?$', string)

        def is_valid_symbolic_mode(string):
            parts = string.split(',')
            for part in parts:
                # NOTE(gyee): This should match the most popular symbolic
                # representations out there. 't' matches sticky bit and 'X'
                # matches special execute bit. See
                # https://en.wikipedia.org/wiki/Chmod
                if not re.match('^[ugoa]*[+-=]?[rwxXt]+$', part):
                    return False
            return True

        if is_octal_string(mode):
            return not is_valid_octal_mode(mode)
        else:
            return not is_valid_symbolic_mode(mode)


    def matchtask(self, file, task):
        if sys.modules['ardana_noqa'].skip_match(file):
            return False
        action = task["action"]
        if action["module"] in self._commands:
            if action.get("state") in self._ignore_states:
                return False
            if "mode" not in action:
                return True
            mode = action.get("mode")
            if isinstance(mode, int):
                mode = "%04o" % mode
            if not isinstance(mode, str):
                return True
            if mode.startswith("{{"):
                return False
            return self.validate_mode(mode)


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_mode_octal_or_symbolic_rule(ArdanaModeOctalOrSymbolicRule):
    pass
