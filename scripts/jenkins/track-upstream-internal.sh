#!/bin/bash -x

export automationrepo=~/github.com/SUSE-Cloud/automation

if [ ! $component ] && [ $GERRIT_PROJECT ] && [ $GERRIT_BRANCH ]; then
    component="$($automationrepo/scripts/jenkins/cloud/gerrit/gerrit2obs-name.py $GERRIT_PROJECT $GERRIT_BRANCH)"
fi
if [ ! $project ] && [ $GERRIT_BRANCH ]; then
    case $GERRIT_BRANCH in
        master)
            project="Devel:Cloud:9:Staging"
            ;;
        stable/pike)
            project="Devel:Cloud:8:Staging"
            ;;
        *)
            echo "\$GERRIT_BRANCH is set to a branch that is not known: $GERRIT_BRANCH"
            exit 1
            ;;
    esac
fi

PROJECTSOURCE=IBS/${project}

# needs .oscrc with user,pass,trusted_prj
# zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools/SLE_11_SP2/openSUSE:Tools.repo
# zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools:/Unstable/SLE_11_SP2/openSUSE:Tools:Unstable.repo
# zypper in osc obs-service-tar_scm obs-service-github_tarballs obs-service-recompress obs-service-git_tarballs obs-service-set_version obs-service-refresh_patches
[ -z "$PROJECTSOURCE" ] && ( echo "Error: no PROJECTSOURCE defined." ; exit 1 )

# Workaround to get only the name of the job:
# https://issues.jenkins-ci.org/browse/JENKINS-39189
# When the JOB_BASE_NAME contains only in ex. "cloud-mediacheck", this
# workaround can be removed.
echo "$JOB_BASE_NAME"
main_job_name=${JOB_NAME%%/*}

OBS_TYPE=${PROJECTSOURCE%%/*}
OBS_PROJECT=${PROJECTSOURCE##*/}

BUILD_DIST=SLE_12_SP4
OSC_BUILD_ARCH=x86_64

case $project in
    Devel:Cloud:6*)
        BUILD_DIST=SLE_12_SP1
        ;;
    Devel:Cloud:7*)
        BUILD_DIST=SLE_12_SP2
        ;;
    Devel:Cloud:8*)
        BUILD_DIST=SLE_12_SP3
        ;;
esac


case $OBS_TYPE in
    OBS) OSCAPI="https://api.opensuse.org"
        OSC_BUILD_DIST=$BUILD_DIST
        ;;
    IBS) OSCAPI="https://api.suse.de"
        OSC_BUILD_DIST=$BUILD_DIST
        ;;
    *)   echo "This jenkins instance only interacts with OBS or IBS."
        exit 1
        ;;
esac

# remove accidentally added spaces
component=${component// /}
OBS_PROJECT=${OBS_PROJECT// /}

if [ -z "$component" ] ; then
    echo "Error: Variable component is unset."
    exit 1
fi

export OSCAPI
export OSC_BUILD_DIST
export OSC_BUILD_ARCH

export JHOME=/home/jenkins
export BS_CHECKOUT=$JHOME/${OBS_TYPE}_CHECKOUT/$OBS_PROJECT
export OSC_BUILD_ROOT=$JHOME/buildroot

mkdir -p ~/.obs
for i in incoming repo repourl
do
    mkdir -p $JHOME/obscache/tar_scm/$i
done
echo "CACHEDIRECTORY=\"$JHOME/obscache/tar_scm\"" > ~/.obs/tar_scm

mkdir -p "$BS_CHECKOUT"
cd "$BS_CHECKOUT"

rm -rf "$component"
osc -A $OSCAPI co -c "$OBS_PROJECT" "$component"

[ -d "$component" ] || ( echo "Error: Component $component does not exist (yet) or has been removed."  ; exit 1 )
cd "$component"

grep -q "<linkinfo" .osc/_files || exit 2

${automationrepo}/scripts/jenkins/track-upstream-and-package.pl
exit $?
