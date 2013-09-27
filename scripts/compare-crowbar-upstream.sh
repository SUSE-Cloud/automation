#!/bin/bash
#
# Compares two branches of each crowbar barclamp repositories using
# 'git icing' (a wrapper around git cherry).  Run with --help for help.

DEFAULT_TARGET=crowbar/release/pebbles/master
DEFAULT_SOURCE=suse/release/essex-hack-suse/master

compare () {
    source="$1"
    target="$2"
    name="$3"

    [ "$verbosity" -gt 0 ] && echo -e "\e[0;1mComparing $name: $source with $target ...\e[0m"

    for ref in "$target" "$source"; do
        if ! git cat-file -e "$ref" >&/dev/null; then
            [ "$verbosity" -gt 0 ] && echo -e "\e[1;35m$ref does not exist in $name\e[0m" >&2
            return 1
        fi
    done

    #git --no-pager log --no-merges --pretty=format:%H $target..$source
    git icing -s -v$verbosity "$target" "$source" | count_commits_not_upstreamed

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
    count=$( sed -n '/ commits remaining:/{s///;p}' "$tmp" )
    [ -n "$count" ] && [ "$count" -gt 0 ] && printf "  %4d  %s\n" "$count" "$name" >> $counts_tmp
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
Usage: $me [OPTIONS] [TARGET [SOURCE]]

Options:
  -h, --help             Show this help and exit
  -v [N], --verbose [N]  Set verbosity level [default without -v is 2,
                         default with -v and no number N is 3]

Compares a source branch of crowbar and barclamps repositories with a target
using 'git cherry -v'.  Commits missing from the target are prefixed with
a plus (+) symbol, and commits with an equivalent change already in the target
are prefixed with a minus (-) symbol.

Must be run from the top-level crowbar repository.

See git-icing for how to add commits to the blacklist which marks them as
not suitable for upstreaming.

TARGET is the target branch to compare [$DEFAULT_TARGET]
SOURCE is the source branch to compare [$DEFAULT_SOURCE]
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

    target="${ARGV[0]:-$DEFAULT_TARGET}"
    source="${ARGV[1]:-$DEFAULT_SOURCE}"

    counts_tmp=$( mktemp /tmp/compare-crowbar-upstream-tmp.XXXXXXXXX ) || exit 1

    get_barclamps | while read name; do
        if ! cd "$toplevel/barclamps/$name"; then
            echo -e "\n\e[1;33m$name barclamp not found; skipping.\e[0m"
            continue
        fi

        compare "$source" "$target" "$name barclamp"
    done

    [ "$verbosity" = 0 ] && echo >&2

    echo -e "\e[0;1mTotal patches to upstream"
    echo -e "-------------------------\e[0m"
    echo

    sort -nr "$counts_tmp"
    total=$( awk '{t+=$1} END {print t}' "$counts_tmp" )
    echo "  ------------------------------"
    printf "\e[0;1m  %4d  %s\e[0m\n" "$total" "Total"

    rm "$counts_tmp"
}

main "$@"
