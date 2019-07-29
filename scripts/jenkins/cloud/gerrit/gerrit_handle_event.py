#!/usr/bin/env python

import argparse
import os
import sys

sys.path.append(os.path.dirname(__file__))

from gerrit import GerritChange, GerritChangeSet  # noqa: E402

from gerrit_merge import gerrit_merge  # noqa: E402

from gerrit_review import gerrit_review  # noqa: E402


def get_submittable_references(change):
    """
    Get all submittable changes that reference the supplied change
    as a direct implicit or explicit dependency.

    :param change: GerritChange object
    :return: list of GerritChange object representing submittable changes,
    referencing the supplied merged change as a direct dependency, and which
    could be merged themselves on their own
    """
    references = []

    # This query takes care of the explicit dependency part
    explicit_changeset = GerritChangeSet(
        'is:open',
        'is:mergeable',
        'branch:{}'.format(change.branch),
        'message:"Depends-On:"',
        'label:Code-Review=2',
        'label:Verified=2',
        'label:Workflow=1',
        '-label:Verified=-1',
        '-label:Code-Review=-2'
    )

    for reference_change in explicit_changeset.changes():
        if (reference_change.submittable and
           reference_change.has_explicit_dependency(change)):
            references.append(reference_change)

    for reference_change in change.get_implicit_references():
        if (reference_change.submittable and
           reference_change.is_current and
           reference_change.has_implicit_dependency(change)):
            references.append(reference_change)

    return references


def get_stale_references(change):
    """
    Get all changes that directly or indirectly explicitly or implicitly
    depend on the indicated updated Gerrit change and targeting the same
    branch. Only Gerrit changes that are current are considered while
    reconstructing the dependency tree.

    :param change: GerritChange object representing a change
    that has been updated (e.g. for which a new patchset was published)
    :return: list of GerritChange object representing changes directly or
    indirectly referencing the supplied change as an explicit dependency
    """
    explicit_changeset = GerritChangeSet(
        'is:open',
        'message:"Depends-On:"',
        'branch:{}'.format(change.branch)
    )

    # All open changes in the dependency tree will be added to this list
    stale_references = [change]
    for stale_change in stale_references:
        for open_change in explicit_changeset.changes():
            if (open_change not in stale_references and
               open_change.has_explicit_dependency(stale_change)):
                stale_references.append(open_change)
        # We ignore current ancestors of the input change because the
        # only way they can be current is if they were uploaded at the same
        # time or later than the input change, which means that validation
        # jobs are already under way targeting those ancestors
        if stale_change == change:
            continue
        for reference in stale_change.get_implicit_references():
            if (reference not in stale_references and
               reference.is_current):
                stale_references.append(reference)

    # Remove the triggering change
    stale_references.pop(0)
    return stale_references


def handle_change_merged(change, dry_run=False):
    """
    After a Gerrit change is merged, track down all the other open and
    submittable changes that list the merged change as a direct implicit
    or explicit dependency and attempt to merge those as well, if possible.

    :param change: GerritChange object
    :param dry_run:
    :return:
    """

    print('Following up on merged change {}'.format(change))

    if change.status != 'MERGED' and not dry_run:
        print("Skipping - change is {}: {}".format(
            change.status.lower(), change))
        return 0

    references = get_submittable_references(change)
    if not references:
        print("Nothing to do")
        return 0

    print("Attempting to merge related changes:\n{}".format('\n'.join([
            str(c) for c in references])))

    for ref_change in references:
        gerrit_merge(ref_change, dry_run)

    return 0


def handle_change_updated(change, dry_run=False):
    """
    When a new patchset is published for a Gerrit change, track down all the
    other open changes that list the updated change as an explicit dependency
    and invalidate them by clearing the 'Verify' label value and forcing a
    recheck operation.

    Uploading a new patchset will automatically invalidate all other changes
    that implicitly depend on the previous patchset because they will need
    to be rebased before they can be merged.

    :param change: GerritChange object
    :param dry_run:
    :return:
    """

    print('Following up on updated change {}'.format(change))

    if not change.is_current and not dry_run:
        print("Skipping - change is not current: {}".format(change))
        return 1

    if change.status != 'NEW' and not dry_run:
        print("Skipping - change is {}: {}".format(
            change.status.lower(), change))
        return 0

    references = get_stale_references(change)
    if not references:
        print("Nothing to do")
        return 0

    if not dry_run:
        print("Invalidating related changes:\n{}".format('\n'.join([
                str(c) for c in references])))

        for ref_change in references:
            direct = ref_change.has_explicit_dependency(change)
            gerrit_review(ref_change, label='Verified', vote=0,
                          message='Needs recheck. New patchset {} was '
                                  'published for {}direct dependency: '
                                  '{} '.format(
                                    change.patchset,
                                    '' if direct else 'in',
                                    change.gerrit_url)
                          )
    else:
        print("[DRY-RUN] Invalidated changes:\n{}".format('\n'.join([
                str(c) for c in references])))

    return 0


def main():
    parser = argparse.ArgumentParser(
        description='Handle a Gerrit event')
    parser.add_argument('change', type=int,
                        help='the Gerrit change number (e.g. 1234)')
    parser.add_argument('--patch', type=int,
                        default=None,
                        help='the Gerrit patch number (e.g. 3). If not '
                             'supplied, the latest patch will be used')
    parser.add_argument('event',
                        choices=['merged', 'updated'],
                        help='event to handle')
    parser.add_argument('--dry-run', default=False, action='store_true',
                        help='do a dry run')

    args = parser.parse_args()

    change = GerritChange(str(args.change), patchset=args.patch)

    if args.event == 'merged':
        handle_change_merged(change, args.dry_run)
    elif args.event == 'updated':
        handle_change_updated(change, args.dry_run)


if __name__ == '__main__':
    main()
