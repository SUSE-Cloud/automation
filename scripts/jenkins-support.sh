#!/bin/bash
function connect_rally_server_run_test
{
    # Connect to rally server and run tests
    ssh -T root@$rally_server "bash -s" <<'EOF'
    source setenv
    rm rally-failover-test.yml
    wget https://raw.githubusercontent.com/SUSE-Cloud/automation/master/scripts/scenarios/rally/$task
    sed -i -e "s,##net_id##,$netid," rally-failover-test.yml
    # Check if specific cloud deployemnt already exist
    if ! (rally deployment list | grep -q $cloud); then
        # Creat new cloud deployment env
        rally deployment create --filename $cloud-deployment.json --name $cloud
    else
        # Use existing deployment
        rally deployment use $cloud
    fi
    source .openrc
    # Check if jeos image already exist on cloud
    # Upload new image in case no image found
    if ! openstack image show -c name --format value $image_name; then
        wget -r -l1 --no-parent -A "SLES12-SP2-JeOS-for-OpenStack-Cloud.x86_64-1.2.0*.qcow2"  http://download.suse.de/ibs/SUSE:/SLE-12-SP2:/Update:/JeOS/images/ -O $image_name.qcow2
        openstack image create --public --disk-format qcow2 --file $image_name.qcow2 $image_name
        rm $image_name.qcow2
    fi

    # Run rally test
    rally task start "$task"

    # Generate run results output
    out_dir=/root/results
    rm -rf $out_dir
    mkdir -p /root/results
    rally task results > $out_dir/output.json
    rally task report --out=$out_dir/output.html
EOF
}
