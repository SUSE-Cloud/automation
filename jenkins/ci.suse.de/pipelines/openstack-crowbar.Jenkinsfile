/**
 * The openstack-crowbar Jenkins Pipeline
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
          if ( ardana_env.startsWith("qe") || ardana_env.startsWith("pcloud") ) {
              env.cloud_type = "physical"
          }
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
            cd automation-git

            if [ -n "$github_pr" ] ; then
              scripts/jenkins/ardana/pr-update.sh
            fi

            source scripts/jenkins/ardana/jenkins-helper.sh
            ansible_playbook load-job-params.yml \
              -e jjb_file=$WORKSPACE/automation-git/jenkins/ci.suse.de/templates/cloud-crowbar-pipeline-template.yaml \
              -e jjb_type=job-template
            ansible_playbook notify-rc-pcloud.yml -e @input.yml
          ''')
          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
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

    stage('Create heat stack') {
      when {
        expression { cloud_type == 'virtual' }
      }
      steps {
        script {

          // Needed to pass the generated heat template file contents as a text parameter value
          def heat_template = sh (
            returnStdout: true,
            script: 'cat "$WORKSPACE/heat-stack-${scenario_name}${model}.yml"'
          )

          ardana_lib.trigger_build('openstack-ardana-heat', [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "create"),
            text(name: 'heat_template', value: heat_template),
            string(name: 'git_automation_repo', value: "$git_automation_repo"),
            string(name: 'git_automation_branch', value: "$git_automation_branch"),
            string(name: 'os_cloud', value: "$os_cloud")
          ], false)
        }
      }
    }

    stage('Setup SSH access') {
      steps {
        script {
          ardana_lib.ansible_playbook('setup-ssh-access')
          ardana_lib.get_deployer_ip()
        }
      }
    }

    stage('Bootstrap admin node') {
      steps {
        script {
          sh('''
             # This step does the following on the admin node:
             #  - waits for it to complete boot
             #  - resizes the root partition
             #  - sets up Crowbar network/DNS and repos
             #  - installs crowbar packages
             #
             # qa_crowbarsetup.sh onadmin_runlist prepareinstallcrowbar
          ''')
        }
      }
    }

    stage('Bootstrap nodes') {
      steps {
        script {
          sh('''
             # This step does the following on the non-admin nodes:
             #  - waits for them to complete boot
             #  - resizes the root partition
             #  - sets up accounts, passwordless SSH and sudo
          ''')
        }
      }
    }

    stage('Install crowbar') {
      when {
        expression { deploy_cloud == 'true' }
      }
      steps {
        script {
          sh('''
             # This step does the following on the admin node:
             #  - installs crowbar
             #
             # qa_crowbarsetup.sh onadmin_runlist bootstrapcrowbar installcrowbar
          ''')
        }
      }
    }

    stage('Register nodes') {
      when {
        expression { deploy_cloud == 'true' }
      }
      steps {
        script {
          sh('''
             # This step does the following
             #  - registers the Crowbar cloud nodes
          ''')
        }
      }
    }

    stage('Deploy cloud') {
      when {
        expression { deploy_cloud == 'true' }
      }
      steps {
        script {
          sh('''
             # This step does the following:
             #  - deploys the crowbar proposal
          ''')
        }
      }
    }

    stage('Test') {
      when {
        expression { deploy_cloud == 'true' }
      }
      steps {
        script {
          sh('''
             # This step does the following:
             #  - runs tests on the deployed cloud
             #
             # qa_crowbarsetup.sh onadmin_runlist onadmin_testsetup
          ''')
        }
      }
    }

  }

  post {
    always {
      script{
        sh('''
          automation-git/scripts/jenkins/jenkins-job-pipeline-report.py \
            --recursive \
            --filter 'Declarative: Post Actions' \
            --filter 'Setup workspace' > .artifacts/pipeline-report.txt || :
        ''')
        archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
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
** The admin node for the '${ardana_env}' virtual environment is reachable at:
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
** The admin node for the '${ardana_env}' virtual environment is reachable at:
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
** The admin node for the '${ardana_env}' physical environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
            """
          }
        }
      }
    }
    cleanup {
      cleanWs()
    }
  }
}
