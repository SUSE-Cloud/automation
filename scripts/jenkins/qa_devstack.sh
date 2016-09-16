#!/bin/bash

##########################################################################
# Setup devstack and run Tempest
##########################################################################

DEVSTACK_DIR="/tmp/devstack"

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

    if [[ $DIST_NAME == "openSUSE_Leap" ]]; then
        $zypper ar -f http://download.opensuse.org/distribution/leap/${DIST_VERSION}/repo/oss/ Base || true
        $zypper ar -f http://download.opensuse.org/update/leap/${DIST_VERSION}/oss/openSUSE:Leap:${DIST_VERSION}:Update.repo || true
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


function h_setup_extra_repos {
    # NOTE(toabctl): This is currently needed for i.e. haproxy package (and I guess for other packages/OS-versions too)
    # This package is not available in openSUSE 13.1 but needs to be installed for lbaas tempest tests

    # NOTE(toabctl): On Cloud:OpenStack:Master, for SLE12SP1 it must be 12_SP1 (not 12-SP1 which is used in the smt-internal path). It's crazy...
    $zypper ar -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/${DIST_NAME}_${DIST_VERSION//-/_}/Cloud:OpenStack:Master.repo || true
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
    mkfs.ext3 /dev/vdb
    mkdir -p /opt/stack
    mount /dev/vdb /opt/stack
}

function h_setup_devstack {
    $zypper in git-core which
    git clone https://github.com/openstack-dev/devstack.git $DEVSTACK_DIR

    # setup non-root user (username is "stack")
    (cd $DEVSTACK_DIR && ./tools/create-stack-user.sh)
    # configure devstack
    cat > $DEVSTACK_DIR/local.conf <<EOF
[[local|localrc]]
SERVICE_TOKEN=testtoken
DATABASE_PASSWORD=test
ADMIN_PASSWORD=test
RABBIT_PASSWORD=test
SERVICE_PASSWORD=test

RECLONE=yes
HOST_IP=127.0.0.1
LOGFILE=stack.sh.log
LOGDAYS=1
SCREEN_LOGDIR=/opt/stack/logs
LOG_COLOR=False
API_RATE_LIMIT=False
TEMPEST_ALLOW_TENANT_ISOLATION=True

# use postgres instead of mysql as database
disable_service mysql
enable_service postgresql

# swift is disabled by default
#enable_service s-proxy s-object s-container s-account

# Use Neutron instead of Nova network
disable_service n-net
enable_service q-svc
enable_service q-agt
enable_service q-dhcp
enable_service q-l3
enable_service q-meta
enable_service q-metering
# vpn disabled for now. openswan required by devstack but not available in openSUSE
# enable_service q-vpn
# enable_service q-fwaas
enable_service q-lbaas
enable_plugin magnum https://git.openstack.org/openstack/magnum master
# for testing
#enable_service tempest
ENABLED_SERVICES+=,heat,h-api,h-api-cfn,h-api-cw,h-eng
IMAGE_URLS+=https://fedorapeople.org/groups/magnum/fedora-atomic-latest.qcow2
enable_plugin barbican https://git.openstack.org/openstack/barbican
EOF

    chown stack:stack -R $DEVSTACK_DIR
}


###################### Start running code #########################
h_echo_header "Setup"
h_setup_base_repos
h_setup_extra_repos
$zypper ref
h_setup_screen
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
./run_tempest.sh -s -N -C etc/tempest.conf
EOF
fi

exit 0
