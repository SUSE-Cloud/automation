/**
 * The openstack-ardana-virtual Jenkins Pipeline
 *
 * This jobs creates an ECP virtual environment that can be used to deploy
 * an Ardana input model which is either predefined or generated based on
 * the input parameters.
 */
pipeline {

  // skip the default checkout, because we want to use a custom path
  options {
    skipDefaultCheckout()
  }

  agent {
    node {
      label reuse_node ? reuse_node : "cloud-ardana-ci"
      customWorkspace ardana_env ? "${JOB_NAME}-${ardana_env}" : "${JOB_NAME}-${BUILD_NUMBER}"
    }
  }

  stages {
    stage('Setup workspace') {
      steps {
        cleanWs()

        // If the job is set up to reuse an existing workspace, replace the
        // current workspace with a symlink to the reused one.
        // NOTE: even if we specify the reused workspace as the
        // customWorkspace variable value, Jenkins will refuse to reuse a
        // workspace that's already in use by one of the currently running
        // jobs and will just create a new one.
        sh '''
          if [ -n "${reuse_workspace}" ]; then
            rmdir "${WORKSPACE}"
            ln -s "${reuse_workspace}" "${WORKSPACE}"
          fi
        '''

        script {
          if (ardana_env == '') {
            error("Empty 'ardana_env' parameter value.")
          }
          currentBuild.displayName = "#${BUILD_NUMBER} ${ardana_env}"
          if (reuse_workspace == '') {
            sh('git clone $git_automation_repo --branch $git_automation_branch automation-git')
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook load-job-params.yml
            ''')
          }
        }
      }
    }

    stage('Prepare input model') {
      parallel {
        stage('Generate input model') {
          when {
            expression { scenario_name != '' }
          }
          steps {
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook generate-input-model.yml -e @input.yml
            ''')
          }
        }
        stage('Clone input model') {
          when {
            expression { scenario_name == '' }
          }
          steps {
            sh('''
              source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
              ansible_playbook clone-input-model.yml -e @input.yml
            ''')
          }
        }
      }
    }

    stage('Generate heat template') {
      steps {
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook generate-heat-template.yml -e @input.yml
        ''')
      }
    }

    stage('Create heat stack') {
      steps {
        script {
          def slaveJob = build job: 'openstack-ardana-heat', parameters: [
            string(name: 'ardana_env', value: "$ardana_env"),
            string(name: 'heat_action', value: "create"),
            string(name: 'reuse_node', value: "${NODE_NAME}"),
            string(name: 'reuse_workspace', value: "${WORKSPACE}")
          ], propagate: true, wait: true
        }
      }
    }

    stage('Setup SSH access') {
      steps {
        sh('''
          source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
          ansible_playbook setup-ssh-access.yml -e @input.yml
        ''')
      }
    }
  }

  post {
    always {
        archiveArtifacts artifacts: '.artifacts/**/*', allowEmptyArchive: true
    }
    success{
      sh """
      set +x
      cd automation-git/scripts/jenkins/ardana/ansible/ansible_facts
      echo "
*****************************************************************
** The virtual environment is reachable at
**
**        ssh root@\$(awk '/admin-floating-ip/{getline; print \$2}' localhost | sed -e 's/^"//' -e 's/"\$//')
**
** Please delete openstack-ardana-${ardana_env} stack manually when you're done.
*****************************************************************
      "
      """
    }
    failure {
      script {
        def slaveJob = build job: 'openstack-ardana-heat', parameters: [
          string(name: 'ardana_env', value: "$ardana_env"),
          string(name: 'heat_action', value: "delete"),
          string(name: 'reuse_node', value: "${NODE_NAME}"),
          string(name: 'reuse_workspace', value: "${WORKSPACE}")
        ], propagate: false, wait: false
      }
    }
  }
}
