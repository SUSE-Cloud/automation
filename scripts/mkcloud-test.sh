#!/usr/bin/env roundup

describe "roundup(1) testing of mkcloud"

it_gives_help() {
    results=`! ./mkcloud help`
    [[ "$results" =~ "Usage:" ]]
    [[ "$results" =~ "networkingplugin" ]]
}
