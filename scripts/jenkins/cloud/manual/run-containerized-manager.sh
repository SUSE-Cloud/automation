#!/bin/bash

set -u -x

basedir=$(readlink --canonicalize $(dirname $0)/../../../../)

CLI=${CLI:=docker}
# CLI=podman

ionice -c idle ${CLI} build \
    --tag ci-manager .

# Create the container. This command will fail if the container
# already exists. We will ignore that failure...
${CLI} create \
    --interactive --tty \
    --name ci-manager \
    --volume "${basedir}":/opt/automation \
    --volume "${HOME}/.config/openstack":/opt/openstack:ro \
    ci-manager \
    --uid "$(id --user)" \
    --gid "$(id --group)" \
    --git-user-name "$(git config --get user.name)" \
    --git-user-email "$(git config --get user.email)" \
    "$@"

# ... and start the container anyway.
${CLI} start \
    --attach \
    --interactive \
    ci-manager
