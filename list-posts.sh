#!/bin/bash

set -euo pipefail

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

gawk -F ': ' '
BEGIN { print "["; }
FNR == 1 { print "{\"path\": \"" FILENAME "\""; next; }
$0 == "---" { nextfile; }
/.*/ { print ",\"" $1 "\": \"" $2 "\""; }
ENDFILE { print "}"; }
END { print "]"; }
' | jq posts/*.md


exit

# Only include drafts in the default DESTDIR.
case $DESTDIR in
    public) pat='.+' ;;
    *) pat='[0-9-]+' ;;
esac

rg -m 1 "^date: (.+)\$" -o -r '$1' posts \
    | sort -t: -k2 -r \
    | sed -En "s#^posts/(.+)\.md:$pat\$#post/\1/index.html#p" \
    | tee "$tmp" \
    | sed "s#^#$DESTDIR/#"

f=$DESTDIR/.posts.txt
if ! cmp -s "$tmp" "$f"; then
    mkdir -p "$DESTDIR"
    mv -f "$tmp" "$f"
fi
