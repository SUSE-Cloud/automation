/**
 * The cloud-gating Jenkins Pipeline
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
          env.staging_url = "http://provo-clouddata.cloud.suse.de/repos/x86_64/SUSE-OpenStack-Cloud-${version}-devel-staging/media.1/build"
          env.staging_build = sh (
            returnStdout: true,
            script: "wget -q -O - $staging_url | grep -oP 'Build[0-9]+'"
          ).trim()
          currentBuild.displayName = "#${BUILD_NUMBER}: ${staging_build}"

          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')

          env.starttime = sh (
            returnStdout: true,
            script: '''
              rfcdate="$( curl -sI $staging_url | grep 'Last-Modified: ' | head -n1 | cut -d' ' -f2- )"
              epoch=$(date +%s -d "$rfcdate")
              if test "$epoch" -lt "1400000000"; then
                echo "Last-Modified epoch is too low to be valid."
                exit 1
              fi
              echo $epoch
            '''
          ).trim()

          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('Trigger jobs') {
      // Do not abort all stages if one of them fails
      failFast false
      steps {
        script {
          def parallelJobMap = cloud_lib.generate_parallel_stages(
            ["SOC" + version, "SOCC" + version],
            [],
            "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/cloud-gating-config.yml") {
            job_title, job_def ->

            // reserve a resource here for the integration job, to avoid
            // keeping a cloud-ci worker busy while waiting for a
            // resource to become available.
            cloud_lib.run_with_reserved_env(true, cloud_env, null) {
              reserved_env ->
              def job_params = [
                cloud_env            : reserved_env,
                reserve_env          : false,
                rc_notify            : false,
                cleanup              : "on success",
                git_automation_repo  : git_automation_repo,
                git_automation_branch: git_automation_branch
              ]
              // override default parameters with those loaded from config file
              job_params.putAll(job_def.job_params)
              // combine together extra_params from this job with those loaded from config file
              combined_extra_params = [extra_params, job_def.job_params.extra_params?: ""].join('\n').trim()
              if (!combined_extra_params.isEmpty()) {
                 job_params.extra_params = combined_extra_params
              }
              cloud_lib.trigger_build(job_def.job_name, cloud_lib.convert_to_build_params(job_params))
            }
          }

          if (parallelJobMap.isEmpty()) {
            def errorMsg = "ERROR: No jobs found that matched the SOC${version} and SOCC${version} cloud versions."
            echo errorMsg
            error(errorMsg)
          }

          parallel parallelJobMap

        }
      }
    }

    stage('Submit project') {
      when {
        expression { skip_submit_project == 'false' }
      }
      steps {
        script{
          cloud_lib.trigger_build("openstack-submit-project", [
            string(name: 'project', value: "Devel:Cloud:${version}"),
            string(name: 'starttime', value: "${starttime}"),
            string(name: 'subproject', value: "Staging"),
            // for unified gated we want everything white listed
            // and nothing black listed.
            string(name: 'package_whitelist', value: ""),
            string(name: 'package_blacklist', value: "")
          ])
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
