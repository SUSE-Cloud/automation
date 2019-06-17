#!/bin/bash -x

source scripts/jenkins/github-pr/parse.rc
github_context=suse/ardana
if [[ $github_pr_context ]] ; then
    github_context=$github_context/$github_pr_context
fi

ghprrepo=~/github.com/openSUSE/github-pr
ghpr=${ghprrepo}/github_pr.rb
ghpr_paras="--org ${github_org} --repo ${github_repo} --sha $github_pr_sha --context $github_context"

echo "testing PR: https://github.com/$github_pr_repo/pull/$github_pr_id"

# check for newer PRs
if ! $ghpr --action is-latest-sha $ghpr_paras --pr $github_pr_id ; then
    $ghpr --action set-status $ghpr_paras --status "error" --targeturl $BUILD_URL --message "SHA1 mismatch, newer commit exists"
    exit 1
fi
$ghpr --action set-status $ghpr_paras --status "pending" --targeturl $BUILD_URL --message "Started PR gating"

git config --add remote.origin.fetch "+refs/pull/*/head:refs/remotes/origin-pr/*"
git fetch origin $github_pr_sha
git checkout -B ardana-ci FETCH_HEAD
git clean  # remove files deleted from git

