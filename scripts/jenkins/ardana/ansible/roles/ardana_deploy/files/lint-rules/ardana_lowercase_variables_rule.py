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

import re
import sys

from ansiblelint import AnsibleLintRule


class ArdanaLowercaseVariablesRule(AnsibleLintRule):
    id = 'ARDANAANSIBLE0007'
    shortdesc = ('Variables must match pattern, be lowercase or'
                 ' be derived from a function')
    description = ('Variables must follow one of the patterns:\n'
                   '    anycase.advertises_anycase.lowercase\n'
                   '    anycase.consumes_anycase.lowercase\n'
                   '    anycase.vars.lowercase\n'
                   '    lowercase\n'
                   'All variables in role tasks must be lowercase.\n'
                   'CP variables must be aliased in defaults/main.yml\n'
                   'If a function is being used to generate a variable\n'
                   'it is exempt from these rules.')
    tags = ['formatting']
    variables = re.compile(r"{{ ([^}]+?)(\s*\|[^}]+)* }}")
    up = "[A-Z_0-9]*"
    lo = "[a-z_0-9]*"
    subscript = "(?:\[[^]]+\])?"
    either = "(?:%s|%s)" % (up, lo)
    lo_sub = lo + subscript
    many_lo_sub = '(?:%s\.)*%s' % (lo_sub, lo_sub)
    pattern_strings = [
        '%s\.advertises\.%s' % (either, many_lo_sub),
        '%s\.consumes_%s\.%s' % (either, either, many_lo_sub),
        '%s\.vars\.(%s)' % (either, lo_sub),
        '%sverb_hosts\.(%s)' % (either, lo_sub),
        many_lo_sub]
    patterns = '|'.join(pattern_strings)
    pattern = re.compile("^%s$" % patterns)
    functions = '[a-z]+\(.*?\)'
    function = re.compile(functions)

    def match(self, file, line):
        if sys.modules['ardana_noqa'].skip_match(file, line):
            return False
        role = 'roles' in file['path']
        for variable in self.variables.finditer(line):
            matches_patterns = self.pattern.match(variable.group(1))
            if role:
                if self.function.match(variable.group(1)):
                    return False
                if variable.group(1) != variable.group(1).lower():
                    if matches_patterns:
                        return "CP vars must be aliased in defaults/main.yml"
                    else:
                        return True
            else:
                if not matches_patterns:
                    return True
        return False


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_lowercase_variables_rule(ArdanaLowercaseVariablesRule):
    pass
