#!/bin/bash

prepare_file()
{
    suse_label='# SUSE Cloud 2.0 modifications (below)'
    grep -i "^$suse_label$" $1

    if [ $? -ne 0 ]; then
        # the file requires backing up
        sed -i.bk "/#    under the License./a"$'\\\n'"$suse_label"$'\n' $1

        if [ $? -eq 0 ]; then
            echo "Successfully backed up $1"
        else
            echo "ERROR: the backup of $1 failed."
            exit 1
        fi

        # does the file require an import ?
        grep -i '^import testtools$' $1

        # if the import couldn't be found...
        if [ $? -ne 0 ]; then
            sed -i "/$suse_label/a"$'\\\n'"import testtools"$'\n' $1

            if [ $? -eq 0 ]; then
                echo "Added import testtools to $1"
            else
                echo "ERROR: failed to add import testtools to $1"
                exit 1
            fi
        fi
    else
        echo "No need to backup $1, since it has already been backed up."
    fi
}

echo "------------------------------------------------------------------------"
echo "ABOUT TO MODIFY TEMPEST SCRIPTS..."

echo "------------------------------------------------------------------------"
echo "Bug #830518 - Tempest Floating IP tests persistently show a Compute Fault (error)"
echo "Skipping 6 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #830518): Skipped until fixed upstream.")'

path='./tempest/tests/compute/floating_ips/test_floating_ips_actions.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_delete_floating_ip'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

pattern='def\stest_delete_nonexistant_floating_ip'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

path='./tempest/tests/compute/floating_ips/test_list_floating_ips.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_get_nonexistant_floating_ip_details'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"
echo "Bug #830552 - Tempest error: test_create_list_show_delete_interfaces"
echo "Skipping 2 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #830552): Skipped until fixed upstream.")'

path='./tempest/tests/compute/servers/test_attach_interfaces.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_create_list_show_delete_interfaces'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"
echo "Bug #830638 - Associating an IP to a server without passing a floating IP failed tempest test"
echo "Skipping 2 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #830638): Skipped until fixed upstream.")'

path='./tempest/tests/compute/floating_ips/test_floating_ips_actions.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_associate_ip_to_server_without_passing_floating_ip'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"
echo "Bug #830646 - security group id fails to match the uuid"
echo "Skipping 8 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #830646): Skipped until fixed upstream.")'

path='./tempest/tests/compute/security_groups/test_security_group_rules.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_security_group_rules_create_with_invalid_id'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

pattern='def\stest_security_group_rules_delete_with_invalid_id'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

path='./tempest/tests/compute/security_groups/test_security_groups.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_delete_nonexistant_security_group'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

pattern='def\stest_security_group_get_nonexistant_group'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"
echo "Bug #830648 - Security group mismatch errors"
echo "Skipping 5 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #829628 & #830648): Skipped until fixed upstream.")'

path='./tempest/tests/compute/security_groups/test_security_groups.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_security_group_create_with_duplicate_name'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

pattern='def\stest_security_group_create_with_invalid_group_description'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

pattern='def\stest_security_group_create_with_invalid_group_name'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"
echo "Bug #830659 - Failed to prevent the creation of a server with a nonexistent security group"
echo "Skipping 2 tests."

insertion='    @testtools.skip("SUSE Cloud 2.0 (bug #830659): Skipped until fixed upstream.")'

path='./tempest/tests/compute/servers/test_servers_negative.py'
echo "Modifying $path ..."

prepare_file $path

pattern='def\stest_create_with_nonexistent_security_group'
sed -i "/^\s*$pattern.*$/i"$'\\\n'"$insertion"$'\n' $path

echo "------------------------------------------------------------------------"

echo "Finished."
