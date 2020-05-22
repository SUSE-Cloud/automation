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
          if ((gerrit_change_ids == '') && (update_gerrit_change_ids == '') && (upgrade_gerrit_change_ids == '')) {
            error("No Gerrit Change-Ids' specified in 'gerrit_change_ids', 'update_gerrit_change_ids' or 'upgrade_gerrit_change_ids' parameter values.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: deploy=${gerrit_change_ids} update=${update_gerrit_change_ids} upgrade=${upgrade_gerrit_change_ids}"
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('build test packages for deploy') {
      when {
        expression { gerrit_change_ids != '' }
      }
      steps {
        sh('echo "IBS project for test packages: https://build.suse.de/project/show/${homeproject}:ardana-ci-${BUILD_NUMBER}-deploy"')
        sh('echo "zypper repository for test packages: http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${BUILD_NUMBER}-deploy/standard/${homeproject}:ardana-ci-${BUILD_NUMBER}-deploy.repo"')
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
            cd automation-git/scripts/jenkins/cloud/gerrit
            set -eux
            run_python_script -u build_test_package.py --homeproject ${homeproject} --buildnumber ${BUILD_NUMBER}-deploy -c ${gerrit_change_ids//,/ -c }
          ''')
        }
      }
    }

    stage('build test packages for update') {
      when {
        expression { update_gerrit_change_ids != '' }
      }
      steps {
        sh('echo "IBS project for test packages: https://build.suse.de/project/show/${homeproject}:ardana-ci-${BUILD_NUMBER}-update"')
        sh('echo "zypper repository for test packages: http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${BUILD_NUMBER}-update/standard/${homeproject}:ardana-ci-${BUILD_NUMBER}-update.repo"')
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
            cd automation-git/scripts/jenkins/cloud/gerrit
            set -eux
            run_python_script -u build_test_package.py --homeproject ${homeproject} --buildnumber ${BUILD_NUMBER}-update -c ${update_gerrit_change_ids//,/ -c }
          ''')
        }
      }
    }

    stage('build test packages for upgrade') {
      when {
        expression { upgrade_gerrit_change_ids != '' }
      }
      steps {
        sh('echo "IBS project for test packages: https://build.suse.de/project/show/${homeproject}:ardana-ci-${BUILD_NUMBER}-upgrade"')
        sh('echo "zypper repository for test packages: http://download.suse.de/ibs/${homeproject//:/:\\/}:/ardana-ci-${BUILD_NUMBER}-upgrade/standard/${homeproject}:ardana-ci-${BUILD_NUMBER}-upgrade.repo"')
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
            cd automation-git/scripts/jenkins/cloud/gerrit
            set -eux
            run_python_script -u build_test_package.py --homeproject ${homeproject} --buildnumber ${BUILD_NUMBER}-upgrade -c ${upgrade_gerrit_change_ids//,/ -c }
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
