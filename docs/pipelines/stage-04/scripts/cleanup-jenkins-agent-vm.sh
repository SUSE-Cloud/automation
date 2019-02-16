#!/bin/bash

set -xe

if [[ -z "$agent_name" ]]; then
    echo "Empty agent_name variable value"
    exit 1
fi

existing_vm=$(openstack --os-cloud $os_cloud server show ${agent_name}_server || :)

if [[ -n "$existing_vm" ]]; then
    openstack --os-cloud $os_cloud server delete --wait ${agent_name}_server
    openstack --os-cloud $os_cloud router remove subnet ${agent_name}_router ${agent_name}_subnet || :
    openstack --os-cloud $os_cloud router delete ${agent_name}_router || :
    openstack --os-cloud $os_cloud network delete ${agent_name}_network || :
    openstack --os-cloud $os_cloud security group delete ${agent_name}_secgroup || :
fi
