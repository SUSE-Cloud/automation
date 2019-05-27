#!/bin/sh

num_load_balancers=2
for i in $(seq $num_load_balancers)
do
    neutron lbaas-pool-delete lbaas-migrate-pool-http-$i
    neutron lbaas-listener-delete lbaas-migrate-http-$i
    neutron lbaas-loadbalancer-delete lbaas-migrate-$i
done

# delete health monitors
hm_list=$(neutron lbaas-healthmonitor-list -f value | awk '{ print $1 }')
for hm in $hm_list
do
    neutron lbaas-healthmonitor-delete $hm
done

heat stack-delete lbaas

