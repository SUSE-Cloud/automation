/**
 * The openstack-ardana-bootstrap Jenkins Pipeline
 *
 * This job sets up the CLM node by adding/updating software media and repositories,
 * SLES and RHEL artifacts, installing/updating the cloud-ardana pattern, etc.
 * The resulted CLM node can then be used directly to deploy an Ardana cloud or
 * snapshotted and cloned to be later on used to deploy several cloud scenarios
 * based on the same cloudsource media/repositories.

 * This job should only include steps that are common to all cloud setup scenarios
 * using the same clousource media/repositories. It shouldn't include setting up an
 * input model, which would mean specializing the CLM node to be used only with a particular
 * scenario. This job should also not require interaction with any of the other nodes in
 * the cloud. These restrictions are necessary to support the requirement of being able to
 * create a CLM node snapshot that can be reused to spin up several cloud setups based on
 * the same media and software channels.
 */
pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      customWorkspace clm_env ? "${JOB_NAME}-${clm_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
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
          env.cloud_type = "virtual"
          if ( clm_env == '') {
            error("Empty 'clm_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${clm_env}"
          // FIXME: find a better way of differentiating between hardware and virtual environments
          if ( clm_env.startsWith("qe") || clm_env.startsWith("qa") ) {
            env.cloud_type = "physical"
          }
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

    stage('setup ansible vars') {
      when {
        expression { cloud_type == 'virtual' && reuse_workspace == '' }
      }
      steps {
        script {
          // When running as a standalone job, we need a heat stack name to identify
          // the virtual environment and set up the ansible inventory.
          env.heat_stack_name="openstack-ardana-$clm_env"
        }
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          ./bin/setup_virt_vars.sh
        '''
      }
    }

    stage('bootstrap deployer') {
      parallel {
        stage ('bootstrap deployer for virtual setup') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps {
            sh '''
              cd automation-git/scripts/jenkins/ardana/ansible
              source /opt/ansible/bin/activate
              ansible-playbook -v -e clm_env=$clm_env \
                                  -e "cloudsource=${cloudsource}" \
                                  -e "repositories=${repositories}" \
                                  -e "test_repository_url=${test_repository_url}" \
                                  repositories.yml
            '''
          }
        }

        stage('bootstrap deployer for HW setup') {
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
              ansible-playbook -e qe_env=$clm_env \
                               -e cloud_source=$cloud_source \
                               -e cloud_brand=$cloud_brand \
                               -e rc_notify=$rc_notify \
                               -e rhel_computes=$rhel_computes \
                               -e cloud_maint_updates="$cloud_maint_updates" \
                               -e sles_maint_updates="$sles_maint_updates" \
                               bootstrap-deployer-vm.yml
            '''
          }
        }
      }
    }
  }
}
