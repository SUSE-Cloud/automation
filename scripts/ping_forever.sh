#!/bin/sh
#
# The script is expected to run on admin server, takes IP as only argument.
#
# This is used for pinging given IP indefinitely (more specifically,
# until interrupted by creating /var/lib/crowbar/stop_pinging.$IP file).
#
# Originally intended for testing the instances accessibility during the Cloud upgrade.

trap '' 1

fip="$1"
LOGFILE="/var/log/ping_instance.$fip.out"

date -Iseconds > "$LOGFILE"
echo "Starting the ping of $fip" >> "$LOGFILE"

time_at_success=$(date +%s)
seconds_failing=0

while : ; do
    if [ -e "/var/lib/crowbar/stop_pinging.$fip" ]; then
        echo "Stopping the ping of $fip" >> "$LOGFILE"
        rm -f "/var/lib/crowbar/stop_pinging.$fip"
        exit 0
    fi
    if ping "$fip" -W 1 -w 1 > /dev/null ; then
        if [ "$seconds_failing" -gt "0" ]; then
            date -Iseconds >> "$LOGFILE"
            echo "$fip not available for: $seconds_failing" >> "$LOGFILE"
            seconds_failing=0
        fi
        time_at_success=$(date +%s)
    else
        time_now=$(date +%s)
        seconds_failing=$((time_now - time_at_success))
        if [ "$seconds_failing" -lt "2" ]; then
            date -Iseconds >> "$LOGFILE"
            echo "cannot reach $fip" >> "$LOGFILE"
        fi
    fi
done
