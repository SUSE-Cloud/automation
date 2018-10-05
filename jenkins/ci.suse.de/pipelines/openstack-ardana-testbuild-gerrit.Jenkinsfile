/**
 * The openstack-ardana-testbuild-gerrit Jenkins Pipeline
 *
 * This job creates test IBS packages corresponding to supplied Gerrit patches.
 */
pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label "openstack-trackupstream"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        cleanWs()
        script {
          if (gerrit_change_ids == '') {
            error("Empty 'gerrit_change_ids' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
          env.test_repository_url = sh (
            returnStdout: true,
            script: '''
              echo http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${gerrit_change_ids//,/-}/standard/${homeproject}:ardana-ci-${gerrit_change_ids//,/-}.repo
            '''
          ).trim()
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
        }
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
