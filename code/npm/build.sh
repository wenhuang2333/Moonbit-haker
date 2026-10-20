#!/bin/sh
# Rebuild the npm package's vendored engine from the MoonBit source.
#
#   bash code/npm/build.sh
#
# The browser demo and the npm package use the same bundle, so this delegates
# to static/demo/build.sh and copies the result. CI runs `git diff --exit-code`
# on both files.

set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
export PATH="$HOME/.moon/bin:$PATH"
bash "$root/static/demo/build.sh"
mkdir -p "$here/vendor"
cp "$root/static/demo/jsonmend.js" "$here/vendor/jsonmend.js"
echo "wrote code/npm/vendor/jsonmend.js"
