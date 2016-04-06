This repository contains various scripts which SUSE uses to automate
development, testing, and CI (continuous integration) of the various
components of SUSE Cloud, i.e. OpenStack and Crowbar.

# Scripts

This project has several scripts for different automated tasks, some of them are:

* create-vm.sh, creates a fresh KVM VM via libvirt.
* crowbar-prep.sh, prepare a host for Crowbar admin node installation.
* [`/scripts/mkcloud`](docs/mkcloud.md), script used to build a SUSE Cloud environment
  for development or testing purposes.
* repochecker, try to solve runtime dependencies for a given repository

# Documentation

Find out more about configuration/usage

* [`/scripts/mkcloud`](docs/mkcloud.md)

# Contributing

This project uses the pull requests to process contributions,
[travis-ci](http://travis-ci.org/) to test that your changes are OK to be
merged.

It's recommended to read
[Contributing to Open Source on GitHub](https://guides.github.com/activities/contributing-to-open-source)
and [Forking Projects](https://guides.github.com/activities/forking) if you
want to get a better understanding of how GitHub pull requests work.

## Testing your changes

The syntax of the shell scripts is checked using
[bash8](https://pypi.python.org/pypi/bash8), you can install it running.

```
$ sudo pip install bash8
```

Once you have installed bash8 and the changes you wanted, you should check the
syntax of the shell scripts running `make test`, here is an example output of
a successful execution:

```
$ make test
cd scripts ; for f in *.sh mkcloud mkchroot jenkins/{update_automation,*.sh} ; do echo "checking $f" ; bash -n $f || exit 3 ; bash8 --ignore E010,E020 $f || exit 4 ; done
checking compare-crowbar-upstream.sh
checking create-vm.sh
checking crowbar-prep.sh
checking mkcloud-crowbar-logs.sh
checking qa_crowbarsetup.sh
checking setenv.2.sh
checking setenv.sh
checking mkcloud
checking mkchroot
checking jenkins/update_automation
checking jenkins/qa_openstack.sh
checking jenkins/qa_tripleo.sh
checking jenkins/track-upstream-and-package.sh
checking jenkins/update_tempest.sh
cd scripts ; for f in *.pl jenkins/{apicheck,jenkins-job-trigger,*.pl} ; do perl -c $f || exit 2 ; done
analyse-py-module-deps.pl syntax OK
jenkins/apicheck syntax OK
jenkins/jenkins-job-trigger syntax OK
jenkins/cloud-trackupstream-matrix.pl syntax OK
jenkins/jenkinsnotify.pl syntax OK
jenkins/openstack-unittest-testconfig.pl syntax OK
jenkins/track-upstream-and-package.pl syntax OK
```

# jenkins jobs
There are manually maintained jobs and some jobs are now using
[jenkins-job-builder](http://docs.openstack.org/infra/jenkins-job-builder/)
which defines jobs in yaml format. New jobs should always be defined
in yaml format.
To update jobs on ci.opensuse.org, run:

    jenkins-jobs --ignore-cache update scripts/jenkins/jobs-obs/

To update jobs on the SUSE internal CI, run:

    jenkins-jobs --ignore-cache update \
        scripts/jenkins/jobs-ibs/:scripts/jenkins/jobs-ibs/templates/

Both commands need a valid `/etc/jenkins_jobs/jenkins_jobs.ini` configuration.
See [`/scripts/jenkins/jenkins_jobs.ini.sample`](scripts/jenkins/jenkins_jobs.ini.sample)
