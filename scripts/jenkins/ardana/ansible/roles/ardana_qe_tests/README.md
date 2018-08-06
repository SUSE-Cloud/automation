# ardana_qe_tests

Ansible role for running tests from [ardana-qa-tests]

### Assumptions:

1. A bash script is responsible for calling the test from the ardana-qe-tests repo
    - The ardana-qa-tests repository will be cloned by the automation at `~/ardana-qe/ardana-qe-tests`
	- The script is templated by the automation based on variables (work directory, ardana-qe-tests path) to drive its execution
	- The script can use a python interpreter from a virtual environment that will be created by the automation at `~/ardana-qe/ardana-qe-tests/{{ test_name }}/venv` this enables the installation of test dependencies into its own virtual environment
2. A work directory is created for each test (`~/ardana-qe/ardana-qe-tests/{{ test_name }}`)
3. The test execution log is saved at `~/ardana-qe/{{ test_name }}/{{ test_name }}.log`
4. If the test provides a subunit output it is saved at `~/ardana-qe/{{ test_name }}/{{ test_name }}.subunit`
5. Some tests requires creating/deleting OpenStack resources (user, project, etc) before/after its execution. This can be done by the automation using [Ansible OpenStack modules]
6. The `osrc` file for the OpenStack user created by the automation will be placed at `~/ardana-qe/{{ test_name }}/test-user.osrc`


### Adding tests:

1. Clone ardana-deploy repository:
   ```sh
   git clone https://gitlab.suse.de/flaviosr/ardana-deploy
   ```

2. Create a local branch where you will commit your changes:
   ```sh
   cd ardana-deploy
   git checkout -b ardana-qe-tests_<test_name>
   ```

3. All necessary changes will be made at the ardana_qe_tests role, go to its directory
   ```sh
   cd roles/ardana_qe_tests
   ```

4. Create a bash script template for calling the test from ardana-qe-tests and save it at `templates/tests/<test_name>.sh.j2`
Try to use predefined ansible variables whenever possible on the script template, Example:
   ```sh
   {{ ardana_qe_tests_dir }} = ~/ardana-qe/ardana-qe-tests
   {{ ardana_qe_test_work_dir }} = ~/ardana-qe/<test_name>
   ```
   Check examples at: https://gitlab.suse.de/flaviosr/ardana-deploy/tree/master/roles/ardana_qe_tests/templates/tests

5. If the test has any run filter put them at the directory `files/run_filters/<test_name>/`

6. Create the file `vars/<test_name>.yml` to define specific variables for the test, this is like the configuration file of the test.

* The following variables must be defined on it:
    * `ardana_qe_test_get_failed_cmd`: a bash command used to get a list of tests that failed from its execution log.

        Example for iverify:

        ```sh
        grep -e '^iverify.*\\.\\.\\..*FAIL' ~/ardana-qe/iverify/iverify.log || echo 'None'
        iverify.monasca ... FAIL
    	iverify.ceilometer ... FAIL
        iverify.nova_vm ... FAIL
        ```

        So, in `vars/iverify.yml` set:

        ```sh
        ardana_qe_test_get_failed_cmd: "grep -e '^iverify.*\\.\\.\\..*FAIL' {{ ardana_qe_test_log }} || echo 'None'"
        ```

    * `ardana_qe_test_get_results_cmds`: a list of bash commands to get the number of tests that passed, failed and ran from its execution log.

        Example for iverify:

        ```sh
        ardana_qe_test_get_results_cmds:
          passed: "grep -e '^iverify.*\\.\\.\\..*ok' {{ ardana_qe_test_log }} | wc -l"
          failed: "grep -e '^iverify.*\\.\\.\\..*FAIL' {{ ardana_qe_test_log }} | wc -l"
          ran: "grep -e '^iverify.*\\.\\.\\..*' {{ ardana_qe_test_log }} | wc -l"
        ```

    * If the test requires the creation OpenStack resources you must define `os_resources_requires` variable with the resources needed. Example:

        If a test needs a user and project, `os_resources_requires` should be defined as:

        ```sh
        os_resources_requires:
    	  - "user"
    	  - "project"
        ```

        Those resources will be created/deleted by the automation.

    * If the test requires any dependency to be installed on its virtual environment set `ardana_qe_test_venv_requires` with the list list of dependencies. Example:

        ```sh
        ardana_qe_test_venv_requires:
          - 'pymysql'
          - 'python-subunit'
        ```

	    Those packages will be installed on the test virtual environment by the automation.

    Check examples at: https://gitlab.suse.de/flaviosr/ardana-deploy/tree/master/roles/ardana_qe_tests/vars

7. Commit and push your changes:

    ```sh
    git commit -A
    git commit -m "Added support for <test_name> on ardana_qe_tests role"
    git push --set-upstream origin ardana-qe-tests_<test_name>
    ```

8. At this point you can test your changes by using jenkins to run your test (you should set `ardana_deploy_branch: ardana-qe-tests_<test_name>` on the jenkins job)

9. After pushing your branch a message will show a link for opening a merge request on gitlab, open the link on your browser.

10. On gitlab create the merge request (a good practice is to assign someone to review and merge it)

11. If the change is not urgent wait for someone to review and merge, otherwise you can merge it by yourself.


   [ardana-qa-tests]: <http://git.suse.provo.cloud/cgit/ardana/ardana-qa-tests/>
   [Ansible OpenStack modules]: <https://docs.ansible.com/ansible/latest/modules/list_of_cloud_modules.html#openstack>
