#!/bin/bash -x
shopt -s extglob

# emptying the workspace
cd $WORKSPACE
rm -rf ./* ./.[a-zA-Z]*

git_automation_repo=${git_automation_repo:-"SUSE-Cloud"}
git_automation_branch=${git_automation_branch:-"master"}
use_global_clone=${use_global_clone:-true}

export github_pr=${github_pr:-}
export automationrepo=~/github.com/${git_automation_repo}/automation
export AUTOMATION_REPO="github.com/${git_automation_repo}/automation#${git_automation_branch}"

# automation bootstrapping
if ! [ -e ${automationrepo}/scripts/jenkins/update_automation ] ; then
  rm -rf ${automationrepo}
  curl https://raw.githubusercontent.com/${git_automation_repo}/automation/${git_automation_branch}/scripts/jenkins/update_automation | bash
fi

# fetch the latest automation updates
${automationrepo}/scripts/jenkins/update_automation

automationrepo_orig=$automationrepo
automationrepo=${WORKSPACE}/automation-git

if $use_global_clone && [ -z "$github_pr" ]; then
  ln -s $automationrepo_orig $automationrepo
else
  mkdir -p $automationrepo
  rsync -a ${automationrepo_orig%/}/ $automationrepo/
fi
pushd $automationrepo
ghremote=origin

if [ -n "$github_pr" ]; then
    # split $github_pr into multiple variables
    source ${automationrepo}/scripts/jenkins/github-pr/parse.rc

    # Support for automation self-gating
    if [ -n "$github_pr_id" ]; then
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
    fi
fi
popd
