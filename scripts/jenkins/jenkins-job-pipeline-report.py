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
            # to            # extend it with pipeline workflow API calls
            jenkins.BUILD_INFO = WORKFLOW_BUILD_INFO + wf_path % kwargs
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
            # Figure out if the stage wraps a downstream job
            nodes = stage_info.get('stageFlowNodes')
            if nodes and nodes[0]['name'].startswith('Building '):
                log = server.get_workflow_stage_log(
                    job_name, build_number, nodes[0]['id'])

                downstream_jobs = re.findall(
                    "href='(/job/([\w-]+)/([\d]+)/)'",
                    log['text'])
                if downstream_jobs:
                    print("Found downstream job: {}".format(
                        downstream_jobs[0][0]))
                    d_job_name = downstream_jobs[0][1]
                    d_build_number = int(downstream_jobs[0][2])
                    sub_summary = generate_summary(
                        server, d_job_name, d_build_number,
                        filter_stages, recursive, depth+1)
                    stage_url = server.get_pipeline_url(d_job_name,
                                                        d_build_number)
        summary += '{}  - {}: {}{}\n'.format(
            ' '*depth*4, stage['name'], stage['status'],
            ' ({})'.format(stage_url) if stage_url else ''
        )
        summary += sub_summary

    return summary


def generate_pipeline_report(job_name, build_number, filename,
                             filter_stages, recursive):

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

    with open(filename, 'w+') as f:

        summary = generate_summary(
            server, job_name, build_number, filter_stages, recursive)
        f.write(summary)


def main():
    parser = argparse.ArgumentParser(
        description='Create a build summary report from a Jenkins pipeline '
                    'job build')
    parser.add_argument('-j', '--job-name', default=os.environ.get('JOB_NAME'),
                        help='the Jenkins job name. If not supplied, the '
                             'JOB_NAME environment variable is used.')
    parser.add_argument('-b', '--build-number', type=int,
                        default=int(os.environ.get('BUILD_NUMBER', 0)),
                        help='the Jenkins build number. If not not supplied, '
                             'the BUILD_NUMBER environment variable is used.')
    parser.add_argument('-f', '--filter', action='append',
                        help='Name of stage to filter out of the report')
    parser.add_argument('--recursive', action="store_true", default=False,
                        help='include information about downstream builds '
                             'into the build report.')

    parser.add_argument('filename', help='the report filename')
    args = parser.parse_args()

    generate_pipeline_report(args.job_name, args.build_number,
                             args.filename, args.filter, args.recursive)


if __name__ == "__main__":
    main()
