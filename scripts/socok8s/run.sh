#!/bin/bash -x

# the jenkins job will pass these parameters to this script:
#  <org> <repo> <pr_number> <sha1> 
#

org=$1
repo=$2
pr_id=$3
sha1=$4

repo_dir=~/github.com/SUSE-Cloud/socok8s
pr_dir=$(mktemp -d cloud-socok8s.XXXXX)
rsync -a $repo_dir/ "$pr_dir"
pushd "$pr_dir"

### copied from openstack-mkcloud job
ghremote=origin
git config --get-all remote.${ghremote}.fetch | grep -q pull || \
    git config --add remote.${ghremote}.fetch "+refs/pull/*/head:refs/remotes/${ghremote}/pr/*"
git fetch $ghremote 2>&1 | grep -v '\[new ref\]' || :
git checkout -t $ghremote/pr/$pr_id
git config user.email cloud-devel+jenkins@suse.de
git config user.name "Jenkins User"
echo "we merge to always test what will end up in master"
git merge master -m temp-merge-commit
# Show latest commit in log to see what's really tested.
# Include a unique indent so that the log parser plugin
# can ignore the output and avoid false positives.
git --no-pager show | sed 's/^/|@| /'

export PREFIX=socok8s-ci-${pr_id}-${sha1}
export OS_CLOUD=engcloud-cloud-ci
export KEYNAME=engcloud-cloud-ci
export INTERNAL_SUBNET=ccpci-subnet
export ANSIBLE_RUNNER_DIR="${HOME}/${PREFIX}-deploy"
echo "Prefix set to ${PREFIX}"
echo "ANSIBLE_RUNNER_DIR set to ${ANSIBLE_RUNNER_DIR}"
./run.sh
ret=$?

# cleanup
popd
rm -rf "$pr_dir" "$ANSIBLE_RUNNER_DIR"
exit "$ret"
