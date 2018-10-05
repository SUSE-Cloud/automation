#!/bin/bash -xu
shopt -s extglob

# emptying the workspace
cd $WORKSPACE
rm -rf ./* ./.[a-zA-Z]*

if [ ! -v github_pr ] ; then
    exit 0
fi
# split $github_pr into multiple variables
source ${automationrepo}/scripts/jenkins/github-pr/parse.rc

# Support for automation self-gating
if [[ "$github_pr_repo" = "SUSE-Cloud/automation" ]]; then
    automationrepo_orig=$automationrepo
    automationrepo=$WORKSPACE/automation-git

    mkdir -p $automationrepo
    rsync -a ${automationrepo_orig%/}/ $automationrepo/
    pushd $automationrepo
    ghremote=origin
    git config --get-all remote.${ghremote}.fetch | grep -q pull || \
        git config --add remote.${ghremote}.fetch "+refs/pull/*/head:refs/remotes/${ghremote}/pr/*"
    git fetch $ghremote 2>&1 | grep -v '\[new ref\]' || :
    git checkout -t $ghremote/pr/$github_pr_id
    git config user.email cloud-devel+jenkins@suse.de
    git config user.name "Jenkins User"
    echo "we merge to always test what will end up in master"
    git merge master -m temp-merge-commit
    # Show latest commit in log to see what's really tested.
    # Include a unique indent so that the log parser plugin
    # can ignore the output and avoid false positives.
    git --no-pager show | sed 's/^/|@| /'
    popd
fi
