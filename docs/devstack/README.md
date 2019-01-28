# Launching `devstack` on OpenStack via Heat

This repository provides [a heat
template](../../scripts/heat/devstack-heat-template.yaml) for
launching
[`devstack`](https://docs.openstack.org/devstack/latest/index.html) in
a single VM inside an OpenStack cloud.  It uses
[`qa_devstack.sh`](../../scripts/jenkins/qa_devstack.sh) in order to
prepare the VM for `devstack` and then run it.

## Example usage

The below examples use [OpenStack's Heat CLI
client](https://docs.openstack.org/python-heatclient/latest/cli/stack.html#stack-create);
however it is also possible to [launch a stack via the Horizon web
dashboard](https://docs.openstack.org/heat-dashboard/latest/user/stacks.html#launch-a-stack).

Firstly, [set up your environment with the right
credentials](https://docs.openstack.org/python-openstackclient/rocky/cli/man/openstack.html#authentication-methods),
e.g.

    source openrc

or

    # assuming ~/.config/openstack/my-cloud.yaml exists
    export OS_CLOUD=my-cloud

and ensure you have the Python OpenStack client and the `heatclient`
extension both installed.

Then, to boot `devstack` on Leap 15.0:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$USER \
        --parameter image_name=openSUSE-Leap-15.0 \
        $USER-devstack-leap

To boot `devstack` on SLES 12 SP3:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$USER \
        --parameter image_name=SLES12-SP3-JeOS.x86_64 \
        $USER-devstack-sles12-sp3

To boot `devstack` on SLES 12 SP3 using modified versions of
`qa_devstack.sh` and `devstack` from forked branches in GitHub:

    openstack stack create \
        -t scripts/heat/devstack-heat-template.yaml \
        --parameter key_name=$USER \
        --parameter image_name=SLES12-SP3-JeOS.x86_64 \
        --parameter qa_devstack_fork=$USER
        --parameter qa_devstack_branch=devstack-sle
        --parameter devstack_fork=$USER
        --parameter devstack_branch=sles-support \
        $USER-devstack-sles12-sp3

There are more parameters available; details are available inside [the
heat template](../../scripts/heat/devstack-heat-template.yaml) itself,
near the top.
