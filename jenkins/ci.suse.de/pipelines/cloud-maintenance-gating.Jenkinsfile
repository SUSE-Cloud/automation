/**
 * The openstack-maintenance-gating Jenkins Pipeline
 */

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

          def muBuildUrlList = []
          cloudversion = []
          for (project in maint_updates.split(',')) {
              muBuildUrlList = muBuildUrlList + "<a href='https://build.suse.de/project/show/SUSE:Maintenance:${project}'>${project}</a>"
              cloudversions = cloud_lib.maintenance_status("-a get-versions -p ${project}")
              cloudversion.addAll(cloudversions.split(':')[1].split(','))
          }
          cloudversion.unique()

          currentBuild.description = "Maintenance Updates: " + muBuildUrlList.join(", ") + "<br>Products: " + cloudversion.join(", ")

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
          parallel cloud_lib.generate_parallel_stages(
            cloudversion,
            job_filter.tokenize(','),
            "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/cloud-maintenance-gating-config.yml") {
            job_title, job_def ->

            // reserve a resource here for the integration job, to avoid
            // keeping a cloud-ci worker busy while waiting for a
            // resource to become available.
            cloud_lib.run_with_reserved_env(reserve_env.toBoolean(), cloud_env, "${cloud_env}-${job_title}") {
              reserved_env ->
              def job_params = [
                cloud_env            : reserved_env,
                reserve_env          : false,
                maint_updates        : maint_updates,
                rc_notify            : false,
                cleanup              : "never",
                git_automation_repo  : git_automation_repo,
                git_automation_branch: git_automation_branch,
                extra_params         : extra_params
              ]
              // override default parameters with those loaded from config file
              job_params.putAll(job_def.job_params)
              cloud_lib.trigger_build(job_def.job_name, cloud_lib.convert_to_build_params(job_params))
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
