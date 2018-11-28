/**
 * The openstack-ardana-tempest Jenkins Pipeline
 *
 * This job runs tempest on a pre-deployed CLM cloud.
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
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env}"
          // Use a shared workspace folder for all jobs running on the same
          // target 'ardana_env' cloud environment
          env.SHARED_WORKSPACE = sh (
            returnStdout: true,
            script: 'echo "$(dirname $WORKSPACE)/shared/${ardana_env}"'
          ).trim()
          if (reuse_node == '') {
            sh('''
              rm -rf $SHARED_WORKSPACE
              mkdir -p $SHARED_WORKSPACE

              # archiveArtifacts and junit don't support absolute paths, so we have to to this instead
              ln -s ${SHARED_WORKSPACE}/.artifacts ${WORKSPACE}

              cd $SHARED_WORKSPACE
              git clone $git_automation_repo --branch $git_automation_branch automation-git
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook load-job-params.yml
              ansible_playbook setup-ssh-access.yml -e @input.yml
            ''')
          }
          env.DEPLOYER_IP = sh (
            returnStdout: true,
            script: '''
              grep -oP "${ardana_env}\\s+ansible_host=\\K[0-9\\.]+" \\
                $SHARED_WORKSPACE/automation-git/scripts/jenkins/ardana/ansible/inventory
            '''
          ).trim()
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env} (${DEPLOYER_IP})"
          def filter_list = env.tempest_filter_list.split(',')
          for (filter in filter_list) {
            catchError {
              stage(filter) {
                sh("""
                  cd \$SHARED_WORKSPACE
                  source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
                  ansible_playbook run-tempest.yml -e @input.yml \
                                                   -e tempest_run_filter=$filter
                """)
              }
            }
            archiveArtifacts artifacts: ".artifacts/**/ansible.log, .artifacts/**/*${filter}*", allowEmptyArchive: true
            junit testResults: ".artifacts/testr_results_region1_${filter}.xml", allowEmptyResults: true
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
