/**
 * The openstack-ardana-testbuild-gerrit Jenkins Pipeline
 *
 * This job creates test IBS packages corresponding to supplied Gerrit patches.
 */
pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "openstack-trackupstream"
    }
  }

  stages {
    stage('setup workspace and environment') {
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
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
          env.test_repository_url = sh (
            returnStdout: true,
            script: '''
              echo http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${gerrit_change_ids//,/-}/standard/${homeproject}:ardana-ci-${gerrit_change_ids//,/-}.repo
            '''
          )
        }
      }
    }

    stage('clone automation repo') {
      when {
        expression { reuse_workspace == '' }
      }
      steps {
        sh 'git clone $git_automation_repo --branch $git_automation_branch automation-git'
      }
    }

    stage('build test packages') {
      steps {
        sh '''
          cd automation-git/scripts/jenkins/ardana/gerrit
          set -eux
          python -u build_test_package.py
          echo "zypper repository for test packages: $test_repository_url"
        '''
      }
    }
  }
}
