/**
 * The openstack-ardana Jenkins Pipeline
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label 'cloud-ardana-ci'
      customWorkspace ardana_env ? "${JOB_NAME}-${ardana_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        cleanWs()
        script {
          env.cloud_type = "virtual"
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          if ( ardana_env.startsWith("qe") || ardana_env.startsWith("qa") ) {
              env.cloud_type = "physical"
          }
        }
        sh('git clone $git_automation_repo --branch $git_automation_branch automation-git')
        sh('''
          if [ -n "$github_pr" ] ; then
            cd automation-git
            exec scripts/jenkins/ardana/pr-update.sh
          fi
        ''')
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook load-job-params.yml
        ''')
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook notify-rc-pcloud.yml -e @input.yml
        ''')
      }
    }

    stage('Prepare infra and build package(s)') {
      // abort all stages if one of them fails
      failFast true
      parallel {
        stage('Prepare BM cloud') {
          when {
            expression { cloud_type == 'physical' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-pcloud', parameters: [
                string(name: 'ardana_env', value: "$ardana_env"),
                string(name: 'scenario_name', value: "$scenario_name"),
                string(name: 'clm_model', value: "$clm_model"),
                string(name: 'controllers', value: "$controllers"),
                string(name: 'sles_computes', value: "$sles_computes"),
                string(name: 'rhel_computes', value: "$rhel_computes"),
                string(name: 'rc_notify', value: "$rc_notify"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'reuse_workspace', value: "${WORKSPACE}")
              ], propagate: true, wait: true
            }
          }
        }

        stage('Prepare virtual cloud') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-vcloud', parameters: [
                string(name: 'ardana_env', value: "$ardana_env"),
                string(name: 'git_input_model_branch', value: "$git_input_model_branch"),
                string(name: 'git_input_model_path', value: "$git_input_model_path"),
                string(name: 'model', value: "$model"),
                string(name: 'scenario_name', value: "$scenario_name"),
                string(name: 'clm_model', value: "$clm_model"),
                string(name: 'controllers', value: "$controllers"),
                string(name: 'sles_computes', value: "$sles_computes"),
                string(name: 'rhel_computes', value: "$rhel_computes"),
                string(name: 'rc_notify', value: "$rc_notify"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'reuse_workspace', value: "${WORKSPACE}")
              ], propagate: true, wait: true
            }
          }
        }

        stage('Build test packages') {
          when {
            expression { gerrit_change_ids != '' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-testbuild-gerrit', parameters: [
                string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
                string(name: 'develproject', value: "$develproject"),
                string(name: 'homeproject', value: "$homeproject"),
                string(name: 'repository', value: "$repository"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch")
              ], propagate: true, wait: true

              // Load the environment variables set by the downstream job
              env.test_repository_url = slaveJob.buildVariables.test_repository_url
            }
          }
        }
      } // parallel
    } // stage('parallel stage')

    stage('Bootstrap CLM') {
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-bootstrap-clm', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'cloudsource', value: "$cloudsource"),
            string(name: 'cloud_maint_updates', value: "$cloud_maint_updates"),
            string(name: 'sles_maint_updates', value: "$sles_maint_updates"),
            string(name: 'extra_repos', value: "${env.test_repository_url ?: extra_repos}"),
            string(name: 'rc_notify', value: "$rc_notify"),
            string(name: 'git_automation_repo', value: "$git_automation_repo"),
            string(name: 'git_automation_branch', value: "$git_automation_branch"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: true, wait: true
        }
      }
    }

    stage('Bootstrap nodes') {
      failFast true
      parallel {
        stage('Bootstrap BM nodes') {
          when {
            expression { cloud_type == 'physical' }
          }
          steps{
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook bootstrap-pcloud-nodes.yml -e @input.yml
            ''')
          }
        }

        stage('Bootstrap virtual nodes') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps{
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook bootstrap-vcloud-nodes.yml -e @input.yml
            ''')
          }
        }
      }
    }

    stage('Deploy cloud') {
      steps {
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook deploy-cloud.yml -e @input.yml
        ''')
      }
    }

    stage('Run tests') {
      failFast false
      parallel {
        stage ('Tempest') {
          when {
            expression { tempest_run_filter != '' }
          }
          steps {
            script {
              def slaveJob = build job: 'openstack-ardana-tempest', parameters: [
                string(name: 'ardana_env', value: "$ardana_env"),
                string(name: 'tempest_run_filter', value: "$tempest_run_filter"),
                string(name: 'rc_notify', value: "$rc_notify"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'reuse_workspace', value: "${WORKSPACE}")
              ], propagate: true, wait: true
            }
          }
        }
      }
    }

    stage ('Deploy CaaSP') {
      when {
        expression { want_caasp == 'true' }
      }
      steps {
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook deploy-caasp.yml -e @input.yml
        ''')
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '.artifacts/**/*', allowEmptyArchive: true
      script{
        if (cleanup == "always" && cloud_type == "virtual") {
          def slaveJob = build job: 'openstack-ardana-heat', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "delete"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: false, wait: false
        }
      }
    }
    success {
      script {
        if (cleanup == "on success" && cloud_type == "virtual") {
          def slaveJob = build job: 'openstack-ardana-heat', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "delete"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: false, wait: false
        }
      }
      sh '''
        if [ -n "$github_pr" ] ; then
          automation-git/scripts/ardana/pr-success.sh
        fi
      '''
    }
    failure {
      script {
        if (cleanup == "on failure" && cloud_type == "virtual") {
          def slaveJob = build job: 'openstack-ardana-heat', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "delete"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: false, wait: false
        }
      }
      sh '''
        if [ -n "$github_pr" ] ; then
          automation-git/scripts/ardana/pr-failure.sh
        fi
      '''
    }
  }
}
