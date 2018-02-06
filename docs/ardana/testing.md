# Ardana testing

For SOC8, Ardana is deployed in a SUSEfied version (all source come from
the internal build service).
The current testing is far away from perfect and a lot of things are missing
(eg pull request/changeset testing) but it's a first start to get a SUSEfied
Ardana environment up and running.

We currently have a [Jenkins job](https://ci.nue.suse.com/job/ardana-job/) (defined
in the [automation git](https://github.com/SUSE-Cloud/automation/blob/master/jenkins/ci.suse.de/ardana-job.yaml)
which can be used to create a new environment in the [engineering cloud](https://engcloud.prv.suse.net/).
The deployment can then be accessed via the floating IP and used for debugging.

**PLEASE DELETE YOUR ENVIRONMENT IN THE ENGCLOUD AFTER YOU ARE DONE (Jenkins job ID is in the Heat stack name)**
Otherwise we'll run into Quotas in our project.
## Prerequisites

To be able to use the Jenkins job and login to a deployed env, you need:

* the login creds for https://ci.nue.suse.com
* your public ssh key added to [the list of keys](https://github.com/SUSE-Cloud/automation/blob/master/scripts/jenkins/ardana/ansible/ssh-keys.yml) (via normal github pull requests)

## Create a new environment
Start the deployment via [Build with parameters](https://ci.nue.suse.com/job/ardana-job/build). The available parameters should be self-descriptive. Here are some best practices:

 * use your Rocket/irc nickname as ```job_name```
 * To test a custom automation repo, push to your fork and adjust ```git_automation_repo``` and ```git_automation_branch```

In the Jenkins log (also available as output in the Heat stack), the variable
```DEPLOYER_IP``` is set to the floating IP. You can login as root into the
environment then.
