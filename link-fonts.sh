#!/bin/bash

set -eufo pipefail

config=config/development/module.toml

usage() {
    cat <<EOS
Usage: $0 PATH

Write $config so that Hugo will look for .woff2 font files in PATH
when running in the development environment.

In production, the fonts are located elsewhere in the website and that relative
path is provided via HUGO_PARAMS_FONTPATH.
EOS
}

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

path=$(realpath "$1")

if ! find "$path" -type f -name "*.woff2" | grep -q .; then
    echo >&2 "No .woff2 files found in $path"
    exit 1
fi

mkdir -p "$(dirname "$config")"

cat <<EOS > "$config"
[[mounts]]
source = "$path"
target = "static/fonts"
includeFiles = "/*.woff2"
EOS

echo "Wrote $config"
