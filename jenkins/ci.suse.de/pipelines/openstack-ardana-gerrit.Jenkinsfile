/**
 * The openstack-ardana-gerrit Jenkins Pipeline
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label 'cloud-pipeline'
    }
  }

  stages {

    stage('validate commit message') {
      steps {
        script {
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
        }
        cleanWs()
        sh '''
          git clone $git_automation_repo --branch $git_automation_branch automation-git
          export LC_ALL=C.UTF-8
          export LANG=C.UTF-8

          source /opt/gitlint/bin/activate

          echo $GERRIT_CHANGE_COMMIT_MESSAGE | base64 --decode | gitlint -C automation-git/scripts/jenkins/gitlint.ini
        '''
      }
    }

    stage('integration test') {
      when {
        expression { cloudsource == 'stagingcloud9' }
      }
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'reserve_env', value: "$reserve_env"),
            string(name: 'cleanup', value: "on success"),
            string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
            string(name: 'git_automation_repo', value: "$git_automation_repo"),
            string(name: 'git_automation_branch', value: "$git_automation_branch"),
            string(name: 'git_input_model_branch', value: "$GERRIT_BRANCH"),
            string(name: 'model', value: "$model"),
            string(name: 'cloudsource', value: "$cloudsource"),
            string(name: 'tempest_run_filter', value: "$tempest_run_filter"),
            string(name: 'develproject', value: "$develproject"),
            string(name: 'repository', value: "$repository")
          ], propagate: true, wait: true
        }
      }
    }
  }
}
