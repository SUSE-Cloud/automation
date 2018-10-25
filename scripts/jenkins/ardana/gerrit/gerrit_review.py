#!/usr/bin/env python

import argparse

from pygerrit2 import GerritRestAPI, GerritReview, HTTPDigestAuthFromNetrc

GERRIT_URL = 'https://gerrit.suse.provo.cloud/'


def gerrit_review(change_no, patch=None, label=None, vote=1, message=''):
    auth = HTTPDigestAuthFromNetrc(url=GERRIT_URL)
    rest = GerritRestAPI(url=GERRIT_URL, auth=auth, verify=False)
    change = rest.get("/changes/?q={}".format(change_no))[0]
    print("Posting {}: {} review for change: '{}'".format(label, vote,
                                                          change['subject']))
    if not patch:
        current_rev = rest.get("/changes/?q={}&o=CURRENT_REVISION".format(
            change['_number']))
        patch = current_rev[0]['revisions'].values()[0]['_number']
    rev = GerritReview()
    rev.set_message(message)
    if label:
        rev.add_labels({label: vote})

    rest.review(change['_number'], patch, rev)


def main():
    parser = argparse.ArgumentParser(
        description='Post a Gerrit review')
    parser.add_argument('change',
                        help='the Gerrit change number (e.g. 1234)')
    parser.add_argument('--patch',
                        default='0',
                        help='the Gerrit patch number (e.g. 3). If not '
                             'supplied, the latest patch will be used')
    parser.add_argument('--label',
                        default=None,
                        choices=['Code-Review', 'Verified', 'Workflow'],
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

    gerrit_review(int(args.change),
                  int(args.patch),
                  args.label,
                  int(args.vote),
                  message)


if __name__ == '__main__':
    main()
