/**
 * The openstack-jenkins-agent Jenkins pipeline
 *
 */

pipeline {

  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
    // timeout after 10 minutes with no log activity
    timeout(time: 10, unit: 'MINUTES', activity: true)
    // include timestamps in logs
    timestamps()
  }

  agent {
    node {
      label 'cloud-ardana-ci'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Print job info') {
      steps {
        sh ('''
          echo ==============================================================================
          hostname
          echo ==============================================================================
          pwd
          echo ==============================================================================
          find
          echo ==============================================================================
          env
          echo ==============================================================================
        ''')
      }
    }

    stage('Setup workspace') {
      steps {
        script {
          currentBuild.displayName = "#${BUILD_NUMBER}: ${agent_name}"
        }
        sh ('''
          git clone $git_automation_repo --branch $git_automation_branch automation-git
          mkdir .artifacts
        ''')
      }
    }

    stage('Create Jenkins agent VM') {
      steps {
        sh ('automation-git/docs/pipelines/stage-04/scripts/cleanup-jenkins-agent-vm.sh')
        sh ('automation-git/docs/pipelines/stage-04/scripts/create-jenkins-agent-vm.sh')
        script {
          env.AGENT_IP = sh (
            returnStdout: true,
            script: 'cat floatingip.env'
          ).trim()
          currentBuild.displayName = "#${BUILD_NUMBER}: ${agent_name} (${AGENT_IP})"
          echo """
******************************************************************************
** The '${agent_name}' Jenkins agent is reachable at:
**
**        ssh root@${AGENT_IP}
**
******************************************************************************
          """
        }
      }
    }

    stage('Provision agent VM') {
      steps {
        sh ('''
            set +e

            echo "Attempting to ssh to $AGENT_IP"
            agent_accessible=false
            for i in $(seq 20)
            do
                SSHPASS=linux automation-git/docs/pipelines/stage-04/scripts/sshpass.sh ssh-copy-id root@${AGENT_IP}
                if (( $? == 0 )); then
                    agent_accessible=true
                    break
                fi
                sleep 5
            done
            if ! $agent_accessible; then
                echo "Failed to contact ${AGENT_IP}"
                exit 3
            fi
        ''')
      }
    }

    stage('Test Jenkins agent') {
      when {
        expression { run_tests == 'true' }
      }
      steps {
        sh ('''
          ssh -o 'StrictHostKeyChecking=no' root@${AGENT_IP} ping -c 4 ci.suse.de
        ''')
      }
    }
  }

  post {
    always {
      script{
        sh('''
          automation-git/scripts/jenkins/jenkins-job-pipeline-report.py \
            --recursive \
            --filter 'Declarative: Post Actions' \
            --filter 'Setup workspace' > .artifacts/pipeline-report.txt || :
        ''')
        archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
      }
    }
    success {
      script {
        if (env.AGENT_IP != null) {
          echo """
******************************************************************************
** The '${agent_name}' Jenkins agent is reachable at:
**
**        ssh root@${AGENT_IP}
**
******************************************************************************
          """
        }
      }
    }
    failure {
      sh ('automation-git/docs/pipelines/stage-04/scripts/cleanup-jenkins-agent-vm.sh')
    }
    cleanup {
      cleanWs()
    }
  }
}
