# Ardana automated CI/CD

## Jenkins pipeline implementation strategy

* move as much as possible into the Jenkinsfile definition and out of the JJB file:
  * setting the agent node
  * setting the workspace
  * setting the job name
  * post build triggers
  * downstream job triggers (part of the pipeline now)
  * NOT the parameters, because:
    1. if the parameters are configured in the Jenkinsfile, they will overwrite those in the JJB
    after the first run
    2. the automated job that resyncs the Jenkins jobs in the automation repository with those configured
    in ci.suse.de will overwrite the parameters in the Jenkinsfile
* most stages should be implemented as ansible playbook calls
* use downstream jobs for tasks that can be externalized and executed on their own
  * these jobs will have a subset of the parameters that the main pipeline job accepts
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
* the `clm_env` parameter determines a unique Jenkins workspace name, which is required to replay stages
* the `when` pipeline verb is used to conditionally skip stages (instead of checking conditions
inside the stage steps, which would show the stage as being always executed, regardless of result)

