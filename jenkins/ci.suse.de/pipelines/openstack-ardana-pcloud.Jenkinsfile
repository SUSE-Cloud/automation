/**
 * The openstack-ardana-pcloud Jenkins Pipeline
 *
 * This jobs creates an fresh VM on the specified HW environment
 * that can be used to deploy an Ardana input model which is either
 * predefined or generated based on the input parameters.
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

    stage('Generate input model') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook generate-input-model.yml -e @input.yml
        ''')
      }
    }

    stage('Start deployer VM') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook start-deployer-vm.yml -e @input.yml
        ''')
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
      sh """
      set +x
      cd $SHARED_WORKSPACE/automation-git/scripts/jenkins/ardana/ansible
      echo "
*****************************************************************
** The deployer for ${ardana_env} is reachable at
**
**        ssh root@\$(awk '/^${ardana_env}/{print \$2}' inventory | cut -d'=' -f2)
**
*****************************************************************
      "
      """
    }
  }
}
