#!/bin/sh
echo 'this assumes you have applied "adminhost" rules from gitlab@gitlab.suse.de:cloud/cloudsalt.git provo branch
using salt-ssh adminhost state.highstate'

grep -q salt /etc/motd || { echo "error: salt not applied" ; exit 74; }

for vm in crowbarp2 ; do
    virsh define $vm.xml
    virsh start $vm
    virsh autostart $vm
done

sleep 100 # TODO waitfor ssh
echo "default root password is linux"
ssh-copy-id crowbarp2.cloud.suse.de.
cp -a ~/.ssh/authorized_keys{,.pub}
ssh-copy-id -i ~/.ssh/authorized_keys crowbarp2.cloud.suse.de.
rm ~/.ssh/authorized_keys.pub
