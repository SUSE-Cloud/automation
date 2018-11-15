/**
 * The openstack-ardana-gerrit Jenkins Pipeline
 */

pipeline {
  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label 'cloud-pipeline'
    }
  }

  stages {

    stage('Setup workspace') {
      steps {
        script {
          currentBuild.displayName = "#${BUILD_NUMBER}: ${gerrit_change_ids}"
        }
        sh('''
          git clone $git_automation_repo --branch $git_automation_branch automation-git

          if [ -n "$GERRIT_CHANGE_NUMBER" ] ; then
            # Post reviews only for jobs triggered by Gerrit
            automation-git/scripts/jenkins/ardana/gerrit/gerrit_review.py \
              --vote 0 \
              --label 'Verified' \
              --message "
Started build (${JOB_NAME}): ${BUILD_URL}
The following links can also be used to track the results:

- live console output: ${BUILD_URL}console
- live pipeline job view: ${RUN_DISPLAY_URL}
" \
              --patch ${GERRIT_PATCHSET_NUMBER} \
              ${GERRIT_CHANGE_NUMBER}
          fi
        ''')

      }
    }

    stage('validate commit message') {
      when {
        expression { env.GERRIT_CHANGE_COMMIT_MESSAGE != null }
      }
      steps {
        sh '''
          export LC_ALL=C.UTF-8
          export LANG=C.UTF-8

          echo $GERRIT_CHANGE_COMMIT_MESSAGE | base64 --decode | gitlint -C automation-git/scripts/jenkins/gitlint.ini
        '''
      }
      post {
        success {
            sh '''
              echo "- ${STAGE_NAME}: PASSED (${BUILD_URL}console)" > results.txt
            '''
        }
        failure {
            sh '''
              echo "- ${STAGE_NAME}: FAILED (${BUILD_URL}console)" > results.txt
            '''
        }
      }
    }

    stage('integration test') {
      when {
        expression { cloudsource == 'stagingcloud9' }
      }
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana', parameters: [
              string(name: 'ardana_env', value: "$ardana_env"),
              string(name: 'reserve_env', value: "$reserve_env"),
              string(name: 'cleanup', value: "on success"),
              string(name: 'gerrit_change_ids', value: "$gerrit_change_ids"),
              string(name: 'git_automation_repo', value: "$git_automation_repo"),
              string(name: 'git_automation_branch', value: "$git_automation_branch"),
              string(name: 'scenario_name', value: "standard"),
              string(name: 'clm_model', value: "standalone"),
              string(name: 'controllers', value: "2"),
              string(name: 'sles_computes', value: "1"),
              string(name: 'cloudsource', value: "$cloudsource"),
              string(name: 'tempest_run_filter', value: "$tempest_run_filter")
          ], propagate: false, wait: true
          env.jobResult = slaveJob.getResult()
          env.jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
          def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
          echo jobMsg
          sh '''
            echo "- ${STAGE_NAME}: ${jobResult} (${jobUrl})" >> results.txt
          '''
          if (env.jobResult != 'SUCCESS') {
             error(jobMsg)
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
          # Post reviews only for jobs triggered by Gerrit
          if [ -n "$GERRIT_CHANGE_NUMBER" ] ; then
            if [[ $BUILD_RESULT == SUCCESS ]]; then
              if [[ $cloudsource == stagingcloud9 ]]; then
                vote=+2
              else
                vote=0
              fi
              message="
Build succeeded (${JOB_NAME}): ${BUILD_URL}

"
            else
              if [[ $cloudsource == stagingcloud9 ]]; then
                vote=-2
              else
                vote=-1
              fi
              message="
Build failed (${JOB_NAME}): ${BUILD_URL}

"
            fi
            automation-git/scripts/jenkins/ardana/gerrit/gerrit_review.py \
              --vote $vote \
              --label 'Verified' \
              --message "$message" \
              --message-file results.txt \
              --patch ${GERRIT_PATCHSET_NUMBER} \
              ${GERRIT_CHANGE_NUMBER}

            if [[ $BUILD_RESULT == SUCCESS ]]; then
              automation-git/scripts/jenkins/ardana/gerrit/gerrit_merge.py \
                --patch ${GERRIT_PATCHSET_NUMBER} \
                ${GERRIT_CHANGE_NUMBER}
            fi
          fi
        ''')

      }
    }
    cleanup {
      cleanWs()
    }
  }
}
