#!/usr/bin/env roundup

describe "roundup(1) testing of qa_crowbarsetup.sh"

verlist="3 4 5 5minus 7 4plus 7M4plus"
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
    test "$results" = " develcloud3=0110111 GM3=0110111 develcloud4=1010101 GM4=1010101 develcloud5=1100101 GM5=1100101"
}

it_returns_correct_cloudver_matrix_milestone() {
    results=`cloudversionmatrix "M3 M4 M5 Beta3 Beta4 RC3 GMC susecloud7 GM7+up"`
    test "$results" = " M3=1111001 M4=1111000 M5=1111000 Beta3=1111000 Beta4=1111000 RC3=1111000 GMC=1111000 susecloud7=1111000 GM7+up=1111000"
}

getcloudversionmatrixrow() {
    for v in $@ ; do
        export cloudsource=$v ; . ./qa_crowbarsetup.sh ; getcloudver
    done
}

it_returns_correct_getcloudver() {
    results=`getcloudversionmatrixrow develcloud3 GM3 develcloud4 GM4 develcloud5 susecloud5 GM5 M3 M4 M5 Beta3 Beta4 RC3 GMC`
    test "$results" = "33445557777777"
}

it_has_correct_mac_to_nodename() {
    results=`. ./qa_crowbarsetup.sh ; setcloudnetvars $cloud ; mac_to_nodename 52:54:03:88:77:03`
    test "$results" = "d52-54-03-88-77-03.x.cloud.suse.de"
}

it_parses_dhcpd_leases() {
    results=`. ./qa_crowbarsetup.sh ; onadmin_get_ip_from_dhcp 52:54:03:88:77:03 test/data/dhcpd.leases`
    test "$results" = "192.168.124.26"
    # negative result test
    results=`. ./qa_crowbarsetup.sh ; ! onadmin_get_ip_from_dhcp 52:54:03:88:77:07 test/data/dhcpd.leases`
    test "$results" = ""
}

it_breaks_line_in_wait_for() {
    results=`. ./qa_crowbarsetup.sh ; wait_for 75 0 false "being true" "exit 0" | grep "^\."`
    [[ "$results" = "..........................................................................." ]]
    results=`. ./qa_crowbarsetup.sh ; wait_for 151 0 false "being true" "exit 0" | grep "^\."`
    [[ "$results" = "...........................................................................
...........................................................................
." ]]
}
