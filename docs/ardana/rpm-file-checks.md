# rpm file checks

[`ardana-job`](testing.md) performs some automated checks to ensure
that Ardana doesn't mess with the filesystem inappropriately by
removing or modifying rpm-owned files, or adding files into /usr.
This is done by running `rpm -Va` and `rpm -qf` before and after
Ardana deployment (including a tempest run, if deployment succeeded),
and comparing the results.  If any tampering is discovered, `init.yml`
will fail with a helpful error.

[Whitelists](../../scripts/jenkins/cloud/ansible/files/) are used to
ignore known exceptions, some of which need to be fixed in the future.

## Testing changes to the checks

[The `test-post-deployment-checks.yml`
playbook](../../scripts/jenkins/cloud/ansible/test-post-deployment-checks.yml)
is also provided for rapid repeated testing of the post-deployment
checks, without having to deploy an entire fresh cloud each time:

-   Choose [a previous run of
    `ardana-job`](https://ci.suse.de/job/ardana-job/) to reuse for
    testing the changes.

-   Locate the `DEPLOYER_IP` from the job log.

-   `ssh` to the deployer via that IP, and find the name of the
    temporary directory used by these checks to store state.  It will
    be named something like
    `/tmp/ardana-job-rpm-verification.Si3yBCUe/`, but obviously with a
    different suffix.

-   `ssh` to the Jenkins worker used to run the job.  It will probably
    be [`cloud-swarm-ardana-ci`](https://ci.suse.de/computer/cloud-swarm-ardana-ci/).

-   `su` to the `jenkins` user.

-   `cd` to the subdirectory for the `ardana-job` run you want to
    reuse.

-   `cd automation-git`

-   Ensure this checkout of the repo has the changes you want to test.
    For example you could push your changes from your development
    machine to github, and then do:

        git fetch myremote
        git reset --hard myremote/mybranch

-   `cd scripts/jenkins/cloud/ansible/`

-   Run the following command, replacing the temporary directory with
    the one you identified above:

        ansible-playbook \
            -i hosts \
            test-post-deployment-checks.yml \
            -e verification_temp_dir=/tmp/ardana-job-rpm-verification.Si3yBCUe

