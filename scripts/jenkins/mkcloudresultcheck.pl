#!/usr/bin/perl -w
use strict;
# 2015 by Bernhard M. Wiedemann
# Licensed under GPLv2

# This tool updates jenkins build descriptions with extracts from result logs

my $numfile="mkcloudbuildstartnum";
my $startnum=`cat $numfile`;
my $endnum=$startnum+20;
for my $num ($startnum..$endnum) {
    my $build = "openstack-mkcloud/$num";
    $_ = `curl -s https://ci.suse.de/job/$build/consoleText`;
    last if m/<body><h2>HTTP ERROR 404/;
    next unless m/Finished: FAILURE/;
    system("echo \$((1+$num)) > $numfile");
    my $descr = "unknown cause";
    /java.lang.OutOfMemoryError/ and $descr=$&;
    /\+ '\[' (\d+) = 0 '\]'\n\+ exit 1\nBuild step/ and $1 and $descr="ret=$1";
    if(/The step '(\w+)' returned with exit code (\d+)/) {
        $descr="$1/ret=$2";
        if($2 eq "102") {
            if(m/RadosGW Tests: [^0]/) {$descr.="/radosgw"}
            if(m/Volume in VM: (\d+) & (\d+)/ and ($1||$2)) {$descr.="/volume=$1&$2"}
            if(m/Tempest: [^0]/) {
                $descr.="/tempest";
                if(m/FAILED \((failures=\d+)\)\n\+ tempestret=/) {$descr.="/$1"}
            }
        }
    }
    print "$build $descr\n";
    system("./japi", "setdescription", $build, $descr);
}
