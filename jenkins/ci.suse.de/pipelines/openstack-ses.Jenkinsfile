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
      label 'cloud-ardana-ci'
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
            set +x

            # Need a local git clone copy to run from
            export use_global_clone=false
            curl https://raw.githubusercontent.com/SUSE-Cloud/automation/master/scripts/jenkins/ardana/openstack-ardana.prep.sh | bash

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
              grep -oP "${ses_id}\\s+ansible_host=\\K[0-9\\.]+" \\
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
          echo """
******************************************************************************
** The '${ses_id}' SES environment is reachable at:
**
**        ssh root@${SES_IP}
**
** Please delete the 'openstack-ses-${ses_id}' stack when you're done,
** by loging into the ECP at https://engcloud.prv.suse.net/project/stacks/
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
