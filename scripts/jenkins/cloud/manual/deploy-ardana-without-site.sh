#!/bin/bash

# (c) Copyright 2019 SUSE LLC
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

set -e

source lib.sh

validate_input
setup_ansible_venv
mitogen_enable
prepare_input_model
prepare_infra

trap exit_msg EXIT

build_test_packages
bootstrap_clm
deploy_ses_vcloud
bootstrap_nodes
deploy_ardana_but_dont_run_site_yml
