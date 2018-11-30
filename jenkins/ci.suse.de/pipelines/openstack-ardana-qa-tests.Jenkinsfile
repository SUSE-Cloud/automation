/**
 * The openstack-ardana-qa-tests Jenkins Pipeline
 *
 * This job runs ardana-qa-tests on a pre-deployed CLM cloud.
 */

pipeline {

  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          if (test_list == '') {
            error("Empty 'test_list' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env}"
          // Use a shared workspace folder for all jobs running on the same
          // target 'ardana_env' cloud environment
          env.SHARED_WORKSPACE = sh (
            returnStdout: true,
            script: 'echo "$(dirname $WORKSPACE)/shared/${ardana_env}"'
          ).trim()
          if (reuse_node == '') {
            // Resort to the backup dedicated workspace if this job is running as
            // a standalone job allowing users to run several tests in parallel
            // targeting the same environment.
            env.SHARED_WORKSPACE = "$WORKSPACE"
            sh('''
               git clone $git_automation_repo --branch $git_automation_branch automation-git
               source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
               ansible_playbook load-job-params.yml
               ansible_playbook setup-ssh-access.yml -e @input.yml
            ''')
          } else {
            // archiveArtifacts and junit don't support absolute paths, so we have to to this instead
            sh "ln -s ${SHARED_WORKSPACE}/.artifacts ${WORKSPACE}"
          }
          env.DEPLOYER_IP = sh (
            returnStdout: true,
            script: '''
              grep -oP "^${ardana_env}\\s+ansible_host=\\K[0-9\\.]+" \\
                $SHARED_WORKSPACE/automation-git/scripts/jenkins/ardana/ansible/inventory
            '''
          ).trim()
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env} (${DEPLOYER_IP})"
          def test_list = env.test_list.split(',')
          for (test in test_list) {
            catchError {
              stage(test) {
                sh("""
                  cd \$SHARED_WORKSPACE
                  source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
                  ansible_playbook run-ardana-qe-tests.yml -e @input.yml \
                                                           -e test_name=$test
                """)
              }
            }
            archiveArtifacts artifacts: ".artifacts/**/${test}*", allowEmptyArchive: true
            junit testResults: ".artifacts/${test}.xml", allowEmptyResults: true
          }
        }
      }
    }
  }
  post {
    cleanup {
      cleanWs()
    }
  }
}
