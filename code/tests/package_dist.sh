#!/usr/bin/env bash
# The two language packages must be publishable as they stand.
#
#   bash tests/package_dist.sh
#
# Why this exists
# ---------------
#
# Apache-2.0 section 4 says a redistributor has to pass the licence and the
# NOTICE on. Both packages had neither, and nothing checked: the npm tarball
# and the Python wheel were only ever built by hand, so "the package is
# publishable" was an assumption nobody had tested. It is now built, inspected
# and installed.
#
# The check is deliberately about the *artefact* rather than about the source
# files: a `LICENSE` in the working tree proves nothing if the manifest does
# not ship it.
#
# Exit codes: 0 all good, 1 a problem, 2 the check could not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1" >&2
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 2; }
command -v npm >/dev/null 2>&1 || { echo "npm is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

NPM_VERSION="$(node -p "require('./code/npm/package.json').version")"
PY_VERSION="$(python3 - <<'PY'
import re
text = open('code/python/pyproject.toml', encoding='utf-8').read()
m = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
print(m.group(1) if m else "")
PY
)"
MOD_VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' code/moon.mod)"

# --- the versions must agree ------------------------------------------------
for pair in "npm:$NPM_VERSION" "python:$PY_VERSION" "moon.mod:$MOD_VERSION"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [ "$value" != "$MOD_VERSION" ]; then
    fail "$name declares version $value but code/moon.mod says $MOD_VERSION"
  fi
done

# --- the npm tarball --------------------------------------------------------
echo "building the npm tarball..."
(cd code/npm && npm pack --pack-destination "$TMP" >/dev/null 2>&1)
TARBALL="$(ls "$TMP"/interjson-moonbit-*.tgz 2>/dev/null | head -1)"
if [ -z "$TARBALL" ]; then
  fail "npm pack produced no tarball"
else
  ENTRIES="$(tar tzf "$TARBALL" | sed 's|^package/||')"
  for want in LICENSE NOTICE README.md index.cjs index.mjs index.d.ts mcp.cjs vendor/interjson.js; do
    printf '%s\n' "$ENTRIES" | grep -qx "$want" || fail "the npm tarball does not contain $want"
  done
  # The launcher is the product: without it `interjson-mcp` is not on PATH.
  printf '%s\n' "$ENTRIES" | grep -qx "mcp.cjs" || fail "the npm tarball has no MCP launcher"
fi

# --- the Python wheel -------------------------------------------------------
echo "building the Python wheel..."
# `--no-build-isolation` uses the setuptools that is already installed; with
# isolation the build tries to download setuptools, which a sandboxed or
# offline machine cannot do.
python3 -m pip wheel --no-deps --no-build-isolation -w "$TMP/wheel" code/python >/dev/null 2>&1
WHEEL="$(ls "$TMP"/wheel/*.whl 2>/dev/null | head -1)"
if [ -z "$WHEEL" ]; then
  fail "the Python wheel could not be built"
else
  NAMES="$(python3 -c "
import sys, zipfile
print('\\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))
" "$WHEEL")"
  printf '%s\n' "$NAMES" | grep -q 'interjson/py.typed' ||
    fail "the Python wheel does not contain the py.typed marker"
  printf '%s\n' "$NAMES" | grep -qE '(^|/)LICENSE$' ||
    fail "the Python wheel does not contain LICENSE"
  printf '%s\n' "$NAMES" | grep -qE '(^|/)NOTICE$' ||
    fail "the Python wheel does not contain NOTICE"
fi

# --- the installed package must work ----------------------------------------
echo "installing the npm tarball..."
mkdir -p "$TMP/inst" && cd "$TMP/inst"
npm init -y >/dev/null 2>&1
npm install --no-audit --no-fund "$TARBALL" >/dev/null 2>&1
if ! node -e "
const ij = require('interjson-moonbit');
const plan = ij.gate('{\"a\":1,\"a\":2}');
if (ij.version !== '$NPM_VERSION') { throw new Error('version mismatch'); }
if (plan.executable !== false) { throw new Error('the gate accepted a lossy merge'); }
if (!plan.retry || !plan.retry.prompt) { throw new Error('a refusal carries no prompt'); }
if (ij.repair(\"{'a':1,}\") !== '{\"a\":1}') { throw new Error('repair is wrong'); }
" >/dev/null 2>&1; then
  fail "the installed npm package does not behave as documented"
fi

cd "$ROOT" || exit 2
if [ "$FAIL" -gt 0 ]; then
  printf '\npackage_dist.sh: %d problem(s). The packages are meant to be publishable,\n' "$FAIL" >&2
  printf 'and that is a property of the built artefact, not of the source tree.\n' >&2
  exit 1
fi
printf '\npackage_dist.sh: OK — both packages build, carry LICENSE and NOTICE, and the\n'
printf 'installed npm package behaves as documented.\n'
