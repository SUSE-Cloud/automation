# This file shares common code between mkcloud-${mkclouddriver}.sh files and qa_crowbarsetup.sh

# ---- START: functions related to repos and distribution settings

function get_getent_hosts
{
    local db item element
    case $2 in
        ip4) db=ahostsv4
            item=1
        ;;
        ip6) db=ahostsv6
            item=1
        ;;
        fqdn) db=hosts
            item=2
        ;;
        *)  complain 11 "Do not know what to resolve via getent."
        ;;
    esac
    element=$(set -o pipefail ; getent "$db" "$1" | head -n1 | awk "{print \$$item}")
    if [[ $? != 0 || ! $element ]] ; then
        complain 11 "Could not resolve $1 via: getent $db"
    fi
    echo $element
}

function to_ip6
{
    echo "[$(get_getent_hosts $1 ip6)]"
}

function to_ip4
{
    get_getent_hosts $1 ip4
}

function to_ip
{
    ip=$(to_ip4 $1)
    if [ -z $ip ]; then
        ip=$(to_ip6 $1)
    fi
    echo "$ip"
}

function to_fqdn
{
    get_getent_hosts $1 fqdn
}

function wrap_ip
{
  if (( $want_ipv6 > 0 )); then
    echo "[$1]"
  else
    echo $1
  fi
}

function max
{
    echo $(( $1 > $2 ? $1 : $2 ))
}

function echofailed
{
    echo "^^^^^ failed ^^^^^" >&2
}

function wait_for
{
    local timecount=${1:-300}
    local timesleep=${2:-1}
    local condition=${3:-'/bin/true'}
    local waitfor=${4:-'unknown process'}
    local error_cmd=${5:-'exit 11'}
    local print_while=${6:-'echo -n .'}

    local original_xstatus=${-//[^x]/}
    timesleep=$((timesleep*${want_timescaling:-1}))
    set +x
    echo "Waiting for: $waitfor"
    echo "  until this condition is true: $condition"
    echo "  waiting $timecount cycles of $timesleep seconds = $(( $timecount * $timesleep )) seconds"
    local n=$timecount
    while test $n -gt 0 && ! eval $condition
    do
        eval "$print_while"
        sleep $timesleep
        n=$(($n - 1))
        [[ $(( ($timecount - $n) % 75)) != 0 ]] || echo
    done
    echo

    [[ $original_xstatus ]] && set -x
    if [ $n = 0 ] ; then
        echo "Error: Waiting for '$waitfor' timed out."
        echo "This check was used: $condition"
        eval "$error_cmd"
    fi
}

function wait_for_if_running
{
    local procname=${1}
    local timecount=${2:-300}

    wait_for $timecount 5 "! pidofproc ${procname} >/dev/null" "process '${procname}' to terminate"
}

function complain
{
    local ex=$1; shift
    printf "Error ($ex): %s\n" "$@" >&2
    [[ $ex = - ]] || exit $ex
}

function safely
{
    if "$@"; then
        true
    else
        local errmsg="$* failed! (safelyret=$?) Aborting."
        # let error_exit collect supportconfigs if running on host
        is_onhost && error_exit 30 "$errmsg"
        complain 30 "$errmsg"
    fi
}

function safely_skip_support
{
    SKIPSUPPORTCONFIG=1 safely "$@"
}

function rubyjsonparse
{
    ruby -e "
        require 'rubygems'
        require 'json'
        j=JSON.parse(STDIN.read)
        $1"
}

function intercept
{
    if [[ $shell ]] ; then
        echo "Now starting bash for manual intervention..."
        echo "When ready exit this shell to continue with $1"
        bash
    fi
}

function handle_service_dependencies
{
    [[ $want_ceilometer_proposal = 0 ]] && want_aodh_proposal=0
}

function determine_mtu
{
    ( shopt -s extglob; LC_ALL=C eval "sort -n /sys/class/net/!(lo)/mtu" | head -n 1 )
}

function is_opensuse
{
    grep -q ID=opensuse /etc/os-release
}

function is_suse
{
    grep -qi suse /etc/*release
}

function is_debian
{
    grep -q debian /etc/os-release
}

function is_onhost
{
    # match for the mkcloud script name in the BASH_SOURCE stack
    # note: the path may differ, so only match a leading slash
    [[ " ${BASH_SOURCE[@]} " =~ "/mkcloud " ]]
}

function is_onadmin
{
    [[ ${BASH_SOURCE[@]} =~ "qa_crowbarsetup.sh" ]] && [[ ! $is_oncontroller ]]
}

function is_oncontroller
{
    [[ ${BASH_SOURCE[@]} =~ "qa_crowbarsetup.sh" ]] && [[ $is_oncontroller ]]
}

timing_file_host=$artifacts_dir/timing_stats.csv
timing_file_admin=timing_stats_admin.csv
function log_timing
{
    start="$1"
    end="$2"
    kind="${3//,/}"
    item="${4//,/}"
    logfile=/dev/null
    if is_onhost ; then
        logfile="$timing_file_host"
    elif is_onadmin ; then
        logfile="$timing_file_admin"
    fi
    # csv format example:
    # 1508410033,1508410048,proposal,crowbar(default),15
    echo "$start,$end,$kind,$item,$(($end - $start))" >> $logfile
}

sshopts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=20 -oConnectTimeout=5"
scp="scp $sshopts"
ssh="ssh $sshopts"
function ssh_password
{
    SSH_ASKPASS=~/echolinux
    cat > $SSH_ASKPASS <<EOSSHASK
#!/bin/sh
echo $admin_image_password
EOSSHASK
    chmod 0700 $SSH_ASKPASS
    DISPLAY=dummydisplay:0 SSH_ASKPASS=$SSH_ASKPASS setsid $ssh -oNumberOfPasswordPrompts=1 "$@"
}

function sshtest
{
    timeout 10 $ssh -o NumberOfPasswordPrompts=0 "$@"
}

function nodes
{
    local query=${1:number}
    local type=${2:all}
    local start_id=1
    local end_id=$(($nodenumber + $nodenumberlonelynode + $nodenumberironicnode))
    case $type in
        normal|pxe)
            end_id=$nodenumber
        ;;
        lonely|preinstalled)
            start_id=$(($nodenumber + 1))
        ;;
        ironic)
            start_id=$(($nodenumber + $nodenumberlonelynode + 1))
        ;;
        all)
        ;;
    esac

    case $query in
        ids) echo `seq $start_id $end_id`
        ;;
        number) echo $(( 1 + $end_id - $start_id ))
        ;;
    esac
}

: ${macprefix:=52:54:77}
function macfunc
{
    ${mkclouddriver}_do_macfunc $@
}

function mac_to_nodename
{
    local mac=$1
    echo "d${mac//:/-}.$cloudfqdn"
}

function setcloudnetvars
{
    local cloud=$1
    export cloudfqdn=${cloudfqdn:-$cloud.cloud.suse.de}
    if [ -z "$cloud" ] ; then
        complain 101 "Parameter missing that defines the cloud name" \
            "Possible values: [p1, d2, p, virtual]" \
            "Example: $0 d2"
    fi

    # common cloud network prefix within SUSE Nuremberg:
    netp=10.162
    if (( $want_ipv6 > 0 )); then
        net=${net_admin:-'fd00:0:0:3'}
    else
        net=${net_admin:-192.168.124}
    fi
    case "$cloud" in
        p1)
            nodenumbertotal=5
            net=$netp.178
            net_public=$netp.160
            net_fixed=44.11.0
            vlan_storage=568
            vlan_sdn=$vlan_storage
            vlan_public=567
            #vlan_admin=561
            vlan_fixed=566
            want_ipmi=1
        ;;
        p2)
            net=$netp.171
            net_public=$netp.164
            net_fixed=44.0.0
            vlan_storage=563
            vlan_sdn=$vlan_storage
            vlan_public=564
            #vlan_admin=560
            vlan_fixed=565
            want_ipmi=1
        ;;
        p3)
            nodenumbertotal=3
            net=$netp.184
            net_public=$netp.187
            net_fixed=44.13.0
            vlan_storage=582
            vlan_sdn=$vlan_storage
            vlan_public=585
            #vlan_admin=584
            vlan_fixed=583
            want_ipmi=1
        ;;
        d2)
            nodenumbertotal=2
            net=$netp.186
            net_public=$netp.185
            vlan_storage=581
            vlan_sdn=$vlan_storage
            vlan_public=580
            #vlan_admin=562
            vlan_fixed=569
            want_ipmi=1
        ;;
        d3)
            nodenumbertotal=2
            net=$netp.189
            net_public=$netp.188
            vlan_storage=586
            vlan_sdn=$vlan_storage
            vlan_public=588
            #vlan_admin=587
            vlan_fixed=582 # overlap with p3 storage/sdn to use less VLAN IDs
            want_ipmi=1
        ;;
        cf1)
            net_fixed=192.168.129
            net_public=10.162.211
            net_public_size=24
            net_storage=192.168.132
        ;;
        qa2)
            nodenumbertotal=7
            net=${netp}.24
            net_public=$net
            vlan_public=12
            #vlan_admin=610
            vlan_fixed=611
            vlan_storage=612
            vlan_sdn=$vlan_storage
            want_ipmi=1
        ;;
        qa3)
            nodenumbertotal=8
            net=${netp}.25
            net_public=$net
            vlan_public=12
            #vlan_admin=615
            vlan_fixed=615
            vlan_storage=616
            vlan_sdn=$vlan_storage
            want_ipmi=1
        ;;
        qa4)
            nodenumbertotal=7
            net=${netp}.66
            net_public=$net
            #vlan_admin=754
            vlan_public=755
            vlan_storage=756
            vlan_fixed=758
            vlan_sdn=757
            want_ipmi=1
        ;;
        virtual)
                    true # defaults are fine (and overridable)
        ;;
        *)
                    true # defaults are fine (and overridable)
        ;;
    esac
    test -n "$nodenumbertotal" && nodenumber=${nodenumber:-$nodenumbertotal}
    # default networks in crowbar:
    vlan_storage=${vlan_storage:-200}
    vlan_ceph=${vlan_ceph:-600}
    vlan_public=${vlan_public:-300}
    vlan_fixed=${vlan_fixed:-500}
    vlan_sdn=${vlan_sdn:-400}
    if (( ${want_ipv6} > 0 )); then
        net_fixed=${net_fixed:-'fd00:0:0:2'}
        net_public=${net_public:-'fd00:0:0:1'}
        net_storage=${net_storage:-'fd00:0:0:4'}
        net_ceph=${net_ceph:-'fd00:0:0:5'}
        net_ironic=${net_ironic:-'fd00:0:0:6'}
        net_sdn=${net_sdn:-'fd00:0:0:7'}
        : ${adminnetmask:=64}
        : ${ironicnetmask:=64}
        : ${defaultnetmask:=64}
        : ${adminip:=${net}:5054:ff:fe77:7770}
        : ${admin_end_range:=${net}:5054:ff:fe77:7771}
        : ${admingw:=${net}${ip_sep}${ip_sep}1}
        : ${publicgw:=${net_public}${ip_sep}${ip_sep}1}
        : ${ironicgw:=${net_ironic}${ip_sep}${ip_sep}1}
    else
        net_fixed=${net_fixed:-192.168.123}
        net_public=${net_public:-192.168.122}
        net_storage=${net_storage:-192.168.125}
        net_ceph=${net_ceph:-192.168.127}
        net_ironic=${net_ironic:-192.168.128}
        net_sdn=${net_sdn:-192.168.130}
        : ${adminnetmask:=255.255.248.0}
        : ${ironicnetmask:=255.255.255.0}
        : ${defaultnetmask:=255.255.255.0}
        : ${adminip:=${net}${ip_sep}10}
        : ${admingw:=${net}${ip_sep}1}
        : ${publicgw:=${net_public}${ip_sep}1}
        : ${ironicgw:=${net_ironic}${ip_sep}1}
    fi
}

# Returns success if a change was made
function confset
{
    local file="$1"
    local key="$2"
    local value="$3"
    if $sudo grep -q "^$key *= *$value" "$file"; then
        return 1 # already set correctly
    fi

    local new_line="$key = $value"
    if $sudo grep -q "^$key[ =]" "$file"; then
        # change existing value
        $sudo sed -i "s/^$key *=.*/$new_line/" "$file"
    elif $sudo grep -q "^# *$key[ =]" "$file"; then
        # uncomment existing setting
        $sudo sed -i "s/^# *$key *=.*/$new_line/" "$file"
    else
        # add new setting
        echo "$new_line" | $sudo tee -a "$file" >/dev/null
    fi

    return 0
}

function hypervisor_has_virtio
{
    local lt=${1:-$libvirt_type}
    [[ " $lt " =~ " xen hyperv " ]] && return 1
    return 0
}

function jsonice
{
    # create indented json output
    # while taking care for empty strings (eg. replies from curl)
    (echo -n '{}'; cat -) | sed -e 's/^{}\s*{/{/' | safely python -mjson.tool
}

function ensure_packages_installed
{
    if is_suse ; then
        export ZYPP_LOCK_TIMEOUT=60
        rpm -q "$@" &> /dev/null || safely $zypper install $extra_zypper_install_params "$@"
    elif is_debian ; then
        pkglist=$(echo "$@" | sed -e '
            s/\blibvirt\b/libvirt-clients libvirt-daemon-system/;
            s/\blibvirt-python\b/python-libvirt/;
        ')
        safely $sudo apt-get -q -y install $pkglist
    else
        echo "Warning: ensure_packages_installed did not know your OS, doing nothing"
    fi
}

function zypper_refresh
{
    safely $zypper -v refresh "$@"
}

# ---- START: functions related to repos and distribution settings

function getcloudver
{
    if   [[ $cloudsource =~ ^.*(cloud|GM)3(\+up)?$ ]] ; then
        echo -n 3
    elif [[ $cloudsource =~ ^.*(cloud|GM)4(\+up)?$ ]] ; then
        echo -n 4
    elif [[ $cloudsource =~ ^.*(cloud|GM)5(\+up)?$ ]] ; then
        echo -n 5
    elif [[ $cloudsource =~ ^.*(cloud|GM)6(\+up)?$ ]] ; then
        echo -n 6
    elif [[ $cloudsource =~ ^.*(cloud|GM)7(\+up)?$ ]] ; then
        echo -n 7
    elif [[ $cloudsource =~ ^.*(cloud|GM)8(\+up)?$ ]] ; then
        echo -n 8
    elif [[ $cloudsource =~ ^(.+9|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM9?(\+up)?)$ ]] ; then
        echo -n 9
    else
        complain 11 "unknown cloudsource version"
    fi
}

# return if cloudsource is referring a certain SUSE Cloud version
# input1: version
#   6plus refers to version 6 or later
#   6minus refers to version 6 or earlier
#   6 refers to exactly version 6
function iscloudver
{
    [[ $cloudsource ]] || return 1
    local v=$1
    local operator="="
    if [[ $v =~ plus ]] ; then
        v=${v%%plus}
        operator="-ge"
    fi
    if [[ $v =~ minus ]] ; then
        v=${v%%minus}
        operator="-le"
    fi
    local ver=`getcloudver` || exit 11
    if [[ $v =~ M[0-9]+$ ]] ; then
        local milestone=${v#*M}
        v=${v%M*}
        if [[ $ver -eq $v ]] ; then
            local sourcemilestone=999 # no match for M4minus with develcloud
            if [[ $cloudsource =~ ^M[0-9]+$ ]] ; then
                sourcemilestone="${cloudsource#*M}"
            fi
            [ "$sourcemilestone" $operator "$milestone" ]
            return $?
        fi
    fi
    [ "$ver" $operator "$v" ]
    return $?
}

get_nodenumbercontroller()
{
    local nodenumbercontroller=1
    if [[ $clusterconfig == *services* ]]; then
        nodenumbercontroller=`echo ${clusterconfig}\
            | sed -e "s/^.*services[^:]*=\([[:digit:]]\+\).*/\1/"`
    fi
    # Need one more big VM for Monasca
    if iscloudver 7plus && [[ $want_monasca_proposal = 1 ]]; then
        nodenumbercontroller=$(($nodenumbercontroller+1))
    fi
    echo "$nodenumbercontroller"
}

find_fastest_clouddata_server()
{
    local cache=~/.mkcloud/fastest_clouddata_server
    if [[ -r $cache ]] && [[ $cache -nt $BASH_SOURCE ]] ; then
        exec cat $cache || exit 100
    fi
    mkdir -p ~/.mkcloud
    $scripts_lib_dir/find_fastest_server.pl clouddata.nue.suse.com. provo-clouddata.cloud.suse.de. | tee $cache
}

function get_admin_node_dist
{
    # echo the name of the current dist for the admin node
    local dist=
    case $(getcloudver) in
        9)  dist=SLES12-SP4
            ;;
        8)  dist=SLES12-SP3
            ;;
        7)  dist=SLES12-SP2
            ;;
        6)  dist=SLES12-SP1
            ;;
        *)  dist=UNKNOWN
            ;;
    esac
    echo "$dist"
}

function get_lonely_node_dist
{
    local dist=$(get_admin_node_dist)
    echo $dist
}

function dist_to_image_name
{
    # get the name of the image to deploy the admin node
    local image=$1
    echo "$image.qcow2"
}

: ${zypper:=run_zypper}
function run_zypper
{
    local params=${zypper_override_params:---non-interactive --gpg-auto-import-keys --no-gpg-checks}
    $sudo zypper $params "$@"
}

function common_set_versions
{
    if iscloudver 8; then
        suseversion=12.3
        cloudrepover="Crowbar-8"
    elif iscloudver 7; then
        suseversion=12.2
        cloudrepover=7
    elif iscloudver 6; then
        suseversion=12.1
        cloudrepover=6
    else
        suseversion=12.4
        cloudrepover="Crowbar-9"
    fi

    case "$suseversion" in
        12.1)
            slesversion=12-SP1
            slesdist=SLE_12_SP1
            sesversion=2.1
        ;;
        12.2)
            slesversion=12-SP2
            slesdist=SLE_12_SP2
            sesversion=4
        ;;
        12.3)
            slesversion=12-SP3
            slesdist=SLE_12_SP3
            sesversion=5
        ;;
        12.4)
            slesversion=12-SP4
            slesdist=SLE_12_SP4
            sesversion=5
        ;;
    esac

    if [ $want_ses_version -gt 0 ]; then
        sesversion=$want_ses_version
    fi
}

# ---- END: functions related to repos and distribution settings

# ---- START: common variables and defaults

# defaults for generic common variables
: ${arch:=$(uname -m)}
: ${admin_image_password:='linux'}
: ${susedownload:=download.nue.suse.com}

# bmc credentials
: ${bmc_user:=root}
: ${bmc_password:=cr0wBar!}

# NOTE: $clouddata and similar variables are deprecated
if [[ $clouddata || $clouddatadns || $clouddata_base_path || $clouddata_nfs || $clouddata_nfs_dir ]] ; then
    echo 'Warning: $clouddata and all related variables are deprecated.'
    echo '  please use these new variables instead:'
    echo '  - $reposerver'
    echo '    - $reposerver_base_path'
    echo '  - $nfsserver'
    echo '    - $nfsserver_base_path'
    : ${clouddatadns:=clouddata.nue.suse.com}
    : ${clouddata:=$(dig -t A +short $clouddatadns)}
    : ${clouddata_base_path:="/repos"}
    : ${clouddata_nfs:=$clouddata}
    : ${clouddata_nfs_dir:='/srv/nfs'}
    reposerver=$(dig -t A +short $clouddatadns)
    reposerver_base_path=$clouddata_base_path
    nfsserver=$(dig -t A +short $clouddatadns)
    nfsserver_base_path=$clouddata_nfs_dir
    unset clouddata clouddatadns clouddata_base_path clouddata_nfs clouddata_nfs_dir
    sleep 5
fi

# $reposerver,$nfsserver,$rsyncserver are only set from outside
# NOTE: they are not to be used in mkcloud/qa_crowbarsetup
# Please ONLY use the suffixed variables: '*_ip' or '*_fqdn'

: ${reposerver:=$(find_fastest_clouddata_server)}
: ${reposerver_ip:=$(to_ip $reposerver)}
: ${reposerver_fqdn:=$(to_fqdn $reposerver)}
: ${reposerver_base_path:=/repos}
: ${reposerver_url:=http://$reposerver_fqdn$reposerver_httpport$reposerver_base_path}
: ${imageserver_url:=http://$reposerver_fqdn$reposerver_httpport/images}

: ${nfsserver:=$reposerver}
: ${nfsserver_ip:=$(to_ip $nfsserver)}
: ${nfsserver_fqdn:=$(to_fqdn $nfsserver)}
: ${nfsserver_base_path:=/srv/nfs}

: ${rsyncserver:=$reposerver}
: ${rsyncserver_ip:=$(to_ip $rsyncserver)}
: ${rsyncserver_fqdn:=$(to_fqdn $rsyncserver)}
: ${rsyncserver_images_dir:="cloud/images/$arch"}

: ${test_internet_url:=http://$reposerver_fqdn/test}

if [[ $UID != 0 ]] ; then
    : ${sudo:=sudo}
    PATH=/sbin:/usr/sbin:/usr/local/sbin:$PATH
fi
: ${libvirt_type:=kvm}
: ${networkingplugin:=openvswitch}
if [[ "$reposerver" =~ nue.suse.com ]]; then
    : ${architectures:='aarch64 x86_64 s390x'}
else
    : ${architectures:='x86_64'}
fi
: ${nodenumbertotal:=$nodenumber}
: ${nodenumberlonelynode:=0}
: ${nodenumberironicnode:=0}
: ${want_mtu_size:=1500}
# proposals:
: ${want_magnum_proposal:=0}
: ${want_monasca_proposal:=0}
: ${want_murano_proposal:=0}
: ${want_trove_proposal:=0}

[ -z "$want_test_updates" -a -n "$TESTHEAD" ] && export want_test_updates=1

# mysql (MariaDB actually) is the default option for Cloud8
iscloudver 8plus && : ${want_database_sql_engine:="mysql"}
: ${want_external_ceph:=0}
: ${want_ses_version:=0}

# IPv6 Support
: ${want_ipv6:=0}
if (( ${want_ipv6} == 0 )); then
    : ${ip_sep:="."}
else
    : ${ip_sep:=":"}
fi

# ---- END: common variables and defaults
