#!/usr/bin/env bash
#
# Usage, e.g.:
#
#    SSHPASS=myrootpass sshpass ssh-copy-id root@myserver
#


# This script functions both as the SSH wrapper and the SSH_ASKPASS script
# at the same time
if [ -n "$SSH_ASKPASS_PASSWORD" ]; then
    cat <<< "$SSH_ASKPASS_PASSWORD"
else
    SSH_ASKPASS_PASSWORD="$SSHPASS"
    export SSH_ASKPASS_PASSWORD

    sshopts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=20 -oConnectTimeout=5  -oNumberOfPasswordPrompts=1"
    sshcmd=$1

    shift

    DISPLAY=dummydisplay:0 SSH_ASKPASS=$0 setsid $sshcmd $sshopts "$@"
fi