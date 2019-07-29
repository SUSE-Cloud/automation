# setup_zypper_repos

Ansible role for setting up zypper repositories for SUSE OpenStack Cloud.

## Usage

Zypper repositories will be added according to the `cloudsource` value.

The following table presents the possible values for `cloudsource` and the
resulting repositories added.

| `cloudsource`  | Cloud-Pool                             | SLES-Pool | SLES-Updates | Cloud-Updates | SLES-Updates-test         | Cloud-Updates-test        |
| -------------- | ---------------------------------------|:---------:|:------------:|:-------------:|:-------------------------:|:-------------------------:|
| stagingcloudX  | SUSE-OpenStack-Cloud-X-devel-staging   | X         | X            |               | *                         |                           |
| develcloudX    | SUSE-OpenStack-Cloud-X-devel           | X         | X            |               | *                         |                           |
| GMX            | SUSE-OpenStack-Cloud-X-Pool            | X         | X            |               | *                         | *                         |
| GMX+up         | SUSE-OpenStack-Cloud-X-Pool            | X         | X            | X             | *                         | *                         |
| hosdevelcloud8 | HPE-Helion-OpenStack-8-devel           | X         | X            |               | *                         |                           |
| hosGM8         | HPE-Helion-OpenStack-8-Pool            | X         | X            |               | *                         | *                         |
| hosGM8+up      | HPE-Helion-OpenStack-8-Pool            | X         | X            | X             | *                         | *                         |
| cloud9MX       | ISO milestoneX(ibs-mirror.prv.suse.net)| X         | X            |               | *                         | *                         |
| cloud9RCX      | ISO rcX(ibs-mirror.prv.suse.net)       | X         | X            |               | *                         | *                         |
| cloud9GMC      | ISO GMC(ibs-mirror.prv.suse.net)       | X         | X            |               | *                         | *                         |

`X` on `cloudsource` and `Cloud-Pool` represents the cloud version (8 or 9) and
the SLES repositories will be configured according to the cloud version
(SLES12-SP3 for Cloud 8 and SLES12-SP4 for Cloud 9).
As there is no HOS version for cloud 9, `cloudsource` values for HOS are limited
to cloud 8.

For other columns:
 * `X` means that the repository will always be added
 * `*` means that the repository will always be added unless the
 `updates_test_enabled` parameter is explicitly set to False.

### Update-test Repositories

To enable the SLES/Cloud Updates-test repositories override the following
variable:

```sh
updates_test_enabled: True
```

### Maintenance Updates

To add specific maintenance update repositories, override the following
variables with a list of MU ID's (separeted by comma).

```sh
maint_updates: "1234,4321,2233"
```

IMPORTANT: `updates_test_enabled` must be disabled when testing maintenance updates.

### Extra Repositories

It is also possible to use the role to add extra zypper repositories from the
URL by overriding the `extra_repos` variable, for example:

```sh
extra_repos: "http://download.suse.de/ibs/.../,http://download.suse.de/ibs/.../"
```

The packages from those repositories will be available to all cloud nodes
through a new repository with a higher priority, meaning that those packages will be
installed even if there is a newer package available on other repositories.

### Source Repositories

Override the following variables to use different source repositories for
SLES, Cloud or Maintenance updates:

```sh
clouddata_server: "provo-clouddata.cloud.suse.de"
maintenance_updates_server: "dist.suse.de"
```

## Mount vs Rsync

The `setup_zypper_repos` role uses different strategies for setting up the
repository locally.

  - **mount**: faster but risky, as any change on the remote repository can affect
  the system.
  - **rsync**: slower but safer, as it will copy all data from the remote
  repository once and all subsequent tasks will use the local repository.


By default, as the [SLES/Cloud]-Pool repositories are not frequently updated
the role will use **mount** for those repositories and **rsync** for the rest.
