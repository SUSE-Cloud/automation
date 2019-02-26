# Ardana automated testing

Starting with SOC8, Ardana can be deployed and tested using sources coming from the 
[internal build service](https://build.suse.de/project/show/Devel:Cloud:8:Staging), 
automated through jobs running in the [ci.nue.suse.com Jenkins service](https://ci.nue.suse.com/job/openstack-ardana)
and consuming the virtualized resources in [the engineering cloud](https://engcloud.prv.suse.net/project/stacks/).
This process is implemented by the [Jenkins pipeline jobs](https://github.com/SUSE-Cloud/automation/blob/master/jenkins/ci.suse.de/pipelines)
and the [ansible playbooks](https://github.com/SUSE-Cloud/automation/blob/master/scripts/jenkins/ardana/ansible) located
in this repository.

The easiest way to experiment with an automated Ardana deployment is by [triggering a customized Ardana Jenkins job build](#deploying-and-testing-ardana-through-jenkins).
Alternatively, the same ansible playbooks called by the Ardana Jenkins jobs can be used to deploy and test Ardana independently
from Jenkins, by [setting up a local test environment](#deploying-and-testing-ardana-manually) on any host that
has access to the engineering cloud and by running the playbooks there.

## Deploying and testing Ardana through Jenkins

The [Jenkins pipeline job called `openstack-ardana`](https://ci.nue.suse.com/job/openstack-ardana/) (defined in the
[`automation` git repo](https://github.com/SUSE-Cloud/automation/blob/master/jenkins/ci.suse.de/openstack-ardana.yaml))
can be used to create a new virtual environment in the [engineering cloud](https://engcloud.prv.suse.net/) or to deploy
a bare-metal environment on one of the QA hardware clusters. The deployment can then be accessed via the IP address
allocated to the deployer node and used for debugging.

### Prerequisites

To be able to use the Jenkins job and login to a deployed environment, the following are needed:

* the cloud team login credentials for https://ci.nue.suse.com (ask in the cloud-team RocketChat channel if you don't
know what they are, and someone will PM you)
* your public ssh key added to [the list of keys](https://github.com/SUSE-Cloud/automation/blob/master/scripts/jenkins/ardana/ansible/group_vars/all/ssh_pub_keys.yml)(via normal github pull requests)

### Deploying a Jenkins Ardana environment

An Ardana deployment can be started via [Build with
parameters](https://ci.nue.suse.com/job/openstack-ardana/build). The
available parameters should be self-descriptive, but the [Customized deployments](#customized-deployments) section
will provide more information on the provided options. Here are some best
practices:

* For a virtual cloud deployment, use your Rocket/irc nickname as ```ardana_env```. If you need to deploy several Ardana setups,
  use a unique ```ardana_env``` value for each one. Note that ```ardana_env``` values starting with
  `qe` (e.g `qe101`, `qe102`) are reserved for QA baremetal deployments.
* Select a ```cleanup``` value to decide what happens with the Ardana virtual cloud deployment after the job completes
* To test a different input model other than the default `std-min`, adjust the
  ```model``` parameter in the deployment
* To test a different software media, use another `cloudsource` value. The available values and their meaning are documented
[here](../../scripts/jenkins/ardana/ansible/roles/setup_zypper_repos/README.md)
* To test a custom automation repository, push to your fork and adjust the
  ```git_automation_repo``` and ```git_automation_branch``` parameter values

The IP address allocated to the deployer node will be available in several places:
* the Jenkins job build name will be updated automatically to include it, when it becomes available
* it will be printed in the Jenkins job log in several places, e.g.:

```
10:49:22 [Prepare virtual cloud] ******************************************************************************
10:49:22 [Prepare virtual cloud] ** The deployer for the 'cloud-ardana-ci-slot1' virtual environment is reachable at:
10:49:22 [Prepare virtual cloud] **
10:49:22 [Prepare virtual cloud] **        ssh root@10.86.1.146
10:49:22 [Prepare virtual cloud] **
10:49:22 [Prepare virtual cloud] ******************************************************************************
```

* it will also be available as output [in the Heat stack](https://engcloud.prv.suse.net/project/stacks) as the
variable ```admin-floating-ip```, for virtual cloud deployments

The environment can then accessed by logging in as `root` or `ardana` and using the floating IP.


**PLEASE DELETE YOUR ENVIRONMENT IN THE ENGINEERING CLOUD AFTER YOU ARE DONE** otherwise we'll run into quota
limits in our project. Instructions on how to clean up the environment will be printed in the Jenkins job log
at the end of the run, e.g.:

```
13:34:20 ******************************************************************************
13:34:20 ** The deployer for the 'alan-turing' virtual environment is reachable at:
13:34:20 **
13:34:20 **        ssh root@10.86.1.235
13:34:20 **
13:34:20 ** Please delete the 'openstack-ardana-alan-turing' stack when you're done,
13:34:20 ** by using one of the following methods:
13:34:20 **
13:34:20 **  1. log into the ECP at https://engcloud.prv.suse.net/project/stacks/
13:34:20 **  and delete the stack manually, or
13:34:20 **
13:34:20 **  2. (preferred) trigger a manual build for the openstack-ardana-heat job at
13:34:20 **  https://ci.nue.suse.com/job/openstack-ardana-heat/build and use the
13:34:20 **  same 'alan-turing' ardana_env value and the 'delete' action for the
13:34:20 **  parameters
13:34:20 **
13:34:20 ******************************************************************************
```


### Testing a predeployed Jenkins Ardana environment

Aside from manual testing, any of the following pipeline Jenkins jobs can be manually triggered via `Build with Parameters`
to run on an Ardana environment that was previously deployed using the Ardana Jenkins jobs. The target Ardana virtual or
bare-metal environment must be indicated via the `ardana_env` parameter value:

* [openstack-ardana-qa-tests](https://ci.nue.suse.com/job/openstack-ardana-tests/build) : runs tempest or QA test cases
* [openstack-ardana-update](https://ci.nue.suse.com/job/openstack-ardana-update/build) : automates the maintenance update
workflow to install package updates on the Ardana environment
* [openstack-ardana-update-and-test](https://ci.nue.suse.com/job/openstack-ardana-update-and-test/build) : combines the two
jobs above into one pipeline


### Customized deployments

TBD:

custom cloudsource
different input model
gerrit changes
extra repositories
MUs
tempest run filter
QA test cases
  - TODO: link to adding new test cases
automation repo PR
generated input model
  - different scenario (standard, split, mid-size)
  - control number of nodes allocated to each cluster
  - integrated/standalone deployer
  - TODO: disabled services
  - TODO: link to adding new scenarios
QA physical deployment
custom automation repo fork/branch


## Deploying and testing Ardana manually

The ansible playbooks used by the Jenkins job can alternatively be executed manually from any host,
without involving Jenkins at all, to deploy and test either a virtual Ardana environment hosted in the engineering
cloud, or an Ardana QA bare-metal environment.

### Prerequisites

To be able to deploy an Ardana environment using the Ardana automation ansible playbooks, the following are needed:

* an [engineering cloud](https://engcloud.prv.suse.net) account (for virtual Ardana environments)
* your public ssh key added to [the list of keys](https://github.com/SUSE-Cloud/automation/blob/master/scripts/jenkins/ardana/ansible/group_vars/all/ssh_pub_keys.yml)(via normal github pull requests)
* a host with access to the [engineering cloud](https://engcloud.prv.suse.net) (for virtual Ardana environments)
* a host with access to the QA hardware clusters (for QA bare-metal Ardana environments)

### Test environment setup

Setting up a local Ardana test environment:

* clone the [automation repository](https://github.com/SUSE-Cloud/automation) locally
* set up an OpenStack cloud configuration reflecting your engineering cloud credentials (for virtual Ardana environments).
To do that, create an `~/.config/openstack/clouds.yaml` file with the following contents reflecting your engineering cloud account:

```
clouds:
  engcloud-cloud-ci:
    region_name: CustomRegion
    auth:
      auth_url: https://engcloud.prv.suse.net:5000/v3
      username: <your ldap user name>
      password: <your ldap password>
      project_name: cloud
      project_domain_name: default
      user_domain_name: ldap_users
    identity_api_version: 3
    cacert: /usr/share/pki/trust/anchors/SUSE_Trust_Root.crt.pem
```

* create and activate a local python virtualenv and install the following packages:
  * python-openstackclient
  * python-heatclient
  * python-neutronclient
  * ansible
  * netaddr

To verify that the test environment is properly set up:

* run an openstack CLI command, e.g.:

```
openstack --os-cloud engcloud-cloud-ci stack list
```

* run an ansible playbook, e.g.:

```
cd automation/scripts/jenkins/ardana/ansible
ansible_playbook clone-input-model.yml -e model=standard
```


### Manual Ardana deployment

TBD: how to run the ansible playbooks


## Ardana CI jobs

The majority of Ardana SUSE CI Jenkins jobs are [Jenkins pipeline jobs](https://jenkins.io/doc/book/pipeline/). These offer some
advantages over the classical job types, which are heavily exploited by the Ardana Jenkins jobs:

* better usability: a job run can be broken in stages, their pass/fail status and logs individually visualized,
especially useful in the Blue Ocean Jenkins UI
* more flexible
* TBD

### 


TBD: describe the existing jobs, their purpose, triggers,
link to the detailed pipeline description for every job.

### Prepare BM cloud

### Prepare virtual cloud

### Build test packages

### Bootstrap CLM

### Bootstrap nodes

### Deploy cloud

### Tempest

### Deploy CaaSP

## Ardana Jenkins pipelines

### Integration pipeline

Describe the pipeline job, stages, link to detail docs for various features/roles., 
Diagram with job stages/hierarchy.

### Gerrit pipeline

Prepare BM cloud


## Automated checks

Some extra checks are automatically run by the Jenkins job:

- [rpm file checks](rpm-file-checks.md)


