#!/bin/bash
#
# (c) Copyright 2015-2017 Hewlett Packard Enterprise Development LP
# (c) Copyright 2017 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#

set -eux
set -o pipefail

#
# Script to prepare the deployer to run Ardana Ansible
#
ARDANA_INIT_AUTO=${ARDANA_INIT_AUTO:+y}
SCRIPT_DIR="$(readlink -e $(dirname "${BASH_SOURCE}"))"
owner="$(stat -c '%U' "$SCRIPT_DIR")"
group="$(stat -c '%G' "$SCRIPT_DIR")"

deployer_version="ardana-0.9.0"
ansible_package_dir="/opt/stack/venv/ansible-1.9.3"
ansible_service_dir="/opt/stack/service/ansible-1.9.3"
ansible_generic_service_dir="/opt/stack/service/ansible"

script_ansible="${SCRIPT_DIR}/ansible/$deployer_version"
script_input_model="${SCRIPT_DIR}/input-model/$deployer_version"

#
# ardana sources installed via RPM packages
#
ardana_source=/usr/share/ardana
ardana_ansible_source=${ardana_source}/ansible

#
# User output directories.
#
ardana_output_dir="/var/lib/ardana/"
ardana_staging_dir="${ardana_output_dir}/openstack-input"
ardana_ansible_parent_dir="${ardana_staging_dir}/ardana"
ardana_ansible_dir="${ardana_ansible_parent_dir}/ansible"

ardana_target_dir="${ardana_output_dir}/openstack"
ardana_deploy_dir="${ardana_output_dir}/scratch/ansible"
ardana_packager_dir="/opt/ardana_packager/$deployer_version"
ardana_extensions_dir="${ardana_staging_dir}/ardana_extensions"

# Create ssh keys for the current user (if they don't exist) and make sure
# that user is allowed to ssh to localhost without a password.
if [ ! -d ~/.ssh ]; then
    mkdir ~/.ssh
    chmod 0700 ~/.ssh
fi
pushd ~/.ssh > /dev/null
# Disable GSSAPI authentication because it's not configured and that causes
# delays in creating ssh connections to RedHat nodes. If the user has already
# customized their ssh config then leave it alone.
if [ ! -e config ]; then
    cat > config << EOF
Host *
    GSSAPIAuthentication no
EOF
    chmod 0600 config
fi
if [ ! -e id_rsa ]; then
    if [ -z "${ARDANA_INIT_AUTO}" ]; then
        ssh-keygen -q -t rsa -f id_rsa
    else
        ssh-keygen -q -t rsa -N "" -f id_rsa
    fi
fi
if ! grep -q "`cat id_rsa.pub`" authorized_keys; then
    cat id_rsa.pub >> authorized_keys
    chmod 0600 authorized_keys
fi
popd > /dev/null
# Check that ssh works, with no password. The bash option -e is in force
# so we will abort at this point if there's a problem.
ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no localhost date

#
# Clean-up any old deploys first.
#
sudo rm -rf "${ansible_package_dir}" \
  "${ansible_service_dir}" \
  "${script_ansible}" \
  "${ardana_staging_dir}"

# Get Deployer OS name
OS="SLES"
if [ -f /etc/os-release ]; then
   . /etc/os-release
   OS=$NAME
fi

#
# Get an Ansible venv set-up (bootstrap Ansible)
#
sudo mkdir -p "${ansible_package_dir}"
sudo mkdir -p "${ansible_service_dir}"
# Extract the Ansible venv from the venv tarball.
if [ "${OS,,}" == "sles" ]; then
   rpmqpack | grep -qx ansible || {
       sudo rpm -Uvh http://ftp5.gwdg.de/pub/opensuse/discontinued/distribution/leap/42.1/repo/oss/suse/noarch/ansible-1.9.3-1.1.noarch.rpm
   }
else
   echo "Unsupported OS: $OS"
fi

#
# Set-up Ansible playbooks.
#
mkdir -p "${ardana_ansible_dir}"
cp -r "${ardana_ansible_source}"/* "${ardana_ansible_dir}"

#
# Set up ardana-extensions area
#
if false; then
mkdir -p "${ardana_extensions_dir}"
tar xf "${ardana_output_dir}/{{ deployer_ardana_extensions_tarball }}" \
  --owner "${owner}" --group "${group}" \
  -C "${ardana_extensions_dir}"
fi


#
# Set-up default Ansible config.
#
# Clear down any old user Ansible config.
rm -rf "${ardana_output_dir}/.ansible.cfg"
pushd "${ardana_ansible_dir}" &>/dev/null
echo "[defaults]" > ${ardana_output_dir}/.ansible.cfg

ansible-playbook -i hosts/localhost ansible-init.yml
ansible-playbook -i hosts/localhost git-00-initialise.yml
ansible-playbook -i hosts/localhost deployer-init.yml
ansible-playbook -i hosts/localhost git-01-receive-new.yml
popd &>/dev/null

# Disable persistent fact caching for plays in ${ardana_target_dir}/ardana/ansible/
pushd "${ardana_target_dir}/ardana/ansible/" &>/dev/null
ansible-playbook -i hosts/localhost ansible-init.yml -e \
  'fact_caching_enabled=false \
  ansible_cfg_loc='$(pwd)'/ansible.cfg'
popd &>/dev/null

# Create base venv package manifest
declare -a dir_list=( $ardana_packager_dir/rhel_venv $ardana_packager_dir/sles_venv )
for dir in "${dir_list[@]}"; do
    if [ -e "$dir/packages" ]; then
        sudo cp "$dir/packages" "$dir/base_packages"
    fi
done

#
# Tidy up inputs
#
rm -rf "${ardana_staging_dir}"

set +x

echo
tp_dirs=$(shopt -s nullglob dotglob; echo ~/third-party/*/)
if (( ${#tp_dirs} )); then
    RED='\033[0;31m'
    NC='\033[0m'
    echo -e "${RED}Third-party content detected!${NC}"
    echo "To import third-party content, execute the following:"
    echo "    cd ${ardana_target_dir}/ardana/ansible"
    echo "    ansible-playbook -i hosts/localhost third-party-import.yml"
fi

echo
echo "To continue installation copy your cloud layout to:"
echo "    ${ardana_output_dir}/openstack/my_cloud/definition"
echo
echo "Then execute the installation playbooks:"
echo "    cd ${ardana_target_dir}/ardana/ansible"
echo "    git add -A"
echo "    git commit -m 'My config'"
echo "    ansible-playbook -i hosts/localhost cobbler-deploy.yml"
echo "    ansible-playbook -i hosts/localhost bm-reimage.yml"
echo "    ansible-playbook -i hosts/localhost config-processor-run.yml"
echo "    ansible-playbook -i hosts/localhost ready-deployment.yml"
echo "    cd ${ardana_deploy_dir}/next/ardana/ansible"
echo "    ansible-playbook -i hosts/verb_hosts site.yml"
echo
echo "If you prefer to use the UI to install the product, you can"
echo "do either of the following:"
echo "    - If you are running a browser on this machine, you can point"
echo "      your browser to http://localhost:79/dayzero to start the "
echo "      install via the UI."
echo "    - If you are running the browser on a remote machine, you will"
echo "      need to create an ssh tunnel to access the UI.  Please refer"
echo "      to the Ardana installation documentation for further details."
