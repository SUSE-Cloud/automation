#!/usr/bin/python

# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

import argparse
import functools
import os
import sys
import tempfile

import sh
from sh import Command

IBS_MAPPING = {
    'release/stoney/master': 'Devel:Cloud:4:Staging',
    'release/tex/master':    'Devel:Cloud:5:Staging',
    'master':                'Devel:Cloud:6:Staging'
}

CLOUDSRC = {
    'release/stoney/master': 'develcloud4',
    'release/tex/master':    'develcloud5',
    'master':                'develcloud6'
}

MKCLOUD_HA_PARAMETERS = (
    'nodenumber=4', 'hacloud=1',
    'networkingmode=vxlan',
    'clusterconfig="data+services+network=2"')

MKCLOUD_HYPERV_PARAMETERS = (
    'networkingplugin=linuxbridge',
    'libvirt_type=hyperv',
    'networkingmode=vlan')

MKCLOUD_CEPH_PARAMETERS = (
    'nodenumber=4', 'want_ceph=1',
    'networkingplugin=linuxbridge')

JOB_PARAMETERS = {
    'crowbar-ha': MKCLOUD_HA_PARAMETERS,
    'crowbar-hyperv': MKCLOUD_HYPERV_PARAMETERS,
    'crowbar-ceph': MKCLOUD_CEPH_PARAMETERS,
    'barclamp-ceph': MKCLOUD_CEPH_PARAMETERS,
    'barclamp-hyperv': MKCLOUD_HYPERV_PARAMETERS,
    'barclamp-pacemaker': MKCLOUD_HA_PARAMETERS
}

htdocs_dir = '/srv/mkcloud'
htdocs_url = 'http://clouddata.cloud.suse.de/mkcloud/'

iosc = functools.partial(
    Command('/usr/bin/osc'), '-A', 'https://api.suse.de')


def ghs_set_status(repo, head_sha1, status):
    ghs = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'github-status/github-status.rb')))

    ghs('-r', 'crowbar/' + repo,
        '-c', head_sha1, '-a', 'set-status', '-s', status)


def jenkins_job_trigger(repo, github_opts, cloudsource, ptfdir):
    print("triggering jenkins job with " + htdocs_url + ptfdir)

    jenkins = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'jenkins/jenkins-job-trigger')))

    job_parameters = (
        'nodenumber=2', 'networkingplugin=openvswitch')

    if repo in JOB_PARAMETERS:
        job_parameters = JOB_PARAMETERS[repo]

    job_parameters += ('all_noreboot',)

    print(jenkins(
        'openstack-mkcloud',
        '-p', 'mode=standard',
        "github_pr=crowbar/%s:%s" % (repo, github_opts),
        "cloudsource=" + cloudsource,
        'UPDATEREPOS=' + htdocs_url + ptfdir,
        'mkcloudtarget=all_noreboot',
        *job_parameters))


def add_pr_to_checkout(repo, pr_id, head_sha1, pr_branch, spec):
    sh.curl(
        '-s', '-k', '-L',
        "https://github.com/crowbar/%s/compare/%s...%s.patch" % (
            repo, pr_branch, head_sha1),
        '-o', 'prtest.patch')
    sh.sed('-i', '-e', 's,Url:.*,%define _default_patch_fuzz 2,',
           '-e', 's,%patch[0-36-9].*,,', spec)
    Command('/usr/lib/build/spec_add_patch')(spec, 'prtest.patch')
    iosc('vc', '-m', "added PR test patch from %s#%s (%s)" % (
        repo, pr_id, head_sha1))


def prep_webroot(ptfdir):
    webroot = os.path.join(htdocs_dir, ptfdir)
    sh.rm('-rf', webroot)
    sh.mkdir('-p', webroot)
    return webroot


def trigger_testbuild(repo, github_opts):
    pr_id, head_sha1, pr_branch = github_opts.split(':')

    olddir = os.getcwd()
    ptfdir = repo + ':' + github_opts
    webroot = prep_webroot(ptfdir)
    workdir = tempfile.mkdtemp()
    build_failed = False

    try:
        pkg = repo if repo.startswith("crowbar") else "crowbar-" + repo
        spec = pkg + '.spec'

        try:
            os.chdir(workdir)
            buildroot = os.path.join(os.getcwd(), 'BUILD')
            iosc('co', IBS_MAPPING[pr_branch], pkg, '-c')
            os.chdir(pkg)
            add_pr_to_checkout(repo, pr_id, head_sha1, pr_branch, spec)
            iosc('build', '--root', buildroot, '--noverify', '--noservice',
                 'SLE_12_SP1' if pr_branch == 'master' else 'SLE_11_SP3',
                 'x86_64', spec, _out=sys.stdout)
        except:
            build_failed = True
            print("Build failed: " + str(sys.exc_info()[1]))
            raise
        else:
            sh.cp('-p', sh.glob(
                os.path.join(buildroot, '.build.packages/RPMS/*/*.rpm')),
                webroot)
        finally:
            os.chdir(olddir)
            sh.cp('-p', os.path.join(buildroot, '.build.log'),
                  os.path.join(webroot, 'build.log'))
    finally:
        sh.sudo.rm('-rf', workdir)

    if not build_failed:
        jenkins_job_trigger(
            repo, github_opts, CLOUDSRC[pr_branch], ptfdir)

    ghs_set_status(
        repo, head_sha1,
        'failure' if build_failed else'pending')


def main():
    parser = argparse.ArgumentParser(
        description='Build a testpackage for a crowbar/ Pull Request')
    parser.add_argument('repo', metavar='REPO',
                        help='github repo in the crowbar organization')
    parser.add_argument('pr', metavar='PRID:SHA1:BRANCH',
                        help='github PR id, SHA1 head of PR, and '
                             'destination branch of PR')

    args = parser.parse_args()

    trigger_testbuild(args.repo, args.pr)


if __name__ == '__main__':
    main()
