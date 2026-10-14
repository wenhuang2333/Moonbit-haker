#!/bin/sh
# Rebuild the browser demo bundle from the MoonBit source.
#
#   cd code && moon build examples/web --target js --release
#   cp code/_build/js/release/build/examples/web/web.js static/demo/jsonmend.js
#
# The bundle registers `jsonmend.repair`, `jsonmend.report` and
# `jsonmend.snapshot` on `globalThis` through the host hooks in
# `code/examples/web/main.mbt`.
set -e
cd "$(dirname "$0")/../.."
export PATH="$HOME/.moon/bin:$PATH"
(cd code && moon build examples/web --target js --release)
cp code/_build/js/release/build/examples/web/web.js static/demo/jsonmend.js
echo "wrote static/demo/jsonmend.js"
