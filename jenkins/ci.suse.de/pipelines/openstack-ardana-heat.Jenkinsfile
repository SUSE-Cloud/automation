/**
 * The openstack-ardana-heat Jenkins Pipeline
 *
 * This jobs automates creating/deleting heat stacks.
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
    stage('Setup workspace') {
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
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          if (heat_action == '') {
            error("Empty 'heat_action' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${heat_action} ${ardana_env}"
          if (reuse_workspace == '') {
            if (heat_action == 'create') {
              error("This job needs to be called by an upstream job to create a heat stack.")
            }
            sh('git clone $git_automation_repo --branch $git_automation_branch automation-git')
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook load-job-params.yml
            ''')
          }
        }
      }
    }
    stage('Delete heat stack') {
      steps {
        // Run the monitoring bits outside of the ECP-API lock, and lock the
        // ECP API only while actually deleting the stack
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook heat-stack.yml -e @input.yml -e heat_action='monitor'
        ''')
        lock(resource: 'cloud-ECP-API') {
          sh('''
            source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
            ansible_playbook heat-stack.yml -e @input.yml -e heat_action='delete' -e monitor_stack_after_delete=False
          ''')
        }
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook heat-stack.yml -e @input.yml -e heat_action='monitor'
        ''')
      }
    }
    stage('Create heat stack') {
      when {
        expression { heat_action == 'create' }
      }
      steps {
        lock(resource: 'cloud-ECP-API') {
          sh('''
            source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
            ansible_playbook heat-stack.yml -e @input.yml
          ''')
        }
      }
    }
  }
}
