#!/usr/bin/env bash

set -ex

DEPLOYER_IP=$(openstack --os-cloud ${os_cloud} stack output show $heat_stack_name admin-floating-ip -c output_value -f value)

if [ -n "$(grep "^ardana-$clm_env\s\+ansible_host" inventory)" ]; then
  sed -i "s/^ardana-$clm_env.*/ardana-$clm_env      ansible_host=$DEPLOYER_IP/g" inventory
else
  sed -i "/^\[deployer_virt\]/a ardana-$clm_env      ansible_host=$DEPLOYER_IP" inventory
fi

cat inventory

NETWORK_MGMT_ID=$(openstack --os-cloud ${os_cloud} stack output show $heat_stack_name mgmt-network-id -c output_value -f value)

cat << EOF > host_vars/ardana-$clm_env.yml
---
input_model_path: "$input_model_path"
deployer_mgmt_ip: $(openstack --os-cloud ${os_cloud} stack output show $heat_stack_name admin-mgmt-ip -c output_value -f value)
EOF

controller_mgmt_ips=$(openstack --os-cloud ${os_cloud} stack output show $heat_stack_name controller-mgmt-ips -c output_value -f value|grep -o '[0-9.]*')
if [ -n "$controller_mgmt_ips" ]; then
echo "controller_mgmt_ips:" >> host_vars/ardana-$clm_env.yml
for ip in $controller_mgmt_ips; do
    cat << EOF >> host_vars/ardana-$clm_env.yml
  - $ip
EOF
done
fi

compute_mgmt_ips=$(openstack --os-cloud ${os_cloud} stack output show $heat_stack_name compute-mgmt-ips -c output_value -f value|grep -o '[0-9.]*')
if [ -n "$compute_mgmt_ips" ]; then
echo "compute_mgmt_ips:" >> host_vars/ardana-$clm_env.yml
for ip in $compute_mgmt_ips; do
    cat << EOF >> host_vars/ardana-$clm_env.yml
  - $ip
EOF
done
fi

# Get the IP addresses of the dns servers from the mgmt network
echo "dns_servers:" >> host_vars/ardana-$clm_env.yml
openstack --os-cloud ${os_cloud} port list --network $NETWORK_MGMT_ID \
        --device-owner network:dhcp -f value -c 'Fixed IP Addresses' | \
  sed -e "s/^ip_address='\(.*\)', .*$/\1/" | \
  while read line; do echo "  - $line" >> host_vars/ardana-$clm_env.yml; done;

cat host_vars/ardana-$clm_env.yml
