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
mv automation automation.old
git clone --branch=upgrade-scale https://github.com/SUSE-Cloud/automation
# use that before the PR is merged
#git clone --branch=upgrade-scale-scenario https://github.com/skazi0/automation

# setup environment
source automation/hostscripts/upgrade-scale/setup.sh
export want_ipmi_username="<ILO USER>"
export extraipmipw="<ILO PASSWORD>"

# make sure lvm volume for crowbar exists
test -e /dev/system/crowbaru1 || lvcreate -L20G system -n crowbaru1

# remove old ssh server key (if any) to avoid errors when sshing to crowbar vm
ssh-keygen -R 192.168.120.10

# update the local cache
automation/scripts/mkcloud prepare
# install the admin VM
automation/hostscripts/gatehost/freshadminvm crowbaru1 GM7+up
# if crowbar VM is not reachable via ssh at this point, probably it didn't get IP assigned, fix: `systemctl restart dnsmasq` on host
# bootstrap crowbar on the VM
automation/scripts/mkcloud prepareinstcrowbar runupdate bootstrapcrowbar

# upload latest batch files from automation repo to crowbar vm (they will land in /root/batches)
# these will be used later to deploy the cloud
rsync -vr automation/hostscripts/upgrade-scale/batches 192.168.120.10:
# fill ipmi credentials in remote copy (using variables set on host)
ssh 192.168.120.10 sed -i -e "s/%IPMIUSER%/$want_ipmi_username/" -e "s/%IPMIPASS%/$extraipmipw/" batches/00_ipmi.yml

### on crowbar VM
# we need updated packages
#wget -nc http://download.suse.de/ibs/Devel:/Cloud:/7/SLE_12_SP2/noarch/sleshammer-x86_64-0.7.0-0.38.9.noarch.rpm
#wget -nc http://download.suse.de/ibs/Devel:/Cloud:/Shared:/Rubygem/SLE_12_SP2/x86_64/rubygem-chef-10.32.2-27.1.x86_64.rpm
#wget -nc http://download.suse.de/ibs/Devel:/Cloud:/Shared:/Rubygem/SLE_12_SP2/x86_64/ruby2.1-rubygem-chef-10.32.2-27.1.x86_64.rpm
#zypper in -n -f sleshamm* ruby*

# we need some crowbar-core patches
# 1299: Stable 4.0 bsc1054081 by toabctl
# 1297: Avoid crashing chef on listing 'installing' nodes (bsc#1050278) by toabctl
# 1301: provisioner: Wait for admin server after net restart (bsc#1054191) by toabctl
# 1304: Bootdisk detection: Skip cciss, prefer wwn's by toabctl
# 1320: dhcp fix for UEFI (bsc#961536) by toabctl
# 1262: [stable/4.0] ipmi: Add support for bmc_interface (bsc#1046567) by s-t-e-v-e-n-k
# 1321: Properly pass command args to bmc_cmd by toabctl
#zypper -n in patch
#pushd /opt/dell
#for github_pr in 1299 1297 1301 1304 1320 1262 1321; do
#    wget -q https://github.com/crowbar/crowbar-core/pull/$github_pr.patch
#    patch -p1 < $github_pr.patch
#done

### on the admin host
# install crowbar admin node
automation/scripts/mkcloud instcrowbar

### on the crowbar VM
# install patched barclamp
barclamp_install.rb --rpm core
rccrowbar restart

# apply IPMI batch to make sure IPMI settings are discovered from the beginning
crowbar batch build batches/00_ipmi.yml


### on the admin host

# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# TODO: install controller nodes first to avoid picking them for storage or compute needs
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

# pxe boot all nodes listed in the ~/all_machines_ipmi_addresses.txt file
# NOTE: this is one-time boot override, don't use options=persistent as it causes undesired side effects (e.g. switch from UEFI to Legacy boot)
cut -d: -f2 all_machines_ipmi_addresses.txt | xargs -i sh -c 'echo {}; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw chassis bootdev pxe; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power reset'
# NOTE: nodes which are in "off" state will not power on after this command. you can check the power status with:
cut -d: -f2 all_machines_ipmi_addresses.txt | xargs -i sh -c 'echo {}; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power status'
# wait until nodes are discovered

### on the crowbar VM

# allocate all pending nodes and set following boot to pxe for proper AutoYaST installation
# NOTE: the reboot will be done as part of post-allocate action but the IPMI specification requires that the boot option overrides
#   are cleared after ~60sec so the reboot needs to fit in this window (i.e. whole pre-reboot phase of installation can't take more
#   than 60sec or the pxe boot override will expire).
crowbarctl node list --plain | grep pending$ | cut -d' ' -f2 | xargs -i sh -c 'echo {}; crowbarctl node allocate {} && ssh -o StrictHostKeyChecking=no {} ipmitool chassis bootdev pxe'

# wait until nodes are installed, reboot and transition to ready

# set aliases
# controller-class nodes first
count=0
nodes=( `crowbarctl node list --plain | grep ready$ | grep "^d" | cut -d' ' -f1` )
aliases=( "controller0 controller1 controller2 controller3 controller4 controller5 controller6 controller7" )
for a in $aliases; do
    crowbarctl node rename ${nodes[$count]} $a
    echo "${nodes[$count]} -> $a"
    (( count++ ))
done

# pick some compute-class nodes for ceph and monasca
nodes_without_alias=`crowbar machines aliases|grep ^-| sed -e 's/^-\s*//g'|grep -e ^crowbar -v`
count=0
aliases=( "storage0 storage1 storage2 monasca" )
for a in $aliases; do
    crowbarctl node rename ${nodes_without_alias[$count]} $a
    echo "${nodes_without_alias[$count]} -> $a"
    (( count++ ))
done

# the rest are compute nodes
nodes_without_alias=`crowbar machines aliases|grep ^-| sed -e 's/^-\s*//g'|grep -e ^crowbar -v`
count=0
for node in $nodes_without_alias; do
    crowbarctl node rename $node "compute$count"
    echo "${nodes_without_alias[$count]} -> compute$count"
    (( count++ ))
done

# we need some more patches for the OpenStack barclamps
# 1142: [4.0] keystone: fix ha race condition during default objects creation by stefannica
#pushd /opt/dell
#for github_pr in 1142; do
#    wget -q https://github.com/crowbar/crowbar-openstack/pull/$github_pr.patch
#    patch -p1 < $github_pr.patch
#done
#popd

#barclamp_install.rb --rpm openstack
#rccrowbar restart

# use "crowbar batch build XX_X.yml" to build the cloud
find batches -name '*.yml' | sort | xargs -i sh -c 'crowbar batch build {} || exit 255'

# the cloud should be ready now for adding more nodes

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
