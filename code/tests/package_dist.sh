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
# The publishable wheel is the one `build_wheel.sh` produces: it carries the
# engine for every release platform, so `pip install interjson-moonbit` is the
# whole install. A plain `pip wheel` on a checkout builds the client without
# the binaries, and that artefact is *not* what gets published -- shipping it
# would reproduce the bug this exists to prevent, a first call that fails with
# FileNotFoundError.
echo "building the Python wheel..."
# The gate builds its own wheel from the binary this checkout just compiled.
# That keeps the packaging path under test on every commit without needing a
# published release (which would make the gate depend on a previous tag), and
# it is the same code path that produces the published wheel -- only the set
# of platforms differs.
EXTRA_WHEEL="$(mktemp -d "${TMPDIR:-/tmp}/interjson-wheelgate.XXXXXX")"
HOST_KEY=""
case "$(python3 -c 'import platform,sys; print(sys.platform, platform.machine().lower())')" in
  "darwin arm64")   HOST_KEY="macos-arm64" ;;
  "linux x86_64")   HOST_KEY="linux-x86_64" ;;
  "linux aarch64")  HOST_KEY="linux-arm64" ;;
  "linux arm64")    HOST_KEY="linux-arm64" ;;
esac
WHEEL=""
if [ -n "$HOST_KEY" ] && [ -f "$ROOT/code/_build/native/release/build/cmd/interjson/interjson.exe" ]; then
  if bash "$ROOT/code/python/build_wheel.sh" --from-local "$HOST_KEY" \
    --platforms "$HOST_KEY" --out "$EXTRA_WHEEL" >/dev/null 2>&1; then
    WHEEL="$(ls "$EXTRA_WHEEL"/interjson_moonbit-*.whl 2>/dev/null | head -1)"
  fi
fi
if [ -z "$WHEEL" ]; then
  # No local build to package: fall back to a wheel someone already built.
  WHEEL="$(ls "$ROOT"/dist/python/interjson_moonbit-*.whl 2>/dev/null | head -1)"
fi
if [ -z "$WHEEL" ]; then
  fail "no Python wheel was built; run bash code/python/build_wheel.sh first"
else
  NAMES="$(python3 -c "
import sys, zipfile
print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))
" "$WHEEL")"
  printf '%s\n' "$NAMES" | grep -q 'interjson/py.typed' ||
    fail "the Python wheel does not contain the py.typed marker"
  printf '%s\n' "$NAMES" | grep -qE '(^|/)LICENSE$' ||
    fail "the Python wheel does not contain LICENSE"
  printf '%s\n' "$NAMES" | grep -qE '(^|/)NOTICE$' ||
    fail "the Python wheel does not contain NOTICE"
  # Self-contained: the wheel carries the engine for the platform it will be
  # installed on. A full release wheel carries all four; the gate's own build
  # carries the host platform, which is the one that can be executed here.
  if [ -n "$HOST_KEY" ]; then
    if ! printf '%s\n' "$NAMES" | grep -qE "interjson/bin/$HOST_KEY/interjson(\.exe)?$"; then
      fail "the Python wheel does not carry the engine for $HOST_KEY"
    fi
  fi
  # A wheel built by `build_wheel.sh` must never be engine-less: that is the
  # regression this gate exists for.
  if ! printf '%s\n' "$NAMES" | grep -q 'interjson/bin/'; then
    fail "the Python wheel carries no engine at all"
  fi
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

# --- the installed Python wheel must work with nothing else installed --------
# This is the whole point of the bundled binaries: a reader who runs
# `pip install interjson-moonbit` on a machine with no MoonBit toolchain, no
# `interjson` on PATH and no INTERJSON_BIN must be able to make a call. The
# environment is scrubbed here so a developer's own setup cannot hide a wheel
# that only works because an engine happened to be lying around.
if [ -n "${WHEEL:-}" ]; then
  echo "installing the Python wheel into an empty virtualenv..."
  python3 -m venv "$TMP/pyenv" >/dev/null 2>&1
  if "$TMP/pyenv/bin/pip" install --no-index --no-deps -q "$WHEEL" >/dev/null 2>&1; then
    if ! env -u INTERJSON_BIN PATH="$TMP/pyenv/bin:/usr/bin:/bin" \
      "$TMP/pyenv/bin/python" - "$PY_VERSION" <<'PY' >/dev/null 2>&1
import sys
from interjson import Client, __version__, find_binary

assert __version__ == sys.argv[1], f"version {__version__} != {sys.argv[1]}"
binary = find_binary()
assert "site-packages" in binary, f"did not use the bundled engine: {binary}"
with Client() as jm:
    result = jm.repair("{'a':1,}")
    assert result["text"] == '{"a":1}', result["text"]
    plan = jm.analyze('{"a":1,"a":2}', profile="agent")
    assert plan["executable"] is False, plan
    assert plan["retry"]["prompt"], "a refusal carries no prompt"
PY
    then
      fail "the installed Python wheel does not work without an external engine"
    fi
    # The console scripts are the MCP surface; they must start too.
    if ! env -u INTERJSON_BIN PATH="$TMP/pyenv/bin:/usr/bin:/bin" \
      "$TMP/pyenv/bin/interjson-mcp" --version >/dev/null 2>&1; then
      fail "interjson-mcp from the installed wheel does not start"
    fi
  else
    fail "the Python wheel could not be installed into an empty virtualenv"
  fi
fi

rm -rf "$EXTRA_WHEEL"

cd "$ROOT" || exit 2
if [ "$FAIL" -gt 0 ]; then
  printf '\npackage_dist.sh: %d problem(s). The packages are meant to be publishable,\n' "$FAIL" >&2
  printf 'and that is a property of the built artefact, not of the source tree.\n' >&2
  exit 1
fi
printf '\npackage_dist.sh: OK — both packages build, carry LICENSE and NOTICE, and the\n'
printf 'installed npm package behaves as documented. The Python wheel carries the\n'
printf 'engine for its platform and works with nothing else installed.\n'
