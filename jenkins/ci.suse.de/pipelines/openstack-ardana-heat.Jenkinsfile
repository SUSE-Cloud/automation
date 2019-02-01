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
          sh('''
            IFS='/' read -r -a repo_arr <<< "$git_automation_repo"
            export git_automation_repo="${repo_arr[3]}"
            # Need a local git clone copy to run from
            export use_global_clone=false
            curl https://raw.githubusercontent.com/$git_automation_repo/automation/$git_automation_branch/scripts/jenkins/ardana/openstack-ardana.prep.sh | bash
          ''')
          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
          ardana_lib.load_extra_params_as_vars(extra_params)
          ardana_lib.ansible_playbook('load-job-params')
        }
      }
    }
    stage('Delete heat stack') {
      steps {
        script {
          // Run the monitoring bits outside of the ECP-API lock, and lock the
          // ECP API only while actually deleting the stack
          ardana_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
          lock(resource: 'cloud-ECP-API') {
            timeout(time: 10, unit: 'MINUTES', activity: true) {
              ardana_lib.ansible_playbook('heat-stack', "-e heat_action=delete -e monitor_stack_after_delete=False")
            }
          }
          ardana_lib.ansible_playbook('heat-stack', "-e heat_action=monitor")
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

          lock(resource: 'cloud-ECP-API') {
            timeout(time: 10, unit: 'MINUTES', activity: true) {
              ardana_lib.ansible_playbook('heat-stack', "-e heat_template_file=$WORKSPACE/heat_template.yml")
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
