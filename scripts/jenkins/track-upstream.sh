#!/bin/bash -x
PROJECTSOURCE=OBS/${project}
COMPONENT=$component

# needs .oscrc with user,pass,trusted_prj
# zypper ar http://download.opensuse.org/repositories/openSUSE:/Tools/SLE_12/openSUSE:Tools.repo
# zypper ar SDK # for git
zypper -n in osc obs-service-tar_scm obs-service-github_tarballs obs-service-recompress obs-service-git_tarballs \
    obs-service-set_version obs-service-refresh_patches obs-service-python_requires python-setuptools
[ -z "$PROJECTSOURCE" ] && ( echo "Error: no PROJECTSOURCE defined." ; exit 1 )

export automationrepo=~/github.com/SUSE-Cloud/automation

# Workaround to get only the name of the job:
# https://issues.jenkins-ci.org/browse/JENKINS-39189
# When the JOB_BASE_NAME contains only in ex. "openstack-trackupstream", this
# workaround can be removed.
echo "$JOB_BASE_NAME"
main_job_name=${JOB_NAME%%/*}

OBS_TYPE=${PROJECTSOURCE%%/*}
OBS_PROJECT=${PROJECTSOURCE##*/}

case $OBS_TYPE in
    OBS) OSCAPI="https://api.opensuse.org"
        OSC_BUILD_ARCH=x86_64
        case $OBS_PROJECT in
            Cloud:OpenStack:Pike*|Cloud:OpenStack:Queens*)
                OSC_BUILD_DIST=SLE_12_SP3
                ;;
            Cloud:OpenStack:Rocky*)
                OSC_BUILD_DIST=SLE_12_SP4
                ;;
            Cloud:OpenStack:Stein*)
                OSC_BUILD_DIST=SLE_15
                ;;
            Cloud:OpenStack:Master)
                OSC_BUILD_DIST=SLE_15
                ;;
            *)
                echo "Support missing"
                exit 1
                ;;
        esac
        ;;
    *)   echo "This jenkins instance only interacts with OBS."
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
timeout 1h ~/github.com/SUSE-Cloud/automation/scripts/jenkins/track-upstream-and-package.pl
exit $?
