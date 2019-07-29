/**
 * The openstack-ardana-gerrit Jenkins Pipeline
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
          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git
          ''')

          cloud_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-cloud.groovy"
          cloud_lib.load_extra_params_as_vars(extra_params)

          if (GERRIT_CHANGE_NUMBER == '') {
            error("Empty 'GERRIT_CHANGE_NUMBER' parameter value.")
          }

          if (env.GERRIT_PATCHSET_NUMBER == null) {
            // Extract the current patchset number from the Gerrit change, if missing
            env.GERRIT_PATCHSET_NUMBER = sh (
              returnStdout: true,
              script: '''
                source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
                run_python_script automation-git/scripts/jenkins/cloud/gerrit/gerrit_get.py \
                  --attr patchset \
                  ${GERRIT_CHANGE_NUMBER}
              '''
            ).trim()
          }

          currentBuild.displayName = "#${BUILD_NUMBER}: $GERRIT_CHANGE_NUMBER/$GERRIT_PATCHSET_NUMBER ($gerrit_context)"
        }
      }
    }

    stage('supersede running jobs') {
      steps {
        script {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh

            # If this is a job triggered by Gerrit because a new patchset has
            # been published, abort all other older running builds that
            # target the same change number
            if [[ $GERRIT_EVENT_TYPE == 'patchset-created' ]]; then
              run_python_script -u automation-git/scripts/jenkins/jenkins-job-cancel \
                --older-than ${BUILD_NUMBER} \
                --with-param GERRIT_CHANGE_NUMBER=${GERRIT_CHANGE_NUMBER} \
                --wait 600 \
                ${JOB_NAME} || :
            else
              if $voting; then
                # If this is a voting job, abort other older running builds that
                # target the same change number and are also voting.
                run_python_script -u automation-git/scripts/jenkins/jenkins-job-cancel \
                  --older-than ${BUILD_NUMBER} \
                  --with-param GERRIT_CHANGE_NUMBER=${GERRIT_CHANGE_NUMBER} \
                  --with-param voting=True \
                  --wait 600 \
                  ${JOB_NAME} || :
              fi

              # Also abort other older running builds that target the same change
              # number and gerrit_context value, voting or otherwise.
              run_python_script -u automation-git/scripts/jenkins/jenkins-job-cancel \
                --older-than ${BUILD_NUMBER} \
                --with-param GERRIT_CHANGE_NUMBER=${GERRIT_CHANGE_NUMBER} \
                --with-param gerrit_context=${gerrit_context} \
                --wait 600 \
                ${JOB_NAME} || :
            fi
            ''')
        }
      }
    }

    stage('notify Gerrit') {
      steps {
        script {
          sh('''
            source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
            build_str="Build"
            $voting || build_str="(Non-voting) build"
            message="
${build_str} started (${gerrit_context}): ${BUILD_URL}
The following links can also be used to track the results:

- live console output: ${BUILD_URL}console
- live pipeline job view: ${RUN_DISPLAY_URL}
"

            $voting && gerrit_voting_params="--vote 0 --label Verified"
            run_python_script automation-git/scripts/jenkins/cloud/gerrit/gerrit_review.py \
              --message "$message" \
              $gerrit_voting_params \
              --patch ${GERRIT_PATCHSET_NUMBER} \
              ${GERRIT_CHANGE_NUMBER}
          ''')
        }
      }
    }

    stage('validate commit message') {
      steps {
        sh '''
          export LC_ALL=C.UTF-8
          export LANG=C.UTF-8
          source automation-git/scripts/jenkins/cloud/jenkins-helper.sh

          if [[ -n $GERRIT_CHANGE_COMMIT_MESSAGE ]]; then
            commit_message=$(echo $GERRIT_CHANGE_COMMIT_MESSAGE | base64 --decode)
          else
            commit_message=$(run_python_script automation-git/scripts/jenkins/cloud/gerrit/gerrit_get.py \
              --attr commit_message \
              ${GERRIT_CHANGE_NUMBER}/${GERRIT_PATCHSET_NUMBER})
          fi

          echo "$commit_message" | gitlint -C automation-git/scripts/jenkins/gitlint.ini
        '''
      }
    }

    stage('integration test') {
      steps {
        script {
          // reserve a resource here for the integration job, to avoid
          // keeping a cloud-ci worker busy while waiting for a
          // resource to become available.
          cloud_lib.run_with_reserved_env(reserve_env.toBoolean(), cloud_env, cloud_env) {
            reserved_env ->
            cloud_lib.trigger_build(integration_test_job, [
              string(name: 'cloud_env', value: reserved_env),
              string(name: 'reserve_env', value: "false"),
              string(name: 'os_cloud', value: os_cloud),
              string(name: 'gerrit_change_ids', value: "$GERRIT_CHANGE_NUMBER/$GERRIT_PATCHSET_NUMBER"),
              string(name: 'cloudsource', value: "develcloud$version"),
              string(name: 'extra_repos', value: "$extra_repos"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              string(name: 'os_project_name', value: "$os_project_name"),
              text(name: 'extra_params', value: extra_params)
            ])
          }
        }
      }
    }
  }
  post {
    always {
      script{
        env.BUILD_RESULT = currentBuild.currentResult
        sh('''
          source automation-git/scripts/jenkins/cloud/jenkins-helper.sh

          run_python_script automation-git/scripts/jenkins/jenkins-job-pipeline-report.py \
            --recursive \
            --filter 'Declarative: Post Actions' \
            --filter 'Setup workspace' \
            --filter 'supersede running jobs' \
            --filter 'notify Gerrit' > pipeline-report.txt || :

          build_str="Build"
          $voting || build_str="(Non-voting) build"

          if [[ $BUILD_RESULT == SUCCESS ]]; then
            vote=+2
            message_result="succeeded"
          elif [[ $BUILD_RESULT == ABORTED ]]; then
            vote=
            message_result="aborted"
          else
            vote=-2
            message_result="failed"
          fi

          message="
${build_str} ${message_result} ($gerrit_context): ${BUILD_URL}

"

          $voting && [[ -n $vote ]] && gerrit_voting_params="--vote $vote --label Verified"

          run_python_script automation-git/scripts/jenkins/cloud/gerrit/gerrit_review.py \
            --message "$message" \
            --message-file pipeline-report.txt \
            $gerrit_voting_params \
            --patch $GERRIT_PATCHSET_NUMBER \
            $GERRIT_CHANGE_NUMBER

          if $voting && [[ $BUILD_RESULT == SUCCESS ]]; then
            run_python_script automation-git/scripts/jenkins/cloud/gerrit/gerrit_merge.py \
              --patch ${GERRIT_PATCHSET_NUMBER} \
              ${GERRIT_CHANGE_NUMBER}
          fi
        ''')
      }
    }
    cleanup {
      cleanWs()
    }
  }
}
