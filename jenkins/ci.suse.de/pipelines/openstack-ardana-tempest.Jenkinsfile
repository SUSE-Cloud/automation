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
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          if (reuse_workspace == '') {
            sh('git clone $git_automation_repo --branch $git_automation_branch automation-git')
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook load-job-params.yml
            ''')
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook setup-ssh-access.yml -e @input.yml
            ''')
          }
        }
      }
    }

    stage('Run Tempest') {
      steps {
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook run-tempest.yml -e @input.yml
        ''')
      }
      post {
        always {
          junit testResults: '.artifacts/*.xml', allowEmptyResults: true
        }
      }
    }
  }

  post {
    always {
        archiveArtifacts artifacts: '.artifacts/**/*', allowEmptyArchive: true
    }
  }
}
