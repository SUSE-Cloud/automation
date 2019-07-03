#!/bin/bash -xue

#
# small helper to run tox on a PR with github_pr
#   via the RunHelperAndSetStatusAction class
#
# github_pr will pass these parameters to this script:
#  <org> <repo> <pr_number> <sha1> <username>
#

git_service=$1
org=$2
repo=$3
pr_id=$4
sha1=$5
username=$6

repo_dir=~/"${git_service}/${org}/${repo}"

pr_dir=$(mktemp -d cloud-specs.XXXXX)
rsync -a $repo_dir/ "$pr_dir"
pushd "$pr_dir"

### copied from openstack-mkcloud job
ghremote=origin
git config --get-all remote.${ghremote}.fetch | grep -q pull || \
    git config --add remote.${ghremote}.fetch "+refs/pull/*/head:refs/remotes/${ghremote}-pr/*"
git fetch $ghremote 2>&1 | grep -v '\[new ref\]' || :
git checkout -t $ghremote-pr/$pr_id
git config user.email cloud-devel+jenkins@suse.de
git config user.name "Jenkins User"
echo "we merge to always test what will end up in master"
git merge master -m temp-merge-commit
# Show latest commit in log to see what's really tested.
# Include a unique indent so that the log parser plugin
# can ignore the output and avoid false positives.
git --no-pager show | sed 's/^/|@| /'

### run tox
tox -e docs
ret=$?

# cleanup
popd
rm -rf "$pr_dir"
exit "$ret"
