# Installation

`mkcloud` is a script used to build a SUSE Cloud environment for development
or testing purposes.

It requires SLE-12 or openSUSE Leap 42.2 or newer as host OS.

## Obtain automation

* Get automation's sources from git:

  ```
  $ git clone https://github.com/SUSE-Cloud/automation.git
  ```

## Prepare your system

* Install `libvirt` if not present on the system

  ```
  $ sudo zypper install libvirt
  ```

* Check if `libvirtd` is running and if it isn't start it.

  ```
  $ sudo service libvirtd status # to check the status
  $ sudo service libvirtd start  # to start the daemon
  ```

  If you are using `libvirtd >= 1.3.0` then you should also start the
  `virtlogd` service.

  ```
  $ sudo service virtlogd status # to check the status
  $ sudo service virtlogd start  # to start the daemon
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

* Prepare the system with an initial mkcloud run which installs a few required
  packages and sets up the lvm volume. Additionally one of the following
  variables should be set: cloudpv or cloudvg

  ```
  $ export cloudpv=/dev/loopX
  $ sudo -E /path/to/mkcloud setuphost
  ```


# Configuration

## mkcloud

`mkcloud` consists of different steps which can be run independently, provided the order is logical.

`mkcloud` can be configured using different environment variables.

To get a complete list run: `./mkcloud help`

### Additional Information

* `cloudpv`, block device used by mkcloud to create a volume group. This will
  be used as cloudvg later.  In development environments this can be a loop
  device (e.g. `/dev/loop0`) or an unused disk or partition.
* `cloudvg`, volume group used by mkcloud to put LVM partitions, these
  partitions are used to host the virtual machines. If defined, cloudpv is
  ignored.
* `cloudsource`, defines what version of SUSE Cloud will be deployed (e.g. `susecloud4`)
  The latest version always is in development. So do not expect it to work out of the box.
  If you need a stable/working version use <latest-version>-1.
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
$ sudo env cloudpv=/dev/loop0 cloudsource=susecloud6 /path/to/mkcloud plain
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

A basic working mkcloud environment could look like [this](basic-mkcloud-config.sh).


## Using with local repositories

To be able to deploy a complete Cloud with `mkcloud` and without VPN access,
you can run the "prepare" step in mkcloud using the `cache_clouddata=1`
environment variable set. This will create a cache under `$cache_dir` (set to
`/var/cache/mkcloud` by default) of images and repositories needed during
deployment. Make sure your `$cache_dir` partition has enough free space to
store all the repos. You should always monitor the space on that partition and
adjust accordingly.

Note that you will need to run the "prepare" step again (with VPN access) if
your `$cloudsource` environment variable had changed. For example, if you are
developing on "develcloud8" and "develcloud7" in parallel, you will need to run the
"prepare" step for each separately.

Here's an example wrapper script you can use instead of executing mkcloud directly
which will enable caching and create a loopback LVM volume group which is used
by mkcloud then for installation of a virtualized cloud:

```
#!/bin/bash

# tell mkcloud to cache all repositories it will pass into the VMs locally
# on the host that mkcloud is being invoked on during "prepare" step.
#
# This allows running mkcloud without VPN being used.
export cache_clouddata=1

# path to the locally available repositories. By default, cache_dir is set
# to "/var/cache/mkcloud". If you want to change it to a different location,
# you should be making sure that the partition have enough free space to cache
# all the necessary repos.
#export cache_dir=<some other dir>

# setup/create lvm disk
cloud_lvm_disk=$HOME/develcloud-lvm.raw
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
export cloudsource=develcloud7
export cloud=$cloudsource
export net_fixed=192.168.150
export net_public=192.168.151
export net_admin=192.168.152
export vcpus=2

exec /path/to/mkcloud "$@"
```

## Testing patches via PTF packages

If you need to test patches, it is recommended to build packages and
use the PTF update mechanism to apply them.  This is especially useful
for patches which affect code used during the early stages of
installation, otherwise you would have to split up the `mkcloud` steps
and manually install the PTF packages before e.g. applying Crowbar
barclamp proposals.

### Building the PTF packages

You can use the [`build-rpms`](https://github.com/openSUSE/pack-tools/blob/master/contrib/BS-pkg-testing/README.md) tool to build a package from a `git` branch
in a local (or remote) repository.  Once you have followed the installation
instructions, this process is as simple as a one-line command, e.g.

    $ build-rpms -l -r my-git-branch ~/IBS/Devel/Cloud/9/crowbar-core

The output of this command should end with something like:

    /var/tmp/build-root/SLE_12_SP4-x86_64/home/abuild/rpmbuild/RPMS/x86_64/crowbar-core-6.0+git.1555416537.339e8987a-0.x86_64.rpm
    rpms saved in /home/adam/tmp/build-rpms/IBS_Devel_Cloud_9_crowbar-core

Alternatively, you can use the [`osc`](https://en.opensuse.org/openSUSE:OSC)
command directly, which you should already have installed. Create a patch file
containing your change:

    $ git format-patch HEAD^

Check out a local copy of the package you wish to build:

    $ osc bco Devel:Cloud:9:Staging crowbar-core

Copy the patch to the package, add it as a Patch file, and update the %setup
section. Build a local copy of the package:

    $ osc build --no-verify

The output will show you where the rpm is saved, something like:

    /var/tmp/build-root/SLE_12_SP4-x86_64/home/abuild/rpmbuild/RPMS/x86_64/crowbar-core-6.0+git.1555416537.339e8987a-0.x86_64.rpm

Yet another alternative is to commit the change to your remote branch:

    $ osc commit -m "test bugfix"
    $ osc results

OBS will build it for you. Ensure your branch is configured to publish the
packages.

### Getting `mkcloud` to use PTF packages

You will need a directory on the `mkcloud` host which contains all
PTFs which should be applied via the next `mkcloud` run, and this
directory should be accessible over HTTP.  It is suggested that you
create a directory for each topic you want to test, to avoid
accidentally mixing up which PTF packages get applied during a
particular mkcloud test run.  For example,

    # ptfdir=/data/install/PTF/crowbar-bugfix
    # mkdir -p $ptfdir
    # cp ~/tmp/build-rpms/IBS_Devel_Cloud_9_crowbar-core/*.noarch.rpm $ptfdir

Run a simple HTTP web server to serve the RPMs:

    $ cd $ptfdir
    $ python3 -m http.server

Now it is ready to be used by `mkcloud`:

    # export UPDATEREPOS=http://192.168.124.1:8000/
    # mkcloud all_noreboot

Alternatively, if you commit your package to your remote OBS branch, you do not
need to host the PTF content and can instead point mkcloud at your branch:

    # export UPDATEREPOS=http://download.suse.de/ibs/home:/comurphy:/branches:/Devel:/Cloud:/9:/Staging/SLE_12_SP4/
    # mkcloud all_noreboot

Ensure the mkcloud step uses 'addupdaterepo' and 'runupdate' before the
'bootstrapcrowbar' step is run. This happens automatically with the 'all*' steps
but not with the 'plain*' steps.

Now subsequent `mkcloud` runs will automatically apply any packages
found under `/data/install/PTF/crowbar-bugfix`.
