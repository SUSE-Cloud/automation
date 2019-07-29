#!/usr/bin/env python
from __future__ import print_function

import os
import sys

sys.path.append(os.path.dirname(__file__))
from gerrit_settings import gerrit_project_map  # noqa: E402


def main():
    print('(', end='')
    first = True
    for project in gerrit_project_map(sys.argv[1]):
        if first:
            first = False
        else:
            print('|', end='')
        print('ardana/'+project, end='')
    print(')', end='')


if __name__ == '__main__':
    main()
