# Ardana automated CI/CD

## Jenkins pipeline implementation strategy

* the actual stages implementation must not be part of the of the Jenkinsfile. The pipeline stages should
call external scripts (shell, ansible, etc.). Furthermore, one should be able to use these same scripts to run the
pipeline workflow stages without Jenkins present, e.g. from a development environment. Ideally, every pipeline stage
should be implemented by one of the [ansible playbooks/roles](ansible), which can also be executed directly from a
local environment, without any assistance from Jenkins.
* aside from the stage implementation, the following Jenkins specific configuration should be moved out of the JJB file
and into the Jenkinsfile, to enable testing GitHub PRs and fork branches without needing to update the Jenkins job:
  * setting the agent node
  * setting the workspace
  * setting the job name
  * post build triggers
  * downstream job triggers
  * but NOT the parameters, because:
    1. if the parameters are configured in the Jenkinsfile, they will overwrite those in the JJB
    after the first run
    2. the [cloud-update-ci job](https://ci.nue.suse.com/job/cloud-update-ci/) that syncs the Jenkins jobs in the automation
    repository with those configured in ci.nue.suse.com will overwrite the parameters in the Jenkinsfile
* based on the above, the Jenkinsfile contents are restricted to [these allowed directives](#permitted-jenkinsfile-contents)
* (TBD) the Jenkinsfile must be generated from a constrained language that can easily be converted into a programming
language independent data structure, like was done with JJB and YAML for Jenkins jobs. __NOTE:__ this work has been postponed
due to time constraints, but this strategy has been updated to make this possible (see the previous points). The following
high-level work items need to be completed to enable generating the Jenkinsfile contents:
  * eliminate the need for Jenkins build environment variables in order to pass information between pipeline stages, e.g. by
  replacing them with ansible persistent facts or host/group vars
  * create a wrapper that can replicate the behavior of the pipeline by calling the same scripts that implement the Jenkinsfile
  stages, in the same order, with the same parameters. This wrapper can be used to run the pipeline steps without a Jenkins server.
  The same wrapper can be used to generate Jenkinsfiles instead of directly calling the stage scripts, based on a set of
  predefined templates.

* use downstream jobs for stages that can be externalized and executed on their own
  * these jobs will have a subset of the parameters that the main pipeline job can accept
* upstream/downstream execution strategy:
  * the downstream job has the option of reusing the workspace and agent node that is used
  by the upstream job. This is enforced:
    1. to avoid duplicating work between upstream/downstream (e.g. checking out the automation
    repository contents from version control)
    2. to enable sharing large amounts of data between jobs (e.g. generated input models) that would otherwise have
    to be transferred using other means (e.g. artifacts)
    3. to enable sharing the runtime environment (e.g. ansible inventory and variables) between multiple stages,
    which helps to keep the stage implementation closer to the form in which they are executed directly
    from a development environment
  * pass information back to the upstream job by setting them as environment variables in the
  downstream job and using the `.buildVariables` build job object attribute in the upstream job
  (NOTE: this is only possible if the downstream job is also a pipeline job)
* passing information from one stage to the next:
  * use the shared workspace
  * use ansible variables (host/group vars, extra vars) as much as possible
  * use build environment variables (which can only be set by using `env.<variable-name>` in a pipeline script block)
* use the lockable resources mechanism to throttle parallel builds and
implement a virtual resource management and scheduling
* use fast-fail for parallel stages where applicable to abort all the individual stages
comprising a parallel block when a single one fails
* the `ardana_env` parameter determines a unique Jenkins workspace name, which is required to replay stages
* the `when` pipeline verb is used to conditionally skip stages (instead of checking conditions
inside the stage steps, which would show the stage as being always executed, regardless of result)

## Permitted Jenkinsfile contents

The Jenkinsfile definition of a Jenkins declarative pipeline uses a specialized DSL with a syntax similar to Groovy.
Interacting with some of the Jenkins plugins or accessing more advanced Jenkins features sometimes even requires
running Groovy pipeline steps.
While there is no easy way around using the DSL/Groovy to implement Jenkins pipelines, a set of rules have been set
in place to keep the DSL/Groovy footprint in our CI to a minimum. This is enforced for a number of different reasons:
* ensure looser coupling from Jenkins than unrestricted use of everything
  possible in a Jenkinsfile would give, for keeping the cost of replacing
  Jenkins constrained and to be able to test parts without needing to install and
  run Jenkins, bind only to something that needs a Jenkins installation when
  there is an advantage over using an alternative that works without Jenkins
* the test automation strategy is based on the idea of using a common set of tools and scripts for the
development, CI and QA workflows. This requires minimizing the extent of the CI automation logic implemented using
Jenkins pipeline DSL/Groovy because those parts cannot simply be reused in a development environment and would need
to be duplicated using other languages
* developers and QA engineers shouldn't require extensive Jenkins pipeline DSL or Groovy knowledge to make
contributions to the CI

Based on the above, unless Jenkins pipeline DSL/Groovy is absolutely needed to implement something in a pipeline
Jenkins job, for instance because it relates to a Jenkins specific feature, it should be implemented independently
from Jenkins, using other languages, and should be made part of the development workflow. The contents
of a Jenkinsfile are therefore restricted to the following:

* basic pipeline and stage workflow directives [\[1\]](#fn1)[\[2\]](#fn2): `pipeline`, `stages`, `stage`, `steps`
* directives needed to configure the agent and the workspace [\[3\]](#fn3): `agent`, `node`, `label`, `customWorkspace`
* parallel stage workflow directives [\[4\]](#fn4): `parallel`, `failFast`
* post-build action directives [\[5\]](#fn5): `post`, `success`, `always`, `aborted`, `failure`, `unstable`, `cleanup`
* conditional directives [\[6\]](#fn6): `when`
* global Jenkins option directives [\[7\]](#fn7): `options`, `disableConcurrentBuilds`, `retry`, `skipDefaultCheckout`,
`timeout`, `timestamps`
* directives for working with lockable resources [\[8\]](#fn8): `lock`

Aside from the above list of accepted directives, the following pipeline stage steps are
accepted, with the indicated restrictions:

* the `sh` step \[[9\]](#fn9) can be used to execute shell commands or scripts
* the `archiveArtifacts` step [\[10\]](#fn10) can be used to archive Jenkins artifacts
* the `cleanWs` step [\[11\]](#fn11) can be used to perform Jenkins workspace cleanup in a manner that does not
interfere with the internal workings of Jenkins
* using the `script` step is highly discouraged. It should only be used for actions that can't otherwise
be executed with a regular bash script. The following exceptions have been identified so far:
  * the build name can only be set by using the `currentBuild.displayName` variable in a script block
  * build environment variables can only be set by using `env.<variable-name>` in a pipeline script block.
  Exporting environment variables from shell scripts has no effect. Build environment variables are needed
  to pass information from one stage to the next. __NOTE__: this can be avoided by using the shared workspace
  (e.g. creating host/group ansible var files or persisting ansible facts) instead of setting environment
  variables.
  * downstream builds can be triggered using the `build job` directive and the returned object can be used
  to extract information (e.g. environment variables) from the downstream job. __NOTE__: currently, this is
  the only way to run downstream jobs in a pipeline that also allows the upstream job to extract information
  from downstream and also to automatically abort the downstream job when the parent pipeline job or stage is
  aborted. In the future, this could be replaced by an updated [jenkins-job-trigger](../jenkins-job-trigger)
  script.

* <a name="fn1">\[1\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#stage
* <a name="fn2">\[2\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#sequential-stages
* <a name="fn3">\[3\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#agent
* <a name="fn4">\[4\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#parallel
* <a name="fn5">\[5\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#post
* <a name="fn6">\[6\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#when
* <a name="fn7">\[7\]</a>: https://jenkins.io/doc/book/pipeline/syntax/#options
* <a name="fn8">\[8\]</a>: https://wiki.jenkins-ci.org/display/JENKINS/Lockable+Resources+Plugin
* <a name="fn9">\[9\]</a>: https://jenkins.io/doc/pipeline/steps/workflow-durable-task-step/#sh-shell-script
* <a name="fn10">\[10\]</a>: https://jenkins.io/doc/pipeline/tour/tests-and-artifacts/
* <a name="fn10">\[11\]</a>: https://jenkins.io/doc/pipeline/steps/ws-cleanup/#workspace-cleanup-plugin

