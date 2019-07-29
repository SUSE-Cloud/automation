/**
 * The openstack-ses Jenkins Pipeline
 */

pipeline {
  options {
    // skip the default checkout, because we want to use a custom path
    skipDefaultCheckout()
    timestamps()
  }

  agent {
    node {
      label 'cloud-ci'
      customWorkspace "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        script {
          // Set this variable to be used by upstream builds
          env.blue_ocean_buildurl = env.RUN_DISPLAY_URL
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ses_id}"

          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git

            set +x
            export ANSIBLE_FORCE_COLOR=true
            cd $WORKSPACE/automation-git/scripts/jenkins/ses/ansible
            source /opt/ansible/bin/activate
            ansible-playbook load-job-params.yml
          ''')
        }
      }
    }

    stage('Create heat stack') {
      steps {
        script {
          ansible_playbook('ses-heat-stack')

          env.SES_IP = sh (
            returnStdout: true,
            script: '''
              grep -oP "^${ses_id}-ses\\s+ansible_host=\\K[0-9\\.]+" \\
                $WORKSPACE/automation-git/scripts/jenkins/ses/ansible/inventory
            '''
          ).trim()
          currentBuild.displayName = "#${BUILD_NUMBER}: ${ses_id} (${SES_IP})"
          echo """
******************************************************************************
** The SES '${ses_id}' environment is reachable at:
**
**        ssh root@${SES_IP}
**
******************************************************************************
          """
        }
      }
    }

    stage('Bootstrap node') {
      steps {
        script {
          ansible_playbook('bootstrap-ses-node')
        }
      }
    }

    stage('Deploy SES') {
      steps {
        script {
          retry(2) {
            ansible_playbook('ses-deploy')
          }
        }
      }
    }

  }
  post {
    always {
      script{
        archiveArtifacts artifacts: ".artifacts/**/*", allowEmptyArchive: true
      }
      script{
        if (env.SES_IP != null) {
          def cloud_url_text = "the cloud"
          if (os_cloud == 'engcloud') {
            cloud_url_text="the engineering cloud at https://engcloud.prv.suse.net/project/stacks/"
          } else if (os_cloud == 'susecloud') {
            cloud_url_text="the SUSE cloud at https://cloud.suse.de/project/stacks/"
          }
          echo """
******************************************************************************
** The '${ses_id}' SES environment is reachable at:
**
**        ssh root@${SES_IP}
**
** Please delete the '${ses_id}-ses' stack when you're done,
** by loging into ${cloud_url_text}
** and deleting the heat stack.
******************************************************************************
               """
        }
      }
    }
    cleanup {
      cleanWs()
    }
  }
}

def ansible_playbook(playbook, params='') {
  sh("""
    set +x
    export ANSIBLE_FORCE_COLOR=true
    cd $WORKSPACE/automation-git/scripts/jenkins/ses/ansible
    source /opt/ansible/bin/activate
    ansible-playbook """+playbook+""".yml -e @input.yml """+params
  )
}
