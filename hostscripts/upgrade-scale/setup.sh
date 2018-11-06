#!/bin/bash

export SCRIPTS_DIR=/root/automation/scripts

export mkclouddriver=physical
export net_admin=192.168.120
# see https://github.com/SUSE-Cloud/automation/blob/master/docs/mkcloud.md#using-with-local-repositories
export cache_clouddata=1
export want_cached_images=1
export debug_qa_crowbarsetup=1
export debug_mkcloud=1
export want_ldap=1
export want_all_ssl=1
export want_ssl_trusted=0
export controller_raid_volumes=2
export reposerver=provo-clouddata.cloud.suse.de
export susedownload=ibs-mirror.prv.suse.net
export architectures="x86_64"
#export cloudsource=GM8+up
#export upgrade_cloudsource=GM9+up
export cloudsource=develcloud8
export upgrade_cloudsource=develcloud9
export TESTHEAD=1
export virtualcloud=u1
export cloud=$virtualcloud
export nodenumber=6
export want_mtu_size=9000
export hacloud=1
export clusterconfig='database=3:network=2:services=2'
export want_ceilometer_proposal=0
export want_sahara_proposal=0
export want_barbican_proposal=0
export want_magnum_proposal=0
#export cephvolumenumber=3
export want_ceph=1
export want_rootpw=securepassword
export want_tempest=0
#export want_ipmi_reboot=1
#export ipmi_ip_addrs="192.168.10.105 192.168.10.110 192.168.10.111 192.168.10.112 192.168.10.212 192.168.10.213 192.168.10.226 192.168.10.236 192.168.10.238 192.168.10.240 192.168.10.241 192.168.10.242 192.168.10.248 192.168.10.251 192.168.11.4 192.168.11.30 192.168.11.36"
#export want_ipmi_username="XXX"
#export extraipmipw="XXX"
export networkingplugin=openvswitch
export networkingmode=vxlan
export want_dvr=1
export crowbar_vmname=crowbaru1
export sshkey=`cat /root/.ssh/id_rsa.pub`
export cache_dir=/var/cache/mkcloud/$cloud
export upgrade_test_stack_count=200
