#!/usr/bin/env roundup

describe "roundup(1) testing of qa_crowbarsetup.sh"

verlist="3 4 5 6"

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
    test "$results" = " develcloud3=0111 GM3=0111 develcloud4=1011 GM4=1011 develcloud5=1101 GM5=1101"
}

#it_returns_correct_cloudver_M4() {
#    results=`cloudversionmatrixrow M4`
#    test "$results" = "1101"
#}

it_returns_correct_cloudver_M5() {
    results=`cloudversionmatrixrow M5`
    test "$results" = "1101"
}

