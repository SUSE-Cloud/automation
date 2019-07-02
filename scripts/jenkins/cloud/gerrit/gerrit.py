from __future__ import print_function

import argparse
import json
import os
import re
import sys
from functools import partial

try:
    from pygerrit2 import GerritRestAPI, GerritReview, HTTPBasicAuthFromNetrc
except ImportError:
    # Only reviewing and merging functionality depends on pygerrit2
    pass

import requests

GERRIT_URL = 'https://gerrit.prv.suse.net'

GERRIT_VERIFY = os.environ.get('GERRIT_VERIFY', True) in ['true', '1', True]

# We use a more complex regex that matches both formats of Depends-On so that
# we preserve the order in which they are discovered.
DEPENDS_ON_RE = re.compile(
    r"^\W*Depends-On: ("
    r"((http(s)?:\/\/)?gerrit\.prv\.suse\.net\/(\/)?(\#\/c\/)?(\d+).*?)"
    r"|(I[0-9a-f]{40})"
    r")\s*$",
    re.MULTILINE | re.IGNORECASE)


print_err = partial(print, file=sys.stderr)


def argparse_gerrit_change_type(change_id):
    change_regex = re.compile(r"^[0-9]+(/[0-9]+)?$")
    if not change_regex.match(change_id):
        raise argparse.ArgumentTypeError('Invalid Gerrit change ID value: '
                                         '{}'.format(change_id))
    return change_id


class GerritApiCaller:
    _CACHE = {}

    @staticmethod
    def _query_gerrit(query):
        if query in GerritApiCaller._CACHE:
            return GerritApiCaller._CACHE[query]

        query_url = GERRIT_URL + query
        print_err("Running query %s" % query_url)
        response = requests.get(query_url, verify=GERRIT_VERIFY)
        print_err("Got response: %s" % response)
        GerritApiCaller._CACHE[query] = result = \
            json.loads(response.text.replace(")]}'", ''))
        return result


class GerritChange(GerritApiCaller):
    """
    Holds the state of a gerrit change
    """

    def __eq__(self, other):
        return self.id == other.id

    def __hash__(self):
        return hash(self.id)

    def __init__(self, change_id=None, branch=None,
                 patchset=None, change_object=None):
        if change_id:
            print_err("Processing given change id: %s" % change_id)
            if change_id.isdigit():
                self._get_numeric_change(change_id, branch, patchset)
            elif change_id.split('/')[0].isdigit():
                change_id, patchset = change_id.split('/')
                self._get_numeric_change(change_id, branch, patchset)
            elif change_id.startswith('I') and len(change_id) == 41:
                self._get_change_id(change_id, branch, patchset)
            else:
                raise Exception("Unknown change id format (%s)" % change_id)
        elif change_object:
            self._set_change_object(change_object)
        else:
            raise Exception("Unsupported combination of arguments. Either "
                            "'change_id' or 'change_object' must be supplied")

        # Take the known self._change_object and load the attributes we want
        self._load_change_object(patchset)
        self._dependencies = None
        self._dependency_headers = None
        self._implicit_dependencies = None
        self._related_changes = None

    def _get_numeric_change(self, change_id, branch=None, patchset=None):
        """
        Get a change object from a deterministic numeric change number
        """
        query = '/changes/{}/'.format(change_id)
        query += '?o=ALL_REVISIONS&o=ALL_COMMITS&o=SUBMITTABLE'
        response_json = self._query_gerrit(query)

        if branch and response_json['branch'] != branch:
            raise Exception("Change {} does not target branch {}".format(
                change_id, branch))

        self._set_change_object(response_json)

    def _get_change_id(self, change_id, branch=None, patchset=None):
        """
        Get a change object from an ambiguous change ID and matching the
        given branch
        """
        query = '/changes/?q={}'.format(change_id)
        if branch:
            query += '+branch:{}'.format(branch)
        query += '&o=ALL_REVISIONS&o=ALL_COMMITS&o=SUBMITTABLE'
        response_json = self._query_gerrit(query)

        if len(response_json) > 1:
            raise Exception(
                "Unable to get a unique change for {}{}."
                "This can also happen if the same change-id is used "
                "in multiple gerrit projects.".format(
                    change_id,
                    " and branch {}".format(branch) if branch else '')
            )
        elif len(response_json) != 1:
            raise Exception("Unable to find a change for {}{}".format(
                change_id, " and branch {}".format(branch) if branch else ''))

        self._set_change_object(response_json[0])

    def _set_change_object(self, change_object):
        self._change_object = change_object

    def _load_change_object(self, patchset=None):
        self.id = str(self._change_object['_number'])
        self.change_id = self._change_object['change_id']
        self.gerrit_project = self._change_object['project'].split('/')[1]
        self.status = self._change_object['status']
        self.revision = self.current_revision = \
            self._change_object['current_revision']
        if patchset:
            revisions = [
                r_id
                for r_id, r in self._change_object['revisions'].items()
                if r['_number'] == int(patchset)]
            if len(revisions) != 1:
                raise Exception(
                    "Unable to find patchset {} for change {} ".format(
                        patchset, self.id))
            self.revision = revisions[0]
        self.is_current = (self.revision == self.current_revision)
        revision_obj = self._change_object['revisions'][self.revision]
        self.patchset = str(revision_obj['_number'])
        self.url = revision_obj['fetch']['anonymous http']['url']
        self.ref = revision_obj['fetch']['anonymous http']['ref']
        self.branch = self._change_object['branch']
        self.subject = revision_obj['commit']['subject']
        self.commit_message = revision_obj['commit']['message']
        self.parent_revisions = [r['commit']
                                 for r in revision_obj['commit']['parents']]
        self.mergeable = self._change_object.get('mergeable', False)
        self.submittable = self._change_object.get('submittable', False)
        self.gerrit_url = "{}/#/c/{}/{}".format(GERRIT_URL, self.id,
                                                self.patchset)

    def _find_dependency_headers(self):
        if self._dependency_headers is not None:
            return self._dependency_headers

        # Search for Depends-On headers
        self._dependency_headers = []

        for match in DEPENDS_ON_RE.findall(self.commit_message):
            # Grab out the change-id
            if match[6]:
                # Group 6 is the change-id matcher from the URL
                # NOTE: Because we only pull out the change-id here,
                #       if a patchset was included in the URL it will be
                #       ignored at this point.
                #       The check later on will be missed and thus no warning
                #       is raised.
                self._dependency_headers.append(match[6])
            elif match[7]:
                # Group 7 is the gerrit ID in format Ia32...234a (41 chars)
                self._dependency_headers.append(match[7])
        return self._dependency_headers

    def _get_related_changes(self):
        """
        Get a list of GerritChange objects related to this change revision.
        Related changes are open changes that either depend on, or are
        dependencies of the local change and revision.

        :return: A tuple consisting of two lists, the first with changes that
        have one or more revisions that depend on this revision, the second
        with changes on which this revision depends.
        """

        if self._related_changes is not None:
            return self._related_changes

        query = '/changes/{}/revisions/{}/related'.format(self.id,
                                                          self.patchset)
        response_json = self._query_gerrit(query)

        current_list = references = []
        dependencies = []
        # The /related result is ordered the same as a `git log` output,
        # it lists the entries ordered by their ancestry:
        #   - first, references (changes that depend on this one)
        #   - then, the current change, which we skip
        #   - then, implicit dependencies
        for co in response_json['changes']:
            if str(co['_change_number']) == self.id:
                current_list = dependencies
                continue
            current_list.append(GerritChange(str(co['_change_number']),
                                             patchset=co['_revision_number']))

        # The returned references may not all be direct descendants of this
        # revision. Some of them may reference earlier or older patchsets
        # of this change or of its children. We skip these changes, because
        # they are not current.
        # The only way to reconstruct the correct chain of actual descendants
        # is to follow the chain of parent commits
        current_revisions = [self.revision]
        current_refs = []
        for revision in current_revisions:
            for ref in references:
                if revision in ref.parent_revisions:
                    current_refs.append(ref)
                    current_revisions.append(ref.revision)

        self._related_changes = (current_refs, dependencies)
        return self._related_changes

    def get_implicit_dependencies(self):
        """
        Get a list of GerritChange objects representing implicit dependencies,
        computed from the list of related changes.

        :return:
        """

        _, dependencies = self._get_related_changes()
        return dependencies

    def get_implicit_references(self):
        """
        Get a list of GerritChange objects that depend on the local change.

        :return:
        """

        references, _ = self._get_related_changes()
        return references

    def _load_dependencies(self, loaded_deps):
        for change in self.get_implicit_dependencies():
            if change in loaded_deps:
                continue
            loaded_deps.append(change)
        for change_id in self._find_dependency_headers():
            change = GerritChange(change_id, self.branch)
            if change in loaded_deps:
                continue
            loaded_deps.append(change)

    def get_dependencies(self):
        """
        Walks the Depends-On dependency tree associated with this change and
        returns a list of unique GerritChange objects representing all
        direct and indirect dependencies.

        :return collected GerritChange objects
        """

        if self._dependencies is not None:
            return self._dependencies

        self._dependencies = [self]
        for change in self._dependencies:
            change._load_dependencies(self._dependencies)
        self._dependencies.pop(0)
        return self._dependencies

    def has_explicit_dependency(self, change):
        """
        Check if the supplied GerritChange object is a direct explicit
        dependency of this change, specified through a Depends-On commit
        message marker.

        :param change: GerritChange object
        :return: bool
        """
        deps = self._find_dependency_headers()
        return change.id in deps or change.change_id in deps

    def has_implicit_dependency(self, change):
        """
        Check if the supplied GerritChange object is a direct implicit
        dependency of this change (i.e. its revision is listed as a parent).

        :param change: GerritChange object
        :return: bool
        """
        return change.revision in self.parent_revisions

    def review(self, label=None, vote=1, message=''):
        print_err("Posting {} review for change: {}".format(
            " {}: {}".format(label, vote) if label else '', self))
        auth = HTTPBasicAuthFromNetrc(url=GERRIT_URL)
        rest = GerritRestAPI(url=GERRIT_URL, auth=auth, verify=GERRIT_VERIFY)
        rev = GerritReview()
        rev.set_message(message)
        if label:
            rev.add_labels({label: vote})

        rest.review(self.id, self.patchset, rev)

    def merge(self):
        auth = HTTPBasicAuthFromNetrc(url=GERRIT_URL)
        rest = GerritRestAPI(url=GERRIT_URL, auth=auth, verify=GERRIT_VERIFY)
        url_path = '/changes/{}/submit'.format(self.id)
        rest.post(url_path)

    def __repr__(self):
        return "<GerritChange {}/{} ({}/{}): '{}'>".format(
            self.id, self.patchset, self.gerrit_project,
            self.branch, self.subject)


class GerritChangeSet(GerritApiCaller):
    """
    Holds a set of GerritChange objects
    """

    def __init__(self, *query_args):
        query = '+'.join(query_args)
        self._get_changes(query)

        # Create GerritChange object corresponding to the query results
        self._load_changes()

    def _get_changes(self, query):
        """
        Get a set of change objects matching the supplied query
        """
        query = '/changes/?q={}'.format(query)
        query += '&o=ALL_REVISIONS&o=ALL_COMMITS&o=SUBMITTABLE'
        response_json = self._query_gerrit(query)
        self._change_objects = response_json

    def _load_changes(self):
        # FIXME: optimization - we might not need to load all changes into
        # GerritChange objects, e.g. a set of helper functions targeting
        # the query response collected here might answer some shallow
        # questions
        self._changes = [GerritChange(change_object=_change_object)
                         for _change_object in self._change_objects]

    def changes(self):
        return self._changes
