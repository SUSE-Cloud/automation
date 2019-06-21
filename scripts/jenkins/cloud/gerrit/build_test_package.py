#!/usr/bin/env python

"""
This file takes in a list of gerrit changes to build into the supplied OBS
project.
"""

import argparse
import contextlib
import glob
import os
import re
import shutil
import sys
import tempfile
import time

import sh


if sys.version_info[0] < 3:
    from urllib import quote_plus
else:
    from urllib.parse import quote_plus

try:
    from xml.etree import cElementTree as ET
except ImportError:
    import cElementTree as ET

sys.path.append(os.path.dirname(__file__))

from gerrit import GERRIT_URL, GerritApiCaller, GerritChange  # noqa: E402,I100

from gerrit_settings import gerrit_project_map, \
    obs_project_settings  # noqa: E402,I100


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


class OBSPackage:
    """
    Manage the workspace of a package.
    """

    def __init__(self, gerrit_project, url, target_branch, source_workspace):
        self.gerrit_project = gerrit_project
        self.name = gerrit_project_map(target_branch)[gerrit_project]
        self.url = url
        self.target_branch = target_branch
        self.test_branch = 'test-merge'
        self.source_workspace = source_workspace
        self.source_dir = os.path.join(
            self.source_workspace, '%s.git' % self.gerrit_project)
        self._workspace_ready = False
        self._applied_changes = set()

    def prep_workspace(self):

        if self._workspace_ready:
            return

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

        self._workspace_ready = True

    def add_change(self, change):
        """
        Merge a given GerritChange into the git source_workspace if possible
        """
        print("Attempting to add %s to %s" % (change, self))
        if change in self._applied_changes:
            print("Change %s has already been applied" % change)
            return
        if change.branch != self.target_branch:
            raise Exception(
                "Cannot merge change %s from branch %s onto target branch %s "
                "in package %s" %
                (change, change.branch, self.target_branch, self))
        # Check change isn't already merged.
        if change.status == "MERGED":
            print("Change %s has already been merged in gerrit" % change)
            return
        elif change.status == "ABANDONED":
            raise Exception("Can not merge abandoned change %s" % change)

        self.prep_workspace()

        with cd(self.source_dir):
            # If another change has already applied this change by having it as
            # one of its ancestry commits then the following merge will do a
            # harmless null operation
            print("Fetching ref %s" % change.ref)
            sh.git('fetch', self.url, change.ref)
            sh.git('merge', '--no-edit', 'FETCH_HEAD')
            self._applied_changes.add(change)

    def applied_change_numbers(self):
        return ", ".join([change.id for change in self._applied_changes])

    def has_applied_changes(self):
        return bool(self._applied_changes)

    def __repr__(self):
        return "<OBSPackage %s>" % self.name


def find_in_osc_file(description):

    def wrapper(find_func):

        def wrapped_f(project, osc_filename=None,
                      package=None, osc_data=None):
            if osc_data:
                return find_func(project, osc_data)
            osc_data = sh.osc(
                '-A', 'https://api.suse.de', 'cat',
                project.obs_linked_project,
                package.name,
                osc_filename)

            osc_data_item = find_func(project, str(osc_data))
            if not osc_data_item:
                raise ValueError(
                    "Could not find a %s in "
                    "https://build.suse.de/package/view_file/%s/%s/%s"
                    % (description, project.obs_linked_project,
                       package.name, osc_filename))
            return osc_data_item
        return wrapped_f
    return wrapper


class OBSProject(GerritApiCaller):
    """
    Manage the OBS Project
    """

    def __init__(self, obs_test_project_name, obs_linked_project,
                 obs_repository, obs_project_description):
        self.obs_test_project_name = obs_test_project_name
        self.obs_linked_project = obs_linked_project
        self.obs_repository = obs_repository
        self.obs_project_description = obs_project_description
        self._create_test_project()
        self.packages = set()

    def _create_test_project(self):
        repo_metadata = """
<project name="%(obs_test_project_name)s">
<title>Autogenerated CI project</title>
<description>
    %(obs_project_description)s
</description>
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
            'obs_repository': self.obs_repository,
            'obs_project_description': self.obs_project_description
        }

        with tempfile.NamedTemporaryFile(mode='w+') as meta:
            meta.write(repo_metadata)
            meta.flush()
            print("Creating test project %s linked to project %s" %
                  (self.obs_test_project_name, self.obs_linked_project))
            sh.osc('-A', 'https://api.suse.de', 'api', '-T', meta.name,
                   '/source/%s/_meta' % self.obs_test_project_name)

        # The '--all' parameter is required starting with v0.164.0
        osc_version = int(sh.osc('--version').strip().split('.')[1])
        sh.osc('-A', 'https://api.suse.de', 'deleterequest',
               self.obs_test_project_name, '--accept-in-hours', 720,
               '-m', 'Auto delete after 30 days.',
               '--all' if osc_version > 163 else '')

    @find_in_osc_file('obs_scm filename')
    def _get_obsinfo_basename(self, service_def):
        root = ET.fromstring(service_def)
        nodes = root.findall(
            './service[@name="obs_scm"]/param[@name="filename"]')
        if len(nodes) != 1 or not nodes[0].text:
            return None
        return nodes[0].text

    @find_in_osc_file('obsinfo commit value')
    def _get_obsinfo_commit(self, obsinfo):
        matches = re.findall(r'^commit: (\S+)$', obsinfo, re.MULTILINE)
        if len(matches) != 1:
            return None
        return matches[0]

    def get_target_branch_head(self, package):
        gerrit_query = "/projects/{}/branches/{}".format(
            quote_plus('ardana/{}'.format(package.gerrit_project)),
            quote_plus(package.target_branch))
        head_commit = self._query_gerrit(gerrit_query)['revision']
        return head_commit

    def is_current(self, package):
        if package.has_applied_changes():
            return False
        obsinfo_basename = self._get_obsinfo_basename('_service', package)
        ibs_package_commit = self._get_obsinfo_commit(
            '%s.obsinfo' % obsinfo_basename, package)
        gerrit_branch_commit = self.get_target_branch_head(package)

        return ibs_package_commit == gerrit_branch_commit

    def add_test_package(self, package):
        """
        Create a package in the OBS Project
         - Copy the given package into the OBS Project
         - Update the service file to use the local git checkout of the package
           source
         - Grab the local source
         - Commit the package to be built into the project
        """

        if self.is_current(package):
            print(
                "Skipping %s as the inherited package is the same."
                % package.name)
            return

        print("Creating test package %s" % package.name)

        package.prep_workspace()

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
                obsinfo_basename = self._get_obsinfo_basename(
                    osc_data=service_def)
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
            sh.osc('rm', glob.glob('%s*.obscpio' % obsinfo_basename))
            env = os.environ.copy()
            # TODO use proper api, once available from:
            # https://github.com/openSUSE/obs-service-tar_scm/issues/258
            # Workaround to make obs_scm work with a local path.
            # Otherwise it only works with remote URLs.
            env['TAR_SCM_TESTMODE'] = '1'
            sh.osc('service', 'disabledrun', _env=env)
            sh.osc('add', glob.glob('%s*.obscpio' % obsinfo_basename))
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


def test_project_name(home_project, build_number):
    return '%s:ardana-ci-%s' % \
           (home_project, build_number)


def build_test_packages(change_ids, obs_linked_project, home_project,
                        obs_repository, build_number):

    print('Attempting to build packages for changes {}'.format(
        ', '.join(change_ids)))

    # The target branch associated with the first change is used for
    # all changes
    branch = None

    # Grab each change for the supplied change_ids
    changes = []
    for id in change_ids:
        c = GerritChange(id, branch=branch)
        branch = branch or c.branch
        changes.append(c)
        # Add the dependent changes to the changes list to process
        changes.extend(c.get_dependencies())

    # Use the default OBS linked project and repository configured for
    # the target branch, if not supplied as arguments
    project_settings = obs_project_settings(branch)
    obs_linked_project = obs_linked_project or \
        project_settings['develproject']
    obs_repository = obs_repository or project_settings['repository']

    # The Jenkins workspace we are building in
    workspace = os.getcwd()
    # The location for package sources
    source_workspace = os.path.join(workspace, 'source')
    cleanup_path(source_workspace)

    if not os.path.exists(source_workspace):
        os.mkdir(source_workspace)

    obs_test_project_name = test_project_name(home_project, build_number)
    obs_test_project_description = "Packages built with gerrit changes: %s" % \
        (', '.join(change_ids).replace('/', '-'))

    obs_project = OBSProject(
        obs_test_project_name, obs_linked_project, obs_repository,
        obs_test_project_description)

    # Keep track of processed changes
    processed_changes = []
    # Keep track of the packages to build as a dict of
    # 'gerrit_project': Package()
    packages = {}

    # We process the supplied changes, as well as their dependencies.
    # If a change has already been processed we skip it to avoid circular
    # dependencies.
    for c in changes:
        if c in processed_changes:
            # Duplicate dependency, skipping..
            continue
        processed_changes.append(c)

        # skip packages that don't have asssociated RPMs
        if c.gerrit_project not in gerrit_project_map(branch):
            print("Warning: Project %s has no RPM, Skipping"
                  % c.gerrit_project)
        else:
            # Create the package if it doesn't exist already
            if c.gerrit_project not in packages:
                # NOTE: The first change processed for a package determines
                #       the target branch for that package. All subsquent
                #       changes must match the target branch.
                packages[c.gerrit_project] = OBSPackage(
                    c.gerrit_project, c.url, c.branch, source_workspace)

            # Merge the change into the package
            packages[c.gerrit_project].add_change(c)

    for project_name, package in gerrit_project_map(branch).items():
        if project_name in packages:
            continue
        url = GERRIT_URL + "/ardana/" + project_name
        packages[project_name] = OBSPackage(
            project_name, url, branch, source_workspace)

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
    parser = argparse.ArgumentParser(
        description='Build OBS packages corresponding to one or more '
                    'Gerrit changes and their dependencies. '
                    'If --develproject or --repository are not supplied, they '
                    'will be determined automatically based on the Gerrit '
                    'change target branch and the gerrit-settings.json file')
    parser.add_argument('-c', '--changes', action='append', required=True,
                        help='Gerrit change number (e.g. 1234) or change '
                             'number and patchset number (e.g. 1234/2)')
    parser.add_argument('--homeproject', default=None, required=True,
                        help='Project in OBS that will act as the parent '
                             'project for the newly generated test project '
                             '(e.g. home:username)')
    parser.add_argument('--buildnumber', default='NA', required=False,
                        help='A unique number used for the build homeproject. '
                             'When ran from Jenkins this is the job build '
                             'number.')
    parser.add_argument('--develproject', default=None,
                        help='The OBS development project that will be linked '
                             'against (e.g. Devel:Cloud:9:Staging)')
    parser.add_argument('--repository', default=None,
                        help='Name of the repository in OBS against which to '
                             'build the test packages (e.g. SLE_12_SP4)')
    args = parser.parse_args()

    results = build_test_packages(
        args.changes, args.develproject, args.homeproject, args.repository,
        args.buildnumber)

    if not results:
        sys.exit(1)
    sys.exit(0)


if __name__ == '__main__':
    main()
