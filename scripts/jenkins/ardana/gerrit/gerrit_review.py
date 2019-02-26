#!/usr/bin/env python

import argparse
import os
import sys

sys.path.append(os.path.dirname(__file__))
from gerrit import GerritChange  # noqa: E402
from gerrit_settings import gerrit_project_map  # noqa: E402


def gerrit_review(change, label=None, vote=1, message=''):
    if change.gerrit_project not in gerrit_project_map():
        print("Skipping - project {} not in the list of "
              "allowed projects ".format(change.gerrit_project))
        return 1

    if not change.is_current:
        print("Skipping - change {} is not current".format(change))
        return 1

    change.review(label, vote, message)

    return 0


def main():
    parser = argparse.ArgumentParser(
        description='Post a Gerrit review')
    parser.add_argument('change', type=int,
                        help='the Gerrit change number (e.g. 1234)')
    parser.add_argument('--patch', type=int,
                        default=None,
                        help='the Gerrit patch number (e.g. 3). If not '
                             'supplied, the latest patch will be used')
    parser.add_argument('--label',
                        default=None,
                        choices=['Code-Review', 'Verified',
                                 'Workflow', 'QE-Review'],
                        help='a label to use for voting')
    parser.add_argument('--vote',
                        default='1',
                        choices=['-2', '-1', '0', '+1', '+2'],
                        help='the vote value given for the label')
    parser.add_argument('--message',
                        default='',
                        help='string message to be posted with the review')
    parser.add_argument('--message-file',
                        default=None,
                        help='append file contents to the message to be '
                             'posted with the review')

    args = parser.parse_args()

    message = args.message
    if args.message_file:
        with open(args.message_file) as msg_file:
            message += msg_file.read()

    change = GerritChange(str(args.change), patchset=args.patch)

    gerrit_review(change,
                  args.label,
                  args.vote,
                  message)


if __name__ == '__main__':
    main()
