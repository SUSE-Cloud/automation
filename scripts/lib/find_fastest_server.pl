#!/usr/bin/perl -w
# input: list of servers
# output: one server name
#   the one that responded fastest, or the first one if all are unreachable

use strict;
my %best;
foreach my $server (@ARGV) {
    $_ = `ping -W 1 -c 3 -i .2 -q $server |tail -1`;
    next unless (m/ = ([0-9.]+)\//);
    my $time = $1;
    if(!defined $best{"time"} || $time < $best{"time"}) {
        %best = ("time"=>$time, "server"=>$server);
    }
    #print STDERR "$server $time\n"; # debug
}
$best{server} ||= $ARGV[0];
print $best{server},"\n";
