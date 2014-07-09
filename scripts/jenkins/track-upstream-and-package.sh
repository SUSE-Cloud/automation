#!/bin/sh
PROJECTSOURCE=OBS/${project}
COMPONENT=$component

# needs .oscrc with user,pass,trusted_prj
# zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools/SLE_11_SP2/openSUSE:Tools.repo
# zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools:/Unstable/SLE_11_SP2/openSUSE:Tools:Unstable.repo
# zypper in osc obs-service-tar_scm obs-service-github_tarballs obs-service-recompress obs-service-git_tarballs obs-service-set_version
[ -z "$PROJECTSOURCE" ] && ( echo "Error: no PROJECTSOURCE defined." ; exit 1 )

[ -e /root/bin/update_automation ] || wget -O /root/bin/update_automation https://raw.github.com/SUSE-Cloud/automation/master/scripts/jenkins/update_automation && chmod a+x /root/bin/update_automation
# fetch the latest automation updates
update_automation track-upstream-and-package.pl

OBS_TYPE=${PROJECTSOURCE%%/*}
OBS_PROJECT=${PROJECTSOURCE##*/}

case $OBS_TYPE in
    OBS) OSCAPI="https://api.opensuse.org"
        OSC_BUILD_DIST=SLE_11_SP2
        OSC_BUILD_ARCH=x86_64
        ;;
    *)  echo "This jenkins instance only interacts with OBS."
        exit 1
        ;;
esac

# remove accidentally added spaces
COMPONENT=${COMPONENT// /}
OBS_PROJECT=${OBS_PROJECT// /}

if [ -z "$COMPONENT" ] ; then
    echo "Error: Variable COMPONENT is unset."
    exit 1
fi

export OSCAPI
export OSC_BUILD_DIST
export OSC_BUILD_ARCH

export JHOME=/home/jenkins
export OBS_CHECKOUT=$JHOME/OBS_CHECKOUT/$OBS_PROJECT
export OSC_BUILD_ROOT=$JHOME/buildroot

mkdir -p ~/.obs
for i in incoming repo repourl
do
    mkdir -p $JHOME/obscache/tar_scm/$i
done
echo "CACHEDIRECTORY=\"$JHOME/obscache/tar_scm\"" > ~/.obs/tar_scm

mkdir -p "$OBS_CHECKOUT"
cd "$OBS_CHECKOUT"

rm -rf "$COMPONENT"
osc -A $OSCAPI co -c "$OBS_PROJECT" "$COMPONENT"

[ -d "$COMPONENT" ] || ( echo "Error: Component $COMPONENT does not exist (yet) or has been removed."  ; exit 1 )
cd "$COMPONENT"

set +e
if [ ${OBS_PROJECT} != "Cloud:OpenStack:Master" ] ; then
    # skip test in C:O:M as we do not have linked packages there
    grep -q "<linkinfo" .osc/_files || exit 2
fi

# call script in /root/bin
track-upstream-and-package.pl
