# Scale cloud

This cloud is used to test upgrade procedure before performing it on ECP.
This is a very succinct description of what we currently have.

## The admin host (the gate)

* 10.84.208.1 is the host where the crowbaru1 vm is running.
* crowbar vm qcow2 image is extracted to the /dev/system/crowbaru1 lvm
* The ports 1122 and 1180 are forwarded to 10.84.208.1(crowbaru1) port 22 and 80 correspondingly.

## The crowbaru1 VM

Because of the port forwarding on the host, use this to access crowbar:
* crowbar UI: http://10.84.208.1:1180
* crowbar SSH: ssh root@10.84.208.1 -p 1122

## IPMI (bmc, ilo) for the nodes

Please use the SOCKS5 proxy on 10.84.208.1 (or any other jumphost with access to provo iLO network) to access the IPMI of the nodes
For this to work supply the -D parameter when sshing to 10.84.208.1
E.g.:

```bash
ssh -D 12345 root@10.84.208.1
```

And then configure your browser to use the corresponding SOCKS5 proxy
or use the following proxy automatic configuration script in your browser:

```javascript
function FindProxyForURL(url, host)
{
    // IPMI access
    // 192.168.10.1 - 192.168.11.254
    if (isInNet(host, "192.168.10.0", "255.255.254.0")) {
        return "SOCKS5 127.0.0.1:12345";
    }
    // 192.168.8.1 - 192.168.9.254
    if (isInNet(host, "192.168.8.0", "255.255.254.0")) {
        return "SOCKS5 127.0.0.1:12345";
    }
    return "DIRECT";
}
```

## The networking picture is worth a thousand words

![Provo Networking](../img/lab_setup_2.png "Provo Networking")

![Networking Diagram source file](../img/lab_setup_2.uxf "Provo Networking source")

The tool used for opening the diagram is called UMLet http://www.umlet.com/

## Preparing the SES/Ceph cluster
The external one-node SES/Ceph cluster for testing the scale cloud was deployed on
one of the compute-class nodes. The node was "excluded" from the pool by adding
"CEPH" comment in the all_computes.txt file.
The node needed a basic OS installed and previously deployed crowbar was (ab)used
for that. The node was discovered, installed and then forgotten in crowbar.

IP address for the SES node (192.168.120.5/21) was selected from the part of admin network
not covered by any "range" in network proposal and manually configured in
/etc/sysconfig/network/ifcfg-eth0.
This way, the cluster should be directly accessible inside the admin network.
NOTE: make sure there are no old entries in /etc/hosts file on the SES node.

After installing base OS and configuring network, SES was deployed using ansible
playbooks from: https://github.com/SUSE-Cloud/automation/tree/master/scripts/jenkins/ses/ansible
```bash
### on the admin host
zypper in git-core ansible
# if ansible is too old, try virtualenv with ansible from pip
git clone https://github.com/SUSE-Cloud/automation automation-ses
cd automation-ses/scripts/jenkins/ses/ansible
echo >> inventory # make sure there's a new line
echo 192.168.120.5 >> inventory
# remove old crowbar-based repos
ssh 192.168.120.5 "rm /etc/zypp/repos.d/*"
# prepare the node for SES deployment
ansible-playbook bootstrap-ses-node.yml
# if you get errors about sshpass, remove all lines with "ansible_password"
# from bootstrap-ses-node.yml
# deploy SES
ansible-playbook ses-deploy.yml
# if you get NTP validation errors, change the NTP server, e.g.:
#   ssh 192.168.120.5 "echo 'time_server: ntp.suse.de' >> /srv/pillar/ceph/stack/global.yml"
#   ansible-playbook ses-deploy.yml
# create users and pools for OpenStack services
ssh 192.168.120.5 salt-run openstack.integrate --out=yaml

# this should create all required resources and output a yaml file with configuration:
# example config yaml
ceph_conf:
  cluster_network: 192.168.120.0/21
  fsid: e2b3f62f-eb4d-3c70-b31c-d4017fd4a591
  mon_host: 192.168.120.5
  mon_initial_members: d8c-dc-d4-02-19-d8
  public_network: 192.168.120.0/21
cinder:
  key: AQAbBOVdAAAAABAAuHichsooXjmI4K3LWtCUmQ==
  rbd_store_pool: cloud-volumes
  rbd_store_user: cinder
cinder-backup:
  key: AQAbBOVdAAAAABAAoKDRTyppnMFmwn7e1Bi8vw==
  rbd_store_pool: cloud-backups
  rbd_store_user: cinder-backup
glance:
  key: AQAbBOVdAAAAABAAs6mxIZY0LTpxSr7ojPeQlg==
  rbd_store_pool: cloud-images
  rbd_store_user: glance
nova:
  rbd_store_pool: cloud-vms
radosgw_urls:
- http://d8c-dc-d4-02-19-d8:8080/swift/v1
```
Save this configuration as ses.yaml on the admin host. It will be later used for configuring
OpenStack services.

## Installing the cloud

These are instructions that can be used to (re)install the cloud.

### Important: power down all nodes
Remember to power off all nodes of existing cloud before re-installing. This is needed
to ensure that all interfaces with IPs assigned from this cloud's ranges are down to
avoid conflicts.

```bash
# This is all based on the upgrade-scale branch from the suse-cloud/automation repo
# See https://github.com/SUSE-Cloud/automation/upgrade-scale
# Make sure to persist all local changes to the repo to make this reproducible

### on the admin host
# everything starts in root home
cd

# get fresh version of automation scripts
rm -r automation.old
mv automation automation.old
git clone --branch=upgrade-scale https://github.com/SUSE-Cloud/automation

# setup environment
source automation/hostscripts/upgrade-scale/setup.sh
export want_ipmi_username="<ILO USER>"
export extraipmipw="<ILO PASSWORD>"
# OR
# above lines with real credentials stored in file (create this file if it's not present on the adminhost)
source ./ipmi.sh

# reset previous state
# NOTE: this is needed only if you want to rebuild the cloud from scratch. individual `*-done` files can also
# be removed from this directory to re-trigger steps selectively.
automation/hostscripts/upgrade-scale/build.sh reset

# (re)build the cloud
# this script wraps most steps required to deploy the crowbar VM and baremetal cloud nodes.
# by default it will run series of predefined "steps" which are just bash functions defined inside the script.
# it can also be used to run selected steps explicitly by passing their names as command arguments (like "reset"
# above).
# because `set -e` is used and there is currently no special error handling, the script will die on any failure.
# to retry failed step, simply run the command again. it should pick up from where it left off.
# there is currently no timeout logic for discovery/installation steps. if the script gets stuck on DDDD... or
# III....., kill the script with Ctrl+C and try again.
automation/hostscripts/upgrade-scale/build.sh

# start workloads
automation/hostscripts/upgrade-scale/build.sh workload_start

# before admin server upgrade, prepare repos
automation/hostscripts/upgrade-scale/build.sh prepare_admin_repos

# before nodes upgrade, prepare repos
automation/hostscripts/upgrade-scale/build.sh prepare_nodes_repos

# some other useful commands
# if applying proposals times out on syncmarks often, try increasing default syncmark timeout
# e.g. /opt/dell/chef/cookbooks/crowbar-pacemaker/resources/sync_mark.rb -> attribute :timeout, kind_of: Integer, default: 120
# upload modified cookbook: knife cookbook upload crowbar-pacemaker -o /opt/dell/chef/cookbooks

# list compute nodes sorted by number of running instances
nova --all-tenants --insecure list --fields id,host,status | grep ACTIVE | awk '{print $4}' | sort | uniq -c | sort -n

# generate VMs/node histogram data (line format: <number of nodes> <number of VMs>)
nova --all-tenants --insecure list --fields id,host,status | grep ACTIVE | awk '{print $4}' | sort | uniq -c | sort -n | awk '{print $1}' | sort | uniq -c

# remove all instances from least loaded compute node
nova --insecure list --fields id,host,status | grep ACTIVE | awk '{print $4}' | sort | uniq -c | sort -n | head -n1 | awk '{print $2}' | \
  xargs nova --insecure list --host | grep ACTIVE | awk '{print $2}' | xargs -i nova --insecure delete {}

# collect logs and etc from all nodes (on adminhost)
ssh crowbaru1 crowbarctl node list --plain | cut -d' ' -f1 | xargs -i ssh crowbaru1 host {} | \
  while read host h a ip; do mkdir -p $host;echo $host; rsync -e "ssh -o StrictHostKeyChecking=no" -avz $ip:/var/log :/etc $host; done

# roughly estimate write performance of local storage on all nodes
crowbarctl node list --plain | cut -d' ' -f2 | xargs -i ssh {} "echo -n {}\ ;dd bs=4096k count=250 if=/dev/zero of=/tmp/ddtemp oflag=direct 2>&1 |grep copied;rm -rf /tmp/ddtemp"

# @crowbar: download link from https://support.hpe.com/hpsc/swd/public/detail?swItemId=MTX_04bffb688a73438598fef81ddd
wget https://downloads.hpe.com/pub/softlib2/software1/pubsw-linux/p1857046646/v114618/hpssacli-2.40-13.0.x86_64.rpm -P /srv/tftpboot

# install hpssacli on all nodes (put it in /srv/tftpboot on crowbar node before)
crowbarctl node list --plain | cut -d' ' -f1 | grep -v crowbar | xargs -i sh -c "echo {}; ssh {} rpm -i http://192.168.120.10:8091/hpssacli-2.40-13.0.x86_64.rpm"

# fetch current storage configs and store in per-node files
crowbarctl node list --plain | cut -d' ' -f1 | grep -v crowbar | xargs -i sh -c "echo {}; ssh {} hpssacli ctrl all show config detail > {}.txt"

# reconfigure all DISCOVERED nodes to 2x2 RAID0 (this is done via running sleshammer image)
crowbarctl node list --plain | grep pending$ | cut -d' ' -f1 | grep -v crowbar | \
  xargs -i sh -c "echo {}; ssh {} 'hpssacli ctrl slot=2 delete forced override; \
  hpssacli ctrl slot=2 create type=ld drives=1I:1:1,1I:1:2 raid=0 forced; \
  hpssacli ctrl slot=2 create type=ld drives=all raid=0 forced'"


# maybe needed: export/update the barclamp batch files
# TODO: update this part to include proper list of barclamps
#count=0; for bc in ipmi pacemaker nfs_client database rabbitmq keystone glance cinder neutron tempest; do echo $bc; crowbar batch export $bc > batch-exports1/`printf "%02i" ${count}`_${bc}.batch; (( count++ )); done
```

## NOTES:
Add nodes in batches not all at once. dhcp pool for discovery has limited capacity
and some nodes can fail to boot. After nodes are allocated and installed, they
receive IPs from different pool and the ones used during discovery are released.
Another reason to follow "discovery, allocate, discovery, ..." workflow is that
each node kept in discovered mode uses one NFS connection to admin server. By
default there can be 140 connections. To increase this limit, set
`USE_KERNEL_NFSD_NUMBER="10"` in `/etc/sysconfig/nfs` and run `rcnfsserver restart`
(check https://www.novell.com/support/kb/doc.php?id=7010903 for more details).
