#!/usr/bin/python

#
# (c) Copyright 2018 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
# Generates a summary report based on the Jenkins pipeline API results.

import argparse
import json
import os
import re
import sys

import jenkins

BUILD_INFO = jenkins.BUILD_INFO
WORKFLOW_BUILD_INFO = '%(folder_url)sjob/%(short_name)s/%(number)d/'
WORKFLOW_INFO = 'wfapi/describe'
WORKFLOW_STAGE_INFO = 'execution/node/%(stage)s/wfapi/describe'
WORKFLOW_STAGE_LOG = 'execution/node/%(stage)s/wfapi/log'
PIPELINE_URL = 'blue/organizations/jenkins/%(name)s/detail/' \
               '%(name)s/%(number)s/pipeline'
PIPELINE_STAGE_URL = 'blue/organizations/jenkins/%(name)s/detail/' \
                     '%(name)s/%(number)s/pipeline/%(stage)s'


class WorkflowJenkins(jenkins.Jenkins):

    def _workflow_api_query(self, wf_path, name, number, **kwargs):
        """Call the pipeline workflow API.

        :param wf_path: Workflow URL sub-path, ``str``
        :param name: Job name, ``str``
        :param number: Build number, ``int``
        :returns: dictionary of pipeline information, ``dict``

        """
        try:
            # We temporarily 'hack' the jenkins.Jenkins get_build_info method
            # to extend it with pipeline workflow API calls
            jenkins.BUILD_INFO = os.path.join(WORKFLOW_BUILD_INFO,
                                              wf_path % kwargs)
            return self.get_build_info(name, number)
        finally:
            jenkins.BUILD_INFO = BUILD_INFO

    def get_workflow_info(self, name, number):
        """Get pipeline workflow information dictionary.

        :param name: Job name, ``str``
        :param number: Build number, ``int``
        :returns: dictionary of pipeline information, ``dict``

        """
        return self._workflow_api_query(WORKFLOW_INFO, name, number)

    def get_pipeline_url(self, name, number):
        return self._build_url(PIPELINE_URL, locals())

    def get_pipeline_stage_url(self, name, number, stage):
        return self._build_url(PIPELINE_STAGE_URL, locals())

    def get_workflow_stage_info(self, name, number, stage):
        """Get pipeline workflow stage information dictionary.

        :param name: Job name, ``str``
        :param number: Build number, ``int``
        :param stage: Stage number, ``int``
        :returns: dictionary of pipeline information, ``dict``

        """
        return self._workflow_api_query(WORKFLOW_STAGE_INFO,
                                        name, number,
                                        stage=stage)

    def get_workflow_stage_log(self, name, number, stage):
        """Get pipeline workflow stage log dictionary.

        :param name: Job name, ``str``
        :param number: Build number, ``int``
        :param stage: Stage number, ``int``
        :returns: dictionary of pipeline information, ``dict``

        """
        return self._workflow_api_query(WORKFLOW_STAGE_LOG,
                                        name, number,
                                        stage=stage)


def generate_summary(server, job_name, build_number,
                     filter_stages, recursive, depth=0):
    summary = ''

    workflow_info = server.get_workflow_info(job_name, build_number)

    failed = False
    for stage in workflow_info['stages']:
        # stages that are not executed are not included in the summary
        if stage['status'] == 'NOT_EXECUTED':
            continue
        if stage['name'] in filter_stages:
            continue
        stage_info = server.get_workflow_stage_info(
            job_name, build_number, stage['id'])
        stage_url = server.get_pipeline_stage_url(
            job_name, build_number, stage['id'])

        if stage['status'] == 'FAILED':
            # an aborted stage is indicated by the FlowInterruptedException
            # error type
            if stage['error']['type'].endswith("FlowInterruptedException"):
                stage['status'] = "ABORTED"
                stage_url = None
            else:
                # we only mark the first FAILED stage as actually failed,
                # all subsequent FAILED stages are marked as SKIPPED
                if failed:
                    stage['status'] = "SKIPPED"
                    stage_url = None
                failed = True

        sub_summary = ''
        if recursive and stage['status'] not in ['ABORTED', 'SKIPPED']:
            # Figure out if the stage wraps one or more downstream jobs
            nodes = stage_info.get('stageFlowNodes')
            for node in nodes:
                if node['name'].startswith('Building '):
                    log = server.get_workflow_stage_log(
                        job_name, build_number, node['id'])

                    downstream_jobs = re.findall(
                        r"href='(/job/([\w-]+)/([\d]+)/)'",
                        log['text'])
                    if downstream_jobs:
                        d_job_name = downstream_jobs[0][1]
                        d_build_number = int(downstream_jobs[0][2])
                        stage['name'] = '{} ({})'.format(stage['name'],
                                                         d_job_name)
                        sub_summary = generate_summary(
                            server, d_job_name, d_build_number,
                            filter_stages, recursive, depth + 1)
                        stage_url = server.get_pipeline_url(d_job_name,
                                                            d_build_number)
        if stage_url is not None:
            stage_url = stage_url.replace('ci.suse.de', 'ci.nue.suse.com')
        summary += '{}  - {}: {}{}\n'.format(
            ' ' * depth * 4, stage['name'], stage['status'],
            ' ({})'.format(stage_url) if stage_url else ''
        )
        summary += sub_summary

    return summary


def print_pipeline_report(job_name, build_number, filter_stages, recursive):

    config_files = ('/etc/jenkinsapi.conf', './jenkinsapi.conf')
    config = dict()

    for config_file in config_files:
        if not os.path.exists(config_file):
            continue
        with open(config_file, 'r') as f:
            config.update(json.load(f))

    if not config:
        print('Error: No config file could be loaded. Please '
              'create either of: %s' % ', '.join(config_files))
        sys.exit(1)

    server = WorkflowJenkins(str(config['jenkins_url']),
                             username=config['jenkins_user'],
                             password=config['jenkins_api_token'])

    if build_number is None:
        build_number = server.get_job_info(job_name)['lastBuild']['number']

    summary = generate_summary(server, job_name, build_number,
                               filter_stages, recursive)

    print(summary)


def argparse_jenkins_job_type(jenkins_job):
    change_regex = re.compile(r"^([a-zA-Z0-9_-]+)(/([0-9]+))?$")
    match = change_regex.match(jenkins_job)
    if not match:
        raise argparse.ArgumentTypeError(
            'Invalid Jenkins job name/build number value: {}'.format(
                jenkins_job))
    job_name = match.groups()[0]
    build_number = match.groups()[2]
    if build_number is not None:
        build_number = int(build_number)
    return job_name, build_number


def main():

    parser = argparse.ArgumentParser(
        description='Print a build summary report from a Jenkins pipeline '
                    'job build')
    parser.add_argument('job', type=argparse_jenkins_job_type, nargs='?',
                        help="the Jenkins job name followed by an optional "
                             "build number (e.g. 'openstack-ardana' or "
                             "'openstack-ardana/123'). If a build number "
                             "isn't supplied, the latest build number is "
                             "used. "
                             "If this argument is omitted, the JOB_NAME "
                             "and BUILD_NUMBER environment variables "
                             "are used.")
    parser.add_argument('-f', '--filter', action='append',
                        help='Name of stage to filter out of the report')
    parser.add_argument('--recursive', action="store_true", default=False,
                        help='include information about downstream builds '
                             'into the build report.')

    args = parser.parse_args()

    if args.job:
        job_name, build_number = args.job
    else:
        build_number = None
        job_name = os.environ.get('JOB_NAME')
        if not job_name:
            print('ERROR: could not determine job name from '
                  'the JOB_NAME environment variable')
            exit(1)
    if build_number is None:
        build_number = os.environ.get('BUILD_NUMBER')
        if build_number:
            build_number = int(build_number)

    print_pipeline_report(job_name, build_number,
                          args.filter, args.recursive)


if __name__ == "__main__":
    main()
