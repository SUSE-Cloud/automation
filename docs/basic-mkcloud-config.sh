#!/bin/bash
unset PARALLEL
unset cloudpv
unset cloudsource
unset nodenumber
unset want_sles12sp1

export PARALLEL=yes
export cloudpv=/dev/loop0
export cloudsource=develcloud6
export nodenumber='2'
export want_sles12sp1=2

exec /path/to/mkcloud "$@"
