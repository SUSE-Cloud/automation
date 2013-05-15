#!/bin/bash
#
# Compares two branches of each crowbar barclamp repositories using
# 'git icing' (a wrapper around git cherry).  Run with --help for help.

DEFAULT_UPSTREAM=crowbar/release/pebbles/master
DEFAULT_LOCAL=suse/release/essex-hack-suse/master

compare () {
    local="$1"
    upstream="$2"
    name="$3"

    [ "$verbosity" -gt 0 ] && echo -e "\e[0;1mComparing $name: $local with $upstream ...\e[0m"

    for ref in "$upstream" "$local"; do
        if ! git cat-file -e "$ref" >&/dev/null; then
            [ "$verbosity" -gt 0 ] && echo -e "\e[1;35m$ref does not exist in $name\e[0m" >&2
            return 1
        fi
    done

    #git --no-pager log --no-merges --pretty=format:%H $upstream..$local
    if [ "$verbosity" -gt 0 ]; then
        icing_verbosity=$(($verbosity - 1))
    else
        icing_verbosity=0
    fi
    git icing -v$icing_verbosity "$upstream" "$local" | count_commits_not_upstreamed

    if [ "$verbosity" = 0 ]; then
        echo -n "." >&2
    else
        echo
    fi
}

count_commits_not_upstreamed () {
    tmp=$( mktemp /tmp/compare-crowbar-upstream.XXXXXXXXX ) || exit 1
    if [ "$verbosity" -le 1 ]; then
        cat >"$tmp"
    else
        tee "$tmp"
    fi
    escape=$'\033'
    count=$( grep -chE "^(${escape}\[[0-9;]+m)?\+ " "$tmp" )
    [ "$count" -gt 0 ] && printf "  %4d  %s\n" "$count" "$name" >> $counts_tmp
    rm "$tmp"
}

get_barclamps () {
    # This only works if we have the right branch checked out ...
    (
        cd barclamps
        for d in *; do
            [ -d "$d" ] && echo "$d"
        done
    )
    #git submodule --quiet foreach 'echo ${name#barclamps/}'
}

usage () {
    # Call as: usage [EXITCODE] [USAGE MESSAGE]
    exit_code=1
    if [[ "$1" == [0-9] ]]; then
        exit_code="$1"
        shift
    fi
    if [ -n "$1" ]; then
        echo "$*" >&2
        echo
    fi

    me=`basename $0`

    cat <<EOF >&2
Usage: $me [OPTIONS] [UPSTREAM [LOCAL]]

Options:
  -h, --help             Show this help and exit
  -v [N], --verbose [N]  Set verbosity level [default without -v is 2,
                         default with -v and no number N is 3]

Compares local branch of crowbar and barclamps repositories with upstream
using 'git cherry -v'.  Commits missing from upstream are prefixed with
a plus (+) symbol, and commits with an equivalent change already upstream
are prefixed with a minus (-) symbol.

Must be run from the top-level crowbar repository.

See git-icing for how to add commits to the blacklist which marks them as
not suitable for upstreaming.

UPSTREAM is the upstream branch to compare [$DEFAULT_UPSTREAM]
LOCAL is the local branch to compare [$DEFAULT_LOCAL]
EOF
    exit "$exit_code"
}

parse_opts () {
    verbosity=2

    while [ $# != 0 ]; do
        case "$1" in
            -h|--help)
                usage 0
                ;;
            -v|--verbose)
                verbosity=3
                shift
                case "$1" in
                    [0-9])
                        verbosity="$1"
                        shift
                        ;;
                esac
                ;;
            -*)
                usage "Unrecognised option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [ $# -gt 2 ]; then
        usage
    fi

    ARGV=( "$@" )
}

check_prereqs () {
    if ! which git-icing >/dev/null 2>&1; then
        cat >&2 <<EOF
This script needs git-icing.  Please download from

    https://raw.github.com/aspiers/git-config/master/bin/git-icing

and save as an executable somewhere on your \$PATH.
EOF
        exit 1
    fi
}

main () {
    check_prereqs

    parse_opts "$@"

    if ! [ -f dev ]; then
        echo "You must run this from the top of the crowbar tree; aborting." >&2
        exit 1
    fi

    toplevel=`pwd`

    upstream="${ARGV[0]:-$DEFAULT_UPSTREAM}"
    local="${ARGV[1]:-$DEFAULT_LOCAL}"

    counts_tmp=$( mktemp /tmp/compare-crowbar-upstream-tmp.XXXXXXXXX ) || exit 1

    get_barclamps | while read name; do
        if ! cd "$toplevel/barclamps/$name"; then
            echo -e "\n\e[1;33m$name barclamp not found; skipping.\e[0m"
            continue
        fi

        compare "$local" "$upstream" "$name barclamp"
    done

    [ "$verbosity" = 0 ] && echo >&2

    echo -e "\e[0;1mTotal patches to upstream"
    echo -e "-------------------------\e[0m"
    echo

    sort -nr "$counts_tmp"
    rm "$counts_tmp"
}

main "$@"
