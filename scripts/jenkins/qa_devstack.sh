#!/bin/bash

##########################################################################
# Setup devstack and run Tempest
##########################################################################

DEVSTACK_DIR="/opt/stack/devstack"


# if this variable is set to non-empty, the clone of devstack git
# will be set up with this gerrit review id being merged

# This allows testing with an unmerged change included. An
# empty variable disables that behavior
PENDING_REVIEW="576798"

set -ex


zypper="zypper --gpg-auto-import-keys -n"


function h_echo_header {
    local text=$1
    echo "################################################"
    echo "$text"
    echo "################################################"
}

function h_setup_base_repos {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release

        # openSUSE Leap has a space in it's name
        DIST_NAME=${NAME// /_}
        DIST_VERSION=${VERSION_ID}

        # /etc/os-release has SLES as $NAME, but we need SLE for repositories
        if [[ $DIST_NAME == "SLES" ]]; then
            DIST_NAME="SLE"
            DIST_VERSION=${VERSION}
        fi

        # /etc/os-release has a date and string combination for Tumbleweed
        # we need only the string for repositories
        if [[ $VERSION == *"Tumbleweed"* ]]; then
            DIST_VERSION="Tumbleweed"
        fi
    fi
    USE_PYTHON3=False
    PYTHON3_VERSION=3.4

    if [[ $DIST_NAME == "openSUSE_Leap" ]]; then
        $zypper ar -f http://download.opensuse.org/distribution/leap/${DIST_VERSION}/repo/oss/ Base || true
        $zypper ar -f http://download.opensuse.org/update/leap/${DIST_VERSION}/oss/openSUSE:Leap:${DIST_VERSION}:Update.repo || true
        # Python 3.x support is quite broken atm
        if false && [[ $DIST_VERSION == "15.0" ]]; then
            USE_PYTHON3=True
            PYTHON3_VERSION=3.6
        fi
    fi

    if [[ $DIST_NAME == "openSUSE" ]]; then
        if [[ $DIST_VERSION == "Tumbleweed" ]]; then
            # Tumbleweed needs to be lower case
            dv=${DIST_VERSION,,}
            $zypper ar -f http://download.opensuse.org/${dv}/repo/oss/ Base || true
        else
            $zypper ar -f http://download.opensuse.org/distribution/${DIST_VERSION}/repo/oss/ Base || true
            $zypper ar -f http://download.opensuse.org/update/${DIST_VERSION}/${DIST_NAME}:${DIST_VERSION}:Update.repo || true
        fi
    fi

    if [[ $DIST_NAME == "SLE" ]]; then
        if [[ $DIST_VERSION == 12* ]]; then
            $zypper ar -f "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Updates/SLE-SERVER/${DIST_VERSION}/x86_64/update/" Updates || true
            $zypper ar -f "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Products/SLE-SERVER/${DIST_VERSION}/x86_64/product" Base || true
            $zypper ar -f "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Products/SLE-SDK/${DIST_VERSION}/x86_64/product" SDK || true
            $zypper ar -f "http://smt-internal.opensuse.org/repo/\$RCE/SUSE/Updates/SLE-SDK/${DIST_VERSION}/x86_64/update/" SDK-Update || true
        fi
    fi
}


function h_setup_screen {
    cat > ~/.screenrc <<EOF
altscreen on
defscrollback 20000
startup_message off
hardstatus alwayslastline
hardstatus string '%H (%S%?;%u%?) %-Lw%{= BW}%50>%n%f* %t%{-}%+Lw%<'
EOF
}

function h_setup_extra_disk {
    $zypper in e2fsprogs
    yes y | mkfs.ext4 /dev/vdb
    mkdir -p /opt/stack
    mount /dev/vdb /opt/stack
}

function h_setup_devstack {
    $zypper in git-core which ca-certificates-mozilla net-tools git-review
    $zypper in 'group(nogroup)'

    git config --global user.email root@cleanvm.ci.opensuse.org
    git config --global user.name "Devstack User"

    git clone https://github.com/openstack-dev/devstack.git $DEVSTACK_DIR
    hostname -f || hostname cleanvm.ci.opensuse.org

    if [[ "$PENDING_REVIEW" ]]; then
        pushd $DEVSTACK_DIR
        changerev="refs/changes/${PENDING_REVIEW: -2}/${PENDING_REVIEW}"
        # Find latest rev
        changerev=$(git ls-remote -q --refs origin "$changerev/*" | sort -V \
            egrep -o "$changerev.*" | tail -n 1)
        git pull --no-edit origin $changerev
        popd
    fi

    # setup non-root user (username is "stack")
    (cd $DEVSTACK_DIR && ./tools/create-stack-user.sh)

    SWIFT_SERVICES="s-account,s-container,s-object,s-proxy,"
    # Swift still broken for python 3.x
    [ "$USE_PYTHON3" = "True" ] && SWIFT_SERVICES=""
    # configure devstack
    cat > $DEVSTACK_DIR/local.conf <<EOF
[[local|localrc]]
SERVICE_TOKEN=testtoken
DATABASE_PASSWORD=test
ADMIN_PASSWORD=test
RABBIT_PASSWORD=test
SERVICE_PASSWORD=test
SWIFT_HASH=f515ae389a20420fa466f27a0779d845

RECLONE=yes
HOST_IP=127.0.0.1
LOGFILE=stack.sh.log
LOGDAYS=1
SCREEN_LOGDIR=/opt/stack/logs
LOG_COLOR=False
API_RATE_LIMIT=False
TEMPEST_ALLOW_TENANT_ISOLATION=True

USE_PYTHON3=$USE_PYTHON3
PYTHON3_VERSION=$PYTHON3_VERSION

ENABLED_SERVICES=c-api,c-bak,c-sch,c-vol,ceilometer-acentral,ceilometer-acompute,ceilometer-alarm-evaluator,ceilometer-alarm-notifier,ceilometer-anotification,ceilometer-api,ceilometer-collector,cinder,dstat,etcd3,g-api,g-reg,horizon,key,mysql,n-api,n-api-meta,n-cauth,n-cond,n-cpu,n-novnc,n-obj,n-sch,peakmem_tracker,placement-api,q-agt,q-dhcp,q-l3,q-meta,q-metering,q-svc,rabbit,$SWIFT_SERVICES,tempest,tls-proxy

# vpn disabled for now. openswan required by devstack but not available in openSUSE
# enable_service q-vpn
# enable_service q-fwaas
enable_service q-lbaas

# for testing
enable_service tempest
EOF

    chown stack:stack -R $DEVSTACK_DIR
}


###################### Start running code #########################
h_echo_header "Setup"
h_setup_base_repos
$zypper ref
h_setup_screen
trap 'killall swift-{proxy,object,container,account}-{server,updater,reconstructor,sync,reaper,replicator,auditor,sharder} 2>/dev/null || :' EXIT
# setup extra disk if parameters given
if [ -e "/dev/vdb" ]; then
    h_setup_extra_disk
fi
h_setup_devstack
h_echo_header "Run devstack"
sudo -u stack -i <<EOF
cd $DEVSTACK_DIR
FORCE=yes ./stack.sh
EOF
h_echo_header "Run tempest"
# FIXME(toabctl): enable the extensions for tempest
$zypper in crudini
crudini --set /opt/stack/tempest/etc/tempest.conf network-feature-enabled api_extensions "provider,security-group,dhcp_agent_scheduler,external-net,ext-gw-mode,binding,agent,quotas,l3_agent_scheduler,multi-provider,router,extra_dhcp_opt,allowed-address-pairs,extraroute,metering,fwaas,service-type,lbaas,lbaas_agent_scheduler"

if [ -z "${DISABLE_TEMPESTRUN}" ]; then
    sudo -u stack -i <<EOF
cd /opt/stack/tempest
tox -e smoke
EOF
fi

exit 0
