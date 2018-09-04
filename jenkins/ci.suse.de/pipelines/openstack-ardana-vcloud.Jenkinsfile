/**
 * The openstack-ardana-virtual Jenkins Pipeline
 *
 * This jobs creates an ECP virtual environment that can be used to deploy
 * an Ardana input model which is either predefined or generated based on
 * the input parameters.
 */
pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      customWorkspace ardana_env ? "${JOB_NAME}-${ardana_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('setup workspace and environment') {
      steps {
        cleanWs()

        // If the job is set up to reuse an existing workspace, replace the
        // current workspace with a symlink to the reused one.
        // NOTE: even if we specify the reused workspace as the
        // customWorkspace variable value, Jenkins will refuse to reuse a
        // workspace that's already in use by one of the currently running
        // jobs and will just create a new one.
        sh '''
          if [ -n "${reuse_workspace}" ]; then
            rmdir "${WORKSPACE}"
            ln -s "${reuse_workspace}" "${WORKSPACE}"
          fi
        '''

        script {
          if ( ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          env.heat_stack_name="openstack-ardana-$ardana_env"
          env.input_model_path = "${WORKSPACE}/input-model"
          env.heat_template_file = "${WORKSPACE}/heat-ardana-${model}.yaml"
        }
      }
    }

    stage('clone automation repo') {
      when {
        expression { reuse_workspace == '' }
      }
      steps {
        sh 'git clone $git_automation_repo --branch $git_automation_branch automation-git'
      }
    }

    stage('clone input model repo') {
      when {
        expression { git_input_model_repo != '' && scenario == '' }
      }
      steps {
        sh 'git clone $git_input_model_repo --branch $git_input_model_branch input-model-git'
        script {
          env.input_model_path = "${WORKSPACE}/input-model-git/${git_input_model_path}/${model}"
        }
      }
    }

    stage('generate input model') {
      when {
          expression { scenario != '' }
      }
      steps {
        script {
          env.virt_config = "${WORKSPACE}/${scenario}-virt-config.yml"
        }
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          source /opt/ansible/bin/activate
          ansible-playbook -v \
                           -e qe_env=$ardana_env \
                           -e cloud_release="${cloud_release}" \
                           -e scenario_name="${scenario}" \
                           -e input_model_dir="${input_model_path}" \
                           -e virt_config_file="${virt_config}" \
                           -e clm_model=$clm_model \
                           -e controllers=$controllers \
                           -e sles_computes=$sles_computes \
                           -e rhel_computes=$rhel_computes \
                           -e rc_notify=$rc_notify \
                           generate-input-model.yml
        '''
      }
    }

    stage('generate heat') {
      steps {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          source /opt/ansible/bin/activate
          ansible-playbook -v \
                           -e cloud_release="${cloud_release}" \
                           -e input_model_path="${input_model_path}" \
                           -e heat_template_file="${heat_template_file}" \
                           -e virt_config_file="${virt_config}" \
                           generate-heat.yml
        '''
      }
    }

    stage('create virtual env') {
      steps {
        lock(resource: 'cloud-ECP-API') {
          sh '''
            cd automation-git/scripts/jenkins/ardana/ansible
            ./bin/heat_stack.sh create "${heat_stack_name}" "${heat_template_file}"
          '''
        }
      }
    }

    stage('setup ansible vars') {
      steps {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          ./bin/setup_virt_vars.sh
        '''
        script {
          env.DEPLOYER_IP = sh (
            script: '''
              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible -o localhost -a "echo {{ hostvars['ardana-$ardana_env'].ansible_host }}" | cut -d' ' -f 8
            ''',
            returnStdout: true
          ).trim()
        }
      }
    }

    stage('setup SSH access') {
      steps {
        sh '''
          sshargs="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
          # FIXME: Use cloud-init in the used image
          sshpass -p linux ssh-copy-id -o ConnectionAttempts=120 $sshargs root@${DEPLOYER_IP}
          cd automation-git/scripts/jenkins/ardana/ansible
          source /opt/ansible/bin/activate
          ansible-playbook -v -e ardana_env=$ardana_env \
                               ssh-keys.yml
        '''
      }
    }
  }

  post {
    success{
      echo """
*****************************************************************
** The virtual environment is reachable at
**
**        ssh root@${DEPLOYER_IP}
**
** Please delete the $heat_stack_name stack manually when you're done.
*****************************************************************
      """
    }
    failure {
      lock(resource: 'cloud-ECP-API') {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          if [ -n "${heat_stack_name}" ]; then
            ./bin/heat_stack.sh delete "${heat_stack_name}"
          fi
        '''
      }
    }
  }
}

