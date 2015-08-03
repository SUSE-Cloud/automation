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

JOB_PARAMETERS = {
    'barclamp-ceph': ('nodenumber=3', 'networkingplugin=linuxbridge'),
    'barclamp-pacemaker': ('nodenumer=3', 'hacloud=1')
}

htdocs_dir = '/srv/www/htdocs/mkcloud'
htdocs_url = 'http://tu-sle12.j.cloud.suse.de/mkcloud/'


def ghs_set_status(repo, pr_id, head_sha1, status):
    ghs = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'github-status/github-status.rb')))

    ghs('-r', 'crowbar/' + repo,
        '-p', pr_id, '-c', head_sha1, '-a', 'set-status',
        '-s', status)


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
        'label=openstack-mkcloud-SLE12',
        'UPDATEREPOS=' + htdocs_url + ptfdir,
        'mkcloudtarget=all_noreboot',
        *job_parameters))


def trigger_testbuild(repo, github_opts):
    pr_id, head_sha1, pr_branch = github_opts.split(':')

    olddir = os.getcwd()
    workdir = tempfile.mkdtemp()
    build_failed = False
    try:
        ptfdir = repo + ':' + github_opts
        webroot = os.path.join(htdocs_dir, ptfdir)
        pkg = repo if repo == "crowbar" else "crowbar-" + repo
        spec = pkg + '.spec'

        sh.rm('-rf', webroot)
        sh.mkdir('-p', webroot)

        try:
            os.chdir(workdir)
            iosc = functools.partial(
                Command('/usr/bin/osc'), '-A', 'https://api.suse.de')
            iosc('co', IBS_MAPPING[pr_branch], pkg)
            os.chdir(os.path.join(IBS_MAPPING[pr_branch], pkg))
            sh.curl(
                '-s', '-k', '-L',
                "https://github.com/crowbar/%s/pull/%s.patch" % (repo, pr_id),
                '-o', 'prtest.patch')
            sh.sed('-i', '-e', 's,Url:.*,%define _default_patch_fuzz 2,',
                '-e', 's,%patch[0-36-9].*,,', spec)
            Command('/usr/lib/build/spec_add_patch')(spec, 'prtest.patch')
            iosc('vc', '-m', " added PR test patch from " + ptfdir)
            buildroot = os.path.join(os.getcwd(), 'BUILD')
            iosc('build', '--root', buildroot,
                 '--noverify', '--noservice', 'SLE_11_SP3', 'x86_64',
                 pkg + '.spec', _out=sys.stdout)
        except:
            build_failed = True
        else:
            sh.cp('-p',
                  sh.glob(os.path.join(buildroot,
                                       'usr/src/packages/RPMS/*/*.rpm')),
                  webroot)

        finally:
            os.chdir(olddir)
            sh.cp(
                '-p', os.path.join(buildroot, '.build.log'),
                os.path.join(webroot, 'build.log'))
    finally:
        sh.sudo.rm('-rf', workdir)

    if not build_failed:
        jenkins_job_trigger(
            repo, github_opts, CLOUDSRC[pr_branch], ptfdir)

    ghs_set_status(
        repo, pr_id, head_sha1,
        'failure' if build_failed else'pending')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Test a crowbar/ PR')
    parser.add_argument("repo", help='github ORG/REPO')
    parser.add_argument('pr', help='github PR <PRID>:<SHA1>:<BRANCH>')

    args = parser.parse_args()

    trigger_testbuild(args.repo, args.pr)
    sys.exit(0)
