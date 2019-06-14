#!/usr/bin/env python

import argparse
import os
import sys

sys.path.append(os.path.dirname(__file__))
from gerrit import GerritChange, argparse_gerrit_change_type  # noqa: E402


def main():
    parser = argparse.ArgumentParser(
        description='Get a Gerrit change attribute')
    parser.add_argument('change', type=argparse_gerrit_change_type,
                        help='the Gerrit change number and an optional patch '
                             'number (e.g. 1234 or 1234/1). If the patch '
                             'number is not supplied, the latest patch will '
                             'be used')
    parser.add_argument('--attr',
                        required=True,
                        help='GerritChange object attribute name')

    args = parser.parse_args()

    change = GerritChange(args.change)
    print(getattr(change, args.attr))


if __name__ == '__main__':
    main()
