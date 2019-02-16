# Jenkins pipelines tutorial

This is a step-by-step tutorial to implementing Jenkins pipeline jobs.
It demonstrates generic concepts, reusable for other objectives related
to automating tasks that involve management of Cloud environments, but
the particular objective of the pipelines covered here is to automate
the deployment of new Jenkins agent nodes running as Cloud VMs.

## Objectives

* one "core", heavily parameterized Jenkins pipeline job
* multiple instantiations of the "core" job via JJB templates
* Lockable Resources are used to manage virtual Cloud resources
* one must be able to run back-end scripts independently from Jenkins

## Test environment setup

The tutorial includes a set of Jenkins jobs that can be installed in a
Jenkins service via [jenkins-job-builder](http://docs.openstack.org/infra/jenkins-job-builder/)
in a manner similar to the way the official automation GitHub repository
Jenkins jobs have to be configured.

The following steps may be followed to test the Jenkins jobs covered
in this tutorial:

* clone the [automation repository](https://github.com/SUSE-Cloud/automation) locally
* set up a Jenkins credentials file(see [`/scripts/jenkins/jenkins_jobs.ini.sample`](jenkins_jobs.ini.sample)
* create and activate a local python virtualenv and install the following
packages (or, alternatively, install these packages as system packages,
using zypper):
  * jenkins-job-builder

With all the above in check, run the following command in this folder to
install or update one of the tutorial Jenkins jobs (e.g. for the
`stage-01` job version):

```
PYTHONHTTPSVERIFY=0 jenkins-jobs --conf jenkins_jobs.ini update stage-01/jenkins openstack-jenkins-agent
```

To also be able to run the back-end scripts from the local host, the
following are also required:

* set up an OpenStack cloud configuration reflecting your cloud
credentials. To do that, create an `~/.config/openstack/clouds.yaml`
file with the configuration reflecting your OpenStack cloud account.
The following example describes an Engineering Cloud account:

```
clouds:
  engcloud-cloud-ci:
    region_name: CustomRegion
    auth:
      auth_url: https://engcloud.prv.suse.net:5000/v3
      username: <your ECP ldap user name>
      password: <your ECP ldap password>
      project_name: <your ECP project>
      project_domain_name: default
      user_domain_name: ldap_users
    identity_api_version: 3
    cacert: /usr/share/pki/trust/anchors/SUSE_Trust_Root.crt.pem
```

* install the following additional packages in the python virtualenv
(or as system packages, using zypper):
  * python-openstackclient
  * python-heatclient
  * python-neutronclient
  * ansible
  * netaddr

The pipeline jobs assume the above back-end requirements are also set up
on the Jenkins agent nodes they are running on. In addition to that,
parts of the Jenkins agent configuration that is already present on the
node will be reused for the newly deployed agent.

## Stage 1 - inline pipeline definition

The first pipeline uses an inline DSL pipeline definition, which is
basically keeping everything in one file: the JJB job configuration,
the pipeline definition and the back-end scripts implementing the job.

Things to note:

* adding `sandbox: true` is required because, by default, the pipeline
is not running in a sandbox and needs to be explicitly approved by a
Jenkins admin before it can execute. Not doing that will result in the
following error:

`org.jenkinsci.plugins.scriptsecurity.scripts.UnapprovedUsageException: script not yet approved for use`

* specifying an agent is mandatory:

```
agent {
  node {
    label 'cloud-ardana-ci'
  }
}
```

, otherwise the following error will ensue:

`WorkflowScript: 1: Missing required section "agent" @ line 1, column 1`

* all `sh` scripts are executed with the -xe flags set by default.
`set +e` and/or `set +x` need to be explicitly specified to disable
these options.

* job parameters are available as environment variables

* use the Blue Ocean UI to get a better user experience

* the greatest disadvantage of this approach is the JJB file needs to
be installed every time there's a change in either the pipeline
definition or the back-end scripts. The next implementation stage will
attempt to correct that.

## Stage 2 - pipeline as code

The second implementation stage re-organizes everything to keep the JJB
job configuration, the pipeline definition (Jenkinsfile) and the
back-end scripts separated.

Things to note:

* introduced two new parameters, which can be used to manually test
job versions that reside in other git branches and/or forks

* the workspace now contains a git checkout corresponding to the
specified SCM configuration

## Stage 3 - pipeline options for usability and cleanup

The third implementation stage introduces a few JJB and Jenkins pipeline
options to improve the usability of the job.

Things to note:

* the JJB `validating-string` parameter type can be used to validate
input

* global pipeline options:
  * use `skipDefaultCheckout` to control where and when to checkout git
  sources
  * use `timeout` to abort the job after a specified amount of time with
  no log activity
  * use `timestamps` to add time stamps to the logs

* `customWorkspace` can be used to dictate the workspace folder on the
Jenkins agent

* the `script` step contains groovy code and can be used to customize
the behavior of the Jenkins job
  * use `currentBuild.displayName` to dynamically change the build name
  as more information becomes available
  * in groovy, the environment variables can be accessed in a manner
  similar to bash
  * use `if` for conditions
  * use `echo` to print messages
  * note the difference in the Blue Ocean UI between `stage/script/sh`
  and `stage/sh` and between shell `echo` and `stage/script/echo`

* setting a global environment variable can only be done through groovy,
by executing a shell command and saving its output into an environment
variable:

```
script {
  env.AGENT_IP = sh (
    returnStdout: true,
    script: 'cat floatingip.env'
  ).trim()
}
```

* introducing conditional stages - the `when` step takes in a groovy
conditional expression that can be based on environment variables:

```
when {
  expression { run_tests == 'true' }
}
```

* introducing post-build stages - the `post` step and its `success`,
`failure`, `cleanup` and `always` sub-steps can be used to run
additional steps after the job completes

* introducing the `archiveArtifacts` step, which can be uses to collect
Jenkins artifacts

* introducing the `cleanWs` step, which can be used to clean up the
workspace