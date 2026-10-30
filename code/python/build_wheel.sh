#!/usr/bin/env bash
# Build the publishable Python distributions: one wheel that carries the
# engine for every platform the release ships, plus the sdist it was built from.
#
#   bash code/python/build_wheel.sh [--from-dir DIR]
#
# Why the wheel carries the binaries
# ----------------------------------
#
# `pip install interjson-moonbit` used to install a client with no engine: the
# package is a thin client for `interjson serve`, and the binary came from the
# GitHub release. That is a working install only if the user already knew to
# fetch the binary, so the first thing a pip user saw was
#
#   FileNotFoundError: the interjson engine was not found
#
# The npm package does not have this problem because the engine compiles to
# JavaScript and travels inside the tarball. The native binary cannot be
# compiled at install time (there is no MoonBit toolchain on a normal machine),
# so it is placed in the wheel: all four release binaries, selected at runtime
# by `find_binary()`. The wheel is ~3 MB, which is noise next to numpy.
#
# The binaries are taken from the published release rather than from a local
# build, so the wheel and the release carry the same bytes and the release's
# own SHA256SUMS is the check. `--from-dir` takes a directory that already
# holds those assets (CI downloads them there; a local build does the same).
#
# Exit codes: 0 the distributions were built, 1 a failure, 2 the check could
# not run.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE"
OUT="$ROOT/dist/python"
FROM_DIR=""
LOCAL_PLATFORM=""
PLATFORMS="linux-x86_64 linux-arm64 macos-arm64 windows-x86_64"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-dir)
      [ $# -ge 2 ] || { echo "--from-dir needs a directory" >&2; exit 2; }
      FROM_DIR="$2"
      shift 2
      ;;
    --platforms)
      [ $# -ge 2 ] || { echo "--platforms needs a space-separated list" >&2; exit 2; }
      PLATFORMS="$2"
      shift 2
      ;;
    --out)
      [ $# -ge 2 ] || { echo "--out needs a directory" >&2; exit 2; }
      OUT="$2"
      shift 2
      ;;
    --from-local)
      [ $# -ge 2 ] || { echo "--from-local needs a platform key" >&2; exit 2; }
      LOCAL_PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/code/moon.mod")"
[ -n "$VERSION" ] || { echo "could not read the version from code/moon.mod" >&2; exit 2; }

# The four binaries the release publishes. `interjson-probe.wasm`,
# `interjson-demo.js` and `interjson-install.sh` are not part of the wheel: the
# first two are not the CLI, and the installer would be a second copy of a
# download path that the wheel exists to remove.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/interjson-wheel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ASSETS="$WORK/assets"
mkdir -p "$ASSETS"

if [ -n "$LOCAL_PLATFORM" ]; then
  # The gate builds the wheel from the binary this checkout just compiled, so
  # the packaging path (package-data, platform directory, find_binary) is
  # exercised on every commit without depending on a published release. The
  # checksum here only proves the copy is intact; the published release's own
  # SHA256SUMS is what a released wheel is verified against.
  case "$LOCAL_PLATFORM" in
    windows-*) local_name="interjson.exe" ;;
    *)         local_name="interjson" ;;
  esac
  local_bin="$ROOT/code/_build/native/release/build/cmd/interjson/interjson.exe"
  [ -f "$local_bin" ] || {
    echo "--from-local needs $local_bin; build it with" >&2
    echo "  moon build cmd/interjson --target native --release" >&2
    exit 2
  }
  case "$LOCAL_PLATFORM" in
    windows-*) staged="interjson-windows-x86_64.exe" ;;
    *)         staged="interjson-$LOCAL_PLATFORM" ;;
  esac
  cp "$local_bin" "$ASSETS/$staged"
  ( cd "$ASSETS" && shasum -a 256 "$staged" > SHA256SUMS )
elif [ -n "$FROM_DIR" ]; then
  [ -d "$FROM_DIR" ] || { echo "--from-dir $FROM_DIR is not a directory" >&2; exit 2; }
  cp "$FROM_DIR"/* "$ASSETS"/ 2>/dev/null || true
else
  echo "downloading the $VERSION release assets..."
  # github.com is not reachable from every network; api.github.com is, and the
  # asset endpoint redirects to the same bytes. The release API gives us the
  # asset ids, so the download does not depend on a redirect chain either.
  API="https://api.github.com/repos/wenhuang2333/Moonbit-haker/releases/tags/v$VERSION"
  curl -fsSL --max-time 60 "$API" -o "$WORK/release.json" || {
    echo "could not read the v$VERSION release; pass --from-dir with the assets" >&2
    exit 2
  }
  python3 - "$WORK/release.json" <<'PY' > "$WORK/ids.txt"
import json
import sys

release = sys.argv[1]
data = json.load(open(release, encoding="utf-8"))
names = {"SHA256SUMS"}
for platform in ("linux-x86_64", "linux-arm64", "macos-arm64", "windows-x86_64.exe"):
    names.add("interjson-" + platform)
for asset in data["assets"]:
    if asset["name"] in names:
        print(asset["id"], asset["name"])
PY
  while read -r id name; do
    [ -n "$id" ] || continue
    curl -fsSL --max-time 180 \
      -H "Accept: application/octet-stream" \
      -o "$ASSETS/$name" \
      "https://api.github.com/repos/wenhuang2333/Moonbit-haker/releases/assets/$id"
  done < "$WORK/ids.txt"
fi

# --- every binary must be the one the release published ----------------------
# A wheel that carries a stale or truncated binary is worse than one that
# carries none: `pip install` succeeds and every call fails at the protocol
# layer. The release's own SHA256SUMS is the reference, so nothing is trusted
# that a reader could not verify themselves.
[ -f "$ASSETS/SHA256SUMS" ] || {
  echo "no SHA256SUMS among the assets; cannot verify the binaries" >&2
  exit 2
}
(
  cd "$ASSETS"
  # Only the four binaries are in the wheel; the other three lines of
  # SHA256SUMS name files this script does not need.
  filtered="$(mktemp)"
  for platform in $PLATFORMS; do
    case "$platform" in
      windows-*) name="interjson-windows-x86_64.exe" ;;
      *) name="interjson-$platform" ;;
    esac
    grep -E "  $name\$" SHA256SUMS >> "$filtered"
  done
  shasum -a 256 -c "$filtered"
  rm -f "$filtered"
)

# --- assemble the package tree ----------------------------------------------
mkdir -p "$WORK/tree"
cp -R "$HERE/interjson" "$WORK/tree/interjson"
cp "$HERE/README.md" "$HERE/LICENSE" "$HERE/NOTICE" "$WORK/tree/"
cp "$HERE/pyproject.toml" "$WORK/tree/"

# Strip bytecode and build leftovers, then place one directory per platform so
# `find_binary()` can pick the one this interpreter can actually run.
find "$WORK/tree" -name '__pycache__' -type d -prune -exec rm -rf {} +
rm -rf "$WORK/tree/interjson/bin"
for platform in $PLATFORMS; do
  case "$platform" in
    windows-*) name="interjson-windows-x86_64.exe" ;;
    *) name="interjson-$platform" ;;
  esac
  mkdir -p "$WORK/tree/interjson/bin/$platform"
  case "$platform" in
    windows-*) cp "$ASSETS/$name" "$WORK/tree/interjson/bin/$platform/interjson.exe" ;;
    *)         cp "$ASSETS/$name" "$WORK/tree/interjson/bin/$platform/interjson" ;;
  esac
  chmod +x "$WORK/tree/interjson/bin/$platform"/*
done

mkdir -p "$OUT"
rm -f "$OUT"/*.whl "$OUT"/*.tar.gz

# `python -m build` is the normal entry point, but it is not installed
# everywhere and it may not be installable on an offline machine. What it does
# for a setuptools project is `pip wheel` plus `setup.py sdist`, and both of
# those only need setuptools, which is already a build requirement of this
# package. The fallback is what CI runs.
echo "building the distributions..."
if python3 -c 'import build' 2>/dev/null; then
  python3 -m build --no-isolation --wheel --sdist -o "$OUT" "$WORK/tree" >/dev/null
else
  python3 -m pip wheel --no-deps --no-build-isolation -w "$OUT" "$WORK/tree" >/dev/null
  ( cd "$WORK/tree" && python3 -c 'from setuptools import setup; setup()' sdist --dist-dir "$OUT" >/dev/null )
fi

WHEEL="$(ls "$OUT"/interjson_moonbit-"$VERSION"-*.whl 2>/dev/null | head -1)"
[ -n "$WHEEL" ] || { echo "no wheel was produced" >&2; exit 1; }

# --- the built artefact must carry what the install needs --------------------
python3 - "$WHEEL" "$PLATFORMS" "$VERSION" <<'PY'
import sys
import zipfile

wheel, platforms, version = sys.argv[1], sys.argv[2].split(), sys.argv[3]
names = zipfile.ZipFile(wheel).namelist()
fails = []
for platform in platforms:
    entry = f"interjson/bin/{platform}/interjson"
    # Windows binaries keep their .exe suffix; everything else is `interjson`.
    if entry not in names and f"{entry}.exe" not in names:
        fails.append(f"wheel does not carry {entry}")
for want in ("interjson/py.typed", "interjson/client.py", "interjson/mcp.py"):
    if want not in names:
        fails.append(f"wheel does not carry {want}")
if not any(n.endswith("dist-info/licenses/LICENSE") or n.endswith(".data/data/LICENSE") for n in names):
    fails.append("wheel does not carry LICENSE")
if not any(n.endswith("dist-info/licenses/NOTICE") or n.endswith(".data/data/NOTICE") for n in names):
    fails.append("wheel does not carry NOTICE")
meta = [n for n in names if n.endswith("dist-info/METADATA")]
if meta:
    text = zipfile.ZipFile(wheel).read(meta[0]).decode()
    if f"Version: {version}" not in text:
        fails.append(f"wheel metadata does not say Version: {version}")
else:
    fails.append("wheel has no METADATA")
if fails:
    print("build_wheel.sh:", file=sys.stderr)
    for f in fails:
        print("  " + f, file=sys.stderr)
    raise SystemExit(1)
PY

echo "built:"
ls -1 "$OUT" | sed 's/^/  /'
