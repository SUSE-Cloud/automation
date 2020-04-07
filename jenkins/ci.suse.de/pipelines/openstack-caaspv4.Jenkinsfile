/**
 * The openstack-ardana-caaspv4 Jenkins Pipeline
 *
 * This job runs casspv4 deployment on a pre-deployed CLM cloud.
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
          currentBuild.displayName = "#${BUILD_NUMBER}: ${cloud_env}"
          sh('''
             git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)
          cloud_lib.load_os_params_from_resource(cloud_env)
          cloud_lib.ansible_playbook('load-job-params')
          cloud_lib.get_deployer_ip()
        }
      }
    }
    stage ('Deploy Caaspv4 using Terraform') {
      when {
        expression { want_caaspv4 == 'true' }
      }
      steps {
        script {
          // Generate stage for CaaSPv4 deployment
          if (want_caaspv4 == 'true') {
            stage('Deploy CaaSPv4') {
              cloud_lib.ansible_playbook('deploy-caasp-v4-terraform')
            }
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
