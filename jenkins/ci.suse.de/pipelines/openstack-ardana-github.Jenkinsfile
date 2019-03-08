/**
 * The openstack-ardana-github Jenkins Pipeline
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
      label 'cloud-pipeline'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {

    stage('Setup workspace') {
      steps {
        script {
          // Extract the current commit number from the GitHub PR
          env.github_pr_sha = sh (
            returnStdout: true,
            script: '''
              ~/github.com/openSUSE/github-pr/github_pr.rb \
                --action get-latest-sha \
                --org SUSE-Cloud \
                --repo automation \
                --pr $github_pr_id
            '''
          ).trim()

          currentBuild.displayName = "#${BUILD_NUMBER}: $github_pr_id/" + github_pr_sha.take(7) +" ($github_context)"

          sh('''
            export git_automation_repo=SUSE-Cloud
            export git_automation_branch=$github_pr_sha
            curl https://raw.githubusercontent.com/$git_automation_repo/automation/$git_automation_branch/scripts/jenkins/ardana/openstack-ardana.prep.sh | bash
          ''')

          ardana_lib = load "$WORKSPACE/automation-git/jenkins/ci.suse.de/pipelines/openstack-ardana.groovy"
          ardana_lib.load_extra_params_as_vars(extra_params)
        }
      }
    }

    stage('supersede running jobs') {
      steps {
        script {
          sh('''
            # Abort other older running builds that target the same pull
            # request number and context

            python -u automation-git/scripts/jenkins/jenkins-job-cancel \
              --older-than ${BUILD_NUMBER} \
              --with-param github_pr_id=$github_pr_id \
              --with-param github_context=$github_context \
              --wait 600 \
              ${JOB_NAME} || :
          ''')
        }
      }
    }

    stage('notify GitHub') {
      steps {
        script {
          sh('''
            ghprrepo=~/github.com/openSUSE/github-pr
            ghpr=${ghprrepo}/github_pr.rb
            ghpr_paras="--org SUSE-Cloud --repo automation --sha $github_pr_sha --context $github_context"

            if ! $ghpr --action is-latest-sha $ghpr_paras --pr $github_pr_id ; then
                $ghpr --action set-status $ghpr_paras --status "error" --targeturl $BUILD_URL --message "SHA1 mismatch, newer commit exists"
                exit 1
            fi
            $ghpr --action set-status $ghpr_paras --status "pending" --targeturl $BUILD_URL --message "Started PR gating"
          ''')
        }
      }
    }

    stage('integration test') {
      when {
        expression { integration_test_job != '' }
      }
      steps {
        script {
          // reserve a resource here for the openstack-ardana job, to avoid
          // keeping a cloud-ardana-ci worker busy while waiting for a
          // resource to become available.
          ardana_lib.run_with_reserved_env(reserve_env == 'true', ardana_env, ardana_env) {
            reserved_env ->
            ardana_lib.trigger_build(integration_test_job, [
              string(name: 'ardana_env', value: reserved_env),
              string(name: 'reserve_env', value: "false"),
              string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
              string(name: 'extra_repos', value: "$extra_repos"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$github_pr_sha"),
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
          automation-git/scripts/jenkins/jenkins-job-pipeline-report.py \
            --recursive \
            --filter 'Declarative: Post Actions' \
            --filter 'Setup workspace' \
            --filter 'supersede running jobs' \
            --filter 'notify GitHub' > pipeline-report.txt || :

          if [[ $BUILD_RESULT == SUCCESS ]]; then
            status=success
            message_result="succeeded"
          elif [[ $BUILD_RESULT == ABORTED ]]; then
            status=error
            message_result="aborted"
          else
            status=error
            message_result="failed"
          fi

          ghprrepo=~/github.com/openSUSE/github-pr
          ghpr=${ghprrepo}/github_pr.rb
          ghpr_paras="--org SUSE-Cloud --repo automation --sha $github_pr_sha --context $github_context"

          if ! $ghpr --action is-latest-sha $ghpr_paras --pr $github_pr_id ; then
              $ghpr --action set-status $ghpr_paras --status "error" --targeturl $BUILD_URL --message "SHA1 mismatch, newer commit exists"
          else
              $ghpr --action set-status $ghpr_paras --status $status --targeturl $BUILD_URL --message "PR gating $message_result"
          fi
        ''')
      }
    }
    cleanup {
      cleanWs()
    }
  }
}
