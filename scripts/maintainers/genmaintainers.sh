#!/bin/sh

# This script is the entry point for generating maintainer lists. It takes a
# Cloud version and a working directory as arguments. Example for Cloud 7:

#  genmaintainers.sh 7 maintainer_dir

# The working directory will be created automatically if it does not exist. It
# can and can and should be re-used for different Cloud releases (this will save
# some time).



cloud_release=$1
work_dir=$2

osc="osc -A https://api.suse.de"

PATH=$PATH:$(readlink -e $(dirname $0))

usage() {
  echo "usage: $0 <cloud release> <work dir>"
  echo ""
  echo "  cloud_release:: 7 | 8 | 9"
  }

if [ -z $cloud_release ]; then
  usage
  exit 1
fi

case $cloud_release in
  "7")
    ;;
  "8")
    ;;
  "9")
    ;;
  *)
    usage
    exit 1
esac

if [ -z "$work_dir" ]; then
  usage
  exit 1
fi

mkdir -p $work_dir || exit 1
pushd $work_dir || exit 1

if [ ! -d "SUSE:Channels" ]; then
  $osc co SUSE:Channels || exit 1
  grep -w binary $(find SUSE:Channels -name _channel) > binaries
fi

if [ ! -d Devel:Cloud:${cloud_release} ]; then
  $osc co Devel:Cloud:${cloud_release} _product || exit 1
fi

(cloudpackages.py Devel:Cloud:${cloud_release}/_product/*.product
cloudpackages.py -u Devel:Cloud:${cloud_release} patterns-{cloud-admin,cloud-compute,cloud-controller,cloud-network}) \
  | sort | uniq > packages-Devel:Cloud:${cloud_release}

canonicalpac.pl binaries packages-Devel:Cloud:${cloud_release} \
  | awk '{ print $1 " " $4 }' | sort | uniq > packages-canonical-Devel:Cloud:${cloud_release}

awk '{print "osc -A https://api.suse.de maintainer " $2 " " $1 "| sed \"s# :#/" $1 "#\""}' \
     packages-canonical-Devel:Cloud:${cloud_release} | sh 2>&1 | tee maintainers_raw-Devel:Cloud:${cloud_release}

parse_maintainers.pl maintainers_raw-Devel:Cloud:${cloud_release} > maintainers-Devel:Cloud:${cloud_release}

echo
echo
echo "List of package maintainers for Cloud ${cloud_release} written to maintainers-Devel:Cloud:${cloud_release}"
