/**
 * The openstack-ardana-virtual Jenkins Pipeline
 *
 * This jobs creates an ECP virtual environment that can be used to deploy
 * an Ardana input model which is either predefined or generated based on
 * the input parameters.
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
            ''')
          }
        }
      }
    }

    stage('Prepare input model') {
      parallel {
        stage('Generate input model') {
          when {
            expression { scenario_name != '' }
          }
          steps {
            sh('''
              cd $SHARED_WORKSPACE
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook generate-input-model.yml -e @input.yml
            ''')
          }
        }
        stage('Clone input model') {
          when {
            expression { scenario_name == '' }
          }
          steps {
            sh('''
              cd $SHARED_WORKSPACE
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook clone-input-model.yml -e @input.yml
            ''')
          }
        }
      }
    }

    stage('Generate heat template') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook generate-heat-template.yml -e @input.yml
        ''')
      }
    }

    stage('Create heat stack') {
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-heat', parameters: [
              string(name: 'ardana_env', value: "$ardana_env"),
              string(name: 'heat_action', value: "create"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              string(name: 'reuse_node', value: "${NODE_NAME}")
          ], propagate: false, wait: true
          def jobResult = slaveJob.getResult()
          def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
          def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
          echo jobMsg
          if (jobResult != 'SUCCESS') {
             error(jobMsg)
          }
        }
      }
    }

    stage('Setup SSH access') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook setup-ssh-access.yml -e @input.yml
        ''')
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
      cleanWs()
    }
    success{
      script {
        env.DEPLOYER_IP = sh (
          returnStdout: true,
          script: '''
            grep -oP "${ardana_env}\s+ansible_host=\K[0-9\.]+" \
              $SHARED_WORKSPACE/automation-git/scripts/jenkins/ardana/ansible/inventory
          '''
        ).trim()
      }
      echo """
******************************************************************************
** The deployer for the '${ardana_env}' virtual environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
** Please delete the 'openstack-ardana-${ardana_env}' stack manually when you're done.
******************************************************************************
      """
    }
  }
}
