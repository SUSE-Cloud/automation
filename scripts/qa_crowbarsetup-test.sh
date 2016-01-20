#!/usr/bin/env roundup

describe "roundup(1) testing of qa_crowbarsetup.sh"

verlist="3 4 5 6 4plus 6M4plus"
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
    test "$results" = " develcloud3=011111 GM3=011111 develcloud4=101101 GM4=101101 develcloud5=110101 GM5=110101"
}

it_returns_correct_cloudver_matrix_milestone() {
    results=`cloudversionmatrix "M3 M4 M5 Beta3 Beta4 RC3 GMC susecloud6 GM6+up"`
    test "$results" = " M3=111001 M4=111000 M5=111000 Beta3=111000 Beta4=111000 RC3=111000 GMC=111000 susecloud6=111000 GM6+up=111000"
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
