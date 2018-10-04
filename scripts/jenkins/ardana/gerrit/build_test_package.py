#!/usr/bin/env python

"""
This file takes in a list of gerrit changes to build into the supplied OBS
project.
"""

import contextlib
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import requests

import sh

sys.path.append(os.path.dirname(__file__))
from gerrit_project_map import gerrit_project_map  # noqa: E402

GERRIT_URL = 'https://gerrit.suse.provo.cloud'

# We use a more complex regex that matches both formats of Depends-On so that
# we preserve the order in which they are discovered.
DEPENDS_ON_RE = re.compile(
    r"^\W*Depends-On: ("
    r"((http(s)?:\/\/)?gerrit\.suse\.provo\.cloud\/(\/)?(\#\/c\/)?(\d+).*?)"
    r"|(I[0-9a-f]{40})"
    r")\s*$",
    re.MULTILINE | re.IGNORECASE)


def find_dependency_headers(message):
    # Search for Depends-On headers
    dependencies = []

    for match in DEPENDS_ON_RE.findall(message):
        # Grab out the change-id
        if match[6]:
            # Group 6 is the change-id matcher from the URL
            # NOTE: Because we only pull out the change-id here, if a patchset
            #       was included in the URL it will be ignored at this point.
            #       The check later on will be missed and thus no warning is
            #       raised.
            dependencies.append(match[6])
        elif match[7]:
            # Group 7 is the gerrit ID in format Ia32...234a (41 chars)
            dependencies.append(match[7])
    # Reverse the order so that we process the oldest Depends-On first
    dependencies.reverse()
    return dependencies


@contextlib.contextmanager
def cd(dir):
    pwd = os.getcwd()
    try:
        os.chdir(dir)
        yield
    finally:
        os.chdir(pwd)


def cleanup_path(path):
    if os.path.exists(path):
        shutil.rmtree(path)


class GerritChange:
    """
    Holds the state of a gerrit change
    """

    @staticmethod
    def _query_gerrit(query):
        query_url = GERRIT_URL + query
        print("Running query %s" % query_url)
        response = requests.get(query_url)
        print("Got response: %s" % response)
        return json.loads(response.text.replace(")]}'", ''))

    def __init__(self, change_id, try_branches=['master']):
        print("Processing given change id: %s" % change_id)
        if change_id.isdigit():
            self.id = change_id
            self._get_numeric_change()
        elif change_id.split(',')[0].isdigit():
            print("Warning: Ignoring given patchset number for change %s."
                  " Latest patchset will be used." % change_id)
            self.id = change_id.split(',')[0]
            self._get_numeric_change()
        elif change_id.startswith('I') and len(change_id) == 41:
            self._get_change_id(change_id, try_branches)
        else:
            raise Exception("Unknown change id format (%s)" % change_id)

        # Take the known self._change_object and load the attributes we want
        self._load_change_object()

    def _get_numeric_change(self):
        """
        Get a change object from a deterministic numeric change number
        """
        query = '/changes/%(id)s/' % {'id': self.id}
        query += '?o=CURRENT_REVISION&o=CURRENT_COMMIT'
        response_json = self._query_gerrit(query)

        self._change_object = response_json

    def _get_change_id(self, change_id, try_branches):
        """
        Get a change object from an ambiguous change ID by matching the first
        given try_branches
        """
        query = '/changes/?q=%(change_id)s' % {'change_id': change_id}
        query += '&o=CURRENT_REVISION&o=CURRENT_COMMIT'
        response_json = self._query_gerrit(query)

        matches = []
        for branch in try_branches:
            for change_obj in response_json:
                if branch == change_obj['branch']:
                    matches.append(change_obj)
            if len(matches) > 0:
                # We have matched a preferable branch, we don't need to
                # coninue checking
                break

        if len(matches) > 1:
            raise Exception(
                "Unable to get a unique change for %s given the branches seen "
                "so far. This can also happen if the same change-id is used "
                "in multiple gerrit projects." % change_id
            )
        elif len(matches) != 1:
            raise Exception("Unable to find a change for %s" % change_id)

        self.id = str(matches[0]['_number'])
        self._change_object = matches[0]

    def _load_change_object(self):
        self.change_id = self._change_object['change_id']
        self.gerrit_project = self._change_object['project'].split('/')[1]
        self.status = self._change_object['status']
        current_revision = self._change_object['current_revision']
        revision_obj = self._change_object['revisions'][current_revision]
        self.url = revision_obj['fetch']['anonymous http']['url']
        self.ref = revision_obj['fetch']['anonymous http']['ref']
        self.target = self._change_object['branch']
        self.subject = revision_obj['commit']['subject']
        self.commit_message = revision_obj['commit']['message']

    def __repr__(self):
        return "<GerritChange %s>" % self.id


class OBSPackage:
    """
    Manage the workspace of a package.
    """

    def __init__(self, gerrit_project, url, target_branch, source_workspace):
        self.gerrit_project = gerrit_project
        self.name = gerrit_project_map()[gerrit_project]
        self.url = url
        self.target_branch = target_branch
        self.test_branch = 'test-merge'
        self.source_workspace = source_workspace
        self.source_dir = os.path.join(
            self.source_workspace, '%s.git' % self.gerrit_project)
        self._prep_workspace()
        self._applied_changes = set()

    def _prep_workspace(self):
        with cd(self.source_workspace):
            if not os.path.exists('%s.git/.git' % self.gerrit_project):
                print("Cloning gerrit project %s" % self.gerrit_project)
                sh.git('clone', self.url, '%s.git' % self.gerrit_project)

        with cd(self.source_dir):
            # If another change is already checked out on this branch,
            # don't clobber it. This shouldn't happen when building in a clean
            # workspace so long as there is only one Package per
            # gerrit_project.
            try:
                sh.git('checkout', self.test_branch)
            except sh.ErrorReturnCode_1:
                sh.git('checkout', '-b', self.test_branch,
                       'origin/%s' % self.target_branch)

    def add_change(self, change):
        """
        Merge a given GerritChange into the git source_workspace if possible
        """
        print("Attempting to add %s to %s" % (change, self))
        if change in self._applied_changes:
            print("Change %s has already been applied" % change)
            return
        if change.target != self.target_branch:
            raise Exception(
                "Cannot merge change %s from branch %s onto target branch %s "
                "in package %s" %
                (change, change.target, self.target_branch, self))
        # Check change isn't already merged.
        if change.status == "MERGED":
            print("Change %s has already been merged in gerrit" % change)
            return
        elif change.status == "ABANDONED":
            raise Exception("Can not merge abandoned change %s" % change)

        with cd(self.source_dir):
            # If another change has already applied this change by having it as
            # one of its ancestry commits then the following merge will do a
            # harmless null operation
            print("Fetching ref %s" % change.ref)
            sh.git('fetch', self.url, change.ref)
            sh.git('merge', '--no-edit', 'FETCH_HEAD')
            self._applied_changes.add(change)

    def get_depends_on_changes(self):
        """
        Return a list of numeric change_id's that are dependencies of the
        current repo state
        """
        # NOTE: Because a given gerrit change may be at the bottom of a tail of
        #       commits we can't just check the changes as they merge. Instead
        #       we must also check for any "Depends-On" strings in any commits
        #       that may have also been merged on top of the target branch

        with cd(self.source_dir):
            log_messages = subprocess.check_output(
                ["git", "log", "origin/%s..HEAD" % self.target_branch]).decode(
                    'utf-8')

        dependencies = find_dependency_headers(log_messages)
        if dependencies:
            print("Found the following dependencies between %s..HEAD:"
                  % self.target_branch)
            print(dependencies)
        return dependencies

    def applied_change_numbers(self):
        return ", ".join([change.id for change in self._applied_changes])

    def __repr__(self):
        return "<OBSPackage %s>" % self.name


class OBSProject:
    """
    Manage the OBS Project
    """

    def __init__(self, obs_test_project_name, obs_linked_project,
                 obs_repository):
        self.obs_test_project_name = obs_test_project_name
        self.obs_linked_project = obs_linked_project
        self.obs_repository = obs_repository
        self._create_test_project()
        self.packages = set()

    def _create_test_project(self):
        repo_metadata = """
<project name="%(obs_test_project_name)s">
<title>Autogenerated CI project</title>
<description/>
<link project="%(obs_linked_project)s"/>
<person userid="opensuseapibmw" role="maintainer"/>
<publish>
    <enable repository="standard"/>
</publish>
<repository name="standard" rebuild="direct" block="local"
    linkedbuild="localdep">
    <path project="%(obs_linked_project)s" repository="%(obs_repository)s"/>
    <arch>x86_64</arch>
</repository>
</project>
""" % {
            'obs_test_project_name': self.obs_test_project_name,
            'obs_linked_project': self.obs_linked_project,
            'obs_repository': self.obs_repository
        }

        with tempfile.NamedTemporaryFile() as meta:
            meta.write(repo_metadata)
            meta.flush()
            print("Creating test project %s linked to project %s" %
                  (self.obs_test_project_name, self.obs_linked_project))
            sh.osc('-A', 'https://api.suse.de', 'api', '-T', meta.name,
                   '/source/%s/_meta' % self.obs_test_project_name)
            sh.osc('-A', 'https://api.suse.de', 'deleterequest',
                   self.obs_test_project_name, '--accept-in-hours', 720,
                   '-m', 'Auto delete after 30 days.')

    def add_test_package(self, package):
        """
        Create a package in the OBS Project
         - Copy the given package into the OBS Project
         - Update the service file to use the local git checkout of the package
           source
         - Grab the local source
         - Commit the package to be built into the project
        """

        print("Creating test package %s" % package.name)

        # Clean up any checkouts from previous builds
        cleanup_path(os.path.join(self.obs_test_project_name, package.name))

        # Copy the package from the upstream project into our teste project
        sh.osc('-A', 'https://api.suse.de', 'copypac', '--keep-link',
               self.obs_linked_project, package.name,
               self.obs_test_project_name)
        # Checkout the package from obs
        sh.osc('-A', 'https://api.suse.de', 'checkout',
               self.obs_test_project_name, package.name)

        # cd into the checked out package
        with cd(os.path.join(self.obs_test_project_name, package.name)):
            with open('_service', 'r+') as service_file:
                # Update the service file to use the git state in our workspace
                service_def = service_file.read()
                service_def = re.sub(
                    r'<param name="url">.*</param>',
                    '<param name="url">%s</param>' % package.source_dir,
                    service_def)
                service_def = re.sub(
                    r'<param name="revision">.*</param>',
                    '<param name="revision">%s</param>' % package.test_branch,
                    service_def)
                service_file.seek(0)
                service_file.write(service_def)
                service_file.truncate()
            # Run the osc service and commit the changes to OBS
            sh.osc('rm', glob.glob('%s*.obscpio' % package.name))
            sh.osc('service', 'disabledrun')
            sh.osc('add', glob.glob('%s*.obscpio' % package.name))
            sh.osc('commit', '-m',
                   'Testing gerrit changes applied to %s'
                   % package.applied_change_numbers())
        self.packages.add(package)

    def wait_for_package(self, package):
        """
        Wait for a particular package to complete building
        """

        print("Waiting for %s to build" % package.name)
        # cd into the checked out package
        with cd(os.path.join(self.obs_test_project_name, package.name)):
            while 'unknown' in sh.osc('results'):
                print("Waiting for build to be scheduled")
                time.sleep(3)
            print("Waiting for build results")
            for attempt in range(3):
                results = sh.osc('results', '--watch')
                print("Build results: %s" % results)
                if 'broken' in results:
                    # Sometimes results --watch ends too soon, give it a few
                    # retries before actually failing
                    print("Sleeping for 10s before rechecking")
                    time.sleep(10)
                    continue
                else:
                    break

        if 'succeeded' not in results:
            print("Package build failed.")
            return False
        return True

    def wait_for_all_results(self):
        """
        Wait for all the packages to complete building
        """

        # Check all packages are built
        # NOTE(jhesketh): this could be optimised to check packages in
        # parallel. However, the worst case scenario at the moment is
        # "time for longest package" + "time for num_of_package checks" which
        # isn't too much more than the minimum
        # ("time for longest package" + "time for one check")
        for package in self.packages:
            result = self.wait_for_package(package)
            if not result:
                return False
        return True

    def cleanup_test_packages(self):
        """
        Removes from disk the osc copies of any packages
        """
        for package in self.packages:
            cleanup_path(
                os.path.join(self.obs_test_project_name, package.name))


def test_project_name(change_ids, home_project):
    return '%s:ardana-ci-%s' % (home_project, '-'.join(change_ids))


def build_test_packages(change_ids, obs_linked_project, home_project,
                        obs_repository):

    # The Jenkins workspace we are building in
    workspace = os.getcwd()
    # The location for package sources
    source_workspace = os.path.join(workspace, 'source')
    cleanup_path(source_workspace)

    if not os.path.exists(source_workspace):
        os.mkdir(source_workspace)

    obs_test_project_name = test_project_name(change_ids, home_project)

    obs_project = OBSProject(
        obs_test_project_name, obs_linked_project, obs_repository)

    # Keep track of processed changes
    processed_changes = []
    # Keep track of the packages to build as a dict of
    # 'gerrit_project': Package()
    packages = {}

    # Grab each change for the supplied change_ids. As we go through the
    # changes the change_ids list may expand with dependencies. These are also
    # processed. If a change has already been processed we skip it to avoid
    # circular dependencies.
    try_branches = ['master']
    for id in change_ids:
        if id in processed_changes:
            # Duplicate dependency, skipping..
            continue
        c = GerritChange(id, try_branches)
        if c.target not in try_branches:
            # Save the branch as a hint to disambiguate cross-repo
            # dependencies.
            try_branches.insert(0, c.target)
        processed_changes.append(c.id)

        # skip packages that don't have asssociated RPMs
        if c.gerrit_project not in gerrit_project_map():
            print("Warning: Project %s has no RPM, Skipping"
                  % c.gerrit_project)

        else:
            # Create the package if it doesn't exist already
            if c.gerrit_project not in packages:
                # NOTE: The first change processed for a package determines
                #       the target branch for that package. All subsquent
                #       changes must match the target branch.
                packages[c.gerrit_project] = OBSPackage(
                    c.gerrit_project, c.url, c.target, source_workspace)

            # Merge the change into the package
            packages[c.gerrit_project].add_change(c)

            # Add the dependent changes to the change_ids to process
            change_ids.extend(
                packages[c.gerrit_project].get_depends_on_changes())

    # Add the packages into the obs project and begin building them
    for project_name, package in packages.items():
        obs_project.add_test_package(package)

    # Wait for, and grab, the obs results
    results = obs_project.wait_for_all_results()

    # Cleanup created files
    obs_project.cleanup_test_packages()
    cleanup_path(source_workspace)

    return results


def main():
    # A list of change id's to apply to packages
    change_ids = os.environ['gerrit_change_ids'].split(',')
    # The OBS project to link from
    obs_linked_project = os.environ['develproject']
    # The home project to build in
    home_project = os.environ['homeproject']
    # The target repository
    obs_repository = os.environ['repository']

    results = build_test_packages(
        change_ids, obs_linked_project, home_project, obs_repository)

    if not results:
        sys.exit(1)
    sys.exit(0)


if __name__ == '__main__':
    main()
