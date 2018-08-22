#!/bin/bash
set +x
. $WORKSPACE/heat_stack_env

# the name for the cloud defined in ~./config/openstack/clouds.yaml
CLOUD_CONFIG_NAME=engcloud-cloud-ci
# mirror used to download images
image_mirror_url=http://provo-clouddata.cloud.suse.de/images/openstack/x86_64

set -ex

pushd automation-git/scripts/jenkins/ardana/ansible

DEPLOYER_IP=$(openstack --os-cloud $CLOUD_CONFIG_NAME stack output show $heat_stack_name admin-floating-ip -c output_value -f value)
NETWORK_MGMT_ID=$(openstack --os-cloud $CLOUD_CONFIG_NAME stack output show $heat_stack_name mgmt-network-id -c output_value -f value)
sed -i "s/^ardana-virt.*/ardana-virt      ansible_host=$DEPLOYER_IP/g" inventory

cat << EOF > host_vars/ardana-virt.yml
---
input_model_path: "$input_model_path"
deployer_mgmt_ip: $(openstack --os-cloud $CLOUD_CONFIG_NAME stack output show $heat_stack_name admin-mgmt-ip -c output_value -f value)
EOF

controller_mgmt_ips=$(openstack --os-cloud $CLOUD_CONFIG_NAME stack output show $heat_stack_name controller-mgmt-ips -c output_value -f value|grep -o '[0-9.]*')
if [ -n "$controller_mgmt_ips" ]; then
    echo "controller_mgmt_ips:" >> host_vars/ardana-virt.yml
    for ip in $controller_mgmt_ips; do
        cat << EOF >> ardana_virt.yml
        - $ip
EOF
    done
fi

compute_mgmt_ips=$(openstack --os-cloud $CLOUD_CONFIG_NAME stack output show $heat_stack_name compute-mgmt-ips -c output_value -f value|grep -o '[0-9.]*')
if [ -n "$compute_mgmt_ips" ]; then
    echo "compute_mgmt_ips:" >> host_vars/ardana-virt.yml
    for ip in $compute_mgmt_ips; do
        cat << EOF >> host_vars/ardana-virt.yml
        - $ip
EOF
    done
fi

# Get the IP addresses of the dns servers from the mgmt network
echo "mgmt_dnsservers:" >> host_vars/ardana-virt.yml
openstack --os-cloud $CLOUD_CONFIG_NAME port list --network $NETWORK_MGMT_ID \
          --device-owner network:dhcp -f value -c 'Fixed IP Addresses' | \
    sed -e "s/^ip_address='\(.*\)', .*$/\1/" | \
    while read line; do echo "  - $line" >> host_vars/ardana-virt.yml; done;

cat host_vars/ardana-virt.yml

sshargs="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
# FIXME: Use cloud-init in the used image
sshpass -p linux ssh-copy-id -o ConnectionAttempts=120 $sshargs root@${DEPLOYER_IP}

source /opt/ansible/bin/activate

ansible-playbook -v ssh-keys.yml
if [ -n "$gerrit_change_ids" ] ; then
    test_repository=http://download.suse.de/ibs/${homeproject//:/:\/}:/ardana-ci-${gerrit_change_ids//,/-}/standard
fi
ansible-playbook -v -e "build_url=$BUILD_URL" \
                    -e "cloudsource=${cloudsource}" \
                    -e "repositories='${repositories}'" \
                    -e "test_repository_url=${test_repository}" \
                    repositories.yml
verification_temp_dir=$(ssh $sshargs root@$DEPLOYER_IP \
                        "mktemp -d /tmp/ardana-job-rpm-verification.XXXXXXXX")
ansible-playbook -v -e "deployer_floating_ip=$DEPLOYER_IP" \
                    -e "verification_temp_dir=$verification_temp_dir" \
                    -e cloudsource="${cloudsource}" \
                    init.yml

# Run site.yml outside ansible for output streaming
ssh $sshargs ardana@$DEPLOYER_IP "cd ~/scratch/ansible/next/ardana/ansible ; \
    ansible-playbook -v -i hosts/verb_hosts site.yml"

# Run Update if required
if [ -n "$update_cloudsource" -a "$update_cloudsource" != "$cloudsource" -o -n "$update_repositories" ]; then

    # Run pre-update checks
    ansible-playbook -v \
        -e "image_mirror_url=${image_mirror_url}" \
        -e "tempest_run_filter=${tempest_run_filter}" \
        pre-update-checks.yml

    ansible-playbook -v \
        -e "build_url=$BUILD_URL" \
        -e "cloudsource=${update_cloudsource}" \
        -e "repositories='${update_repositories}'" \
        repositories.yml

    ansible-playbook -v \
        -e "cloudsource=${update_cloudsource}" \
        -e "update_method=${update_method}" \
        update.yml
fi

# Run post-deploy checks
ansible-playbook -v \
    -e "image_mirror_url=${image_mirror_url}" \
    -e "tempest_run_filter=${tempest_run_filter}" \
    -e "verification_temp_dir=$verification_temp_dir" \
    post-deploy-checks.yml
