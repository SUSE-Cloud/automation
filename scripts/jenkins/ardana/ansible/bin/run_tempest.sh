#!/usr/bin/env bash

set -ex

sshargs="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

ssh $sshargs ardana@${DEPLOYER_IP} "cd ~/scratch/ansible/next/ardana/ansible ; \
     ansible-playbook -v -i hosts/verb_hosts tempest-run.yml \
                       -e run_filter=$tempest_run_filter"
