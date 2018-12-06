/**
 * The openstack-ardana Jenkins pipeline library
 */

def ansible_playbook(playbook, params='') {
  sh("""
    cd $SHARED_WORKSPACE
    source automation-git/scripts/jenkins/ardana/jenkins-helper.sh
    ansible_playbook """+playbook+""".yml -e @input.yml """+params
  )
}

def trigger_build(job_name, parameters, propagate=true, wait=true) {
  def slaveJob = build job: job_name, parameters: parameters, propagate: propagate, wait: wait
  if (wait && !propagate) {
    def jobResult = slaveJob.getResult()
    def jobUrl = slaveJob.buildVariables.blue_ocean_buildurl
    def jobMsg = "Build ${jobUrl} completed with: ${jobResult}"
    echo jobMsg
    if (jobResult != 'SUCCESS') {
      error(jobMsg)
    }
  }
  return slaveJob
}

def get_deployer_ip() {
  env.DEPLOYER_IP = sh (
    returnStdout: true,
    script: '''
      grep -oP "^${ardana_env}\\s+ansible_host=\\K[0-9\\.]+" \\
        $SHARED_WORKSPACE/automation-git/scripts/jenkins/ardana/ansible/inventory
    '''
  ).trim()
  currentBuild.displayName = "#${BUILD_NUMBER}: ${ardana_env} (${DEPLOYER_IP})"
  echo """
******************************************************************************
** The deployer for the '${ardana_env}' environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
  """
}

def generate_tempest_stages(tempest_filter_list) {
  for (filter in tempest_filter_list.split(',')) {
    catchError {
      stage("Tempest: "+filter) {
        ansible_playbook('run-tempest', "-e tempest_run_filter=$filter")
      }
    }
    archiveArtifacts artifacts: ".artifacts/**/ansible.log, .artifacts/**/*${filter}*", allowEmptyArchive: true
    junit testResults: ".artifacts/testr_results_region1_${filter}.xml", allowEmptyResults: true
  }
}

def generate_qa_tests_stages(qa_test_list) {
  for (test in qa_test_list.split(',')) {
    catchError {
      stage("QA test: "+test) {
        ansible_playbook('run-ardana-qe-tests', "-e test_name=$test")
      }
    }
    archiveArtifacts artifacts: ".artifacts/**/${test}*", allowEmptyArchive: true
    junit testResults: ".artifacts/${test}.xml", allowEmptyResults: true
  }
}

return this
