#!/usr/bin/env roundup

describe "roundup(1) testing of update_automation"

export dryrun_update_automation=1

it_fetches_upstream_repos_with_master() {
    results=`./update_automation`
    [[ $results =~ github.com/SUSE-Cloud/automation\ .*\ master ]]
    [[ $results =~ github.com/openSUSE/github-pr\ .*\ master ]]
}

it_fetches_other_automation_repo_with_master() {
    results=`automation_repo=github.com/other-org/other-repo ./update_automation`
    [[ $results =~ github.com/other-org/other-repo\ .*\ master ]]
    [[ $results =~ github.com/openSUSE/github-pr\ .*\ master ]]
}

it_fetches_other_automation_repo_with_other_branch() {
    results=`automation_repo="github.com/other-org/other-repo#other-branch" ./update_automation`
    [[ $results =~ github.com/other-org/other-repo\ .*\ other-branch ]]
    [[ $results =~ github.com/openSUSE/github-pr\ .*\ master ]]
}

it_prints_usage_on_wrong_repo_definition() {
    results=`! automation_repo="https://github.com/other-org/other-repo.git" ./update_automation`
    [[ $results =~ "Syntax error with automation repo definition" ]]
}
