#!/bin/bash

set -xe

: ${os_image:=cleanvm-jeos-SLE12SP4}
: ${os_flavor:=m1.large}
: ${os_floating_net:=floating}
: ${os_cloud:=engcloud-cloud-ci}

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

openstack --os-cloud $os_cloud network create -f value -c id ${agent_name}_network
openstack --os-cloud $os_cloud subnet create \
    --network ${agent_name}_network \
    --subnet-range 192.168.100.0/24 \
    ${agent_name}_subnet
openstack --os-cloud $os_cloud router create ${agent_name}_router
openstack --os-cloud $os_cloud router set --external-gateway $os_floating_net ${agent_name}_router
openstack --os-cloud $os_cloud router add subnet ${agent_name}_router ${agent_name}_subnet
openstack --os-cloud $os_cloud security group create ${agent_name}_secgroup
openstack --os-cloud $os_cloud security group rule create ${agent_name}_secgroup \
    --protocol tcp --dst-port 22:22
openstack --os-cloud $os_cloud security group rule create ${agent_name}_secgroup \
    --protocol icmp

openstack --os-cloud $os_cloud server create \
    --image $os_image \
    --flavor $os_flavor \
    --network ${agent_name}_network \
    --security-group ${agent_name}_secgroup \
    --wait \
    ${agent_name}_server

floatingip=$(openstack --os-cloud $os_cloud floating ip create -f value -c floating_ip_address $os_floating_net)
openstack --os-cloud $os_cloud server add floating ip ${agent_name}_server $floatingip
