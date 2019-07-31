/**
 * The openstack-cloud Jenkins pipeline library
 */


// Loads the list of extra parameters into the environment
def load_extra_params_as_vars(extra_params) {
  if (extra_params) {
    def props = readProperties text: extra_params
    for(key in props.keySet()) {
      value = props["${key}"]
      env."${key}" = "${value}"
    }
  }
}

// When a CI lockable resource slot name is used for the `cloud_env` value,
// this function overrides the os_cloud and os_project_name values to correspond
// to the target OpenStack platform associated with the slot and the 'cloud-ci'
// OpenStack project used exclusively for the Cloud CI
def load_os_params_from_resource(cloud_env) {
  if (cloud_env.startsWith("engcloud-ci-slot")) {
    env.os_cloud = "engcloud"
    env.os_project_name = "cloud-ci"
  } else if (cloud_env.startsWith("susecloud-ci-slot")) {
    env.os_cloud = "susecloud"
    env.os_project_name = "cloud-ci"
  } else if (os_project_name == "cloud-ci") {
    error("""The OpenStack 'cloud-ci' project is reserved and may only be used with
'cloud_env' values that correspond to CI Lockable Resource slots.
Please adjust your 'cloud_env' or 'os_project_name' parameter values to avoid this error.""")
  }
}

def ansible_playbook(playbook, params='') {
  sh("""
    cd $WORKSPACE
    source automation-git/scripts/jenkins/cloud/jenkins-helper.sh
    if [[ -e automation-git/scripts/jenkins/cloud/ansible/input.yml ]]; then
      ansible_playbook """+playbook+""".yml -e @input.yml """+params+"""
    else
      ansible_playbook """+playbook+""".yml """+params+"""
    fi
  """)
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
      grep -oP "^${cloud_env}\\s+ansible_host=\\K[0-9\\.]+" \\
        $WORKSPACE/automation-git/scripts/jenkins/cloud/ansible/inventory
    '''
  ).trim()
  currentBuild.displayName = "#${BUILD_NUMBER}: ${cloud_env} (${DEPLOYER_IP})"
  echo """
******************************************************************************
** The deployer for the '${cloud_env}' environment is reachable at:
**
**        ssh root@${DEPLOYER_IP}
**
******************************************************************************
  """
}

def generate_tempest_stages(tempest_filter_list) {
  if (tempest_filter_list != '') {
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
}

def generate_qa_tests_stages(qa_test_list) {
  if (qa_test_list != '') {
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
}

def maintenance_status(params='') {
  return sh (
    returnStdout: true,
    script: """
      cd $WORKSPACE/automation-git/scripts/maintenance-status
       ./maintenance-status.rb """+params+"""
    """
  ).trim()
}

// Converts a map of <param-name>: <param-value> pairs into a list of
// parameters accepted by the "build job" function that triggers a
// Jenkins job
def convert_to_build_params(param_map) {
  def job_params = []
  param_map.each { param_name, param_value ->
    // extra_params is special
    if (param_name == 'extra_params') {
      job_params.add(text(name: param_name, value: param_value))
    } else if (param_value instanceof Boolean) {
      job_params.add(booleanParam(name: param_name, value: param_value))
    } else {
      job_params.add(string(name: param_name, value: "$param_value"))
    }
  }
  return job_params
}

// Generates and returns a set of parallel stages according to the
// supplied task configuration file and list of task groups.
// The task configuration file has to be formatted using yaml, as follows:
//
// <task-group-name>:
//   <task-name>:
//     <attribute>: <value>
//     <attribute>: <value>
// <task-group-name>:
//   <task-name>:
//     <attribute>: <value>
//     <attribute>: <value>
// [...]
//
// Stages will be generated only for the tasks that belong to one of the
// groups supplied in `task_group_list`.
//
// Input:
//  * task_group_list: list of string values indicating which of the
//    task groups described in the task configuration file should be
//    included
//  * task_config_file: filesystem path pointing to a yaml configuration
//    file describing the tasks
//  * task_filter: when non-empty, stages are only generated for tasks that
//    are found in this list. Otherwise, stages will be generated for all the
//    tasks in the supplied list of task groups
//  * body: closure that will be called for each of the generated
//    stages. The closure will be supplied two parameters: the
//    <task-name> and the map of <attribute>: <value> pairs read from
//    the task configuration file
//
def generate_parallel_stages(task_group_list, task_filter, task_config_file, body) {
  def out_stages = [:]
  task_config = readYaml file: task_config_file
  for (task_group in task_group_list) {
    if (task_group in task_config) {
      task_config[task_group].each { task_name, task_def ->
        if (task_filter.isEmpty() || task_name in task_filter) {
          // we need local scope variables, otherwise the closure is
          // called with the last values that the task_name and task_def
          // iterator variables get
          def out_task_def = task_def
          def out_task_name = task_name
          out_stages[task_name] = {
            stage(task_name) {
              body(out_task_name, out_task_def)
            }
          }
        }
      }
    }
  }
  return out_stages
}

// Implements a simple closure that executes the supplied function (body) with
// or without reserving a Lockable Resource identified by the 'resource_label'
// label value, depending on the 'reserve' boolean value.
//
// The reserved resource will be passed to the supplied closure as a parameter.
// For convenience, the function also accepts a 'default_resource' parameter
// that will be used as a default value for the name of the resource, if a
// resource does not actually need to be reserved. This enables the supplied
// function body to use the resource name without needing to check again if it
// has been reserved or not. If 'default_resource' is null, the 'resource_label'
// value will be used in its place.
//
def run_with_reserved_env(reserve, resource_label, default_resource, body) {

  if (reserve) {
    lock(resource: null, label: resource_label, variable: 'reserved_resource', quantity: 1) {
      if (env.reserved_resource && reserved_resource != null) {
        echo "Reserved resource: " + reserved_resource
        body(reserved_resource)
      } else  {
        def errorMsg = "Jenkins bug (JENKINS-52638): couldn't reserve a resource with label " + resource_label
        echo errorMsg
        error(errorMsg)
      }
    }
  } else {
    def reserved_resource = default_resource != null ? default_resource: resource_label
    echo "Using resource without a reservation: " + reserved_resource
    body(reserved_resource)
  }
}

return this
