# This file shares common code between mkcloud-${mkclouddriver}.sh files and qa_crowbarsetup.sh

# defaults for generic common variables
: ${admin_image_password:='linux'}
: ${clouddatadns:=clouddata.nue.suse.com}
: ${clouddata:=$(dig -t A +short $clouddatadns)}
: ${clouddata_base_path:="/repos"}
: ${clouddata_nfs:=$clouddata}
: ${clouddata_nfs_dir:='srv/nfs'}
: ${distsuse:=dist.nue.suse.com}
distsuseip=$(dig -t A +short $distsuse)
: ${susedownload:=download.nue.suse.com}
: ${libvirt_type:=kvm}
: ${networkingplugin:=openvswitch}
: ${arch:=$(uname -m)}
: ${architectures:='aarch64 x86_64 s390x'}
: ${nodenumberlonelynode:=0}

function max
{
    echo $(( $1 > $2 ? $1 : $2 ))
}

function wait_for
{
    local timecount=${1:-300}
    local timesleep=${2:-1}
    local condition=${3:-'/bin/true'}
    local waitfor=${4:-'unknown process'}
    local error_cmd=${5:-'exit 11'}

    local original_xstatus=${-//[^x]/}
    set +x
    echo "Waiting for: $waitfor"
    echo "  until this condition is true: $condition"
    echo "  waiting $timecount cycles of $timesleep seconds = $(( $timecount * $timesleep )) seconds"
    local n=$timecount
    while test $n -gt 0 && ! eval $condition
    do
        echo -n .
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

function rubyjsonparse
{
    $ruby -e "
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

function determine_mtu
{
    LC_ALL=C sort -n /sys/class/net/*/mtu | head -n 1
}

function is_suse
{
    grep -qi suse /etc/*release
}

function is_onhost
{
    # match for the mkcloud script name in the BASH_SOURCE stack
    # note: the path may differ, so only match a leading slash
    [[ " ${BASH_SOURCE[@]} " =~ "/mkcloud " ]]
}

function is_onadmin
{
    [[ $BASH_SOURCE =~ qa_crowbarsetup.sh$ ]] && [[ ! $is_oncontroller ]]
}

function is_oncontroller
{
    [[ $BASH_SOURCE =~ qa_crowbarsetup.sh$ ]] && [[ $is_oncontroller ]]
}

sshopts="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oServerAliveInterval=20"
scp="scp $sshopts"
ssh="ssh $sshopts"
function ssh_password
{
    SSH_ASKPASS=/root/echolinux
    cat > $SSH_ASKPASS <<EOSSHASK
#!/bin/sh
echo $admin_image_password
EOSSHASK
    chmod +x $SSH_ASKPASS
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
    local end_id=$(($nodenumber + $nodenumberlonelynode))
    case $type in
        normal|pxe)
            end_id=$nodenumber
        ;;
        lonely|preinstalled)
            start_id=$(($nodenumber + 1))
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
    ${mkclouddriver}_do_macfunc $1
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
    net=${net_admin:-192.168.124}
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
            want_ipmi=true
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
            want_ipmi=true
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
            want_ipmi=true
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
            want_ipmi=true
        ;;
        d3)
            nodenumbertotal=3
            net=$netp.189
            net_public=$netp.188
            vlan_storage=586
            vlan_sdn=$vlan_storage
            vlan_public=588
            #vlan_admin=587
            vlan_fixed=589
            want_ipmi=true
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
            want_ipmi=true
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
            want_ipmi=true
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
            want_ipmi=true
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
    vlan_public=${vlan_public:-300}
    vlan_fixed=${vlan_fixed:-500}
    vlan_sdn=${vlan_sdn:-400}
    net_fixed=${net_fixed:-192.168.123}
    net_public=${net_public:-192.168.122}
    net_storage=${net_storage:-192.168.125}
    net_sdn=${net_sdn:-192.168.130}
    : ${admingw:=$net.1}
    : ${adminip:=$net.10}
}

# Returns success if a change was made
function confset
{
    local file="$1"
    local key="$2"
    local value="$3"
    if grep -q "^$key *= *$value" "$file"; then
        return 1 # already set correctly
    fi

    local new_line="$key = $value"
    if grep -q "^$key[ =]" "$file"; then
        # change existing value
        sed -i "s/^$key *=.*/$new_line/" "$file"
    elif grep -q "^# *$key[ =]" "$file"; then
        # uncomment existing setting
        sed -i "s/^# *$key *=.*/$new_line/" "$file"
    else
        # add new setting
        echo "$new_line" >> "$file"
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
    local pack
    for pack in "$@" ; do
        rpm -q $pack &> /dev/null || safely install_trying_all_versions "$pack"
    done
}

function install_trying_all_versions
{
    local package_name
    package_name="$1"

    local available_versions
    available_versions="$(zypper search -s $package_name --non-interactive |
        grep $package_name |
        cut -d'|' -f 4 |
        tr -d ' ' |
        sort -r)"
    local zypper_params="--non-interactive --gpg-auto-import-keys --no-gpg-checks"
    local package_name_with_version

    for version in $available_versions; do
        package_name_with_version="${package_name}-${version}"
        echo "Trying to install $package_name_with_version"
        if zypper $zypper_params install "$package_name_with_version"; then
            return 0
        fi
    done

    return 1
}

function zypper_refresh
{
    # --no-gpg-checks for Devel:Cloud repo
    safely zypper -v --gpg-auto-import-keys --no-gpg-checks -n ref
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
    elif [[ $cloudsource =~ ^(.+7|M[[:digit:]]+|Beta[[:digit:]]+|RC[[:digit:]]*|GMC[[:digit:]]*|GM7?(\+up)?)$ ]] ; then
        echo -n 7
    else
        complain 11 "unknown cloudsource version"
    fi
}

# return if cloudsource is referring a certain SUSE Cloud version
# input1: version - 6plus refers to version 6 or later ; only a number refers to one exact version
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

function get_admin_node_dist
{
    # echo the name of the current dist for the admin node
    local dist=
    case $(getcloudver) in
        7)  dist=SLE12SP2
            [[ $want_sles12sp1_admin ]] && dist=SLE12SP1
            ;;
        6)  dist=SLE12SP1 ;;
        5)  dist=SLE11    ;;
        *)  dist=SLE11    ;;
    esac
    echo "$dist"
}

function get_lonely_node_dist
{
    local dist=$(get_admin_node_dist)
    iscloudver 5 && [[ $want_sles12 ]] && dist=SLE12
    echo $dist
}

function dist_to_image_name
{
    # get the name of the image to deploy the admin node
    local dist=$1
    case $dist in
        SLE12SP2) image=SLES12-SP2 ;;
        SLE12SP1) image=SLES12-SP1 ;;
        SLE12)    image=SLES12     ;;
        SLE11)    image=SP3-64up   ;;
        *)
            complain 71 "No admin node image defined for this distribution: $dist"
        ;;
    esac
    iscloudver 7plus && [[ $want_efi ]] && \
        [[ $arch == x86_64 ]] && image="SLES12-SP2-uefi"
    echo "$image.qcow2"
}

# ---- END: functions related to repos and distribution settings
