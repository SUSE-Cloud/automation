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

import collections
import re

from ansiblelint import AnsibleLintRule


_NOQA = collections.defaultdict(lambda: False)


def skip_match(file, line=None):
    """Support noqa line comments and blocks (noqa-on / noqa-off).

    The block markers must be on their own lines to maximise clarity and
    minimise any risk of accidents.
    """
    global _NOQA
    filename = file.get('path')
    noqa = _NOQA[filename]
    # matchtask rules don't have a line to check
    if not line:
        return noqa
    if re.match('\s*#\s+noqa-on', line):
        _NOQA[filename] = True
        return True
    elif re.match('\s*#\s+noqa-off', line):
        _NOQA[filename] = False
        return True
    elif re.search('#\s+noqa', line):
        return True
    return noqa


# ansible-lint falls over if any file in this dir doesn't contain a rule
class ardana_noqa(AnsibleLintRule):
    id = 'noqa'
    shortdesc = 'noqa'
    description = 'noqa'
    tags = []
