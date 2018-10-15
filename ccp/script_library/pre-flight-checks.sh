#!/usr/bin/env bash

openstack_tests (){
    if [ -z ${OS_CLOUD+x} ]; then
        echo "No OS_CLOUD given. export OS_CLOUD=... corresponding to your clouds.yaml" && exit 1
    fi

    if [ -z ${KEYNAME+x} ]; then
        echo "No KEYNAME given. You must give an openstack security keypair name to add to your server. Please export KEYNAME='<name of your keypair>'." && exit 1
    fi

    if [ -z ${PREFIX+x} ]; then
        echo "No PREFIX given. export PREFIX to match your network. It will be used as network and server names"
    fi

    if [ -z ${INTERNAL_SUBNET+x} ];
    then
        echo "INTERNAL_SUBNET name not given. export INTERNAL_SUBNET=..." && exit 1
    fi
}

openstack_early_tests (){
    echo "Running OpenStack pre-flight checks"
    openstack_tests
    which openstack > /dev/null  || (echo "Please install openstack and heat CLI in your PATH"; exit 1)
    openstack keypair list | grep ${KEYNAME} > /dev/null || (echo "keyname not found. export KEYNAME=" && exit 2)
    openstack network list | grep "${PREFIX}-net" > /dev/null || (echo "network not found. Make sure a network exist matching ${PREFIX}-net" && exit 3)
    openstack subnet list | grep ${INTERNAL_SUBNET} > /dev/null || (echo "subnet not found" && exit 4)
}

ansible_tests (){
    which ansible-playbook > /dev/null || (echo "Please install ansible in your PATH"; exit 1)
}
general (){
    ansible_tests
}

if [ -z ${1+x} ]; then
    echo "No preflight checks run"
else
    $1
fi
