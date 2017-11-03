#!/bin/bash
#
# This script is expected to run on the admin (crowbar) server and will build an external
# SES cluster on a bunch of nodes. The nodes in question are passed in as arguments as are
# optionally the ceph public and cluster networks.
#
# This script is expecting the arguments in the form:
#    build_ses.sh [<public net> <cluster net>] <node 1> <node 2> [<node 3> ..]
#
# The networks are in the form:
#    1.2.3.0/24
# Or as it's used in qa_crowbarsetup.sh:
#    ${net_public}.0/24
#
# The nodes are the crowbar machine names. Because SES uses deepsea, the first node provided
# will become the salt master. So any other way of viewing the argument list of nodes are as:
#    <salt master> <salt minion> [<salt minion> ..]
#
# This script is used in the function onadmin_external_ceph by qa_crowbarsetup.sh as apart of
# the deployexternalceph step.
#
# For further ses5 install instructions on which this was based
# see: http://beta.suse.com/private/SUSE-Storage-Beta/doc/ses-manual_en/ceph.install.saltstack.html
NUM_MASTER=1
NUM_ADMIN=1
NUM_MON=3
NUM_MDS=1
NUM_IGW=0
NUM_RGW=2

ip_cidr_regex='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|[1-2][0-9]|3[0-2]))$'

if (( $# < 2 ))
then
    echo "Usage: $0 [<public_network/cidr> <cluster_network/cidr>] <salt master> <salt minion> [, <salt minion>, ..]"
    exit 1
fi

if [[ "$1" =~ $ip_cidr_regex ]]
then
    public_network=$1
    shift
    if [[ "$1" =~ $ip_cidr_regex ]]
    then
        cluster_network=$1
        shift
    fi
fi
master=$1
shift
minions=($@)

function run_ssh_cmd() {
    host=$1
    shift
    ssh $host -C "$@"
    if (( $? > 0 ))
    then
        echo "Ssh command '$@' failed on host '$host'"
        exit 2
    fi
}

function salt_setup() {
    # install salt master
    run_ssh_cmd $master "zypper -n in deepsea"
    run_ssh_cmd $master "systemctl enable salt-master.service"
    run_ssh_cmd $master "systemctl start salt-master.service"
    run_ssh_cmd $master "echo 'master: $master' > /etc/salt/minion.d/master.conf"
    run_ssh_cmd $master "sudo systemctl enable salt-minion.service"
    run_ssh_cmd $master "sudo systemctl start salt-minion.service"
    if ssh $master "[ ! -f /srv/pillar/ceph/deepsea_minions.sls.bak ]  && [ -f /srv/pillar/ceph/deepsea_minions.sls ]"
    then
        run_ssh_cmd $master "sudo cp /srv/pillar/ceph/deepsea_minions.sls /srv/pillar/ceph/deepsea_minions.sls.bak"
        cat <<EOF | ssh $master "cat > /srv/pillar/ceph/deepsea_minions.sls"
# Using the deepsea grain 'G@deepsea:*' wasn't working, so setting to all nodes.
# original file saved to /srv/pillar/ceph/deepsea_minions.sls.bak
deepsea_minions: '*'
EOF
    fi

    # install salt minion on the minions
    for minion in "${minions[@]}"
    do
        run_ssh_cmd $minion "sudo zypper -n in salt-minion"
        run_ssh_cmd $minion "sudo systemctl enable salt-minion.service"
        run_ssh_cmd $minion "echo 'master: $master' > /etc/salt/minion.d/master.conf"
        run_ssh_cmd $minion "sudo systemctl start salt-minion.service"
    done

    # Back on master, accept all the minions salt keys
    run_ssh_cmd $master "salt-key --accept-all -y"
    echo -n "waiting on keys (wait 20 times in 2 sec increments)."
    for x in $(seq 20)
    do
        if (( $(run_ssh_cmd $master "salt-key -l acc |grep -cv 'Accepted Keys:'") != $(( ${#minions[@]} + 1 )) ))
        then
            echo '.'
            run_ssh_cmd $master "salt-key --accept-all -y 2> /dev/null"
            sleep 2
        else
            echo 'done'
            break
        fi
    done
    if (( $(run_ssh_cmd $master "salt-key -l acc |grep -cv 'Accepted Keys:'") != $(( ${#minions[@]} + 1 )) ))
    then
        echo 'failed'
        exit 1
    fi
}

function rnd_sel_nodes() {
    num=$1
    shift
    local nodes
    nodes=($@)

    if (( $num >= ${#nodes[@]} ))
    then
        echo ${nodes[@]}
        return
    fi

    result=()
    while (( $num > 0 ))
    do
        rnd=$(( RANDOM % ${#nodes[@]} ))
        result=(${result[@]} ${nodes[$rnd]})
        unset nodes[$rnd]
        nodes=( ${nodes[@]} )
        let "num-=1"
    done

    echo ${result[@]}
}

function generate_policy_config() {
    pconf="/srv/pillar/ceph/proposals/policy.cfg"

    cat <<EOF | ssh $master "cat > $pconf"
# cluster assignment
cluster-ceph/cluster/*.sls

# Role assignment
EOF

    # Need to assign roles
    # masters
    run_ssh_cmd $master "echo 'role-master/cluster/${master}.sls' >> $pconf"
    if (( $NUM_MASTER > 1 ))
    then
        masters=( $(rnd_sel_nodes $(($NUM_MASTER -1)) ${minions[@]}) )
        for mas in ${masters[@]}
        do
            run_ssh_cmd $master "echo 'role-master/cluster/${mas}.sls' >> $pconf"
        done
    fi
    # admins
    run_ssh_cmd $master "echo 'role-admin/cluster/${master}.sls' >> $pconf"
    if (( $NUM_ADMIN > 1 ))
    then
        admins=( $(rnd_sel_nodes $(($NUM_ADMIN -1)) ${minions[@]}) )
        for ad in ${admins[@]}
        do
            run_ssh_cmd $master "echo 'role-admin/cluster/${ad}.sls' >> $pconf"
        done
    fi
    # Monitors
    mons=( $(rnd_sel_nodes $NUM_MON $master ${minions[@]}) )
    for mon in ${mons[@]}
    do
        cat <<EOF | ssh $master "cat >> $pconf"
role-mon/stack/default/ceph/minions/${mon}.yml
role-mon/cluster/${mon}.sls
EOF
    done
    # mgrs (ses5 only) - runs on the mon nodes
    if ssh $master "[ -d $(dirname $pconf)/role-mgr ]"
    then
        for mon in ${mons[@]}
        do
            run_ssh_cmd $master "echo 'role-mgr/cluster/${mon}.sls' >> $pconf"
        done
    fi
    # mds
    mds=( $(rnd_sel_nodes $NUM_MDS $master ${minions[@]}) )
    for md in ${mds[@]}
    do
        run_ssh_cmd $master "echo 'role-mds/cluster/${md}.sls' >> $pconf"
    done
    # Iscsi gateways
    igws=( $(rnd_sel_nodes $NUM_IGW $master ${minions[@]}) )
    for igw in ${igws[@]}
    do
        cat <<EOF | ssh $master "cat >> $pconf"
role-igw/stack/default/ceph/minions/${igw}.yml
role-igw/cluster/${igw}.sls
EOF
    done
    # Rados gateways
    rgws=( $(rnd_sel_nodes $NUM_RGW $master ${minions[@]}) )
    for rgw in ${rgws[@]}
    do
        run_ssh_cmd $master "echo 'role-rgw/cluster/${rgw}.sls' >> $pconf"
    done

    cat <<EOF | ssh $master "cat >> $pconf"
# common configuration
config/stack/default/global.yml
config/stack/default/ceph/cluster.yml

# profile assignment
EOF

    # Need to assign profiles, we'll just add whatever was found
    for profile in $(ssh $master "find $(dirname $pconf) -name 'profile*'")
    do
        profile=$(echo $profile |sed "s#^$(dirname $pconf)/##g")
        cat <<EOF | ssh $master "cat >> $pconf"
$profile/cluster/*.sls
$profile/stack/default/ceph/minions/*.yml
EOF
    done
}

function install_ses() {
    echo "== run stage 0 (prep) =="
    # Note: we don't use run_ssh_cmd because a reboot during prep returns a > 0 errorcode.
    ssh $master "salt-run state.orch ceph.stage.prep"
    prep_return=$?

    # there is a chance the nodes will reboot so ping check them
    if (( $prep_return > 0 ))
    then
        # wait a big for the nodes to shutdown.
        sleep 10
    fi
    for hn in $master ${minions[@]}
    do
        echo "Attempting to ssh to $hn"
        ip_good=0
        for i in $(seq 60)
        do
            ssh $hn "zypper --gpg-auto-import-keys ref -f"
            if (( $? == 0 ))
            then
                ip_good=1
                # refresh repoistories after the reboot, as cloud repo can update key.
                ssh $hn "zypper --gpg-auto-import-keys ref -f"
                break
            fi
            sleep 2
        done
        if (( ip_good == 0 ))
        then
            echo "failed to contact $hn"
            exit 3
        fi
    done
    if (( $prep_return > 0 ))
    then
        # prep stage might have needed to reboot, so need to run it a second time
        echo "== run stage 0 (prep) - take 2 =="
        run_ssh_cmd $master "salt-run state.orch ceph.stage.prep"
    fi

    echo "== run stage 1 (discovery) ==" # - collect data from the nodes
    run_ssh_cmd $master "salt-run state.orch ceph.stage.discovery"

    echo "== generate policy.cfg ==" # from data found during discovery
    generate_policy_config

    echo "== run stage 2 (configure) =="
    run_ssh_cmd $master "salt-run state.orch ceph.stage.configure"

    echo "== Setting networks =="
    if [[ -n "$public_network" ]]
    then
        echo "public_network: $public_network"
        cat <<EOF | ssh $master "cat >> /srv/pillar/ceph/stack/ceph/cluster.yml"
public_network: $public_network
EOF
        if [[ -n "$cluster_network" ]]
        then
            echo "cluster_network: $cluster_network"
            cat <<EOF | ssh $master "cat >> /srv/pillar/ceph/stack/ceph/cluster.yml"
cluster_network: $cluster_network
EOF
        fi
    fi

    # there seems to be a bug, sometimes during deploy osd.deploy fails. Restarting the salt minions
    # fixes it, so the minions must not get synced or confused. So now we give them a restart.
    run_ssh_cmd $master "salt '*' cmd.run 'rcsalt-minion restart'"

    echo "== run stage 3 (deploy) =="
    run_ssh_cmd $master "salt-run state.orch ceph.stage.deploy"

    # Check the chef status, for those watching at home
    run_ssh_cmd $master "ceph -s"

    echo "== run stage 4 (services) ==" # - generate keyrings, start services etc.
    run_ssh_cmd $master "salt-run state.orch ceph.stage.services"
}

salt_setup
install_ses

