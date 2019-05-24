#!/bin/sh -x
exec >> /root/cleanvm.log 2>&1

IS_HEAT=_NOTHEAT

if [ "$IS_HEAT" = HEAT ]; then
    # When run by Heat template, these will be substituted with the template's parameters
    OSHEAD=_TESTHEAD
    cloudsource=_cloudsource
    automation_repo=_automation_repo
    automation_branch=_automation_branch
    quickstart_repo=_quickstart_repo
    quickstart_branch=_quickstart_branch
    package_repo=_package_repo
    allow_vendor_change=_allow_vendor_change
else
    # In standalone mode these defaults are used:
    : ${OSHEAD:=1}
    : ${cloudsource:=openstackocata}
    : ${automation_repo:='https://github.com/suse-cloud/automation.git'}
    : ${automation_branch:='master'}
    :  ${quickstart_repo:='https://github.com/suse-cloud/openstack-quickstart.git'}
    : ${quickstart_branch:='stable/ocata'}
    : ${package_repo:=''}
    : ${allow_vendor_change:=''}
fi

export OSHEAD cloudsource allow_vendor_change automation_repo automation_branch quickstart_repo quickstart_branch package_repo

if [ -n "$package_repo" ]; then
    zypper ar --priority 22 -G -f "$package_repo" extra
fi

. /etc/os-release; # retrieve VERSION_ID

zypper='zypper --non-interactive'

case "$VERSION_ID" in
    "12.4")
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12-SP4/x86_64/product/' SLE12-SP4-Pool
        $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12-SP4/x86_64/update/' SLES12-SP4-Updates
        ;;
    "12.3")
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12-SP3/x86_64/product/' SLE12-SP3-Pool
        $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12-SP3/x86_64/update/' SLES12-SP3-Updates
        ;;
    "12.2")
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12-SP1/x86_64/product/' SLE12-SP1-Pool
        $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12-SP1/x86_64/update/' SLES12-SP1-Updates
        ;;
    "12.1")
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12-SP1/x86_64/product/' SLE12-SP1-Pool
        $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12-SP1/x86_64/update/' SLES12-SP1-Updates
        ;;
    "12")
        $zypper ar 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Products/SLE-SERVER/12/x86_64/product/' SLES12-Pool
        $zypper ar -f 'http://smt-internal.opensuse.org/repo/$RCE/SUSE/Updates/SLE-SERVER/12/x86_64/update/' SLES12-Updates
        ;;
    *)
        echo "Error: Add repo urls in $0 for: $VERSION_ID"
        exit 1
        ;;
esac

zypper --non-interactive install git-core ca-certificates-mozilla

# override openstack-quickstart if an alternate repo was specified
if [ -n "$quickstart_repo" ]; then
    export QUICKSTART_DEBUG=1
    git clone $quickstart_repo  --branch $quickstart_branch /root/openstack-quickstart
    install -p -m 755 /root/openstack-quickstart/scripts/keystone_data.sh /tmp
    install -p -m 755 /root/openstack-quickstart/lib/functions.sh /tmp
    install -p -m 644 /root/openstack-quickstart/etc/bash.openstackrc /tmp
    install -p -m 755 /root/openstack-quickstart/scripts/openstack-loopback-lvm /tmp
    install -p -m 755 /root/openstack-quickstart/scripts/openstack-quickstart-demosetup /tmp
    install -p -m 600 /root/openstack-quickstart/etc/openstackquickstartrc /tmp
fi

git clone $automation_repo --branch $automation_branch /root/automation

sh -x /root/automation/scripts/jenkins/qa_openstack.sh &&
touch /root/cleanvm_finished
