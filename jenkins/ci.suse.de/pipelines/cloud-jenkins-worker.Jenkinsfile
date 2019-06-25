/**
 * The cloud-jenkins-worker Jenkins Pipeline
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
          currentBuild.displayName = "#${BUILD_NUMBER}: ${worker_ids}"

          sh('''
            git clone $git_automation_repo --branch $git_automation_branch automation-git

            set +x
            export ANSIBLE_FORCE_COLOR=true
            cd $WORKSPACE/automation-git/scripts/jenkins/workers
            source /opt/ansible/bin/activate
            ansible-playbook load-job-params.yml
          ''')
        }
      }
    }

    stage('Create/Get server(s)') {
      steps {
        script {
          ansible_playbook('create-server')
        }
      }
    }

    stage('Bootstrap jenkins worker') {
      steps {
        script {
          ansible_playbook('jenkins-worker')
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

def ansible_playbook(playbook, params='') {
  sh("""
    set +x
    export ANSIBLE_FORCE_COLOR=true
    cd $WORKSPACE/automation-git/scripts/jenkins/workers
    source /opt/ansible/bin/activate
    ansible-playbook """+playbook+""".yml -e @input.yml """+params
  )
}
