#!/bin/bash

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

ANSIBLE_VENV=${ANSIBLE_VENV:-"/opt/ansible"}
AUTOMATION_DIR=${AUTOMATION_DIR:-"$WORKSPACE/automation-git"}


function ansible_playbook {
    set +x
    export ANSIBLE_FORCE_COLOR=true
    source $ANSIBLE_VENV/bin/activate
    if [[ "$PWD" != *scripts/jenkins/cloud/ansible ]]; then
        cd $AUTOMATION_DIR/scripts/jenkins/cloud/ansible
    fi
    echo "Running: ansible-playbook ${@}"
    ansible-playbook "${@}"
}


# this wrapper will choose python3 over python2 when running a python script
function run_python_script {
    set +x
    python_bin=$(command -v python3 || command -v python)
    $python_bin "${@}"
}
