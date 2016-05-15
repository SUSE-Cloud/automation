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
import re
import sys
import tempfile

import sh
from sh import Command

try:
    import jenkins
except ImportError:
    print("Please install 'python-jenkins' from pypi")
    sys.exit(1)


IBS_MAPPING = {
    'release/stoney/master': 'Devel:Cloud:4:Staging',
    'release/tex/master':    'Devel:Cloud:5:Staging',
    'stable/3.0':            'Devel:Cloud:6:Staging',
    'master':                'Devel:Cloud:7:Staging'
}

REPO_MAPPING = {
    'release/stoney/master': 'SLE_11_SP3',
    'release/tex/master':    'SLE_11_SP3',
    'stable/3.0':            'SLE_12_SP1',
    'master':                'SLE_12_SP2'
}

CLOUDSRC = {
    'release/stoney/master': 'develcloud4',
    'release/tex/master':    'develcloud5',
    'stable/3.0':            'develcloud6',
    'master':                'develcloud7'
}

MKCLOUD_HA_PARAMETERS = {
    'nodenumber': '4',
    'hacloud' :'1',
    'networkingmode': 'vxlan',
    'clusterconfig': '"data+services+network=2"'
}

MKCLOUD_HYPERV_PARAMETERS = {
    'networkingplugin': 'linuxbridge',
    'libvirt_type': 'hyperv',
    'networkingmode' :'vlan'
}

MKCLOUD_CEPH_PARAMETERS = {
    'nodenumber': '4',
    'want_ceph': '1',
    'networkingplugin': 'linuxbridge'
    }

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

def _jenkins_read_api_credentials(cred_path):
    """file format for credentials is from jenkins-job-trigger perl script:
"""
    data = {}
    with open(cred_path, "r") as f:
        for line in f:
            m = re.match(r'\$(.*)="(.*)";', line)
            if m:
                key, val = m.group(1, 2)
                data[key] = val
    if 'SCHEME' not in data.keys():
        data['SCHEME'] = 'https'
    return data

def jenkins_job_trigger(repo, github_opts, cloudsource, ptfdir):
    print("triggering jenkins job with " + htdocs_url + ptfdir)
    creds = _jenkins_read_api_credentials('/etc/jenkinsapi.cred')
    server = jenkins.Jenkins('%s://%s' % (creds['SCHEME'], creds['JURL']),
                             username=creds['USER'], password=creds['APIKEY'])

    jenkins = Command(
        os.path.abspath(
            os.path.join(os.path.dirname(sys.argv[0]),
                         'jenkins/jenkins-job-trigger')))

    job_parameters = {
        'nodenumber': '2',
        'networkingplugin': 'openvswitch'
    }

    if repo in JOB_PARAMETERS:
        job_parameters = JOB_PARAMETERS[repo]

    job_parameters['cloudsource'] = cloudsource
    job_parameters['UPDATEREPOS'] = "%s%s" % (htdocs_url, ptfdir)
    job_parameters['github_pr'] = "crowbar/%s:%s" % (repo, github_opts)
    job_parameters['mkcloudtarget'] = "all_noreboot"

    server.build_job('openstack-mkcloud', **job_parameters)

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
                 REPO_MAPPING[pr_branch], 'x86_64', spec, _out=sys.stdout)
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
