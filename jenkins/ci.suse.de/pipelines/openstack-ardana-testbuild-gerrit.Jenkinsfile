/**
 * The openstack-ardana-testbuild-gerrit Jenkins Pipeline
 *
 * This job creates test IBS packages corresponding to supplied Gerrit patches.
 */

def ardana_lib = null

pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
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
          if (gerrit_change_ids == '') {
            error("Empty 'gerrit_change_ids' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('build test packages') {
      steps {
        sh('echo "IBS project for test packages: https://build.suse.de/project/show/${homeproject}:ardana-ci-${BUILD_NUMBER}"')
        sh('echo "zypper repository for test packages: http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${BUILD_NUMBER}/standard/${homeproject}:ardana-ci-${BUILD_NUMBER}.repo"')
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
            cd automation-git/scripts/jenkins/cloud/gerrit
            set -eux
            run_python_script -u build_test_package.py --homeproject ${homeproject} --buildnumber ${BUILD_NUMBER} -c ${gerrit_change_ids//,/ -c }
          ''')
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
