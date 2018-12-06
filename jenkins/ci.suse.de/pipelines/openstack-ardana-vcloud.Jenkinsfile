/**
 * The openstack-ardana-virtual Jenkins Pipeline
 *
 * This jobs creates an ECP virtual environment that can be used to deploy
 * an Ardana input model which is either predefined or generated based on
 * the input parameters.
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
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          env.cloud_type = 'virtual'
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
            ''')
          }
          ardana_lib = load "$SHARED_WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
        }
      }
    }

    stage('Prepare input model') {
      steps {
        script {
          if (scenario_name != '') {
            ardana_lib.ansible_playbook('generate-input-model')
          } else {
            ardana_lib.ansible_playbook('clone-input-model')
          }
        }
      }
    }

    stage('Generate heat template') {
      steps {
        script {
          ardana_lib.ansible_playbook('generate-heat-template')
        }
      }
    }

    stage('Create heat stack') {
      steps {
        script {
          ardana_lib.trigger_build('openstack-ardana-heat', [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "create"),
            string(name: 'git_automation_repo', value: "$git_automation_repo"),
            string(name: 'git_automation_branch', value: "$git_automation_branch"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'os_cloud', value: "$os_cloud")
          ])
        }
      }
    }

    stage('Setup SSH access') {
      steps {
        script {
          ardana_lib.ansible_playbook('setup-ssh-access')
        }
      }
    }
  }

  post {
    always {
      script {
        // Let the upstream job archive artifacts
        if (reuse_node == '') {
          archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
        }
      }
    }
    success{
      ardana_lib.get_deployer_ip()
    }
    cleanup {
      cleanWs()
    }
  }
}
