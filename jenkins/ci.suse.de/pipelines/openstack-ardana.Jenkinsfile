/**
 * The openstack-ardana Jenkins Pipeline
 */

pipeline {
  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
    timestamps()
    // reserve a resource if instructed to do so, otherwise use a dummy resource
    // and a zero quantity to fool Jenkins into thinking it reserved a resource when in fact it didn't
    lock(label: reserve_env == 'true' ? ardana_env:'dummy-resource',
         variable: 'reserved_env',
         quantity: reserve_env == 'true' ? 1:0 )
  }

  agent {
    node {
      label 'cloud-ardana-ci'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          env.cloud_type = "virtual"
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          if (env.reserved_env && reserved_env != null) {
            env.ardana_env = reserved_env
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env}"
          if ( ardana_env.startsWith("qe") || ardana_env.startsWith("qa") ) {
              env.cloud_type = "physical"
          }
          // Use a shared workspace folder for all jobs running on the same
          // target 'ardana_env' cloud environment
          env.SHARED_WORKSPACE = sh (
            returnStdout: true,
            script: 'echo "$(dirname $WORKSPACE)/shared/${ardana_env}"'
          ).trim()
        }
        sh('''
          rm -rf "$SHARED_WORKSPACE"
          mkdir -p "$SHARED_WORKSPACE"

          # archiveArtifacts and junit don't support absolute paths, so we have to to this instead
          ln -s ${SHARED_WORKSPACE}/.artifacts ${WORKSPACE}

          cd $SHARED_WORKSPACE
          git clone $git_automation_repo --branch $git_automation_branch automation-git
          cd automation-git

          if [ -n "$github_pr" ] ; then
            scripts/jenkins/ardana/pr-update.sh
          fi

          source scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook load-job-params.yml \
            -e jjb_file=$SHARED_WORKSPACE/automation-git/jenkins/ci.suse.de/templates/cloud-ardana-pipeline-template.yaml \
            -e jjb_type=job-template
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
                  string(name: 'core_nodes', value: "$core_nodes"),
                  string(name: 'lmm_nodes', value: "$lmm_nodes"),
                  string(name: 'dbmq_nodes', value: "$dbmq_nodes"),
                  string(name: 'neutron_nodes', value: "$neutron_nodes"),
                  string(name: 'swpac_nodes', value: "$swpac_nodes"),
                  string(name: 'swobj_nodes', value: "$swobj_nodes"),
                  string(name: 'sles_computes', value: "$sles_computes"),
                  string(name: 'rhel_computes', value: "$rhel_computes"),
                  string(name: 'disabled_services', value: "$disabled_services"),
                  string(name: 'rc_notify', value: "$rc_notify"),
                  string(name: 'git_automation_repo', value: "$git_automation_repo"),
                  string(name: 'git_automation_branch', value: "$git_automation_branch"),
                  string(name: 'reuse_node', value: "${NODE_NAME}")
              ], propagate: false, wait: true
              def jobResult = slaveJob.getResult()
              def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
              def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
              echo jobMsg
              if (jobResult != 'SUCCESS') {
                 error(jobMsg)
              }

              // Load the environment variables set by the downstream job
              env.DEPLOYER_IP = slaveJob.buildVariables.DEPLOYER_IP
              currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env} (${DEPLOYER_IP})"
              echo """
******************************************************************************
** The deployer for the '${ardana_env}' physical environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
              """
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
                  string(name: 'core_nodes', value: "$core_nodes"),
                  string(name: 'lmm_nodes', value: "$lmm_nodes"),
                  string(name: 'dbmq_nodes', value: "$dbmq_nodes"),
                  string(name: 'neutron_nodes', value: "$neutron_nodes"),
                  string(name: 'swpac_nodes', value: "$swpac_nodes"),
                  string(name: 'swobj_nodes', value: "$swobj_nodes"),
                  string(name: 'sles_computes', value: "$sles_computes"),
                  string(name: 'rhel_computes', value: "$rhel_computes"),
                  string(name: 'disabled_services', value: "$disabled_services"),
                  string(name: 'rc_notify', value: "$rc_notify"),
                  string(name: 'git_automation_repo', value: "$git_automation_repo"),
                  string(name: 'git_automation_branch', value: "$git_automation_branch"),
                  string(name: 'reuse_node', value: "${NODE_NAME}")
              ], propagate: false, wait: true
              def jobResult = slaveJob.getResult()
              def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
              def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
              echo jobMsg
              if (jobResult != 'SUCCESS') {
                 error(jobMsg)
              }

              // Load the environment variables set by the downstream job
              env.DEPLOYER_IP = slaveJob.buildVariables.DEPLOYER_IP
              currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env} (${DEPLOYER_IP})"
              echo """
******************************************************************************
** The deployer for the '${ardana_env}' virtual environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
              """
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
              ], propagate: false, wait: true

              def jobResult = slaveJob.getResult()
              def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
              def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
              echo jobMsg
              if (jobResult != 'SUCCESS') {
                 error(jobMsg)
              }

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
              string(name: 'updates_test_enabled', value: "$updates_test_enabled"),
              string(name: 'cloud_maint_updates', value: "$cloud_maint_updates"),
              string(name: 'sles_maint_updates', value: "$sles_maint_updates"),
              string(name: 'extra_repos', value: "${env.test_repository_url ?: extra_repos}"),
              string(name: 'rc_notify', value: "$rc_notify"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              string(name: 'reuse_node', value: "${NODE_NAME}")
          ], propagate: false, wait: true
          def jobResult = slaveJob.getResult()
          def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
          def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
          echo jobMsg
          if (jobResult != 'SUCCESS') {
             error(jobMsg)
          }
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
              cd $SHARED_WORKSPACE
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
              cd $SHARED_WORKSPACE
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
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook deploy-cloud.yml -e @input.yml
        ''')
      }
    }

    stage('Update cloud') {
      when {
        expression { update_after_deploy == 'true' }
      }
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-update', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'update_to_cloudsource', value: "$update_to_cloudsource"),
            string(name: 'updates_test_enabled', value: "$updates_test_enabled"),
            string(name: 'cloud_maint_updates', value: "$cloud_maint_updates"),
            string(name: 'sles_maint_updates', value: "$sles_maint_updates"),
            string(name: 'rc_notify', value: "$rc_notify"),
            string(name: 'git_automation_repo', value: "$git_automation_repo"),
            string(name: 'git_automation_branch', value: "$git_automation_branch"),
            string(name: 'reuse_node', value: "${NODE_NAME}")
          ], propagate: false, wait: true
          def jobResult = slaveJob.getResult()
          def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
          def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
          echo jobMsg
          if (jobResult != 'SUCCESS') {
             error(jobMsg)
          }
        }
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
                  string(name: 'reuse_node', value: "${NODE_NAME}")
              ], propagate: false, wait: true
              def jobResult = slaveJob.getResult()
              def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
              def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
              echo jobMsg
              if (jobResult != 'SUCCESS') {
                 error(jobMsg)
              }
            }
          }
        }
      }
    }

    stage('Run QA tests') {
      when {
        // For extended-choice parameter we also need to check if the variable
        // is defined
        expression { env.qa_test_list != null && qa_test_list != '' }
      }
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-qa-tests', parameters: [
              string(name: 'ardana_env', value: "$ardana_env"),
              string(name: 'test_list', value: "$qa_test_list"),
              string(name: 'rc_notify', value: "$rc_notify"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              string(name: 'reuse_node', value: "${NODE_NAME}")
          ], propagate: false, wait: true
          def jobResult = slaveJob.getResult()
          def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
          def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
          echo jobMsg
          if (jobResult != 'SUCCESS') {
             error(jobMsg)
          }
        }
      }
    }

    stage('Deploy CaaSP') {
      when {
        expression { want_caasp == 'true' }
      }
      steps {
        sh('''
          cd $SHARED_WORKSPACE
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook deploy-caasp.yml -e @input.yml
        ''')
      }
    }
  }

  post {
    always {
      script{
        archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
        if ( tempest_run_filter != '' ) {
          junit testResults: ".artifacts/*.xml", allowEmptyResults: true
        }
      }
      script{
        if (env.DEPLOYER_IP != null) {
          if (cloud_type == "virtual") {
            if (cleanup == "always" ||
                cleanup == "on success" && currentBuild.currentResult == "SUCCESS" ||
                cleanup == "on failure" && currentBuild.currentResult != "SUCCESS") {

              build job: 'openstack-ardana-heat', parameters: [
                string(name: 'ardana_env', value: "$ardana_env"),
                string(name: 'heat_action', value: "delete"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch")
              ], propagate: false, wait: false
            } else {
              if (reserve_env == 'true') {
                echo """
******************************************************************************
** The deployer for the '${ardana_env}' virtual environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
** IMPORTANT: the '${ardana_env}' virtual environment may be (may have
** already been) deleted by any of the future periodic job runs. To prevent
** that, you should use the Lockable Resource page at
** https://ci.nue.suse.com/lockable-resources and reserve the '${ardana_env}'
** resource.
**
** Please remember to release the '${ardana_env}' Lockable Resource when
** you're done with the environment.
**
** You don't have to manually delete the heat stack if you don't want to.
**
******************************************************************************
                """
              } else {
                echo """
******************************************************************************
** The deployer for the '${ardana_env}' virtual environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
** Please delete the 'openstack-ardana-${ardana_env}' stack when you're done,
** by using one of the following methods:
**
**  1. log into the ECP at https://engcloud.prv.suse.net/project/stacks/
**  and delete the stack manually, or
**
**  2. (preferred) trigger a manual build for the openstack-ardana-heat job at
**  https://ci.nue.suse.com/job/openstack-ardana-heat/build and use the
**  same '${ardana_env}' ardana_env value and the 'delete' action for the
**  parameters
**
******************************************************************************
                """
              }
            }
          } else {
            echo """
******************************************************************************
** The deployer for the '${ardana_env}' physical environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
            """
          }
        }
      }
    }
    success {
      sh '''
        cd $SHARED_WORKSPACE
        if [ -n "$github_pr" ] ; then
          automation-git/scripts/ardana/pr-success.sh
        else
          automation-git/scripts/jtsync/jtsync.rb --ci suse --job $JOB_NAME 0
        fi
      '''
    }
    failure {
      sh '''
        cd $SHARED_WORKSPACE
        if [ -n "$github_pr" ] ; then
          automation-git/scripts/ardana/pr-failure.sh
        else
          automation-git/scripts/jtsync/jtsync.rb --ci suse --job $JOB_NAME 1
        fi
      '''
    }
    cleanup {
      cleanWs()
    }
  }
}
