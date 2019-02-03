/**
 * The openstack-ardana-heat Jenkins Pipeline
 *
 * This job automates creating/deleting heat stacks.
 */

def ardana_lib = null

pipeline {

  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label "cloud-ardana-ci"
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          if (heat_action == '') {
            error("Empty 'heat_action' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${heat_action} ${ardana_env}"
          // The ardana_lib.ansible_playbook scripts still rely on this variable
          env.SHARED_WORKSPACE = "$WORKSPACE"
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
            source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
            ansible_playbook load-job-params.yml
          ''')
          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
        }
      }
    }
    stage('Delete heat stack') {
      steps {
        script {
          retry(1) {
            // Run the monitoring bits outside of the ECP-API lock, and lock the
            // ECP API only while actually deleting the stack
            ardana_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
            lock(resource: 'cloud-ECP-API') {
              timeout(time: 5, unit: 'MINUTES') {
                ardana_lib.ansible_playbook('heat-stack', "-e heat_action=delete -e monitor_stack_after_delete=False")
              }
            }
            ardana_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
          }
        }
      }
    }
    stage('Create heat stack') {
      when {
        expression { heat_action == 'create' }
      }
      steps {
        script {
          // Dump the heat_template multi-string parameter value into a file
          writeFile file: "$WORKSPACE/heat_template.yml", text: params.heat_template

          retry(1) {
            lock(resource: 'cloud-ECP-API') {
              timeout(time: 10, unit: 'MINUTES') {
                ardana_lib.ansible_playbook('heat-stack', "-e heat_template_file=$WORKSPACE/heat_template.yml")
              }
            }
          }
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
