#!/bin/bash
unset cloudpv
unset cloudsource
unset nodenumber

export cloudpv=/dev/loop0
export cloudsource=develcloud9
export nodenumber='2'

exec /path/to/mkcloud "$@"
