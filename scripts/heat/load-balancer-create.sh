#!/bin/bash

# lbaasv2
# https://docs.openstack.org/ocata/networking-guide/config-lbaas.html

# Cirros image with thttpd and tcpdump enabled
if [ ! -f cirros-thttpd.img ]; then
    wget http://clouddata.nue.suse.com/images/openstack/x86_64/cirros-thttpd.img
fi

if ! openstack image show cirros-thttpd; then
    openstack image create --disk-format qcow2 --container-format bare --public --file cirros-thttpd.img cirros-thttpd
fi

if ! heat stack-show lbaas; then
    heat stack-create lbaas -f load-balancer.yaml
fi

# wait for stack to be created
stack_status=$(heat stack-list | grep lbaas | awk '{ print $6 }')
while [ $stack_status != "CREATE_COMPLETE" ]; do sleep 2; stack_status=$(heat stack-list | grep lbaas | awk '{ print $6 }'); done

private_subnet=$(neutron subnet-list -f value | grep lbaas | awk '{ print $1 }')

# Create several load balancers just using two instances but different ports
num_load_balancers=2

for i in $(seq $num_load_balancers)
do
    if ! neutron lbaas-loadbalancer-show lbaas-migrate-$i; then
        neutron lbaas-loadbalancer-create --name lbaas-migrate-$i $private_subnet
    fi

    # wait for LB to be created before continuing
    lb_status=$(neutron lbaas-loadbalancer-show lbaas-migrate-$i | grep provisioning_status | awk '{ print $4 }')
    while [ $lb_status != "ACTIVE" ]
    do
        sleep 2
        lb_status=$(neutron lbaas-loadbalancer-show lbaas-migrate-$i | grep provisioning_status | awk '{ print $4 }')
    done

    vip_port_id=$(neutron lbaas-loadbalancer-show lbaas-migrate-$i | grep vip_port_id | awk '{ print $4 }')
    security_group_id=$(neutron security-group-list | grep lbaas | awk '{ print $2 }')
    neutron port-update --security-group $security_group_id $vip_port_id

    if ! neutron lbaas-listener-show lbaas-migrate-http-$i; then
        neutron lbaas-listener-create --name lbaas-migrate-http-$i --loadbalancer lbaas-migrate-$i --protocol HTTP --protocol-port $((79+$i))
    fi

    # wait for listener to be created before creating the pool
    lb_status=$(neutron lbaas-loadbalancer-show lbaas-migrate-$i | grep provisioning_status | awk '{ print $4 }')
    while [ $lb_status != "ACTIVE" ]
    do
        sleep 2
        lb_status=$(neutron lbaas-loadbalancer-show lbaas-migrate-$i | grep provisioning_status | awk '{ print $4 }')
    done

    # pool creation
    if ! neutron lbaas-pool-show lbaas-migrate-pool-http-$i; then
        neutron lbaas-pool-create --name lbaas-migrate-pool-http-$i --lb-algorithm ROUND_ROBIN --listener lbaas-migrate-http-$i --protocol HTTP
    fi
    east_ip=$(openstack server list -f value | grep east | cut -d '=' -f 2 | cut -d ',' -f 1)
    west_ip=$(openstack server list -f value | grep west | cut -d '=' -f 2 | cut -d ',' -f 1)

    # cloud6 doesn't allow name argument for member creation
    neutron lbaas-member-create --subnet $private_subnet --address $east_ip --protocol-port $((79+$i)) lbaas-migrate-pool-http-$i
    neutron lbaas-member-create --subnet $private_subnet --address $west_ip --protocol-port $((79+$i)) lbaas-migrate-pool-http-$i

    # health monitor (no mame attribute)
    neutron lbaas-healthmonitor-create --delay 5 --max-retries 2 --timeout 10 --type HTTP --pool lbaas-migrate-pool-http-$i

    # floating ip for balancer
    floatingip_id=$(neutron floatingip-create floating | grep ' id' | awk '{ print $4 }')
    neutron floatingip-associate $floatingip_id $vip_port_id

    # web server
    # do not use this anymore: gets 502 bad gateway. Use the server in the cirros image instead
    # while true; do echo -e "HTTP/1.0 200 OK\r\n$(cat /etc/hostname)" | sudo nc -l -p 80; sleep 1; done

    # client (controller node)
    lbaas_fip=$(neutron floatingip-show $floatingip_id | grep floating_ip_address | awk '{ print $4 }')
    vips+=("VIP: $lbaas_fip:$((79+$i))")

done

# print VIPs
for vip in ${vips[@]}; do
    echo $vip
done
