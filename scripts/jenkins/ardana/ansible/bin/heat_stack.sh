#!/usr/bin/env bash

set -ex

delete_heat_stack() {
    stack_name=$1
    delete_rc=0

    # We shouldn't delete a stack which is undergoing a transition.
    while [[ $(get_heat_stack $heat_stack_name) == *"_IN_PROGRESS" ]]; do
      sleep 10
    done

    if [[ $(get_heat_stack $heat_stack_name) != *" DELETE_COMPLETE" ]]; then

        # Resume stack before deletion, otherwise deleting it results in failure
        openstack --os-cloud ${os_cloud} stack delete -y --wait $stack_name && rc=$? || rc=$?
        if [[ $rc != 0 ]]; then
            # Attempt a brute force type of cleanup
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Nova::Server \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' server delete --wait "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Cinder::Volume \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' volume delete "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Neutron::Trunk \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' network trunk delete "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Neutron::Port \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' port delete "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Neutron::Router \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' router delete "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Neutron::Subnet \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' subnet delete "$1 }' | sh -x || :
            openstack --os-cloud ${os_cloud} stack resource list --filter type=OS::Neutron::Net \
              -f value -c physical_resource_id $stack_name |
              awk '{print "openstack --os-cloud '${os_cloud}' network delete "$1 }' | sh -x || :

            openstack --os-cloud ${os_cloud} stack delete -y --wait $stack_name && rc=$? || rc=$?
            if [[ $rc != 0 ]]; then
                # Usually, retrying after a short break works
                sleep 20
                openstack --os-cloud ${os_cloud} stack delete --wait $stack_name && rc=$? || rc=$?
                delete_rc=$rc
            fi
        fi
    fi

    # After deleting a stack, it will still remain configured with a DELETE_COMPLETE
    # status for a while (and re-creating one with the same name during this time will
    # fail).
    while [[ $(get_heat_stack $heat_stack_name) == *" DELETE_COMPLETE" ]]; do
      delete_rc=0
      sleep 10
    done

    return $delete_rc
}

get_heat_stack() {
    stack_name=$1
    openstack --os-cloud ${os_cloud} stack list \
              -f value -c 'Stack Name' -c 'Stack Status' |
              grep "^$stack_name " || :
}

usage_and_exit() {
  echo "Usage: $0 <create|update|delete> <heat-stack-name> [<heat-template-file>]"
  exit 1
}


action=$1
heat_stack_name=$2
heat_template_file=$3

if [[ $action == "create" ]]; then

    if [[ -z $heat_stack_name ]] || [[ -z $heat_template_file ]]; then
      echo "Both a heat stack name and a heat template file are required"
      usage_and_exit
    fi

    heat_stack=$(get_heat_stack $heat_stack_name)
    if [[ -n $heat_stack ]]; then
      delete_heat_stack $heat_stack_name
    fi
    exit_rc=0
    openstack --os-cloud ${os_cloud} stack create --timeout 10 --wait \
        -t "$heat_template_file"  \
        $heat_stack_name && rc=$? || rc=$?
    if [[ $rc != 0 ]]; then
        exit_rc=$rc
        delete_heat_stack $heat_stack_name || :
        exit $exit_rc
    fi
elif [[ $action == "update" ]]; then

    if [[ -z $heat_stack_name ]] || [[ -z $heat_template_file ]]; then
      echo "Both a heat stack name and a heat template file are required"
      usage_and_exit
    fi

    openstack --os-cloud ${os_cloud} stack update --timeout 10 --wait \
        -t "$heat_template_file"  \
        $heat_stack_name
elif [[ $action == "delete" ]]; then

    if [[ -z $heat_stack_name ]] ; then
      echo "A heat stack name is required"
      usage_and_exit
    fi

    heat_stack=$(get_heat_stack $heat_stack_name)
    if [[ -n $heat_stack ]]; then
        delete_heat_stack $heat_stack_name
    fi
fi
