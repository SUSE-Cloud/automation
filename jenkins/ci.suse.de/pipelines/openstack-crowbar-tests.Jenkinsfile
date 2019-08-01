/**
 * The openstack-ardana-tests Jenkins Pipeline
 *
 * This job runs tempest and ardana-qa-tests on a pre-deployed CLM cloud.
 */


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
          if (tempest_filter_list == '' && test_cloud == 'false') {
            error("Empty 'tempest_run_filter/test_cloud' parameter value.")
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
        }
      }
    }

    stage('Test cloud') {
      when {
        expression { test_cloud == 'true' }
      }
      steps {
        script {
          // This step does the following on the non-admin nodes:
          //  - runs tempest (smoke) and other tests on the deployed cloud
          cloud_lib.ansible_playbook('run-crowbar-tests')
          archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
          junit testResults: ".artifacts/testr_crowbar.xml", allowEmptyResults: false
        }
      }
    }

    stage ('Prepare tempest tests') {
      when {
        expression { tempest_filter_list != '' }
      }
      steps {
        script {
          // Generate stages for Tempest tests
          cloud_lib.generate_tempest_stages(env.tempest_filter_list, 'crowbar')
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
