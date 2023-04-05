#!/bin/bash

set -eufo pipefail

usage() {
cat <<EOS
Usage: $0

Watch files and live-reload the blog

Press enter to choose an output file using fzf.
EOS
}

output=
entr_pid=
ncpu=$(sysctl -n hw.ncpu)

main() {
    if [[ "$(uname -s)" != Darwin ]]; then
        die "this script only works on macOS"
    fi

    cd "$(dirname "$0")"
    trap cleanup EXIT
    while :; do
        new_output=$(! make -qp | rg '^(public/.*\.html):' -r '$1' -o | fzf)
        output=${new_output:-$output}
        kill_entr
        fd | entr -ns 'refresh' & entr_pid=$!
        read -r
    done
}

refresh() {
    if make "-j$ncpu" "$output" public/style.css; then
        open -g "$output"
    fi
}

# Make functions work in entr.
export SHELL=/bin/bash
export output
export -f refresh

cleanup() {
    kill_entr
    rm -f render.sock
}

kill_entr() {
    if [[ -n "$entr_pid" ]]; then
        kill "$entr_pid" || :
    fi
}

case $# in
    0) main ;;
    1)
        case $1 in
            -h|--help) usage ;;
            *) usage >&2; exit 1 ;;
        esac
        ;;
    *) usage >&2; exit 1 ;;
esac
