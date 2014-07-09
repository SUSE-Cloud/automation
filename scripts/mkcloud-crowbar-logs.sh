#!/bin/bash

tstamp=$(date +%s)

mkdir mkcloud-crowbar-logs-$tstamp
cd  mkcloud-crowbar-logs-$tstamp
for i in `crowbar machines list`; do
    echo $i
    mkdir -p $i/chef
    scp root@$i:/var/log/chef/* $i/chef
    mkdir -p $i/ceph
    scp root@$i:/var/log/ceph/* $i/ceph
    mkdir -p $i/nova
    scp root@$i:/var/log/nova/* $i/nova
    mkdir -p $i/glance
    scp root@$i:/var/log/glance/* $i/glance
    mkdir -p $i/keystone
    scp root@$i:/var/log/keystone/* $i/keystone
    knife node show -l $i > $i.node
done

cp -av /opt/dell/crowbar_framework/log/ /var/log/crowbar/chef-client .
cd ..

tar cvjf mkcloud-crowbar-logs-$tstamp.tar.bz2 mkcloud-crowbar-logs-$tstamp/


