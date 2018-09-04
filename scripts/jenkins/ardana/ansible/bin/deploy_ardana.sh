#!/usr/bin/env bash

image_mirror_url=http://provo-clouddata.cloud.suse.de/images/openstack/x86_64

set -ex

# Set up the directory used by for the post-validation check
sshargs="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
verification_temp_dir=$(ssh $sshargs root@${DEPLOYER_IP} \
                        "mktemp -d /tmp/ardana-job-rpm-verification.XXXXXXXX")
sed -i "s/^verification_temp_dir.*/verification_temp_dir: '${verification_temp_dir//\//\\/}'/g" vars/main.yml

source /opt/ansible/bin/activate
ansible-playbook -v -e clm_env=$clm_env \
                    pre-deploy-checks.yml

# Run site.yml outside ansible for output streaming
ssh $sshargs ardana@${DEPLOYER_IP} "cd ~/scratch/ansible/next/ardana/ansible ; \
     ansible-playbook -v -i hosts/verb_hosts site.yml"

ssh $sshargs ardana@${DEPLOYER_IP} "cd ~/scratch/ansible/next/ardana/ansible ; \
     ansible-playbook -v -i hosts/verb_hosts ardana-cloud-configure.yml \
     -e local_image_mirror_url=\"$image_mirror_url\""
