# Installation

`mkcloud` is a script used to build a SUSE Cloud environment for development
or testing purposes.

## Obtain automation

* Get automation's sources from git:

  ```
  $ git clone https://github.com/SUSE-Cloud/automation.git
  ```

## Prepare your system

* Check if `libvirtd` is running and if it isn't start it.

  ```
  $ sudo service libvirtd status # to check the status
  $ sudo service libvirtd start  # to start the daemon
  ```

  It's recommended to configure libvirtd to start on boot.

  * For systems running systemd:
    ```
    $ sudo systemctl enable libvirtd
    ```

  * For systems running SysV:
    ```
    $ sudo chkconfig libvirtd on
    ```

### mkcloud

To use mkcloud the following additional steps are needed:

* Create a disk file where the virtual machines are going to be stored. The
  minimum recommended is 80 GB.

  ```
  $ fallocate -l 80G mkcloud.disk
  ```

* Attach the created disk file to a loop device

  ```
  $ sudo losetup -f mkcloud.disk
  ```

* Turn off the firewall, otherwise there are going to be conflicts with the
  rules added by `libvirt`.

  ```
  $ sudo service SuSEfirewall2 stop
  ```

  Disable the firewall service to prevent it from starting on boot.

  * Using systemd:
    ```
    $ sudo systemctl disable SuSEfirewall2
    ```
  * Using SysV:
    ```
    $ sudo service SuSEfirewall2 off
    ```

# Configuration

## mkcloud

`mkcloud` consists of different steps which can be run independently, provided the order is logical.

`mkcloud` can be configured using different environment variables.

To get a complete list run: `./mkcloud help`

### Additional Information

* `cloudpv`, block device used by mkcloud to put LVM partitions, these partitions
  are used to host the virtual machines. In development environments this is
  usually a loop device (e.g. `/dev/loop0`)
* `cloudsource`, defines what version of SUSE Cloud will be deployed (e.g. `susecloud4`)
* `TESTHEAD`, if this variable is set mkcloud will use `Devel:Cloud:Staging`
  repository to install and then update the system using the SUSE Cloud
  repositories (if they are available).
* `admin_node_memory` and `compute_node_memory` define the amount of memory in
  KB assigned to the admin node and the compute nodes respectively, by default
  both variables are set to 2 GB.
* `controller_node_memory` define the amount of memory in KB assigned to the controller
  node, by default are set to 4 GB.

# Usage

You can run `mkcloud` from anywhere although it is not recommended to run it directly from your git clone.

Usually it is useful to have a runtest.foo bash script to setup the environment similar to `scripts/mkcloudhost/runtestn` or the one further down in this document.

It is best to have an `exec /path/to/mkcloud` in the last line.

Using this exec instead of sourcing the environment has the big advantage that you can never forget to unset variables that will then unexpectedly influence later runs.

Furthermore your git clone will not be littered with files that are created in your working directory during a `mkcloud` run.

## Example usage

```
$ sudo env cloudpv=/dev/loop0 cloudsource=susecloud4 /path/to/mkcloud plain
```

This will create a cloud with an admin node (crowbar) and 2 nodes (1 for
compute, 1 for controller).

If you want to run `tempest` in an already created cloud you can run the
following command:

```
$ sudo /path/to/mkcloud testsetup
```

If you want to test `crowbar_register` for 1 non-crowbar node within an already deployed cloud, run:
```
sudo env nodenumberlonelynode=1 /path/to/mkcloud setuplonelynodes crowbar_register
```

## Using with local repositories

To be able to deploy a complete Cloud with `mkcloud` and without network access,
you need a couple of repositories locally synced.
The repositories are `SUSE-Cloud-SLE-11-SP3-deps` and `SUSE-Cloud-5-devel`. Depending on your
env variables, other repositories maybe needed.
The repositories can be synced with a tool called `sync-repos` (which is a SUSE internal tool).

Here's an example script you can execute to create a full cloud:

```
#!/bin/bash

# path to the locally available repositories
export localreposdir_src=/home/tom/devel/repositories/

# setup/create lvm disk
cloud_lvm_disk=/home/tom/devel/libvirt-images/develcloud5-lvm.raw
if ! [ -f $cloud_lvm_disk ] ; then
    qemu-img create -f raw $cloud_lvm_disk 100G
fi

if ! losetup -l|grep $cloud_lvm_disk; then
    export loused=`losetup -f`
    losetup $loused $cloud_lvm_disk
else
    loused=`losetup |grep -v "NAME"|grep $cloud_lvm_disk|awk '{print $1}'`
fi

export cloudpv=${loused}
export cloudsource=develcloud5
export cloud=$cloudsource
export net_fixed=192.168.150
export net_public=192.168.151
export net_admin=192.168.152
export vcpus=2

exec /path/to/mkcloud "$@"
```
