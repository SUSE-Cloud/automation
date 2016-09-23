# mkcloud driver implementation using SMAPI and DirMaint
#
# For more information,
# see http://www.vm.ibm.com/related/dirmaint/overview.html

function dirmaint_do_setuphost()
{
    vmcp q cplevel || complain 191 "Something is wrong with the CP link"
}

function dirmaint_do_sanity_checks()
{
    : Sanity is doing the same thing over and over again and seeing no difference
}

function dirmaint_do_cleanup()
{
    echo "FIXME: do_cleanup"
}
