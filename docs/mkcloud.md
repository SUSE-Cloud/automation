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

`mkcloud` can be configured using different environment variables, some of
them are listed below, to get a complete list run `./mkcloud -h`

* `CVOL`, block device used by mkcloud to put LVM partitions, these partitions
  are used to host the virtual machines. In development environments this is
  usually a loop device (e.g. `/dev/loop0`)
* `cloudsource`, defines what version of SUSE Cloud will be deployed (e.g. `susecloud4`)
* `TESTHEAD`, if this variable is set mkcloud will use `Devel:Cloud:Staging`
  repository to install and then update the system using the SUSE Cloud
  repositories (if they are available).
* `ADMIN_NODE_MEMORY` and `COMPUTE_NODE_MEMORY` define the amount of memory in
  KB assigned to the admin node and the compute nodes respectively, by default
  both variables are set to 2 GB.

# Usage

Example usage

```
$ sudo env CVOL=/dev/loop0 cloudsource=susecloud4 ./mkcloud plain
```

This will create a cloud with an admin node (crowbar) and 2 nodes (1 for
compute, 1 for controller).

If you want to run `tempest` in an already created cloud you can run the
following command:

```
$ sudo ./mkcloud testsetup
```
