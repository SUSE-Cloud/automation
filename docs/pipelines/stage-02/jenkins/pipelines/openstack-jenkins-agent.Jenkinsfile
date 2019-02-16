/**
 * The openstack-jenkins-agent Jenkins pipeline
 *
 */

pipeline {
  agent {
    node {
      label 'cloud-ardana-ci'
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

    stage('Create Jenkins agent VM') {
      steps {
        sh ('docs/pipelines/stage-02/scripts/create-jenkins-agent-vm.sh')
      }
    }
  }
}
