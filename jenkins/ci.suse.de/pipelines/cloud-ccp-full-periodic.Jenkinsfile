pipeline {
  /* No idea what I am doing: options? Time trigger? Automatic running of
     cleanup stage if failure on "deployer everything" stage?
  */
  options {
    skipDefaultCheckout() /* skips the clone of automation repo into wrkspc */
    timestamps()
    timeout(time: 30, unit: 'MINUTES', activity: true)
  }

  agent {
    node {
      label "cloud-ccp-ci"
    }
  }

  stages {
    stage('Deploy everything'){
      steps {
        script {
          sh('''
            set -ex
            export PREFIX=${PREFIX:-'ccpci'}
            export OS_CLOUD=${OS_CLOUD:-'engcloud-cloud-ci'}
            export KEYNAME=${KEYNAME:-'engcloud-cloud-ci'}
            export INTERNAL_SUBNET="${PREFIX}-subnet"

            # Make sure the job has a cloud available, and environemnt
            # vars are properly defined
            cat ~/.config/openstack/clouds.yaml | grep -v password
            env

            # Get started
            mkdir ${WORKSPACE}/ccp/ || true
            pushd ${WORKSPACE}/ccp
                # No need for branchname, as the full periodic job always tests
                # latest master branch
                rm -rf socok8s || true
                git clone --recursive ${ccp_repo} socok8s
                pushd socok8s
                    git checkout ${ccp_branch}
                    ./run.sh
                popd
            popd

          ''')
        }
      }
    }
    stage('Ask to hold the instance'){
      /* beforeInput can be used to clarify intent:
         https://jenkins.io/doc/book/pipeline/syntax/
         In the meantime, input is given in "steps".
         beforeInput true
      */
      when {
        environment name: 'ask_to_hold_instance', value: 'true'
      }
      options {
        timeout(time: 9, unit: 'HOURS')
      }
      steps {
        echo "This stage is running because ask to hold instance is set to ${ask_to_hold_instance}."
        input(message: "Waiting for input before deleting the ccp env")
      }
    }
  }
  post {
    always {
      script {
        sh('''
          env
          pushd ${WORKSPACE}/ccp/
            export PREFIX=${PREFIX:-'ccpci'}
            export OS_CLOUD=${OS_CLOUD:-'engcloud-cloud-ci'}
            export KEYNAME=${KEYNAME:-'engcloud-cloud-ci'}
            export INTERNAL_SUBNET="${PREFIX}-subnet"

            pushd socok8s
                ./run.sh teardown
            popd
            rm -rf socok8s
          popd
        ''')
      }
    }
  }
}
