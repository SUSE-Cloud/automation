#!/bin/bash

set -o errexit

action=${1:-deploy}
deploy_mechanism=${2:-openstack}

if [ ! -f ~/suse-osh-deploy/user_variables.yml ]; then
    ansible_playbook="ansible-playbook "
else
    ansible_playbook="ansible-playbook -e @~/suse-osh-deploy/user_variables.yml "
fi

source script_library/pre-flight-checks.sh general

function deploy_on_openstack(){
    source script_library/pre-flight-checks.sh openstack_early_tests
    echo "Deploying on OpenStack"
    ./1_ses_node_on_openstack/create.sh
    echo "Step 1 success"
    ./2_deploy_ses_aio/run.sh
    echo "Step 2 success"
    ./3_caasp_nodes_on_openstack_heat/create.sh
    echo "Step 3 success"
    ./4_osh_node_on_openstack/create.sh
    echo "Step 4 success"
    $ansible_playbook ./5_automate_caasp_enroll/play.yml -i inventory-osh.ini
    echo "Step 5 success"
    $ansible_playbook ./6_preflight_checks/checks.yml -i inventory-osh.ini
    echo "Step 6 success"
    $ansible_playbook ./7_deploy_osh/play.yml -i inventory-osh.ini
    echo "Step 7 success"
    exit 0
}

function deploy_on_kvm(){
    echo "Deploying on KVM"
    echo "NOT IMPLEMENTED"
    exit 1
}

function delete_on_openstack(){
    echo "Deleting on OpenStack"
    ./4_osh_node_on_openstack/delete.sh
    echo "Delete Caasp nodes"
    ./3_caasp_nodes_on_openstack_heat/delete.sh || true
    ./3_caasp_nodes_on_openstack_manually/delete.sh || true
    echo "Delete SES node"
    ./1_ses_node_on_openstack/delete.sh
    exit 0
}

function delete_on_kvm(){
    echo "Deleting on KVM"
    echo "NOT IMPLEMENTED"
    exit 1
}

function delete_user_files(){
    echo "DANGER ZONE"
    read -p "Press Enter or Ctrl-C. Enter will delete userspace files in ~/suse-osh-deploy/"
    rm -rf ~/suse-osh-deploy/*
}

case "$action" in
    "deploy")
        deploy_on_$deploy_mechanism
        ;;
    "delete")
        delete_on_$deploy_mechanism
        ;;
    "delete_userspace")
        delete_user_files
        ;;
    *)
        echo "Usage: ${0} deploy|delete|delete_userspace"
        ;;
esac
