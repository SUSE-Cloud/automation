/**
 * The openstack-ardana-tests Jenkins Pipeline
 *
 * This job runs tempest and ardana-qa-tests on a pre-deployed CLM cloud.
 */

def ardana_lib = null

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
          // Parameters of the type 'extended-choice' are set to null when the job
          // is automatically triggered and its value is set to ''. So, we need to set
          // it to '' to be able to pass it as a parameter to downstream jobs.
          if (env.tempest_filter_list == null) {
            env.tempest_filter_list = ''
          }
          if (env.qa_test_list == null) {
            env.qa_test_list = ''
          }
          if (tempest_filter_list == '' && qa_test_list == '') {
            error("Empty 'tempest_run_filter' and 'qa_test_list' parameter values.")
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
          ardana_lib = load "$SHARED_WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
          ardana_lib.get_deployer_ip()

          // Generate stages for Tempest tests
          ardana_lib.generate_tempest_stages(env.tempest_filter_list)
          // Generate stages for QA tests
          ardana_lib.generate_qa_tests_stages(env.qa_test_list)

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
