/**
 * The openstack-ardana-update Jenkins Pipeline
 *
 * This job updates a pre-deployed CLM cloud.
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
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          if (cloud_env == '') {
            error("Empty 'cloud_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${cloud_env}"
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_os_params_from_resource(cloud_env)
          cloud_lib.load_extra_params_as_vars(extra_params)
          cloud_lib.ansible_playbook('load-job-params')
          cloud_lib.ansible_playbook('setup-ssh-access')
          cloud_lib.get_deployer_ip()
        }
      }
    }

    stage('Update ardana') {
      steps {
        script {
          cloud_lib.ansible_playbook('ardana-update', "-e cloudsource=$update_to_cloudsource")
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
    }
    cleanup {
      cleanWs()
    }
  }
}
