#!/bin/bash
# NOTE: remove state dir to do a full clean run instead of starting from last failure
STATEDIR=~/.scale-cloud
: ${want_json_assignment:=0}

set -x
set -e

function reset() {
    rm -f $STATEDIR/*-done
}

function setup_host() {
    # setup environment
    source automation/hostscripts/upgrade-scale/setup.sh
    export want_ipmi_username="<ILO USER>"
    export extraipmipw="<ILO PASSWORD>"
    # OR
    # above lines with real credentials stored in file
    source ./ipmi.sh

    # make sure lvm volume for crowbar exists
    test -e /dev/system/crowbaru1 || lvcreate -L20G system -n crowbaru1

    # remove old ssh server key (if any) to avoid errors when sshing to crowbar vm
    ssh-keygen -R 192.168.120.10
    ssh-keygen -R crowbaru1

    # disable host key verification for all hosts
    cat > ~/.ssh/config << EOL
Host *
    StrictHostKeyChecking no
EOL
    chmod 0400 ~/.ssh/config
}

function update_repo_cache() {
    # update the local cache
    automation/scripts/mkcloud prepare
}

function get_all_controllers() {
    awk '{print $2}' all_controllers.txt
}

function poweroff_all_controllers() {
    # NOTE: make sure all nodes are off to avoid IP conflicts.
    # if needed, power off the nodes
    get_all_controllers | tr -d '#' | xargs -i sh -c 'echo -n "{} "; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power off'
    # give the nodes some time to poweroff
    sleep 10
    # check the power status with:
    get_all_controllers | tr -d '#' | xargs -i sh -c 'echo -n "{} "; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power status'
}

function get_all_computes() {
    awk '{print $1}' all_computes.txt
}

function poweroff_all_computes() {
    # NOTE: make sure all nodes are off to avoid IP conflicts.
    # if needed, power off the nodes
    get_all_computes | tr -d '#' | xargs -i sh -c 'echo -n "{} "; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power off'
    # give the nodes some time to poweroff
    sleep 10
    # check the power status with:
    get_all_computes | tr -d '#' | xargs -i sh -c 'echo -n "{} "; ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power status'
}

function setup_crowbar() {
    # install the admin VM
    automation/hostscripts/gatehost/freshadminvm crowbaru1 $cloudsource
    # if crowbar VM is not reachable via ssh at this point, probably it didn't get IP assigned, fix: `systemctl restart dnsmasq` on host
    # bootstrap crowbar on the VM
    automation/scripts/mkcloud prepareinstcrowbar runupdate bootstrapcrowbar

    # these will be used later to deploy the cloud
    rsync -vr automation/hostscripts/upgrade-scale/batches 192.168.120.10:
    # fill ipmi credentials in remote copy (using variables set on host)
    ssh 192.168.120.10 sed -i -e "s/%IPMIUSER%/$want_ipmi_username/" -e "s/%IPMIPASS%/$extraipmipw/" batches/01_ipmi.yml

    # install crowbar admin node
    automation/scripts/mkcloud instcrowbar

    # apply IPMI and provisioner batch to make sure IPMI settings are discovered from the beginning and correct installation settings are used
    ssh crowbaru1 crowbar batch build batches/00_provisioner.yml
    ssh crowbaru1 crowbar batch build batches/01_ipmi.yml
}

function allocate_all_pending_nodes() {
    # allocate all pending nodes and set following boot to pxe for proper AutoYaST installation
    # NOTE: the reboot will be done as part of post-allocate action but the IPMI specification requires that the boot option overrides
    #   are cleared after ~60sec so the reboot needs to fit in this window (i.e. whole pre-reboot phase of installation can't take more
    #   than 60sec or the pxe boot override will expire).
    ssh crowbaru1 "crowbarctl node list --plain | grep pending$ | cut -d' ' -f2 | xargs -i sh -c 'echo {}; \
        crowbarctl node allocate {} && ssh -o StrictHostKeyChecking=no {} ipmitool chassis bootdev pxe'"
}

function set_controller_aliases() {
    count=0
    nodes=( `ssh crowbaru1 crowbarctl node list --plain | grep ready$ | grep "^d" | cut -d' ' -f1` )
    aliases=( "controller0 controller1 controller2 controller3 controller4 controller5 controller6" )
    for a in $aliases; do
        ssh crowbaru1 "crowbarctl node rename ${nodes[$count]} $a; \
            crowbarctl node group ${nodes[$count]} control"
        echo "${nodes[$count]} -> $a"
        (( ++count ))
    done
}

function install_controllers() {
    poweroff_all_controllers
    # give the nodes some time to poweroff
    sleep 10
    # NOTE: make sure all controllers / DL360s are set to Legacy BIOS boot mode. UEFI sometimes causes weird problems.
    # pxe boot all controller nodes listed in the ~/all_controllers.txt file
    # NOTE: this is one-time boot override, don't use options=persistent as it causes undesired side effects (e.g. switch from UEFI to Legacy boot)
    get_all_controllers | xargs -i sh -c 'echo {}; \
      ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw chassis bootdev pxe; \
      ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power on'

    # wait until nodes are discovered
    controller_count=$(get_all_controllers | wc -l | cut -d' ' -f1)
    set +x
    while [[ $(ssh crowbaru1 crowbarctl node list | grep pending -c) -lt $controller_count ]]; do sleep 10; echo -n 'D'; done
    set -x
    # check status
    ssh crowbaru1 crowbarctl node list

    # give the dns some time to update node entries
    sleep 20

    allocate_all_pending_nodes

    # wait until nodes are installed, rebooted and transition to ready
    set +x
    while [[ $(ssh crowbaru1 crowbarctl node list | grep -v -e crowbar -e unready | grep ready -c) -lt $controller_count ]]; do sleep 10; echo -n 'I'; done
    set -x
    # check status
    ssh crowbaru1 crowbarctl node list

    set_controller_aliases
}

function set_compute_aliases() {
    # set aliases for remaining compute nodes
    nodes_without_alias=( `ssh crowbaru1 crowbar machines aliases | grep ^- | sed -e 's/^-\s*//g' | grep -e ^crowbar -v` )
    count=$(ssh crowbaru1 crowbar machines aliases | grep compute | cut -d' ' -f1 | tr -d [:alpha:] | sort -n | tail -n1)
    test -z "$count" && count=0 || (( ++count ))
    for node in ${nodes_without_alias[@]}; do
        ssh crowbaru1 "crowbarctl node rename $node compute$count; \
            crowbarctl node group $node compute"
        echo "$node -> compute$count"
        (( ++count ))
    done
}

function install_first_n_computes() {
    poweroff_all_computes
    # note that n should be greater than number of non-compute nodes below plus nodes used in nova proposal (see batch files)
    n=10
    # install first n compute-class nodes for non-compute use and some initial computes
    get_all_computes | head -n$n | xargs -i sh -c 'echo {}; \
        ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw chassis bootdev pxe; \
        ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power on'
    # wait until nodes are discovered
    set +x
    while [[ $(ssh crowbaru1 crowbarctl node list | grep -v -e crowbar -e controller | grep pending -c) -lt $n ]]; do sleep 10; echo -n 'D'; done
    set -x
    # check status
    ssh crowbaru1 crowbarctl node list

    # give the dns some time to update node entries
    sleep 20

    allocate_all_pending_nodes

    # wait until nodes are installed, rebooted and transition to ready
    set +x
    while [[ $(ssh crowbaru1 crowbarctl node list | grep -v -e crowbar -e controller | grep " ready" -c) -lt $n ]]; do sleep 10; echo -n 'I'; done
    set -x
    # check status
    ssh crowbaru1 crowbarctl node list

    # pick some free (compute-class) nodes for ceph and monasca
    nodes_without_alias=( `ssh crowbaru1 crowbar machines aliases|grep ^-| sed -e 's/^-\s*//g'|grep -e ^crowbar -v` )
    count=0
    aliases=( "storage0 storage1 storage2 monasca" )
    for a in $aliases; do
        ssh crowbaru1 "crowbarctl node rename ${nodes_without_alias[$count]} $a; \
            crowbarctl node group ${nodes_without_alias[$count]} misc"
        echo "${nodes_without_alias[$count]} -> $a"
        (( ++count ))
    done

    # the rest are compute nodes
    set_compute_aliases
}

# e.g. forget_nodes pending
function forget_nodes() {
    state=$1
    echo "INFO: forgetting nodes with state: $state"
    ssh crowbaru1 "crowbarctl node list --plain | grep -v crowbar | grep \" $state$\" | cut -d' ' -f2 | xargs -i sh -c 'echo {}; crowbarctl node poweroff {}; crowbarctl node delete {}'"
    # wait until there are no nodes with given status (all were deleted)
    set +x
    while ssh crowbaru1 crowbarctl node list | grep -v crowbar | grep -q " $state$"; do sleep 10; echo -n 'F'; done
    set -x
}

# these are just aliases to be used as step overrides on the command line
function forget_nodes_pending() { forget_nodes pending; }
function forget_nodes_unknown() { forget_nodes unknown; }

# NOTE: this probably makes sense only for ECP upgrade testing (this function was not really tested)
function setup_json_assignment() {
  [[ $want_json_assignment = 1 ]] || return 0
  # manually install python-keystone-json-assignment package on all nodes which will go to 'services' cluster
  for node in controller5 controller6; do
  #  ssh $node "wget -nc http://download.suse.de/ibs/Devel:/Cloud:/7:/Staging/SLE_12_SP2/noarch/python-keystone-json-assignment-0.0.2-2.14.noarch.rpm"
  #  ssh $node "zypper -n --no-gpg-checks in -f python-keystone-json-assignment*"
    ssh crowbaru1 ssh $node zypper -n in python-keystone-json-assignment
    ssh crowbaru1 ssh $node "mkdir -p /etc/keystone; wget -nc --no-check-certificate https://w3.suse.de/~bwiedemann/cloud/user-project-map.json -O /etc/keystone/user-project-map.json"
  done
}

function apply_proposals() {
    [[ $want_json_assignment = 0 ]] && ssh crowbaru1 "rm -f batches/06b_keystone.yml"
    ssh crowbaru1 "find batches -name '*.yml' | sort | xargs -i sh -c 'crowbar batch build --timeout 3600 {} || exit 255'"
}

function save_all_known_ipmi() {
    # collect ipmi addresses of all nodes known to crowbar
    ssh crowbaru1 "crowbarctl node list --plain | cut -d' ' -f1 | grep -v crowbar | xargs -i knife node show -a crowbar_wall.ipmi.address {} | cut -d: -f2" > all_known_ipmi.txt
}

function poweroff_unknown_nodes() {
    # power off all unused compute nodes
    get_all_computes | tr -d '#' | xargs -i sh -c 'grep -q {} all_known_ipmi.txt || echo {}' | xargs -i  sh -c 'echo {}; \
        ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power off'
}

function install_remaining_computes() {
    save_all_known_ipmi

    poweroff_unknown_nodes

    # give the nodes some time to poweroff
    sleep 10

    # trigger discovery of all unused compute nodes
    get_all_computes | grep -v '#' | xargs -i sh -c 'grep -q {} all_known_ipmi.txt || echo {}' | xargs -i  sh -c 'echo {}; \
        ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw chassis bootdev pxe; \
        ipmitool -I lanplus -H {} -U $want_ipmi_username -P $extraipmipw power on'

    # wait for first discovered (pending) node
    set +x
    while ! ssh crowbaru1 crowbarctl node list | grep -v -e crowbar -e controller | grep -q pending; do sleep 10; echo -n 'D'; done
    set -x
    # wait some more time to get the rest of nodes discovered (we don't know how many nodes to expect here)
    # TODO: maybe wait until all nodes are "pending" (i.e. there are no "unknown" nodes)?
    sleep 600

    allocate_all_pending_nodes

    # TODO: wait for installation to finish
    set_compute_aliases
}

function add_all_computes_to_nova() {
    add_first_n_computes_to_nova $(ssh crowbaru1 crowbarctl node list --plain | grep compute -c)
}

function add_computes_to_nova() {
    n=10
    current=$(ssh crowbaru1 crowbarctl proposal show nova default --plain | grep deployment.nova.elements.nova-compute-kvm -c)
    add_first_n_computes_to_nova $(( $current + $n ))
}

function add_first_n_computes_to_nova() {
    # add up to "$COMPUTES" computes to nova proposal
    COMPUTES=$1
    # only include "ready" nodes to not block the commit
    nodes=$(ssh crowbaru1 crowbarctl node list --plain | grep compute | grep " ready$" | sort --key=2.9 -n | cut -d' ' -f1 | head -n $COMPUTES | sed -e 's/^/"/' -e 's/$/",/' | tr -d '\n' | sed 's/,$//')
    ssh crowbaru1 "crowbarctl proposal edit nova default -m --data='{\"deployment\": {\"nova\": {\"elements\": {\"nova-compute-kvm\": [$nodes]}}}}'"
    ssh crowbaru1 crowbarctl proposal commit nova default
}

function network_stop() {
    BRIDGE=bru1

    ip link del vlan1341
    ip link set ${BRIDGE} down
    ip link set eth0 down
    ip link set eth1 down
    brctl delbr ${BRIDGE}
    ip link del bond0
}

function network_start() {
    : ${DEVICE:=eth0}

    BRIDGE=bru1

    if [[ ${DEVICE} =~ "bond" ]]; then
        ip link add bond0 type bond
        ip link set bond0 type bond mode active-backup
        ip link set eth0 down
        ip link set eth0 master bond0
        ip link set eth1 down
        ip link set eth1 master bond0
    fi

    brctl delbr ${BRIDGE}

    brctl addbr ${BRIDGE}
    brctl addif ${BRIDGE} ${DEVICE}

    ip link set ${BRIDGE} up
    ip link set ${DEVICE} up
    ip link set dev ${DEVICE} mtu 9000

    ip address add 192.168.120.1/21 dev ${BRIDGE}
    ip route add 192.168.8.0/21 via 192.168.127.254

    ip link add link ${BRIDGE} name vlan1341 type vlan id 1341
    ip link set vlan1341 up
    ip link set vlan1341 mtu 9000
    ip address add 10.84.208.1/21 dev vlan1341
    ip route add default via 10.84.215.254

    ip -d address
    ip route
}

##############################################################
# MAIN
##############################################################
setup_host

force=0
steps="
    update_repo_cache
    poweroff_all_controllers
    poweroff_all_computes
    setup_crowbar
    install_controllers
    install_first_n_computes
    setup_json_assignment
    apply_proposals
    install_remaining_computes
    add_computes_to_nova
    "

# override from CLI arguments
if [[ "$@" != "" ]]; then
    force=1
    steps=$@
fi

for step in $steps; do
    [ "$(type -t $step)" = function ] || continue
    if [[ $force = 1 ]] || [ ! -e $STATEDIR/$step-done ]; then
        echo "INFO: starting $step"
        $step
        mkdir -p $STATEDIR
        touch $STATEDIR/$step-done
        echo "INFO: finished $step"
    else
        echo "INFO: skipping already done step $step"
    fi
done
