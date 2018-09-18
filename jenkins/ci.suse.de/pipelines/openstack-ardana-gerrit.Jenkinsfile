/**
 * The openstack-ardana-gerrit Jenkins Pipeline
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label 'cloud-trigger'
    }
  }

  stages {

    stage('validate commit message') {
      steps {
        script {
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
        }
        echo 'TBD: trigger commit message validator job...'
      }
    }

    stage('integration test') {
      steps {
        lock(resource: null, label: "$build_pool", variable: 'ardana_env', quantity: 1) {
          script {
            def slaveJob = build job: 'openstack-ardana', parameters: [
              string(name: 'ardana_env', value: "$ardana_env"),
              string(name: 'cleanup', value: "on success"),
              string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
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
}
