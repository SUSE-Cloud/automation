/**
 * The openstack-ardana Jenkins Pipeline
 */

def ardana_lib = null

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
          // Parameters of the type 'extended-choice' are set to null when the job
          // is automatically triggered and its value is set to ''. So, we need to set
          // it to '' to be able to pass it as a parameter to downstream jobs.
          if (env.tempest_filter_list == null) {
            env.tempest_filter_list = ''
          }
          if (env.qa_test_list == null) {
            env.qa_test_list = ''
          }
          // Use a shared workspace folder for all jobs running on the same
          // target 'ardana_env' cloud environment
          env.SHARED_WORKSPACE = sh (
            returnStdout: true,
            script: 'echo "$(dirname $WORKSPACE)/shared/${ardana_env}"'
          ).trim()
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
          ardana_lib = load "$SHARED_WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
        }
      }
    }

    stage('Prepare input model') {
      steps {
        script {
          if (scenario_name != '') {
            ardana_lib.ansible_playbook('generate-input-model')
          } else {
            ardana_lib.ansible_playbook('clone-input-model')
          }
        }
      }
    }

    stage('Generate heat template') {
      when {
        expression { cloud_type == 'virtual' }
      }
      steps {
        script {
          ardana_lib.ansible_playbook('generate-heat-template')
        }
      }
    }

    stage('Prepare infra and build package(s)') {
      // abort all stages if one of them fails
      failFast true
      parallel {

        stage('Start bare-metal deployer VM') {
          when {
            expression { cloud_type == 'physical' }
          }
          steps {
            script {
              ardana_lib.ansible_playbook('start-deployer-vm')
            }
          }
        }

        stage('Create heat stack') {
          when {
            expression { cloud_type == 'virtual' }
          }
          steps {
            script {
              ardana_lib.trigger_build('openstack-ardana-heat', [
                string(name: 'ardana_env', value: "$ardana_env"),
                string(name: 'heat_action', value: "create"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                string(name: 'reuse_node', value: "${NODE_NAME}"),
                string(name: 'os_cloud', value: "$os_cloud")
              ], false)
            }
          }
        }

        stage('Build test packages') {
          when {
            expression { gerrit_change_ids != '' }
          }
          steps {
            script {
              def slaveJob = ardana_lib.trigger_build('openstack-ardana-testbuild-gerrit', [
                string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch")
              ], false)
              env.test_repository_url = "http://download.suse.de/ibs/Devel:/Cloud:/Testbuild:/ardana-ci-${slaveJob.getNumber()}/standard/Devel:Cloud:Testbuild:ardana-ci-${slaveJob.getNumber()}.repo"
              if (extra_repos == '') {
                env.extra_repos = test_repository_url
              } else {
                env.extra_repos = "${test_repository_url},${extra_repos}"
              }
            }
          }
        }

      } // parallel
    } // stage('Prepare infra and build package(s)')

    stage('Setup SSH access') {
      steps {
        script {
          ardana_lib.ansible_playbook('setup-ssh-access')
          ardana_lib.get_deployer_ip()
        }
      }
    }

    stage('Bootstrap CLM') {
      steps {
        script {
          ardana_lib.ansible_playbook('bootstrap-clm', "-e extra_repos='$extra_repos'")
        }
      }
    }

    stage('Bootstrap nodes') {
      steps{
        script {
          if (cloud_type == 'virtual') {
            ardana_lib.ansible_playbook('bootstrap-vcloud-nodes')
          } else {
            ardana_lib.ansible_playbook('bootstrap-pcloud-nodes')
          }
        }
      }
    }

    stage('Deploy cloud') {
      steps {
        script {
          ardana_lib.ansible_playbook('deploy-cloud')
        }
      }
    }

    stage('Update cloud') {
      when {
        expression { update_after_deploy == 'true' }
      }
      steps {
        script {
          ardana_lib.ansible_playbook('ardana-update', "-e cloudsource=$update_to_cloudsource")
        }
      }
    }

    stage ('Prepare tests') {
      when {
        expression { tempest_filter_list != '' || qa_test_list != '' || want_caasp == 'true' }
      }
      steps {
        script {
          // Generate stages for Tempest tests
          ardana_lib.generate_tempest_stages(env.tempest_filter_list)
          // Generate stages for QA tests
          ardana_lib.generate_qa_tests_stages(env.qa_test_list)
          // Generate stage for CaaSP deployment
          if (want_caasp == 'true') {
            stage('Deploy CaaSP') {
              ardana_lib.ansible_playbook('deploy-caasp')
            }
          }
        }
      }
    }

  }

  post {
    always {
      script{
        sh('''
          automation-git/scripts/jenkins/jenkins-job-pipeline-report.py \
            -j $JOB_NAME -b $BUILD_NUMBER --recursive \
            --filter 'Declarative: Post Actions' \
            --filter 'Setup workspace' \
            .artifacts/pipeline-report.txt || :
        ''')
        archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
        if ( env.tempest_filter_list != null && tempest_filter_list != '' ) {
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
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                string(name: 'os_cloud', value: "$os_cloud")
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
