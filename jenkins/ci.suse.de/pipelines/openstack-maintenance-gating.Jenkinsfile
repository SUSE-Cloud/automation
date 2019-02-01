/**
 * The openstack-ardana-maintenance-gating Jenkins Pipeline
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
      label 'cloud-trigger'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          if (maint_updates == '') {
            error("Empty 'maint_updates' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${maint_updates}"

          sh('''
            IFS='/' read -r -a repo_arr <<< "$git_automation_repo"
            export git_automation_repo="${repo_arr[3]}"
            curl https://raw.githubusercontent.com/$git_automation_repo/automation/$git_automation_branch/scripts/jenkins/ardana/openstack-ardana.prep.sh | bash
          ''')

          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
          ardana_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('Trigger jobs') {
      // Do not abort all stages if one of them fails
      failFast false
      parallel {
        stage('Run cloud deploy job') {
          when {
            expression { deploy == 'true' }
          }
          steps {
            script {
              // reserve a resource here for the openstack-ardana job, to avoid
              // keeping a cloud-ardana-ci worker busy while waiting for a
              // resource to become available.
              ardana_lib.run_with_reserved_env(reserve_env.toBoolean(), ardana_env, "${ardana_env}-deploy") {
                reserved_env ->
                def slaveJob = ardana_lib.trigger_build("cloud-ardana8-job-entry-scale-kvm-maintenance-update-x86_64", [
                  string(name: 'ardana_env', value: reserved_env),
                  string(name: 'reserve_env', value: "false"),
                  string(name: 'cloudsource', value: "$cloudsource"),
                  string(name: 'maint_updates', value: "$maint_updates"),
                  string(name: 'update_after_deploy', value: "false"),
                  string(name: 'rc_notify', value: "true"),
                  string(name: 'cleanup', value: "on success"),
                  string(name: 'git_automation_repo', value: "$git_automation_repo"),
                  string(name: 'git_automation_branch', value: "$git_automation_branch"),
                  string(name: 'os_cloud', value: "engcloud-cloud-ci-private"),
                  text(name: 'extra_params', value: extra_params)
                ], false)
              }
            }
          }
        }

        stage('Run cloud update job') {
          when {
            expression { deploy_and_update == 'true' }
          }
          steps {
            script {
              // reserve a resource here for the openstack-ardana job, to avoid
              // keeping a cloud-ardana-ci worker busy while waiting for a
              // resource to become available.
              ardana_lib.run_with_reserved_env(reserve_env.toBoolean(), ardana_env, "${ardana_env}-update") {
                reserved_env ->
                def slaveJob = ardana_lib.trigger_build("cloud-ardana8-job-entry-scale-kvm-maintenance-update-x86_64", [
                  string(name: 'ardana_env', value: reserved_env),
                  string(name: 'reserve_env', value: "false"),
                  string(name: 'cloudsource', value: "$cloudsource"),
                  string(name: 'maint_updates', value: "$maint_updates"),
                  string(name: 'update_after_deploy', value: "true"),
                  string(name: 'rc_notify', value: "true"),
                  string(name: 'cleanup', value: "on success"),
                  string(name: 'git_automation_repo', value: "$git_automation_repo"),
                  string(name: 'git_automation_branch', value: "$git_automation_branch"),
                  string(name: 'os_cloud', value: "engcloud-cloud-ci-private"),
                  text(name: 'extra_params', value: extra_params)
                ], false)
              }
            }
          }
        }
      }
    }
  }
  post{
    cleanup {
      cleanWs()
    }
  }
}
