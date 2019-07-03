#!/bin/bash

log=/var/log/mkcloud-testbuild-cleanup.log
echo "Started mkcloud testbuild cleanup at `date`" >> $log

pushd /srv/nfs/mkcloud >/dev/null
(
    # find obsolete builds
    for i in $(ls -1t | cut -d: -f1-3 | sort | uniq | grep ":"); do
        ls -1trd $i:* | head -n -1
    done
    # find builds older than 30 days
    find . -maxdepth 1 -type d -mtime +30
) | sort | uniq | tee -a $log | xargs rm -rf
popd > /dev/null

datavol=/dev/vdb
usage=`df $datavol | grep $datavol | awk '{ print $5 }'`
if [[ ${usage//%/} -gt 94 ]] ; then
    # do an echo to trigger an email via cron
    echo "$datavol usage on clouddata is: $usage" >&2
fi
