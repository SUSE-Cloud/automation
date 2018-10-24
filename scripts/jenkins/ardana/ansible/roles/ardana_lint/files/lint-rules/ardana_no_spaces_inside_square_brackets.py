#
# (c) Copyright 2016 Hewlett Packard Enterprise Development LP
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


class ArdanaNoSpacesInSquareBrackets(AnsibleLintRule):
    id = 'ARDANAANSIBLE0018'
    shortdesc = 'Avoid white space inside square brackets'
    description = ('General convention is not to use spaces inside '
                   'the square brackets.')
    tags = ['formatting']

    def match(self, file, line):
        if sys.modules['ardana_noqa'].skip_match(file, line):
            return False
        return re.search("\[ | \]", line)


# ansible-lint expects the filename and class name to match
# Python style expects filenames to be all lowercase
# Python style expects classnames to be CamelCase
# Resolution: trick ansible lint with this class
class ardana_no_spaces_inside_square_brackets(ArdanaNoSpacesInSquareBrackets):
    pass
