#!/bin/bash

# We can pass an argument to the function to configure ipv6
# Use ipv4 by default so we are backwards compatible
SVC_IP_VERSION=4
[[ $1 == "ipv6" ]] && SVC_IP_VERSION=6

##########################################################################
# Setup devstack and run Tempest
##########################################################################

DEVSTACK_DIR="/opt/stack/devstack"
: ${DEVSTACK_FORK:=openstack-dev}
: ${DEVSTACK_BRANCH:=master}

# if this variable is set to non-empty, the clone of devstack git
# will be set up with this gerrit review id being merged

# This allows testing with an unmerged change included. An
# empty variable disables that behavior
PENDING_REVIEW=""

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
        # Python 2.7 is scheduled for end-of-life in 2020
        # Openstack goal is to have python3 supported on the end of the T cycle
        # https://governance.openstack.org/tc/resolutions/20180529-python2-deprecation-timeline.html
        if [[ $DIST_VERSION == "15.0" ]]; then
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
        if [[ $DIST_VERSION == 12-SP3 ]]; then
            $zypper ar -f "https://download.opensuse.org/repositories/devel:/languages:/python:/backports/SLE_12_SP3/" devel_languages_python_backports  || true
            $zypper ar -f "https://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/SLE_12_SP3/" Cloud:OpenStack:Master  || true
        elif [[ $DIST_VERSION == 12-SP4 ]]; then
            $zypper ar -f "https://download.opensuse.org/repositories/devel:/languages:/python:/backports/SLE_12_SP4/" devel_languages_python_backports  || true
            $zypper ar -f "https://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/SLE_12_SP4/" Cloud:OpenStack:Master  || true
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
    if [[ $DIST_VERSION == 12-SP[34] ]]; then
        $zypper --no-gpg-checks in http://download.opensuse.org/repositories/openSUSE:/Leap:/42.3/standard/noarch/git-review-1.25.0-6.2.noarch.rpm
    fi
    $zypper in git-core which ca-certificates-mozilla net-tools git-review
    if ! getent group nobody >/dev/null; then
        $zypper in 'group(nogroup)'
    fi

    if ! modinfo openvswitch >/dev/null; then
        echo "openvswitch kernel module is not available; maybe you are" \
             "running a -base kernel?  Aborting." >&2
        exit 1
    fi

    if ! [ -e $DEVSTACK_DIR ]; then
        git clone \
            -b $DEVSTACK_BRANCH \
            https://github.com/$DEVSTACK_FORK/devstack.git \
            $DEVSTACK_DIR
    fi

    if ! hostname -f; then
        echo "You must set a hostname before running qa_devstack.sh; aborting." >&2
        exit 1
    fi

    if [[ "$PENDING_REVIEW" ]]; then
        pushd $DEVSTACK_DIR
        changerev="refs/changes/${PENDING_REVIEW: -2}/${PENDING_REVIEW}"
        # Find latest rev
        changerev=$(git ls-remote -q --refs origin "$changerev/*" | \
            egrep -o "$changerev.*" | sort -V | tail -n 1)
        git pull --no-edit origin $changerev
        popd
    fi

    # setup non-root user (username is "stack")
    (cd $DEVSTACK_DIR && ./tools/create-stack-user.sh)

    SWIFT_SERVICES="
enable_service c-bak
enable_service s-proxy
enable_service s-object
enable_service s-container
enable_service s-account"
    # Swift still broken for python 3.x
    [ "$USE_PYTHON3" = "True" ] && SWIFT_SERVICES=""
    # configure devstack
    cat > $DEVSTACK_DIR/local.conf <<EOF
[[local|localrc]]
disable_all_services
enable_service g-reg
enable_service key
enable_service n-api
enable_service c-api
enable_service g-api
enable_service mysql
enable_service tls-proxy
enable_service etcd3
enable_service q-dhcp
enable_service n-api-meta
enable_service tempest
enable_service q-l3
enable_service c-sch
enable_service n-novnc
enable_service peakmem_tracker
enable_service n-cauth
enable_service q-metering
enable_service rabbit
enable_service n-cond
enable_service q-meta
enable_service q-svc
enable_service placement-api
enable_service n-cpu
enable_service c-vol
enable_service n-obj
enable_service q-agt
disable_service horizon
enable_service cinder
enable_service n-sch
enable_service dstat
$SWIFT_SERVICES

DATABASE_PASSWORD=secretdatabase
ADMIN_PASSWORD=secretadmin
RABBIT_PASSWORD=secretrabbit
SERVICE_PASSWORD=secretservice
SWIFT_HASH=1234123412341234
SWIFT_REPLICAS=1
SWIFT_START_ALL_SERVICES=False

CINDER_PERIODIC_INTERVAL=10
LOG_COLOR=False
NOVA_VNC_ENABLED=True
NOVNC_FROM_PACKAGE=True
PUBLIC_BRIDGE_MTU=1450
VERBOSE_NO_TIMESTAMP=True

NOVNC_FROM_PACKAGE=True
RECLONE=yes

IP_VERSION=4+6
SERVICE_IP_VERSION=$SVC_IP_VERSION
HOST_IP=127.0.0.1
HOST_IPV6=::1
LOGFILE=stack.sh.log
LOGDAYS=1
SCREEN_LOGDIR=/opt/stack/logs
LOG_COLOR=False
API_RATE_LIMIT=False
TEMPEST_ALLOW_TENANT_ISOLATION=True

USE_PYTHON3=$USE_PYTHON3
PYTHON3_VERSION=$PYTHON3_VERSION
$DEVSTACK_EXTRA_CONFIG

[[test-config|$$TEMPEST_CONFIG]]
[compute]
min_compute_nodes = 1
[[post-config|$$NEUTRON_CONF]]
[DEFAULT]
global_physnet_mtu = 1450
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
./stack.sh
EOF
h_echo_header "Run tempest"

if [ -z "${DISABLE_TEMPESTRUN}" ]; then
pip install junitxml
    sudo -u stack -i <<EOF
cd /opt/stack/tempest
tempest run --smoke --subunit | tee tempest.subunit | subunit-trace -f -n
subunit2html tempest.subunit /opt/stack/results.html
# subunit2junitxml will fail if test run failed as it forwards subunit stream result code, ignore it
subunit2junitxml tempest.subunit > /opt/stack/results.xml || true
EOF
fi

exit 0
