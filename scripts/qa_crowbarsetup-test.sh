#!/usr/bin/env roundup

describe "roundup(1) testing of qa_crowbarsetup.sh"

verlist="3 4 5 6 4plus"

cloudversionmatrixrow() {
    r=""
    for v in $verlist ; do
        cloudsource=$1 testfunc=iscloudver bash -x ./qa_crowbarsetup.sh x $v && r="${r}0" || r="${r}1"
    done
    echo $r
}

cloudversionmatrix() {
    srclist=$1
    r=""
    for src in $srclist ; do
        newr=`cloudversionmatrixrow $src`
        r="$r $src=$newr"
    done
    echo "$r"
}

it_returns_correct_cloudver_matrix() {
    results=`cloudversionmatrix "develcloud3 GM3 develcloud4 GM4 develcloud5 GM5"`
    test "$results" = " develcloud3=01111 GM3=01111 develcloud4=10110 GM4=10110 develcloud5=11010 GM5=11010"
}

it_returns_correct_cloudver_matrix_milestone() {
    results=`cloudversionmatrix "M3 M4 M5 Beta3 Beta4 RC3 GMC susecloud5"`
    test "$results" = " M3=11010 M4=11010 M5=11010 Beta3=11010 Beta4=11010 RC3=11010 GMC=11010 susecloud5=11010"
}

getcloudversionmatrixrow() {
    for v in $@ ; do
        cloudsource=$v testfunc=getcloudver bash -x ./qa_crowbarsetup.sh x
    done
}

it_returns_correct_getcloudver() {
    results=`getcloudversionmatrixrow develcloud3 GM3 develcloud4 GM4 develcloud5 GM5 M3 M4 M5 Beta3 Beta4 RC3 GMC susecloud5`
    test "$results" = "33445555555555"
}

it_has_correct_mac_to_nodename() {
    results=`testfunc=mac_to_nodename bash -x ./qa_crowbarsetup.sh x 52:54:03:88:77:03`
    test "$results" = "d52-54-03-88-77-03.x.cloud.suse.de"
}

it_parses_dhcpd_leases() {
    results=`testfunc=onadmin_get_ip_from_dhcp bash -x ./qa_crowbarsetup.sh x 52:54:03:88:77:03 test/data/dhcpd.leases`
    test "$results" = "192.168.124.26"
    # negative result test
    results=`! testfunc=onadmin_get_ip_from_dhcp bash -x ./qa_crowbarsetup.sh x 52:54:03:88:77:07 test/data/dhcpd.leases`
    test "$results" = ""
}
