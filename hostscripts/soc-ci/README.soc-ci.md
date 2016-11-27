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

## Requirements

You need a couple of python packages:

```
$ zypper in python-paramiko python-jenkinsapi python-six
```

## Configuration

When using it the first time, `soc-ci` will ask for the needed
parameters and store them in `~/.soc-ci.ini`.  The username and
password are your normal Jenkin credentials, and the URL is
https://ci.suse.de/.
