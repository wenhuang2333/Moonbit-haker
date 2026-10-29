#!/bin/sh
# Install the InterJSON CLI (and its local MCP server) from a GitHub release.
#
#   curl -fsSL https://github.com/wenhuang2333/Moonbit-haker/releases/download/v1.5.0/interjson-install.sh | sh
#
# The script does four things and nothing else:
#
#   1. works out which platform it is running on,
#   2. downloads the matching release asset,
#   3. verifies its SHA-256 against the release's own SHA256SUMS,
#   4. puts the binary somewhere on PATH and says which directory that was.
#
# It never installs anything else, never writes outside the install directory
# and the PATH hint file, and never runs the binary as root. A checksum that
# does not match is a hard failure: the file is deleted and nothing is
# installed.
#
# Environment:
#   INTERJSON_VERSION   release tag to install (default: the latest release)
#   INTERJSON_DIR       install directory (default: $HOME/.local/bin)
#   INTERJSON_REPO      owner/name (default: wenhuang2333/Moonbit-haker)
#
# Exit codes:
#   0  installed
#   1  the download or the checksum failed
#   2  the platform is not supported by this release

set -eu

REPO="${INTERJSON_REPO:-wenhuang2333/Moonbit-haker}"
VERSION="${INTERJSON_VERSION:-}"
INSTALL_DIR="${INTERJSON_DIR:-$HOME/.local/bin}"

# `die` takes the exit code it should end with, because the header documents
# three of them: 1 for a failed download or checksum, 2 for an unsupported
# platform. A single exit code made the documented contract a lie -- a script
# that always exits 1 cannot be branched on.
die() {
  code="$1"; shift
  printf 'error: %s\n' "$*" >&2
  exit "$code"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die 1 "$1 is required but was not found"
}

need uname
need curl

# -- platform --------------------------------------------------------------

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux) os_name="linux" ;;
  Darwin) os_name="macos" ;;
  MINGW* | MSYS* | CYGWIN*) os_name="windows" ;;
  *) die 2 "unsupported operating system: $os" ;;
esac

case "$arch" in
  x86_64 | amd64) arch_name="x86_64" ;;
  arm64 | aarch64) arch_name="arm64" ;;
  *) die 2 "unsupported architecture: $arch" ;;
esac

if [ "$os_name" = "windows" ]; then
  asset="interjson-windows-${arch_name}.exe"
elif [ "$os_name" = "linux" ] && [ "$arch_name" = "arm64" ]; then
  asset="interjson-linux-arm64"
elif [ "$os_name" = "linux" ]; then
  asset="interjson-linux-x86_64"
elif [ "$os_name" = "macos" ] && [ "$arch_name" = "arm64" ]; then
  asset="interjson-macos-arm64"
elif [ "$os_name" = "macos" ]; then
  # There is no Intel macOS build, and the reason is not a choice: the MoonBit
  # toolchain publishes `darwin-aarch64`, `linux-x86_64` and `linux-aarch64`
  # only, so an Intel Mac cannot build the binary at all. Say that, rather than
  # failing later with a 404 on an asset that does not exist.
  die 2 "no InterJSON build for Intel macOS: the MoonBit toolchain has no darwin-x86_64 target (build from source on an Apple Silicon Mac, or use a Linux/Windows machine)"
else
  die 2 "unsupported platform: $os/$arch"
fi

# -- version ---------------------------------------------------------------

if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1)"
  [ -n "$VERSION" ] || die 1 "could not determine the latest release; set INTERJSON_VERSION"
fi

base="https://github.com/${REPO}/releases/download/${VERSION}"

printf 'InterJSON %s\n' "$VERSION"
printf '  platform : %s/%s (%s)\n' "$os_name" "$arch_name" "$asset"
printf '  target   : %s\n' "$INSTALL_DIR"

# -- download --------------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

printf '  download : '
curl -fsSL -o "$tmp/$asset" "${base}/${asset}" || die 1 "download failed: ${base}/${asset}"
printf 'ok\n'

printf '  checksums: '
curl -fsSL -o "$tmp/SHA256SUMS" "${base}/SHA256SUMS" || die 1 "SHA256SUMS could not be downloaded"
printf 'ok\n'

# -- verify ----------------------------------------------------------------

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)"
else
  die 1 "neither sha256sum nor shasum is available; cannot verify the download"
fi

expected="$(awk -v f="$asset" '$2 == f || $2 == "*"f { print $1 }' "$tmp/SHA256SUMS" | head -n 1)"
[ -n "$expected" ] || die 1 "SHA256SUMS does not name $asset; refusing to install an unverified binary"

if [ "$actual" != "$expected" ]; then
  rm -f "$tmp/$asset"
  die 1 "checksum mismatch for $asset (expected $expected, got $actual); nothing was installed"
fi
printf '  verified : sha256 %s\n' "$actual"

# -- install ---------------------------------------------------------------

mkdir -p "$INSTALL_DIR"

if [ "$os_name" = "windows" ]; then
  target="$INSTALL_DIR/interjson.exe"
else
  target="$INSTALL_DIR/interjson"
fi

cp "$tmp/$asset" "$target"
chmod +x "$target"

printf '  installed: %s\n' "$target"

# -- verify the binary and report -----------------------------------------

if "$target" --version >/dev/null 2>&1; then
  printf '\n%s\n' "$("$target" --version)"
else
  printf '\nwarning: %s did not answer --version; the install may be incomplete\n' "$target" >&2
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf '\n%s is not on your PATH. Add this to your shell profile:\n\n' "$INSTALL_DIR"
    printf '  export PATH="$INSTALL_DIR:$PATH"\n\n'
    ;;
esac

cat <<'EOF'
Next: start the local execution gate for any MCP client.

  interjson mcp --print-config=claude     # prints the Claude Code config
  interjson mcp --print-config=cursor
  interjson mcp --print-config=json       # the raw MCP server config

or run the gate directly:

  echo '{"a":1,}' | interjson --check
EOF
