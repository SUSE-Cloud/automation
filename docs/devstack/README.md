# Launching `devstack` on OpenStack via Heat

This repository provides [a heat
template](../../scripts/heat/devstack-heat-template.yaml) for
launching
[`devstack`](https://docs.openstack.org/devstack/latest/index.html) in
a single VM inside an OpenStack cloud.  It uses
[`qa_devstack.sh`](../../scripts/jenkins/qa_devstack.sh) in order to
prepare the VM for `devstack` and then run it.

The below examples use [OpenStack's Heat CLI
client](https://docs.openstack.org/python-heatclient/latest/cli/stack.html#stack-create);
however it is also possible to [launch a stack via the Horizon web
dashboard](https://docs.openstack.org/heat-dashboard/latest/user/stacks.html#launch-a-stack).

## Prerequites

The [Python OpenStack client with the `heatclient`
extension](https://docs.openstack.org/mitaka/user-guide/common/cli_install_openstack_command_line_clients.html)
must be installed.

## Example usage

[Set up your environment with the right
credentials](https://docs.openstack.org/python-openstackclient/rocky/cli/man/openstack.html#authentication-methods).
The easiest way to create an Openstack RC file (an `openrc` for `source`ing) or
the cloud configuration file (`~/.config/openstack/cloud.yaml`) is to navigate
to the Project / API Access page in horizon and use the pulldown menu
on the right to download a file that is already populated with the appropriate
values for our environment.  To avoid further prompts, you may add your password
into the file that you downloaded.  Then either

    source openrc

or

    # assuming that ~/.config/openstack/cloud.yaml contains the openstack cloud
    export OS_CLOUD=openstack

Also ensure that you have created or imported an ssh key pair into
your OpenStack account.  This can be done on the
Project / Compute / Key Pairs page in horizon
or with the `openstack keypair create` CLI command.

In the instructions below, it is assumed that
you have set `$KEY_NAME` to the name of your public key, e.g.

    export KEY_NAME=my-key-name

Then, to boot `devstack` on Leap 15.0:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$KEY_NAME \
        --parameter image_name=openSUSE-Leap-15.0 \
        $USER-devstack-leap

To boot `devstack` on SLES 12 SP3:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$KEY_NAME \
        --parameter image_name=SLES12-SP3-JeOS.x86_64 \
        $USER-devstack-sles12-sp3

To boot `devstack` on SLES 12 SP3 using modified versions of
`qa_devstack.sh` and `devstack` from forked branches in GitHub:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$KEY_NAME \
        --parameter image_name=SLES12-SP3-JeOS.x86_64 \
        --parameter automation_fork=$USER
        --parameter automation_branch=devstack-sle
        --parameter devstack_fork=$USER
        --parameter devstack_branch=sles-support \
        $USER-devstack-sles12-sp3

You can also set the `devstack_extra_config` parameter to pass extra
config to be placed in devstack's `local.conf`.  This can be done
similarly to above via `--parameter devstack_extra_config=...`, but if
the desired extra config is multi-line, it's slightly cleaner to do it
by first creating [an environment
file](https://docs.openstack.org/heat/rocky/template_guide/environment.html),
e.g.:

    cat <<EOF >devstack-branch-env.yaml
    parameters:
      devstack_extra_config: |
        NOVA_REPO=https://review.openstack.org/p/openstack/nova
        NOVA_BRANCH=refs/changes/50/5050/1
    EOF

Then adding `-e devstack-branch-env.yaml` to your `openstack stack
create` command would cause a particular Gerrit review branch of nova
to be checked out instead of `master`, as [described in the `devstack`
documentation](https://docs.openstack.org/devstack/latest/configuration.html#service-repos).

There are more parameters available; details are available inside [the
heat template](../../scripts/heat/devstack-heat-template.yaml) itself,
near the top.

## Logging into the VM

If all goes well, your server will boot up, become pingable, and after
a while it should be possible to `ssh` to its floating IP as normal
with any other OpenStack instance, e.g.

    fip=$(
        openstack stack output show \
            -c output_value \
            -f value \
            "$MY_STACK" floating-ip
    )
    ssh -i my-key-cert.pem root@$fip

`devstack` should have been triggered by `cloud-init` (see
`/var/log/cloud-init.log`), and the output of the `devstack` run can
be found in `/var/log/cloud-init-output.log`.
