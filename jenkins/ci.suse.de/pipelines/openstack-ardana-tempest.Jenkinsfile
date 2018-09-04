/**
 * The openstack-ardana-tempest Jenkins Pipeline
 *
 * This job runs tempest on a pre-deployed CLM cloud.
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
          env.cloud_type = "virtual"
          if ( ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          // FIXME: find a better way of differentiating between hardware and virtual environments
          if ( ardana_env.startsWith("qe") || ardana_env.startsWith("qa") ) {
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
          env.heat_stack_name="openstack-ardana-$ardana_env"
        }
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          ./bin/setup_virt_vars.sh
        '''
      }
    }

    stage('run tempest') {
      steps {
        sh '''
          cd automation-git/scripts/jenkins/ardana/ansible
          source /opt/ansible/bin/activate
          ansible-playbook -v \
                           -e qe_env=$ardana_env \
                           -e rc_notify=$rc_notify \
                           -e tempest_run_filter=$tempest_run_filter \
                           run-ardana-tempest.yml
        '''
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '.artifacts/**', fingerprint: true
    }
  }
}