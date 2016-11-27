# soc-ci - command line interface to the SUSE OpenStack CI

`soc-ci` is a script to interact with the CI system for SUSE OpenStack Cloud.
It is only useful if access to the internal CI infrastructure is available.

`soc-ci` can be used to reserve and release environments or to list
the current pool for a worker.
Beside that, it can answer most of the questions you have while working with the
CI. Some of theses questions are:

* I have this mkcloud job, in which env is it running?

```
$ soc-ci os-mkcloud-where 42263
crowbar.vl3.cloud.suse.de
```

Now you can block that env with:

```
$ soc-ci worker-pool-reserve l 3
```

and list the result with:

```
$ soc-ci worker-pool-list l
1
2
3.tbechtold.2016-11-23
```

* I have this mkcloud job, is the environment still available?

```
$ soc-ci os-mkcloud-available 42263
job env for 42263 still available on "crowbar.vl3.cloud.suse.de"
```

* I have this mkcloud job, show me the log:

```
$ soc-ci os-mkcloud-console-log 42263|tail -n 10
Variable with name 'BUILD_DISPLAY_NAME' already exists, current value: '#42263: cloud-mkcloud7-job-ha-x86_64', new value: '#42263: cloud-mkcloud7-job-ha-x86_64'
Archiving artifacts
An attempt to send an e-mail to empty list of recipients, ignored.
[BFA] Scanning build for known causes...
........[BFA] Found failure cause(s):
[BFA] Cucumber test failed from category cct
[BFA] Done. 8s
Warning: you have no plugins providing access control for builds, so falling back to legacy behavior of permitting any downstream builds to be triggered
Finished: FAILURE

```

* I have this mkcloud job and want to get the artifacts (which usually
contain the supportconfig tarballs):
```
$ soc-ci os-mkcloud-artifacts 42432
Artifacts downloaded to /home/tom/.soc-ci/artifacts/os-mkcloud/42432
supportconfigs available in /home/tom/.soc-ci/artifacts/os-mkcloud/42432
```
For the automatic supportconfig extraction, you need [unpack-supportconfig](https://build.opensuse.org/package/show/home:aspiers/supportconfig-utils).

* I want to see all my reserved workers:
```
$ soc-ci workers-pool-list
### mkcha.cloud.suse.de ###
### mkchb.cloud.suse.de ###
### mkchc.cloud.suse.de ###
### mkchd.cloud.suse.de ###
1.tbechtold
### mkche.cloud.suse.de ###
2.tbechtold.2016-11-25
### mkchf.cloud.suse.de ###
### mkchg.cloud.suse.de ###
### mkchh.cloud.suse.de ###
```

To list all available reservations, use ```soc-ci workers-pool-list --all```.
## Requirements

You need a couple of python packages:

```
$ zypper in python-paramiko python-jenkinsapi python-six
```

For the automatic supportconfig extraction, you need ```unpack-supportconfig``` from the [supportconfig-utils](https://build.opensuse.org/package/show/home:aspiers/supportconfig-utils)
package.


## Configuration

When using it the first time, `soc-ci` will ask for the needed
parameters and store them in `~/.soc-ci.ini`.  The username and
password are your normal Jenkin credentials, and the URL is
https://ci.suse.de/.

There are some optional parameters with default if the parameters are not in the
config:

* ```artifacts_dir```
The directory path where to store the Jenkins artifacts.
