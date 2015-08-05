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
import shutil
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
    'networkingplugin=vxlan',
    'clusterconfig="data+services+network=2"')


MKCLOUD_CEPH_PARAMETERS = (
    'nodenumber=3', 'want_ceph=1',
    'networkingplugin=linuxbridge')

JOB_PARAMETERS = {
    'crowbar/crowbar-ha': MKCLOUD_HA_PARAMETERS,
    'crowbar/crowbar-ceph': MKCLOUD_CEPH_PARAMETERS,
    'crowbar/barclamp-ceph': MKCLOUD_CEPH_PARAMETERS,
    'crowbar/barclamp-pacemaker': MKCLOUD_HA_PARAMETERS
}

htdocs_dir = '/srv/www/htdocs/mkcloud'
htdocs_url = 'http://tu-sle12.j.cloud.suse.de/mkcloud/'

iosc = functools.partial(
    Command('/usr/bin/osc'), '-A', 'https://api.suse.de')


def ghs_set_status(repo, pr_id, head_sha1, url, status, message):
    ghs = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'github-status/github-status.rb')))

    ghs('-r', repo,
        '-p', pr_id,
        '-c', head_sha1,
        '-t', url,
        '-a', 'set-status',
        '-s', status,
        '-m', message)


def jenkins_job_trigger(repo, github_opts, cloudsource, ptf_url):
    print("triggering jenkins job with " + ptf_url)

    jenkins = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'jenkins/jenkins-job-trigger')))

    job_parameters = (
        'nodenumber=2', 'networkingplugin=openvswitch')

    if repo in JOB_PARAMETERS:
        job_parameters = JOB_PARAMETERS[repo]

    job_parameters += ('all_noreboot',)

    return jenkins(
        'openstack-mkcloud',
        '-p', 'mode=standard',
        "github_pr=%s:%s" % (repo, github_opts),
        "cloudsource=" + cloudsource,
        'UPDATEREPOS=' + ptf_url,
        'mkcloudtarget=all_noreboot',
        *job_parameters)


def add_pr_to_checkout(repo, pr_id, head_sha1, pr_branch, spec):
    sh.curl(
        '-s', '-k', '-L',
        "https://github.com/%s/compare/%s...%s.patch" % (
            repo, pr_branch, head_sha1),
        '-o', 'prtest.patch')
    sh.sed('-i', '-e', 's,Url:.*,%define _default_patch_fuzz 2,',
           '-e', 's,%patch[0-36-9].*,,', spec)
    Command('/usr/lib/build/spec_add_patch')(spec, 'prtest.patch')
    iosc('vc', '-m', "added PR test patch from %s#%s (%s)" % (
        repo, pr_id, head_sha1))


def prep_osc_dir(workdir, repo, pr_id, head_sha1, pr_branch, pkg, spec):
    os.chdir(workdir)
    iosc('co', IBS_MAPPING[pr_branch], pkg, '-c')
    os.chdir(pkg)
    add_pr_to_checkout(repo, pr_id, head_sha1, pr_branch, spec)


def prep_webroot(ptfdir):
    webroot = os.path.join(htdocs_dir, ptfdir)
    shutil.rmtree('-rf', webroot)
    os.makedirs(webroot)
    return webroot


def build_package(spec, webroot, pr_branch):
    buildroot = os.path.join(os.getcwd(), 'BUILD')
    repository = 'SLE_12' if pr_branch == 'master' else 'SLE_11_SP3'

    try:
        iosc('build',
             '--root', buildroot,
             '--noverify',
             '--noservice',
             repository, 'x86_64', spec,
             _out=sys.stdout)
    finally:
        log = os.path.join(buildroot, '.build.log')
        if os.path.exists(log):
            shutil.copy2(log, os.path.join(webroot, 'build.log'))

    sh.cp('-p',
          sh.glob(os.path.join(buildroot,
                               '.build.packages/RPMS/*/*.rpm')),
          webroot)


def trigger_testbuild(org_repo, github_opts):
    pr_id, head_sha1, pr_branch = github_opts.split(':')
    org, repo = org_repo.split('/')

    workdir = tempfile.mkdtemp()
    build_failed = False

    if "crowbar" in repo:
        pkg = repo
    else:
        pkg = "crowbar-" + repo

    spec = pkg + '.spec'
    ptfdir = org_repo + ':' + github_opts
    webroot = prep_webroot(ptfdir)

    try:
        prep_osc_dir(workdir, org_repo, pr_id, head_sha1, pr_branch, pkg, spec)
        build_package(spec, webroot, pr_branch)
    except:
        build_failed = True
        exc_type, exc_val, exc_tb = sys.exc_info()
        print("Build failed: %s" % exc_val)
    finally:
        sh.sudo.rm('-rf', workdir)

    ptf_url = htdocs_url + ptfdir

    pr_set_status = \
        functools.partial(ghs_set_status, org_repo, pr_id, head_sha1, ptf_url)

    if build_failed:
        pr_set_status('failure', 'PTF package build failed')
    else:
        result = jenkins_job_trigger(
            org_repo, github_opts,
            CLOUDSRC[pr_branch], ptf_url)
        print(result)
        pr_set_status('pending', 'mkcloud job triggered')


def main():
    parser = argparse.ArgumentParser(description='Test a github pull request')
    parser.add_argument('orgrepo', metavar='ORG/REPO',
                        help='github organization and repository')
    parser.add_argument('pr', metavar='PRID:SHA1:BRANCH',
                        help='github PR id, SHA1 head of PR, and '
                             'destination branch of PR')

    args = parser.parse_args()

    trigger_testbuild(args.orgrepo, args.pr)


if __name__ == '__main__':
    main()
