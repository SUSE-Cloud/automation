#!/bin/sh
# by Bernhard M. Wiedemann <bwiedemann suse.de>
# use via /etc/cron.d/cloud-stats
#1 10 * * 3 root /root/bin/cloud-stats.sh
if ! [ -e /usr/bin/crowbar ] ; then
    echo "this script is meant to be run on the crowbar/admin node"
    exit 2
fi

outfile=cloud-stats-$(date +%Y-%m-%d)

cd /root/
mkdir -p tmp
cd tmp || exit 3

exec 3>&1
exec > $outfile

cloud=$(hostname -f | cut -d. -f2-)
echo "This is the cloud-stats.sh reporting about $cloud"

crowbar machines list > m
echo -n "number of cloud machines: "
wc -l < m

ssh dashboard '
. .openrc
nova list --all_tenants > /dev/shm/all 2>/dev/null
echo -n "running instance VMs: "
cat /dev/shm/all | grep ACTIVE | wc -l
echo -n "stopped instance VMs: "
cat /dev/shm/all | grep SHUTOFF | wc -l

if [ -e /usr/bin/ceph ] ; then
    echo
    echo "ceph usage:"
    ceph df | grep -A1 -e SIZE -e POOLS -e images
fi
'

echo
echo "Disk and RAM usage of cloud machines (in MiB):"
for m in `cat m` ; do ssh $m "df -m / ; free -m ; echo" ; done

exec 1>&3
cat $outfile

mail -s "$cloud stats" -r bwiedemann@suse.de cloud-devel@suse.de < $outfile
