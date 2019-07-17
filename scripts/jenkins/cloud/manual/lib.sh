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

WORK_DIR=${WORK_DIR:-$PWD}
AUTOMATION_DIR=${AUTOMATION_DIR:-"$(git rev-parse --show-toplevel)"}
ANSIBLE_VENV=${ANSIBLE_VENV:-"$WORK_DIR/ansible-venv"}
ARDANA_INPUT=${ARDANA_INPUT:-"$WORK_DIR/input.yml"}
MITOGEN_URL=${MITOGEN_URL:-"https://github.com/dw/mitogen/archive/master.tar.gz"}
ANSIBLE_CFG_ARDANA=${ANSIBLE_CFG_ARDANA:-"$AUTOMATION_DIR/scripts/jenkins/cloud/ansible/ansible.cfg"}
ANSIBLE_CFG_SES=${ANSIBLE_CFG_SES:-"$AUTOMATION_DIR/scripts/jenkins/ses/ansible/ansible.cfg"}

function get_from_input {
    echo $(grep -v "^#" $ARDANA_INPUT | awk -v var=$1 '$0 ~ var{ print $2 }' | tr -d "'")
}

function is_defined {
    value=$(get_from_input $1)
    if [[ ! -z "${value// }" ]]; then
        true
    else
        false
    fi
}

function setup_ansible_venv {
    if [ ! -d "$ANSIBLE_VENV" ]; then
        virtualenv $ANSIBLE_VENV
        $ANSIBLE_VENV/bin/pip install --upgrade pip
        $ANSIBLE_VENV/bin/pip install -r $WORK_DIR/requirements.txt
    fi
}

function mitogen_enable {
    if [ ! -d "mitogen" ]; then
        wget -qO- $MITOGEN_URL | tar -xz
        mv mitogen-* mitogen
    fi

    for cfg in "${ANSIBLE_CFG_ARDANA}" "${ANSIBLE_CFG_SES}"; do
        if ! grep -Fq "strategy_plugins=" ${cfg}; then
            sed -i "/^\[defaults\]/a\strategy_plugins=$WORK_DIR/mitogen/ansible_mitogen/plugins/strategy" \
                $cfg
        fi
        if ! grep -Fxq "strategy=mitogen_linear" $cfg; then
            sed -i "/^\[defaults\]/a\strategy=mitogen_linear" $cfg
        fi
    done
}

function mitogen_disable {
    if [ -d "mitogen" ]; then
        rm -rf mitogen
    fi
    for cfg in "${ANSIBLE_CFG_ARDANA}" "${ANSIBLE_CFG_SES}"; do
        if grep -Fq "strategy_plugins=" ${cfg}; then
            sed -i "/strategy_plugins=/d" \
                $cfg
        fi
        if grep -Fxq "strategy=mitogen_linear" $cfg; then
            sed -i "/strategy=mitogen_linear/d" $cfg
        fi
    done
}

function ansible_playbook {
    if ! is_defined cloud_env; then
        echo "ERROR: cloud_env must be defined - please check all variables on input.yml"
        return 1
    else
        source $ANSIBLE_VENV/bin/activate
        if [[ "$PWD" != *scripts/jenkins/cloud/ansible ]]; then
            pushd $AUTOMATION_DIR/scripts/jenkins/cloud/ansible
        fi
        echo "Running: ansible-playbook -e @$ARDANA_INPUT ${@}"
        ansible-playbook ${ANSIBLE_VERBOSE:-} --extra-vars @$ARDANA_INPUT "${@}"
        popd
    fi
}

function ansible_playbook_ses {
    if ! is_defined cloud_env; then
        echo "ERROR: cloud_env must be defined - please check all variables on input.yml"
        return 1
    else
        source $ANSIBLE_VENV/bin/activate
        if [[ "$PWD" != *scripts/jenkins/ses/ansible ]]; then
            pushd $AUTOMATION_DIR/scripts/jenkins/ses/ansible
        fi
        echo "Running: ansible-playbook ${@}"
        ansible-playbook "${@}"
        popd
    fi
}

# this wrapper will choose python3 over python2 when running a python script
function run_python_script {
    set +x
    python_bin=$(command -v python3 || command -v python)
    $python_bin "${@}"
}

function is_physical_deploy {
    cloud_env=$(get_from_input cloud_env)
    [[ $cloud_env == qe* ]] || [[ $cloud_env == pcloud* ]]
}

function get_cloud_product {
    echo $(get_from_input cloud_product)
}

function get_deployer_ip {
    grep -oP "^$(get_from_input cloud_env)\\s+ansible_host=\\K[0-9\\.]+" \
        $AUTOMATION_DIR/scripts/jenkins/cloud/ansible/inventory
}

function get_ses_ip {
    grep -oP "^$(get_from_input cloud_env)-ses\\s+ansible_host=\\K[0-9\\.]+" \
        $AUTOMATION_DIR/scripts/jenkins/ses/ansible/inventory
}

function delete_stack {
    if ! is_physical_deploy; then
        ansible_playbook heat-stack.yml -e heat_action=delete
    fi
}

function prepare_input_model {
    if is_defined scenario_name; then
        ansible_playbook generate-input-model.yml
    else
        ansible_playbook clone-input-model.yml
    fi
}

function prepare_heat_template {
    ansible_playbook generate-heat-template.yml
}

function deploy_heat_template {
    ansible_playbook heat-stack.yml
}

function prepare_infra {
    if is_physical_deploy; then
        ansible_playbook start-deployer-vm.yml
    else
        prepare_heat_template
        delete_stack
        deploy_heat_template
    fi
}

function build_test_packages {
    if is_defined gerrit_change_ids; then
        if ! is_defined homeproject; then
            echo "ERROR: homeproject must be defined - please check all variables on input.yml"
            return 1
        else
            pushd $AUTOMATION_DIR/scripts/jenkins/cloud/gerrit
            source $ANSIBLE_VENV/bin/activate
            gerrit_change_ids=$(get_from_input gerrit_change_ids)
            GERRIT_VERIFY=0 PYTHONWARNINGS="ignore:Unverified HTTPS request" \
                run_python_script -u build_test_package.py --buildnumber local \
                --homeproject $(get_from_input homeproject) -c ${gerrit_change_ids//,/ -c }
            popd
        fi
    fi
}

function bootstrap_clm {
    test_repo_url=""
    if is_defined gerrit_change_ids; then
        homeproject=$(get_from_input homeproject)
        test_repo_url="http://download.suse.de/ibs/$(sed 's#\b:\b#&/#' <<< $homeproject):/ardana-ci-local/standard/$(get_from_input homeproject):ardana-ci-local.repo"
    fi
    extra_repos=$(sed -e "s/^,//" -e "s/,$//" <<< "$(get_from_input extra_repos),${test_repo_url}")
    ansible_playbook bootstrap-clm.yml -e extra_repos="${extra_repos}"
}

function bootstrap_crowbar {
    test_repo_url=""
    extra_repos=$(sed -e "s/^,//" -e "s/,$//" <<< "$(get_from_input extra_repos),${test_repo_url}")
    ansible_playbook bootstrap-crowbar.yml -e extra_repos="${extra_repos}"
}

function deploy_ses_vcloud {
    if ! is_physical_deploy && $(get_from_input ses_enabled); then
        ses_id=$(get_from_input cloud_env)
        os_cloud=$(get_from_input os_cloud)
        os_project_name=$(get_from_input os_project_name)
        [[ -n $os_project_name ]] && os_project_option="os_project_name=$os_project_name"
        deploy_ses_using="network="${ses_id}-cloud_management_net""
        # For crowbar SES is deployed on its own network and crowbar accesses it through the
        # external router. This is required to prevent the crowbar DHCP from affecting the SES
        # cluster.
        if [[ "$(get_cloud_product)" == "crowbar" ]]; then
            deploy_ses_using="router=${ses_id}-cloud_router_ext"
        fi
        ansible_playbook_ses ses-heat-stack.yml -e "ses_id=$ses_id $deploy_ses_using os_cloud=$os_cloud $os_project_option"
        ansible_playbook_ses bootstrap-ses-node.yml -e ses_id=$ses_id
        for i in {1..3}; do
            ansible_playbook_ses ses-deploy.yml -e ses_id=$ses_id && break || sleep 5
        done
    fi
}

function bootstrap_nodes {
    if [[ "$(get_cloud_product)" == "crowbar" ]]; then
        ansible_playbook bootstrap-crowbar-nodes.yml
    elif is_physical_deploy; then
        ansible_playbook bootstrap-pcloud-nodes.yml
    else
        ansible_playbook bootstrap-vcloud-nodes.yml
    fi
}

function install_crowbar {
    ansible_playbook install-crowbar.yml
}

function register_crowbar_nodes {
    ansible_playbook register-crowbar-nodes.yml
}
function deploy_cloud {
    if [ "$(get_cloud_product)" == "crowbar" ]; then
        ansible_playbook deploy-crowbar.yml
    elif $(get_from_input deploy_cloud); then
        ansible_playbook deploy-cloud.yml
    fi
}

function deploy_ardana_but_dont_run_site_yml {
    if $(get_from_input deploy_cloud); then
        ansible_playbook deploy-cloud.yml -e "skip_running_site_yml=True"
    fi
}


function update_cloud {
    if $(get_from_input deploy_cloud) && $(get_from_input update_after_deploy); then
        if [ "$(get_cloud_product)" == "crowbar" ]; then
            ansible_playbook crowbar-update.yml -e cloudsource=$(get_from_input update_to_cloudsource)
        elif $(get_from_input deploy_cloud); then
            ansible_playbook ardana-update.yml -e cloudsource=$(get_from_input update_to_cloudsource)
        fi
    fi
}

function run_tempest {
    if $(is_defined tempest_filter_list); then
        tempest_filter_list=($(echo "$(get_from_input tempest_filter_list)" | tr ',' '\n'))
        for filter in "${tempest_filter_list[@]}"; do
            ansible_playbook run-tempest.yml -e tempest_run_filter=$filter
        done
    fi
}

function run_qa_tests {
    if $(is_defined qa_test_list); then
        qa_test_list=($(echo "$(get_from_input qa_test_list)" | tr ',' '\n'))
        for qa_test in "${qa_test_list[@]}"; do
            ansible_playbook run-ardana-qe-tests.yml -e test_name=$qa_test
        done
    fi
}

function run_crowbar_tests {
    if [[ "$(get_cloud_product)" == "crowbar" ]]; then
        ansible_playbook run-crowbar-tests.yml
    fi
}

function validate_input {
    if ! is_defined cloud_env; then
        echo "ERROR: cloud_env must be defined - please check all variables on input.yml"
        return 1
    else
        echo "
*****************************************************************************************
** Ardana will be deployed using the following config:
$(cat input.yml| grep -v "^#\|''\|^[[:space:]]*$" | sed -e 's/^/  ** /')
*****************************************************************************************
        "
        read -p "Continue (y/n)?" choice
        case "$choice" in
            y|Y ) return 0;;
            * ) return 1;;
        esac
    fi
}

function exit_msg {
    DEPLOYER_IP=$(get_deployer_ip)
    if ! is_physical_deploy && $(get_from_input ses_enabled); then
        SES_IP=$(get_ses_ip)
        echo "
*****************************************************************************************
** The '$(get_from_input cloud_env)' SES environment is reachable at:
**
**        ssh root@${SES_IP}
**
** Please delete the '$(get_from_input cloud_env)-ses' stack when you're done,
** by loging into the ECP at https://engcloud.prv.suse.net/project/stacks/
** and deleting the heat stack.
*****************************************************************************************
        "
    fi

    echo "
*****************************************************************************************
** The deployer for the '$(get_from_input cloud_env)' environment is reachable at:
**
**        ssh ardana@${DEPLOYER_IP}
**        or
**        ssh root@${DEPLOYER_IP}
**
** Please delete the '$(get_from_input cloud_env)-cloud' stack when you're done,
** by by using one of the following methods:
**
**  1. log into the ECP at https://engcloud.prv.suse.net/project/stacks/
**  and delete the stack manually, or
**
**  2. call the delete_stack function from the script library:
**    $ source lib.sh
**    $ delete_stack
*****************************************************************************************
    "
}
