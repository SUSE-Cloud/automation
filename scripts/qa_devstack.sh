#!/bin/bash

##########################################################################
# Setup devstack and run Tempest
##########################################################################

set -ex

function h_echo_header()
{
    local text=$1
    echo "################################################"
    echo "$text"
    echo "################################################"
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
    zypper --non-interactive in git
    # FIXME(toabctl): Use upstream devstack when needed patches are merged!
    git clone -b devstack-opensuse131 https://github.com/toabctl/devstack.git
    # configure devstack
    cat > devstack/local.conf <<EOF
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

# for testing
enable_service tempest
EOF
}


###################### Start running code #########################
h_echo_header "Setup"
h_setup_screen
h_setup_devstack
h_echo_header "Run devstack"
(cd devstack && FORCE=yes ./stack.sh)
h_echo_header "Run tempest"
(cd /opt/stack/tempest && ./run_tempest.sh -s -N -C etc/tempest.conf)

exit 0
