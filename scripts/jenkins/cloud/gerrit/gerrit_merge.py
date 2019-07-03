#!/usr/bin/env python

import argparse
import os
import sys

sys.path.append(os.path.dirname(__file__))

from gerrit import GerritChange  # noqa: E402

from gerrit_settings import gerrit_project_map  # noqa: E402


def check_all_dependencies_satisfied(change):
    change_deps = change.get_dependencies()
    unmerged_deps = [change_dep
                     for change_dep in change_deps
                     if change_dep.status != "MERGED"]

    if unmerged_deps:
        print("Unmerged dependencies:\n{}".format('\n'.join([
            str(c) for c in unmerged_deps])))
        return False

    return True


def gerrit_merge(change, dry_run=False):
    """
    Attempt to merge a Gerrit change.

    :param change:
    :param dry_run:
    :return:
    """
    project_map = gerrit_project_map(change.branch)

    print('Attempting to merge change {}'.format(change))

    if not change.is_current and not dry_run:
        print("Skipping - change is not current: {}".format(change))
        return 1

    if change.gerrit_project not in project_map:
        print("Skipping - project {} not in the list of "
              "allowed projects ".format(change.gerrit_project))
        return 1

    if change.status != 'NEW':
        print("Skipping - change is {}: {}".format(
            change.status.lower(), change))
        return 1

    if not change.mergeable:
        print("Change cannot be merged due to conflicts: {}".format(change))
        return 1

    if not change.submittable:
        print("Change doesn't meet submit requirements: {}".format(change))
        return 1

    if not check_all_dependencies_satisfied(change):
        msg = "Unable to merge: Commit dependencies are not satisifed."
        print(msg)
        if not dry_run:
            change.review(message=msg)
        return 1

    if not dry_run:
        change.merge()
        print("Change merged: {}".format(change))
    else:
        print("[DRY-RUN] Change can be merged: {}".format(change))

    return 0


def main():
    parser = argparse.ArgumentParser(
        description='Merge a Gerrit change if its dependencies have merged '
                    'and if it submittable')
    parser.add_argument('change', type=int,
                        help='the Gerrit change number (e.g. 1234)')
    parser.add_argument('--patch', type=int,
                        default=None,
                        help='the Gerrit patch number (e.g. 3). If not '
                             'supplied, the latest patch will be used')
    parser.add_argument('--dry-run', default=False, action='store_true',
                        help='do a dry run')

    args = parser.parse_args()

    change = GerritChange(str(args.change), patchset=args.patch)

    gerrit_merge(change, args.dry_run)


if __name__ == '__main__':
    main()
