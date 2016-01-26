#!/usr/bin/perl -w
use strict;
# 2015 by Bernhard M. Wiedemann
# Licensed under GPLv2

# This tool updates jenkins build descriptions with extracts from result logs

my $jobname=$ENV{jobname}||"openstack-mkcloud";
my $numfile="$jobname.buildnum";
my $startnum=`cat $numfile`-10;
my $endnum=$startnum+30;
for my $num ($startnum..$endnum) {
    my $build = "$jobname/$num";
    $_ = `curl -s https://ci.suse.de/job/$build/consoleText`;
    last if m/<body><h2>HTTP ERROR 404/;
    next unless m/Finished: FAILURE/;
    system("echo \$((1+$num)) > $numfile");
    my $descr = "";
    foreach my $regexp (
        '(java.lang.OutOfMemoryError)',
        '(Slave went offline) during the build',
        '(Crowbar inst)allation terminated prematurely.  Please examine the above',
        'Build (timed out) \(after \d+ minutes\). Marking the build as failed.',
        'Latest (SHA1 from PR does not match) this SHA1',
        '(SHA1 mismatch), newer commit exists',
        'crowbar\.(\w\d+)\.cloud\.suse\.de',
        'Error: (crowbar self-test) failed',
	'(Automatic merge failed)',
        'mk(?:phys)?cloud (ret=\d+)',
        '\((safelyret=12)\) Aborting',
    ) {
        if(m/$regexp/) {$descr.="$1 "}
    }
    /\+ '\[' (\d+) = 0 '\]'\n\+ exit 1\nBuild step/ and $1 and $descr.="ret=$1";
    if(/The step '(\w+)' returned with exit code (\d+)/) {
        $descr.="/$2/$1";
        if($2 eq "102") {
            if(m/RadosGW Tests: [^0]/) {$descr.="/radosgw"}
            if(m/Volume in VM: (\d+) & (\d+)/ and ($1||$2)) {$descr.="/volume=$1&$2"}
            $descr.=tempestdetails() if(m/Tempest: [^0]/);
        }
        if(m/Error: Committing the crowbar '\w+' proposal for '(\w+)' failed/) {$descr.="/$1"}
    }
    $descr ||= "unknown cause";
    if(m{^github_pr=([a-z-]+/[a-z-]+):(\d+)}mi) {
        $descr.=" https://github.com/$1/pull/$2 "
    }
    print "$build $descr\n";
    system("./japi", "setdescription", $build, $descr);
}

sub tempestdetails {
    my $descr="/tempest";
    foreach my $regexp (
        'FAILED \((failures=\d+)\)\n\+ tempestret=',
        'FAIL: tempest\.([a-z0-9._]+)\.',
        '(ServerFault): Got server fault',
        'Cannot get interface (MTU) on \'brq',
        '(Volume) \S+ failed to reach in-use status',
        '(SSHTimeout): Connection to the',
        '(KeyError): ',
        '(MismatchError): ',
        '(AssertionError): ',
    ) {
        if(m/$regexp/) {$descr.=" $1"}
    }
    return $descr;
}
