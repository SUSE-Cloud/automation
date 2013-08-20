#!/bin/bash

tstamp=$(date +%s)

mkdir mkcloud-crowbar-logs-$tstamp
cd  mkcloud-crowbar-logs-$tstamp
for i in `crowbar machines list`; do echo $i; mkdir -p $i/chef; scp root@$i:/var/log/chef/* $i/chef; done
for i in `crowbar machines list`; do echo $i; mkdir -p $i/ceph; scp root@$i:/var/log/ceph/* $i/ceph; done
for i in `crowbar machines list`; do echo $i; mkdir -p $i/nova; scp root@$i:/var/log/nova/* $i/nova; done
for i in `crowbar machines list`; do echo $i; mkdir -p $i/glance; scp root@$i:/var/log/glance/* $i/glance; done
for i in `crowbar machines list`; do echo $i; mkdir -p $i/keystone; scp root@$i:/var/log/keystone/* $i/keystone; done

for i in `crowbar machines list`; do echo $i; knife node show -l $i > $i.node; done

cp -av /opt/dell/crowbar_framework/log/ /var/log/crowbar/chef-client .
cd ..

tar cvjf mkcloud-crowbar-logs-$tstamp.tar.bz2 mkcloud-crowbar-logs-$tstamp/


