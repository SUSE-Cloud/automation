pipeline {
  /* No idea what I am doing: options? Time trigger? Automatic running of
     cleanup stage if failure on "deployer everything" stage?
  */
  options {
    skipDefaultCheckout() /* skips the clone of automation repo into wrkspc */
    timestamps()
    timeout(time: 9, unit: 'HOURS', activity: true)
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
  }
  post {
    always {
      script {
        sh('''
          rm ~/ready-to-cleanup || true
          env
          export PREFIX=${PREFIX:-'ccpci'}
          export OS_CLOUD=${OS_CLOUD:-'engcloud-cloud-ci'}
          export KEYNAME=${KEYNAME:-'engcloud-cloud-ci'}
          export INTERNAL_SUBNET="${PREFIX}-subnet"

          # When holding instance, expire at 540 minutes (9 hours)
          # or when readytocleanup exists
          countdown=540
          if [[ "${ask_to_hold_instance}" == "true" ]]; then
              echo "This holds the instance for 9 hours. Please create ~/ready-to-cleanup file to shorten the process."
              until (stat ~/ready-to-cleanup > /dev/null 2>&1 || [[ $countdown -eq 0 ]]); do
                sleep 1m;
                countdown=`expr ${countdown} - 1`;
              done
          fi

          pushd ${WORKSPACE}/ccp/
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
