/**
 * The openstack-ardana-bootstrap-clm Jenkins Pipeline
 *
 * This job sets up the CLM node by adding/updating software media and repositories,
 * SLES and RHEL artifacts, installing/updating the cloud-ardana pattern, etc.
 * The resulted CLM node can then be used directly to deploy an Ardana cloud or
 * snapshotted and cloned to be later on used to deploy several cloud scenarios
 * based on the same cloudsource media/repositories.

 * This job should only include steps that are common to all cloud setup scenarios
 * using the same clousource media/repositories. It shouldn't include setting up an
 * input model, which would mean specializing the CLM node to be used only with a particular
 * scenario. This job should also not require interaction with any of the other nodes in
 * the cloud. These restrictions are necessary to support the requirement of being able to
 * create a CLM node snapshot that can be reused to spin up several cloud setups based on
 * the same media and software channels.
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

    stage('Bootstrap CLM') {
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook bootstrap-clm.yml -e @input.yml -e extra_repos=$extra_repos
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
  }
}
