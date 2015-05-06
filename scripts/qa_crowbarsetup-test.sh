#!/usr/bin/env roundup

describe "roundup(1) testing of qa_crowbarsetup.sh"

verlist="3 4 5 6 4plus"
export cloud=x

cloudversionmatrixrow() {
    r=""
    for v in $verlist ; do
        export cloudsource=$1 ; . ./qa_crowbarsetup.sh ; iscloudver $v && r="${r}0" || r="${r}1"
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
    results=`cloudversionmatrix "M3 M4 M5 Beta3 Beta4 RC3 GMC susecloud6 GM6+up"`
    test "$results" = " M3=11100 M4=11100 M5=11100 Beta3=11100 Beta4=11100 RC3=11100 GMC=11100 susecloud6=11100 GM6+up=11100"
}

getcloudversionmatrixrow() {
    for v in $@ ; do
        export cloudsource=$v ; . ./qa_crowbarsetup.sh ; getcloudver
    done
}

it_returns_correct_getcloudver() {
    results=`getcloudversionmatrixrow develcloud3 GM3 develcloud4 GM4 develcloud5 susecloud5 GM5 M3 M4 M5 Beta3 Beta4 RC3 GMC`
    test "$results" = "33445556666666"
}

it_has_correct_mac_to_nodename() {
    results=`. ./qa_crowbarsetup.sh ; mac_to_nodename 52:54:03:88:77:03`
    test "$results" = "d52-54-03-88-77-03.x.cloud.suse.de"
}

it_parses_dhcpd_leases() {
    results=`. ./qa_crowbarsetup.sh ; onadmin_get_ip_from_dhcp 52:54:03:88:77:03 test/data/dhcpd.leases`
    test "$results" = "192.168.124.26"
    # negative result test
    results=`. ./qa_crowbarsetup.sh ; ! onadmin_get_ip_from_dhcp 52:54:03:88:77:07 test/data/dhcpd.leases`
    test "$results" = ""
}
