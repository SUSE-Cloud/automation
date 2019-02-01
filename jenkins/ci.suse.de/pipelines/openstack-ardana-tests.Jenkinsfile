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
      label "cloud-ardana-ci"
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
          sh('''
            IFS='/' read -r -a repo_arr <<< "$git_automation_repo"
            export git_automation_repo="${repo_arr[3]}"
            # Need a local git clone copy to run from
            export use_global_clone=false
            curl https://raw.githubusercontent.com/$git_automation_repo/automation/$git_automation_branch/scripts/jenkins/ardana/openstack-ardana.prep.sh | bash
          ''')
          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
          ardana_lib.load_extra_params_as_vars(extra_params)
          ardana_lib.ansible_playbook('load-job-params')
          ardana_lib.ansible_playbook('setup-ssh-access')
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
