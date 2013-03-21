# zypper in osc
# provide .oscrc


# fetch the latest automation updates
[ -e /root/bin/update_automation ] || wget -O /root/bin/update_automation https://raw.github.com/SUSE-Cloud/automation/master/scripts/jenkins/update_automation && chmod a+x /root/bin/update_automation
update_automation openstack-unittest-testconfig.pl

# package is a reserved name in groovy (see combination filter)
package=$component

# basic configuration
OSC_RC="$OSC_RC -A https://api.opensuse.org"
OSC_ARCH=x86_64

case $distribution in
  *-SLE-11-SP2) OSC_DIST=SLE_11_SP2
             ;;
  *-openSUSE-12.2) OSC_DIST=openSUSE_12.2
             ;;
esac

# map label to OBS project
case $distribution in
  master-*)  dist=Cloud:OpenStack:Master
          ;;
  folsom-*)  dist=Cloud:OpenStack:Folsom:Staging
          ;;
  grizzly-*) dist=Cloud:OpenStack:Grizzly:Staging
          ;;
esac

# make sure we have access to all needed packages
cloudrepo=http://download.opensuse.org/repositories/${dist//:/:\/}/${OSC_DIST}/
zypper ar $cloudrepo cloud || true
if [[ $dist =~ ":Staging" ]] ; then
  zypper ar ${cloudrepo/:\/Staging/} cloud-full || true
fi

zypper ar http://download.opensuse.org/repositories/devel:/languages:/python/${OSC_DIST}/ dlp || true
zypper mr --priority 200 dlp
zypper --gpg-auto-import-keys ref


# source config of the test
eval `openstack-unittest-testconfig.pl $dist unittest $package`


# workaround keystone timezone problem 6596 (bmwiedemann)
export TZ=UTC

################
# run the test #
################

# default test command
[ -z "$TESTCMD" ] && TESTCMD="nosetests -v"


EXTRAPKGS=""
# example:
# [ "$package" = "openstack-nova" ] && EXTRAPKGS="python-xxx"

zypper --non-interactive in -y osc

rm -rf $package
mkdir -p $package
cd $package
for p in $package $EXTRAPKGS ; do
    osc $OSC_RC getbinaries -d ./ $dist $p $OSC_DIST $OSC_ARCH
done
zypper --non-interactive ref
zypper --non-interactive rm -y $package $EXTRAPKGS || true
zypper --non-interactive in -y --force `ls *rpm`

if test -d /usr/share/${package}-test/; then
  cd /usr/share/${package}-test/
else
  cd /var/lib/${package}-test/
fi

test_exitcode=1

echo "=== Running SETUPCMD ===" > /dev/null
eval "$SETUPCMD" 
echo "=== Running TESTCMD ===" > /dev/null
$TESTCMD
test_exitcode=$?

echo "=== Running TEARDOWNCMD ===" > /dev/null
eval "$TEARDOWNCMD"

exit $test_exitcode
