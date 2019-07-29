/**
 * The openstack-cloud-heat Jenkins Pipeline
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
          if (cloud_env == '') {
            error("Empty 'cloud_env' parameter value.")
          }
          if (heat_action == '') {
            error("Empty 'heat_action' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${heat_action} ${cloud_env}"
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')
          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_os_params_from_resource(cloud_env)
          cloud_lib.load_extra_params_as_vars(extra_params)
          cloud_lib.ansible_playbook('load-job-params',
                                      "-e jjb_type=job-template -e jjb_file=$WORKSPACE/automation-git/jenkins/ci.suse.de/templates/cloud-heat-template.yaml"
                                      )
        }
      }
    }
    stage('Delete heat stack') {
      steps {
        script {
          // Run the monitoring bits outside of the OpenStack API lock, and lock the
          // OpenStack API only while actually deleting the stack
          cloud_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
          lock(resource: "$os_cloud-API") {
            // Use an activity timeout that is higher than the configured OpenStack heat API create/delete timeout
            timeout(time: heat_stack_timeout.toInteger()+60, unit: 'SECONDS', activity: true) {
              cloud_lib.ansible_playbook('heat-stack', "-e heat_action=delete -e monitor_stack_after_delete=False")
            }
          }
          cloud_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
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

          lock(resource: "$os_cloud-API") {
            // Use an activity timeout that is higher than the configured OpenStack heat API create/delete timeout
            timeout(time: heat_stack_timeout.toInteger()+60, unit: 'SECONDS', activity: true) {
              cloud_lib.ansible_playbook('heat-stack', "-e heat_template_file=$WORKSPACE/heat_template.yml")
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
