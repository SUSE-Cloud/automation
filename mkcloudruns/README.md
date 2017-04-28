MkCloud Runs
------------

# Description

Run multiple copies of various scenarios of SUSE OpenStack Cloud product
using [mkcloud](../scripts/mkcloud).

This directory contains a wrapper which automates the boilerplate required
to start mkcloud with the right configuration settings. Even for non-beginners
this boilerplate wrapper script should be really handy due to the overwhelming
amount of configuration options and environment variables used by mkcloud :|.

- Inspiration:
    > I'm just too lazy.
- The perfect world:
    > We do not need these scripts!

# Deploy SUSE Cloud

* Follow the instructions for installing and configuring [mkcloud](../docs/mkcloud.md).
* Configure storage options in the [SUSECloud.mkcloud](mkcloudconfig/SUSECloud.mkcloud) script. Read the comments under LVM.
  - Ex: export cloudpv=/dev/loop0
  - Replace /dev/loop0 with your LVM partition if you want to use a dedicated PV.

* Go to the [`mkcloudruns`](.) folder and run the script `install_suse_cloud`. For example,
    ```
    $ cd mkcloudruns/mkcloudconfig
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
* Monitor the VMs via virt-manager or virsh. The virt-manager GUI is easier to use for new users.
* After the deployment access the dashboards:
  - Crowbar/Admin Dashboard:
    + URL: `http://192.168.52.10:3000` *For DevelCloud5.mkcloud1 only*
    + User: `crowbar` Pass: `crowbar`
  - OpenStack Dashboard:
    + URL: `http://192.168.52.81` *For DevelCloud5.mkcloud1 only*
    + Admin User: `admin` Pass: `crowbar`
    + OpenStack User: `crowbar` Pass: `crowbar`

# Parallel Mkclouds

* To find out the required IP addresses of the mkcloud steup, go through the
  [SUSECloud.mkcloud](mkcloudconfig/SUSECloud.mkcloud) script. Usually the formula is good to guess the
  required IP addresses.
* Crowbar admin IP is at xxx.10.
* Ex: For `cloud number 5` the ip for admin node is 192.168.60.10

# Roadmap for future development

* Add basic CLI to `install_suse_cloud`.
* Modify the scripts based on others feedback and requirements.
* Fix automation repository the right way so we do not need these scripts in the first place.
