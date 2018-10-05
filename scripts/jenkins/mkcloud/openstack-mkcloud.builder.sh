#!/bin/sh
set -x
shopt -s extglob

export artifacts_dir=$WORKSPACE/.artifacts
rm -rf $artifacts_dir
mkdir -p $artifacts_dir
touch $artifacts_dir/.ignore
export log_dir=$artifacts_dir/mkcloud_log

jtsync=${automationrepo}/scripts/jtsync/jtsync.rb
export ghprrepo=~/github.com/openSUSE/github-pr
export ghpr=${ghprrepo}/github_pr.rb

export want_neutronsles12=1
export want_mtu_size=8900
[[ $libvirt_type = hyperv ]] && want_mtu_size=1500 # windows-PXE-bootloader seems to not like jumbo-packets
export rally_server=backup.cloudadm.qa.suse.de
# to not fail when two concurrent zypper runs happen:
export ZYPP_LOCK_TIMEOUT=120

# enable mkcloud options specific for CI runs
export CI_RUN=1

case $cloudsource in
    develcloud6)
        if [[ $mkcloudtarget =~ upgrade ]]; then
            echo "Unsetting want_ldap for upgrade jobs until hybrid backend is ported to Mitaka"
            unset want_ldap
        fi
        ;;
    M*|develcloud9|develcloud8|develcloud7|GM7|GM7+up|susecloud9)
        if [[ $mkcloudtarget =~ upgrade ]]; then
            echo "Unsetting want_ldap for upgrade jobs until hybrid backend is migrated to domain-specific backends"
            unset want_ldap
        else
            [[ $nodenumber == 2 && -z "$scenario" ]] && export want_ldap=1
        fi
        ;;
    *)
        [[ $nodenumber == 2 && -z "$scenario" ]] && export want_ldap=1
        ;;
esac

if [[ $cinder_backend = " " ]] ; then
  cinder_backend=""
elif [[ $cinder_backend = "nfs" ]] ; then
  export nodenumberlonelynode=1
fi


# HAcloud
if [[ $hacloud == 1 ]] ; then
  case $cloudsource in
    develcloud6|GM7|GM7+up)
        clusternodes=2
        nodes=3
        ;;
    *)
        clusternodes=3
        nodes=4
        ;;
  esac

  : ${clusterconfig:=data+services+network=$clusternodes}
  export clusterconfig
  if [[ $nodenumber -lt $nodes ]] ; then
      export nodenumber=$nodes
  fi

  # for now disable ceph deployment in HA mode explicitly
  # it would need 5 nodes (2 for the cluster + 3 nodes for compute and ceph)
  #### temorarily allow ceph in HA (test if it works)
  #export want_ceph=0
  #export cephvolumenumber=0
fi

#storage
case "$storage_method" in
  none)
    want_ceph=0
    want_swift=0
    ;;
  swift)
    want_ceph=0
    want_swift=1
    ;;
  ceph)
    want_ceph=1
    want_swift=0
    if [[ $nodenumber -lt 5 ]] ; then
      export nodenumber=5
    fi
    if [[ $cephvolumenumber -lt 2 ]] ; then
      cephvolumenumber=2
    fi
    ;;
  *)
    unset want_ceph
    unset want_swift
esac
export want_ceph
export want_swift

if [ ! -z "$UPDATEREPOS" ] ; then
  # testing update only makes sense with GM and without TESTHEAD
#  unset TESTHEAD
#  export cloudsource=GM
  export UPDATEREPOS=${UPDATEREPOS//$'\n'/+}
fi

function mkcloudgating_trap()
{
    $ghpr --action set-status --debugratelimit $ghpr_paras --status "failure" --targeturl ${BUILD_URL}parsed_console/
}

## mkcloud github PR gating
if [[ $github_pr ]] ; then
    # split $github_pr into multiple variables
    source ${automationrepo}/scripts/jenkins/github-pr/parse.rc

    github_context=suse/mkcloud
    if [[ $github_pr_context ]] ; then
      github_context=$github_context/$github_pr_context
    fi
    ghpr_paras="--org ${github_org} --repo ${github_repo} --sha $github_pr_sha --context $github_context"

    echo "testing PR: https://github.com/$github_pr_repo/pull/$github_pr_id"
    sudo ZYPP_LOCK_TIMEOUT=$ZYPP_LOCK_TIMEOUT zypper -n install "rubygem(netrc)" "rubygem(octokit)"

    if ! $ghpr --action is-latest-sha $ghpr_paras --pr $github_pr_id ; then
        $ghpr --action set-status $ghpr_paras --status "error" --targeturl $BUILD_URL --message "SHA1 mismatch, newer commit exists"
        exit 1
    fi

    trap "mkcloudgating_trap" ERR

    if [[ "$github_pr_repo" = "SUSE-Cloud/cct" ]]; then
        export want_cct_pr=$github_pr_id
    fi

    $ghpr --action set-status $ghpr_paras --status "pending" --targeturl $BUILD_URL --message "Started PR gating"

fi

cp ${automationrepo}/scripts/jenkins/log-parser/openstack-mkcloud-rules.txt \
    $WORKSPACE/log-parser-plugin-rules.txt

echo "########################################################################"
env
echo "########################################################################"

MKCLOUDTARGET=$mkcloudtarget
[ $UPDATEBEFOREINSTALL == "true" ] && MKCLOUDTARGET='cleanup prepare setupadmin addupdaterepo instcrowbar setupcompute instcompute proposal testsetup'

[ $(uname -m) = s390x ] && WITHCROWBARREGISTER=true
if [ $WITHCROWBARREGISTER == "true" ] ; then
  export nodenumberlonelynode=1
  [ $(uname -m) = s390x ] && {
      export nodenumberlonelynode=$nodenumber
      export nodenumber=0
      export controller_node_memory=8388608
      export compute_node_memory=6291456
  }
  MKCLOUDTARGET+=" setuplonelynodes crowbar_register"
fi

[ $(uname -m) = aarch64 ] && {
    export vcpus=16
}

pushd ~/pool/
    # free up a pool if more than one is reserved
    # policy allows only one reservation per host at the moment
    ls -1 | grep -v "^[0-9]\+$" | sort -R | head -n -1 | while read p ; do mv $p ${p%%.*} ; done
popd

starttime=`date +%s`

# CHECKPROC in env tells 'allocpool' the process name to compare
export CHECKPROC=mkcloud
mkcloudwrapper="${automationrepo}/scripts/mkcloudhost/allocpool ${automationrepo}/scripts/mkcloudhost/mkcloude"

export clouddescription="Jenkins Build: $BUILD_NUMBER / $JOB_NAME"

$custom_settings

perl -e "alarm 6*60*60 ; exec '${mkcloudwrapper} bash ${automationrepo}/scripts/mkcloud setuphost $(echo -n $MKCLOUDTARGET) ' ; print qq{$!\n} ; exit 127 " | tee $artifacts_dir/mkcloud_short_stdout.log
ret=${PIPESTATUS[0]}
if [[ $ret != 0 ]] ; then
    if [[ $github_pr_sha ]] ; then
      mkcloudgating_trap
    else
      $jtsync --ci suse --job $JOB_NAME 1
    fi
    echo "mkcloud ret=$ret"
    exit $ret # check return code before tee
fi

# report mkcloud-gating status or jenkins trello status
if [[ $github_pr_sha ]] ; then
  $ghpr --action set-status --debugratelimit $ghpr_paras --status "success" --targeturl $BUILD_URL --message "PR gating succeeded"
  trap "-" ERR
else
  $jtsync --ci suse --job $JOB_NAME 0
fi
