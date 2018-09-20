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

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      customWorkspace ardana_env ? "${JOB_NAME}-${ardana_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        cleanWs()

        // If the job is set up to reuse an existing workspace, replace the
        // current workspace with a symlink to the reused one.
        // NOTE: even if we specify the reused workspace as the
        // customWorkspace variable value, Jenkins will refuse to reuse a
        // workspace that's already in use by one of the currently running
        // jobs and will just create a new one.
        sh '''
          if [ -n "${reuse_workspace}" ]; then
            rmdir "${WORKSPACE}"
            ln -s "${reuse_workspace}" "${WORKSPACE}"
          fi
        '''

        script {
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          if (reuse_workspace == '') {
            sh('git clone $git_automation_repo --branch $git_automation_branch automation-git')
            sh('''
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
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook bootstrap-clm.yml -e @input.yml -e extra_repos=$extra_repos
        ''')
      }
    }
  }

  post {
    always {
        archiveArtifacts artifacts: '.artifacts/**/*', allowEmptyArchive: true
    }
  }
}
