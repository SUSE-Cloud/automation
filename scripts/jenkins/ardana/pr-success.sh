#!/bin/bash -x

source scripts/jenkins/github-pr/parse.rc
github_context=suse/ardana
if [[ $github_pr_context ]] ; then
    github_context=$github_context/$github_pr_context
fi

ghprrepo=~/github.com/openSUSE/github-pr
ghpr=${ghprrepo}/github_pr.rb
ghpr_paras="--org ${github_org} --repo ${github_repo} --sha $github_pr_sha --context $github_context"

$ghpr --action set-status --debugratelimit $ghpr_paras --status "success" --targeturl $BUILD_URL --message "PR gating succeeded"
