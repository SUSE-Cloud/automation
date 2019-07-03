#!/usr/bin/env bash

# Workaround to get only the name of the job:
# https://issues.jenkins-ci.org/browse/JENKINS-39189
# When the JOB_BASE_NAME contains only in ex. "openstack-cleanvm", this
# workaround can be removed.
echo "$JOB_BASE_NAME"
main_job_name=cleanvm

sudo /usr/local/sbin/freshvm cleanvm $image
sleep 100
cloudsource=openstack$(echo $openstack_project | tr '[:upper:]' '[:lower:]')
oshead=1
set -u
set +e
scp ${automationrepo}/scripts/jenkins/qa_openstack.sh root@cleanvm:
ssh root@cleanvm "export cloudsource=$cloudsource; export OSHEAD=$oshead; export NONINTERACTIVE=1; bash -x ~/qa_openstack.sh"
ret=$?
echo "Exit code of cleanvm run: $ret"
if [ "$ret" != 0 ] ; then
    echo "The cleanvm run failed. Now trying to cleanup before we let this job fail."
    virsh shutdown cleanvm 2>/dev/null
    # wait for clean shutdown
    n=20 ; while [[ $n > 0 ]] && virsh list |grep cleanvm.*running ; do sleep 2 ; n=$(($n-1)) ; done
    virsh destroy cleanvm 2>/dev/null
    # cleanup old images
    find /mnt/cleanvmbackup -mtime +5 -type f | xargs --no-run-if-empty rm
    # backup /dev/vg0/cleanvm disk image
    file=/mnt/cleanvmbackup/${BUILD_NUMBER}-${openstack_project}-${image}.raw.gz
    gzip -c1 /dev/vg0/cleanvm > $file
    echo "End of cleanup. Now the job will fail."
    exit 1
fi

exit $ret
