pipeline {
  agent { label "cloud-trigger" }

  parameters {
    booleanParam(name: 'usejenkinsrepo', defaultValue: true,
      description: 'Prefer the repo url and branch that Jenkins passed e.g. from the Multibranch Github Plugin. Otherwise use the repourl and branch parameter below.')
    string(name: 'repourl', defaultValue: 'git@github.com:SUSE-Cloud/automation.git', description: 'url to use of a automation.git repository')
    string(name: 'branch', defaultValue: 'master', description: 'branch to use of the automation.git')
  }

  options {
    ansiColor('xterm')
  }

  stages {
    stage('Output environment') {
      steps {
        sh "env"
      }
    }

    stage('Checkout from Multibranch') {
      when { expression { params.usejenkinsrepo } }
      steps {
        git branch: "${env.BRANCH_NAME}",
            url: "${env.GIT_URL}"
      }
    }

    stage('Checkout from parameters') {
      when { not { expression { params.usejenkinsrepo } } }
      steps {
        git branch: "${params.branch}",
            url: "${params.repourl}"
      }
    }

    stage('make clean') {
      steps {
        sh 'make clean'
      }
    }

    stage('Run checks') {
      parallel {

        stage('make filecheck') {
          steps {
            sh 'make filecheck'
          }
        }
        stage('make bashate') {
          steps {
            sh 'echo TODO install python3-bashate to run make bashate'
          }
        }
        stage('make rounduptest') {
          steps {
            sh 'echo TODO package roundup to run make rounduptest'
          }
        }
        stage('make perlcheck') {
          steps {
            sh 'make perlcheck'
          }
        }
        stage('make rubycheck') {
          steps {
            sh 'make rubycheck'
          }
        }
        stage('make pythoncheck') {
          steps {
            sh 'make pythoncheck'
          }
        }
        stage('make flake8') {
          steps {
            sh 'make flake8'
          }
        }
        stage('make python_unittest') {
          steps {
            sh 'make python_unittest'
          }
        }
        stage('make jjb_test') {
          steps {
            sh 'make jjb_test'
          }
        }

      }
    }

    stage('final make clean') {
      steps {
        sh 'make clean'
      }
    }

  }
}
