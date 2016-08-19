MkCloud Runs
------------

# Description

Run multiple copies of various scenarios of SUSE OpenStack Cloud product
using mkcloud ([automation repository](https://github.com/SUSE-Cloud/automation)).

This repository is basically a wrapper which automates the boilerplate required
to start mkcloud with the right configuration settings. Even for non-beginners
this boilerplate wrapper script should be really handy due to the overwhelming
amount of configuration options and environment variables used by mkcloud :|.

- Inspiration:
    > I'm just too lazy.
- The perfect world:
    > We do not need these scripts!

# Deploying SUSE CLoud

Follow these steps to deploy the required SUSE Cloud setup.

## Initial Setup

* Clone the repository
* Setup up libvirt, KVM,LVM as per the automation repo, follow [this link](https://github.com/dguitarbite/automation/blob/master/docs/mkcloud.md)
* Create a LVM drive either using dd or give it one partition from your disk
drive.
* Create PV and VG give the VG name in the config file.

### Libvirt

* Check if `libvirtd` is running and if it isn't start it.

  ```
  $ sudo systemctl status libvirtd.service # to check the status
  $ sudo systemctl start libvirtd.service # to start the daemon
  ```

  It's recommended to configure libvirtd to start on boot.
    ```
    $ sudo systemctl enable libvirtd.service
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

### Setup storage for mkcloud.

#### Using file as a disk.

*Note:* Skip this step if you have a dedicated partition or disk for LVM.

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

* Check the location of the loop device. Something like `/dev/loop0`.
  ```
  $ sudo losetup
  ```

* Set the `cloudpv` variable in (mkcloudrun)[mkcloudrun] script for using this disk.
  - Ex: export cloudpv=/dev/loop0
  - Replace /dev/loop0 with your LVM partition if you want to use a dedicated PV.


##Deploy SUSE Cloud

* Configure storage options in the (mkcloudrun)[mkcloudrun] script. Read the comments under LVM.
* Go to the required folder and run the script `*.mkcloud*`.
* Ex.:
    ```
    $ cd mkcloudconfig/
    $ cp template user.cloud<ver>
    $ ...
    $ cd ..; sudo ./install_suse_cloud
    ```
* Scripts are invoked in a screen sessions. The name of the screen session is taken from the name of your configuration file.
* To monitor the given cloud deployment process join the screen session:
    ```
    $ screen -ls
    $ screen -x <screen_name>
    ```
  To move around in the screen session use the command `<C-R>-a, <tab number>`.
  **Note:** The screen session are mostly invoked as root user, try to use ``sudo screen`` or access as a root user.
* Monitor the VMs via. virt-manager or virsh. Virt-manager should give you a GUI and easier to use for new users.
* After the deployment access the dashboards:
  - Crowbar/Admin Dashboard:
    + URL: `http://192.168.52.10:3000` *For DevelCloud5.mkcloud1 only*
    + User: `crowbar` Pass: `crowbar`
  - OpenStack Dashboard:
    + URL: `http://192.168.52.81` *For DevelCloud5.mkcloud1 only*
    + Admin User: `admin` Pass: `crowbar`
    + OpenStack User: `crowbar` Pass: `crowbar`

##Parallel Mkclouds

* To find out the required IP addresses of the mkcloud steup, go through the
  mkcloudrun file in this folder. Usually the formual is good to guess the
required IP addresses.
* Crowbar admin IP is at xxx.10.
* Ex: For `cloud number 5` the ip for admin node is 192.168.60.10

##RoadMap

* Add basic CLI to `install_suse_cloud`.
* Modify the scripts based on others feedback and requirements.
* Fix automation repository the right way so we do not need these scripts in the first place.
