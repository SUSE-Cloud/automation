ses-ansible
===========

Playbook and role for deploying SUSE Enterprise Storage 5 (SES 5) on a target
node.

## Usage:

With the inventory already in place containing one node named `ses`, run the
playbook:

```bash
cat inventory
ses ansible_ssh_host=192.168.10.11 ansible_ssh_user=root

ansible-playbook ses-install.yml
```

During the installation a system reboot may occur, in that case, after
rebooting rerun the playbook.

## Notes:

* For now it only supports a single node deployment, this is intended only for
QA/tests/development.
* By default all disks, besides the OS disk, will be zapped and used as OSD. If
3 or more OSD disks are present, ceph will be configured with `default pool replicas = min(3, <number of OSDs>)`,
otherwise `default pool replicas = 1`.
* Take a look at `roles/ses/defaults/main.yml` and `roles/setup_ses_configs/defaults/main.yml` for variables that can be overriden.
