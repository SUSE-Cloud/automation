/**
 * The openstack-ardana Jenkins Pipeline
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label 'cloud-ardana-ci'
      customWorkspace ardana_env ? "${JOB_NAME}-${ardana_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('setup workspace and environment') {
      steps {
        cleanWs()

        script {
          env.cloud_type = "virtual"
          if ( ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          if ( ardana_env.startsWith("qe") || ardana_env.startsWith("qa") ) {
            env.cloud_type = "physical"
          }
          env.cloud_release = "cloud"+cloudsource[-1]
          if ( "${want_caasp}" == 'true' ) {
            // Use the CaaSP flavors instead of the default ones, when CaaSP is deployed
            env.virt_config="caasp.yml"
          }
          env.input_model_path = "${WORKSPACE}/input-model"
          env.test_repository_url = ''
        }
      }
    }

    stage('clone automation repo') {
      steps {
        sh 'git clone $git_automation_repo --branch $git_automation_branch automation-git'
      }
    }

    stage('parallel one') {
      // abort all stages if one of them fails
      failFast true
      parallel {

        stage('build test packages') {
          when {
            expression { gerrit_change_ids != '' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-testbuild-gerrit', parameters: [
                string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
                string(name: 'develproject', value: "$develproject"),
                string(name: 'homeproject', value: "$homeproject"),
                string(name: 'repository', value: "$repository"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch")
              ], propagate: true, wait: true

              // Load the environment variables set by the downstream job
              env.test_repository_url = slaveJob.buildVariables.test_repository_url
            }
          }
        }

        stage('rebuild deployer VM for HW setup') {
          when {
            expression { cloud_type == 'physical' }
          }
          steps {
            sh '''
              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible-playbook -v \
                               -e qe_env=$ardana_env \
                               -e rc_notify=$rc_notify \
                               rebuild-deployer-vm.yml

              ansible-playbook -v \
                               -e ardana_env=$ardana_env \
                               ssh-keys.yml
            '''
          }
        }

        stage('generate HW input model') {
          when {
              expression { cloud_type == 'physical' }
          }
          steps {
            script {
              env.virt_config = "${WORKSPACE}/${scenario}-virt-config.yml"
            }
            sh '''
              # convert cloudsource to cloud_source
              # TODO: this will no longer be needed when the virtual/hw stages are merged
              if [[ "$cloudsource" == "GM"* ]]; then
                cloud_source="GM"
              elif [[ "$cloudsource" == "staging"* ]]; then
                cloud_source="devel-staging"
              elif [[ "$cloudsource" == "devel"* ]]; then
                cloud_source="devel"
              fi

              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible-playbook -v \
                               -e qe_env=$ardana_env \
                               -e cloud_source="${cloud_source}" \
                               -e cloud_release="${cloud_release}" \
                               -e cloud_brand=$cloud_brand \
                               -e scenario_name="${scenario}" \
                               -e ardana_input_model="${scenario}" \
                               -e input_model_dir="${input_model_path}" \
                               -e clm_model=$clm_model \
                               -e controllers=$controllers \
                               -e sles_computes=$sles_computes \
                               -e rhel_computes=$rhel_computes \
			       -e ses_enabled=$ses_enabled \
                               -e rc_notify=$rc_notify \
                               generate-input-model.yml
            '''
          }
        }


        stage('prepare virtual environment') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-vcloud', parameters: [
                string(name: 'ardana_env', value: "${ardana_env}"),
                string(name: 'cloud_release', value: "${cloud_release}"),
                string(name: 'git_automation_repo', value: "${git_automation_repo}"),
                string(name: 'git_automation_branch', value: "${git_automation_branch}"),
                string(name: 'git_input_model_repo', value: "${git_input_model_repo}"),
                string(name: 'git_input_model_branch', value: "${git_input_model_branch}"),
                string(name: 'git_input_model_path', value: "${git_input_model_path}"),
                string(name: 'model', value: "${model}"),
                string(name: 'scenario', value: "${scenario}"),
                string(name: 'clm_model', value: "${clm_model}"),
                string(name: 'controllers', value: "${controllers}"),
                string(name: 'sles_computes', value: "${sles_computes}"),
                string(name: 'rhel_computes', value: "${rhel_computes}"),
                string(name: 'os_cloud', value: "${os_cloud}"),
                string(name: 'rc_notify', value: "${rc_notify}"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'reuse_workspace', value: "${WORKSPACE}")
              ], propagate: true, wait: true

              // Load the environment variables set by the downstream job
              env.DEPLOYER_IP=slaveJob.buildVariables.DEPLOYER_IP
              env.heat_stack_name=slaveJob.buildVariables.heat_stack_name
              env.input_model_path=slaveJob.buildVariables.input_model_path
            }
          }
        } // stage('prepare virtual environment')
      } // parallel
    } // stage('parallel stage')

    stage('bootstrap deployer') {
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-bootstrap', parameters: [
            string(name: 'ardana_env', value: "${ardana_env}"),
            string(name: 'git_automation_repo', value: "${git_automation_repo}"),
            string(name: 'git_automation_branch', value: "${git_automation_branch}"),
            string(name: 'cloudsource', value: "${cloudsource}"),
            string(name: 'repositories', value: "${repositories}"),
            string(name: 'test_repository_url', value: "${test_repository_url}"),
            string(name: 'cloud_brand', value: "${cloud_brand}"),
            string(name: 'rc_notify', value: "${rc_notify}"),
            string(name: 'cloud_maint_updates', value: "${cloud_maint_updates}"),
            string(name: 'sles_maint_updates', value: "${sles_maint_updates}"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: true, wait: true

          // Load the environment variables set by the downstream job
        }
      }
    }

    stage('deploy cloud') {
      parallel {
        stage ('deploy virtual cloud') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps {
            sh '''
              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible-playbook -v \
                               -e ardana_env=$ardana_env \
                               -e build_url=$BUILD_URL \
                               -e cloudsource="${cloudsource}" \
                               init.yml
              ./bin/deploy_ardana.sh
            '''
          }
        }

        stage('deploy physical cloud') {
          when {
            expression { cloud_type == 'physical' }
          }
          steps {
            sh '''
              # convert cloudsource to cloud_source
              # TODO: this will no longer be needed when the virtual/hw stages are merged
              if [[ "$cloudsource" == "GM"* ]]; then
                cloud_source="GM"
              elif [[ "$cloudsource" == "staging"* ]]; then
                cloud_source="devel-staging"
              elif [[ "$cloudsource" == "devel"* ]]; then
                cloud_source="devel"
              fi

              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible-playbook -v \
                               -e qe_env=$ardana_env \
                               -e cloud_source=$cloud_source \
                               -e cloud_brand=$cloud_brand \
                               -e rc_notify=$rc_notify \
                               -e ardana_input_model=$scenario \
                               -e input_model_path=$input_model_path \
                               -e cloud_maint_updates=$cloud_maint_updates \
                               -e sles_maint_updates=$sles_maint_updates \
                               -e clm_model=$clm_model \
                               -e controllers=$controllers \
                               -e sles_computes=$sles_computes \
                               -e rhel_computes=$rhel_computes \
                               -e ses_enabled=$ses_enabled \
                               ardana-deploy.yml
            '''
          }
        }
      }
    }

    stage('parallel two') {
      // run all stages to the end, even if one of them fails
      failFast false
      parallel {

        stage ('tempest') {
          when {
            expression { tempest_run_filter != '' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-tempest', parameters: [
                string(name: 'ardana_env', value: "${ardana_env}"),
                string(name: 'git_automation_repo', value: "${git_automation_repo}"),
                string(name: 'git_automation_branch', value: "${git_automation_branch}"),
                string(name: 'tempest_run_filter', value: "${tempest_run_filter}"),
                string(name: 'rc_notify', value: "${rc_notify}"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'reuse_workspace', value: "${WORKSPACE}")
              ], propagate: true, wait: true

              // Load the environment variables set by the downstream job
            }
          }
        }

        stage ('post deploy checks') {
          steps {
            sh '''
              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              # Run post-deploy checks
              ansible-playbook -v \
                               -e ardana_env=$ardana_env \
                               post-deploy-checks.yml
            '''
          }
        }
      }
    }

    stage ('deploy CaaSP') {
      when {
        expression { want_caasp == 'true' }
      }
      steps {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          source /opt/ansible/bin/activate
          ansible-playbook -v \
                           -e ardana_env=$ardana_env \
                           deploy-caasp.yml
        '''
      }
    }
  }

  post {
    always {
      lock(resource: 'cloud-ECP-API') {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          if [ "$cloud_type" == "virtual" ] && [ "$cleanup" == "always" ] && [ -n "${heat_stack_name}" ]; then
            ./bin/heat_stack.sh delete "${heat_stack_name}"
          fi
        '''
      }
    }
    success {
      lock(resource: 'cloud-ECP-API') {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          if [ "$cloud_type" == "virtual" ] && [ "$cleanup" == "on success" ] && [ -n "${heat_stack_name}" ]; then
            ./bin/heat_stack.sh delete "${heat_stack_name}"
          fi
        '''
      }
    }
    failure {
      lock(resource: 'cloud-ECP-API') {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          if [ "$cloud_type" == "virtual" ] && [ "$cleanup" == "on failure" ] && [ -n "${heat_stack_name}" ]; then
            ./bin/heat_stack.sh delete "${heat_stack_name}"
          fi
        '''
      }
    }
  }
}
