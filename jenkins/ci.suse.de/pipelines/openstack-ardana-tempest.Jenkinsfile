/**
 * The openstack-ardana-tempest Jenkins Pipeline
 *
 * This job runs tempest on a pre-deployed CLM cloud.
 */

pipeline {

  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      // Use a single workspace for all job runs, to avoid cluttering the
      // worker node
      customWorkspace "${JOB_NAME}"
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
              cd $SHARED_WORKSPACE
              git clone $git_automation_repo --branch $git_automation_branch automation-git
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook load-job-params.yml
              ansible_playbook setup-ssh-access.yml -e @input.yml
            ''')
          }
        }
      }
    }

    stage('Run Tempest') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook run-tempest.yml -e @input.yml
        ''')
      }
    }
  }

  post {
    always {
        // archiveArtifacts and junit don't support absolute paths, so we have to to this instead
        sh 'ln -s ${SHARED_WORKSPACE} ${BUILD_NUMBER}'
        archiveArtifacts artifacts: "${BUILD_NUMBER}/.artifacts/**/*", allowEmptyArchive: true
        junit testResults: "${BUILD_NUMBER}/.artifacts/*.xml", allowEmptyResults: true
        sh 'rm ${BUILD_NUMBER}'
    }
  }
}
