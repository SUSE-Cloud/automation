#!/bin/bash

##########################################################################
# Setup devstack and run Tempest
##########################################################################

DEVSTACK_DIR="/tmp/devstack"

set -ex

function h_echo_header()
{
    local text=$1
    echo "################################################"
    echo "$text"
    echo "################################################"
}

function h_setup_extra_repos()
{
    #FIXME(toabctl): Also /etc/os-release is not available for SLES11, right!?
    local version=`grep -e "^VERSION_ID=" /etc/os-release | tr -d "\"" | cut -d "=" -f2`
    local name=`grep -e "^NAME=" /etc/os-release | cut -d "=" -f2`
    # NOTE(toabctl): This is currently needed for i.e. haproxy package.
    # This package is not available in openSUSE 13.1 but needs to be installed for lbaas tempest tests.
    zypper --non-interactive ar -f http://download.opensuse.org/repositories/Cloud:/OpenStack:/Master/${name}_${version}/Cloud:OpenStack:Master.repo
    zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
}

function h_setup_screen()
{
    cat > ~/.screenrc <<EOF
altscreen on
defscrollback 20000
startup_message off
hardstatus alwayslastline
hardstatus string '%H (%S%?;%u%?) %-Lw%{= BW}%50>%n%f* %t%{-}%+Lw%<'
EOF
}

function h_setup_devstack()
{
    zypper -n in git-core crudini
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
enable_service q-fwaas
enable_service q-lbaas

# for testing
enable_service tempest
EOF

    chown stack:stack -R $DEVSTACK_DIR
}


###################### Start running code #########################
h_echo_header "Setup"
h_setup_extra_repos
h_setup_screen
h_setup_devstack
h_echo_header "Run devstack"
sudo -u stack -i <<EOF
cd $DEVSTACK_DIR
FORCE=yes ./stack.sh
EOF
h_echo_header "Run tempest"
# FIXME(toabctl): enable the extensions for tempest
crudini --set /opt/stack/tempest/etc/tempest.conf network-feature-enabled api_extensions "provider,security-group,dhcp_agent_scheduler,external-net,ext-gw-mode,binding,agent,quotas,l3_agent_scheduler,multi-provider,router,extra_dhcp_opt,allowed-address-pairs,extraroute,metering,fwaas,service-type,lbaas,lbaas_agent_scheduler"
sudo -u stack -i <<EOF
cd /opt/stack/tempest
./run_tempest.sh -s -N -C etc/tempest.conf
EOF

exit 0
