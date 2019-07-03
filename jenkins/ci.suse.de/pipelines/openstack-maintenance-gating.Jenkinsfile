/**
 * The openstack-maintenance-gating Jenkins Pipeline
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
      label 'cloud-ci-trigger'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          if (cloud_env == '') {
            error("Empty 'cloud_env' parameter value.")
          }
          if (maint_updates == '') {
            error("Empty 'maint_updates' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER}: ${maint_updates}"

          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')

          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          for (project in maint_updates.split(',')) {
              cloud_lib.maintenance_status("-a set-status -p ${project} -s running -m ${BUILD_URL}display/redirect")
          }
          cloud_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('Trigger jobs') {
      // Do not abort all stages if one of them fails
      failFast false
      steps {
        script {
          parallel cloud_lib.generate_mu_stages(cloudversion.split(','), deploy.toBoolean(), deploy_and_update.toBoolean()) {
            cv, update_after_deploy ->
            // reserve a resource here for the integration job, to avoid
            // keeping a cloud-ci worker busy while waiting for a
            // resource to become available.
            def suffix = (update_after_deploy) ? "update" : "deploy"
            cloud_lib.run_with_reserved_env(reserve_env.toBoolean(), cloud_env, "${cloud_env}-${cv}-${suffix}") {
              reserved_env ->
              def slaveJob = cloud_lib.trigger_build(cloud_lib.get_mu_job_name(cv), [
                string(name: 'cloud_env', value: reserved_env),
                string(name: 'reserve_env', value: "false"),
                string(name: 'cloudsource', value: "GM${cv[-1]}+up"),
                string(name: 'maint_updates', value: "$maint_updates"),
                string(name: 'update_after_deploy', value: "${update_after_deploy}"),
                string(name: 'rc_notify', value: "true"),
                string(name: 'cleanup', value: "on success"),
                string(name: 'git_automation_repo', value: "$git_automation_repo"),
                string(name: 'git_automation_branch', value: "$git_automation_branch"),
                text(name: 'extra_params', value: extra_params)
              ], false)
            }
          }
        }
      }
    }
  }
  post{
    success {
      script {
        for (project in maint_updates.split(',')) {
            cloud_lib.maintenance_status("-a set-status -p ${project} -s success -m ${BUILD_URL}display/redirect")
        }
      }
    }
    failure {
      script {
        for (project in maint_updates.split(',')) {
            cloud_lib.maintenance_status("-a set-status -p ${project} -s failure -m ${BUILD_URL}display/redirect")
        }
      }
    }
    cleanup {
      cleanWs()
    }
  }
}
