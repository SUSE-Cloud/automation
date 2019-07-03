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
      label "cloud-ci"
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          if (cloud_env == '') {
            error("Empty 'cloud_env' parameter value.")
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
          currentBuild.displayName = "#${BUILD_NUMBER}: ${cloud_env}"
          sh('''
             git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)
          cloud_lib.load_os_params_from_resource(cloud_env)
          cloud_lib.ansible_playbook('load-job-params')
          cloud_lib.ansible_playbook('setup-ssh-access')
          cloud_lib.get_deployer_ip()

          // Generate stages for Tempest tests
          cloud_lib.generate_tempest_stages(env.tempest_filter_list)
          // Generate stages for QA tests
          cloud_lib.generate_qa_tests_stages(env.qa_test_list)

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
