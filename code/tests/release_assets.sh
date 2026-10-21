#!/usr/bin/env bash
#
# Verify that a published GitHub release carries exactly the files its
# SHA256SUMS lists.
#
# The failure this exists for: v1.1.0 published a SHA256SUMS that names
# `jsonmend-windows-x86_64.exe`, but the release attached only five files and
# the Windows binary was not one of them. A checksum file that names a file
# the reader cannot download is worse than no checksum file at all: it sends a
# verifier to check something that does not exist, and it makes a broken
# release look signed.
#
# The check compares two sets:
#   * the files named in the release's SHA256SUMS, and
#   * the files actually attached to the release,
# with SHA256SUMS itself excluded from the comparison, because a checksum file
# cannot contain its own hash. Any file in one set and not the other is drift.
#
# Usage:
#   bash code/tests/release_assets.sh <tag> [options]
#
#   --repo OWNER/NAME    repository to check
#                        (default: $JSONMEND_REPO, else
#                        wenhuang2333/Moonbit-haker)
#   --api URL            GitHub API base URL (default: $GH_API, else
#                        https://api.github.com)
#   --sums-file PATH     additionally require the published SHA256SUMS to be
#                        byte-identical to PATH (use it to prove that what was
#                        uploaded is what is published)
#   --verify-hashes      download every attached asset and verify its sha256
#                        against the value in SHA256SUMS
#   -h, --help           this text
#
# Token: $GH_TOKEN or $GITHUB_TOKEN. Without one the check is skipped and
# says so: "skipped: no token", exit 0. With a token the check is strict and
# exits non-zero on any drift.
#
# Exit codes:
#   0  the release matches its SHA256SUMS, or the check was skipped
#   1  drift: a listed file is not attached, an extra file is attached, a
#      hash does not match, or the published SHA256SUMS differs from
#      --sums-file
#   2  the check could not run: bad usage, missing tool, release not found
#
set -uo pipefail

REPO="${JSONMEND_REPO:-wenhuang2333/Moonbit-haker}"
API="${GH_API:-https://api.github.com}"
SUMS_FILE=""
VERIFY_HASHES=0
TAG=""

usage() {
  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^set -uo/d'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)        [ "$#" -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --repo=*)      REPO="${1#*=}"; shift ;;
    --api)         [ "$#" -ge 2 ] || die "--api needs a value"; API="$2"; shift 2 ;;
    --api=*)       API="${1#*=}"; shift ;;
    --sums-file)   [ "$#" -ge 2 ] || die "--sums-file needs a value"; SUMS_FILE="$2"; shift 2 ;;
    --sums-file=*) SUMS_FILE="${1#*=}"; shift ;;
    --verify-hashes) VERIFY_HASHES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$TAG" ] || die "unexpected argument: $1"; TAG="$1"; shift ;;
  esac
done

[ -n "$TAG" ] || die "usage: bash code/tests/release_assets.sh <tag> [options]"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# The token is what makes the check strict. Without one there is nothing to
# degrade to: say so plainly instead of pretending the release was checked.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  printf 'skipped: no token (set GH_TOKEN or GITHUB_TOKEN to check %s %s)\n' "$REPO" "$TAG"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-assets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

api_get() {
  # api_get <path> <dest>; prints the http status
  curl -sS -o "$2" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API$1"
}

fetch_asset() {
  # fetch_asset <asset id> <dest>; prints the http status.
  # The API answers a release-asset request with a 302 to a signed URL. The
  # signed URL carries its own authorization, so the token is not sent to the
  # storage host that serves it.
  local id="$1" dest="$2" hdr="$WORK/headers" status loc
  status="$(curl -sS -D "$hdr" -o "$dest" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/octet-stream" \
    "$API/repos/$REPO/releases/assets/$id")" || return 1
  case "$status" in
    200) ;;
    301|302|303|307|308)
      loc="$(awk 'tolower($1) == "location:" { sub(/\r$/, "", $2); print $2; exit }' "$hdr")"
      [ -n "$loc" ] || { echo "redirect without a Location header" >&2; return 1; }
      status="$(curl -sS -o "$dest" -w '%{http_code}' "$loc")" || return 1
      ;;
  esac
  printf '%s' "$status"
}

status="$(api_get "/repos/$REPO/releases/tags/$TAG" "$WORK/release.json")"
if [ "$status" != "200" ]; then
  printf 'error: cannot read release %s of %s (HTTP %s)\n' "$TAG" "$REPO" "$status" >&2
  if [ "$status" = "404" ]; then
    printf 'error: no such release. Check the tag, or that the release is published.\n' >&2
  fi
  exit 2
fi

# "<asset id>\t<asset name>" per line. A non-object body means the API
# answered with an error document, not a release.
if ! python3 -c '
import json, sys
try:
    rel = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(rel, dict) or "assets" not in rel:
    sys.exit(3)
for a in rel["assets"]:
    print("%d\t%s" % (a["id"], a["name"]))
' < "$WORK/release.json" > "$WORK/assets.tsv"; then
  printf 'error: the API did not return a release for %s of %s\n' "$TAG" "$REPO" >&2
  exit 2
fi

SUMS_ID="$(awk -F'\t' '$2 == "SHA256SUMS" { print $1; exit }' "$WORK/assets.tsv")"
if [ -z "$SUMS_ID" ]; then
  printf 'error: release %s of %s has no SHA256SUMS asset\n' "$TAG" "$REPO" >&2
  exit 2
fi

status="$(fetch_asset "$SUMS_ID" "$WORK/SHA256SUMS")"
if [ "$status" != "200" ]; then
  printf 'error: cannot download SHA256SUMS of %s of %s (HTTP %s)\n' "$TAG" "$REPO" "$status" >&2
  exit 2
fi

# "<sha256>\t<file name>" per line, in the order SHA256SUMS lists them.
# The standard layout is a 64 character digest, a two character separator
# ("  " in text mode, " *" in binary mode) and then the name.
awk '
  {
    hash = substr($0, 1, 64)
    if (length(hash) != 64 || hash !~ /^[0-9a-fA-F]+$/) next
    name = substr($0, 67)
    if (name == "") next
    printf "%s\t%s\n", tolower(hash), name
  }
' "$WORK/SHA256SUMS" > "$WORK/sums.tsv"

if [ ! -s "$WORK/sums.tsv" ]; then
  printf 'error: SHA256SUMS of %s of %s lists no files\n' "$TAG" "$REPO" >&2
  exit 2
fi

# SHA256SUMS itself is attached to the release but cannot list itself.
awk -F'\t' '$2 != "SHA256SUMS" { print $2 }' "$WORK/assets.tsv" > "$WORK/attached.txt"
cut -f2 "$WORK/sums.tsv" > "$WORK/listed.txt"

LC_ALL=C sort -u "$WORK/listed.txt"   > "$WORK/listed.sorted"
LC_ALL=C sort -u "$WORK/attached.txt" > "$WORK/attached.sorted"
comm -23 "$WORK/listed.sorted"   "$WORK/attached.sorted" > "$WORK/missing.txt"
comm -13 "$WORK/listed.sorted"   "$WORK/attached.sorted" > "$WORK/extra.txt"

status=0

printf 'release %s  repo %s\n' "$TAG" "$REPO"
printf '  listed in SHA256SUMS (%s):\n' "$(wc -l < "$WORK/listed.txt" | tr -d ' ')"
sed 's/^/    /' "$WORK/listed.txt"
printf '  attached assets (%s, SHA256SUMS itself excluded):\n' "$(wc -l < "$WORK/attached.txt" | tr -d ' ')"
sed 's/^/    /' "$WORK/attached.txt"

printf '  missing (listed in SHA256SUMS, not attached): %s\n' "$(wc -l < "$WORK/missing.txt" | tr -d ' ')"
sed 's/^/    /' "$WORK/missing.txt"
printf '  extra (attached, not listed in SHA256SUMS): %s\n' "$(wc -l < "$WORK/extra.txt" | tr -d ' ')"
sed 's/^/    /' "$WORK/extra.txt"

if [ -s "$WORK/missing.txt" ] || [ -s "$WORK/extra.txt" ]; then
  printf 'FAIL: release %s does not match its SHA256SUMS\n' "$TAG"
  status=1
fi

if [ -n "$SUMS_FILE" ]; then
  if [ ! -f "$SUMS_FILE" ]; then
    printf 'error: --sums-file %s does not exist\n' "$SUMS_FILE" >&2
    exit 2
  fi
  if cmp -s "$SUMS_FILE" "$WORK/SHA256SUMS"; then
    printf '  published SHA256SUMS is identical to %s\n' "$SUMS_FILE"
  else
    printf 'FAIL: the published SHA256SUMS differs from %s\n' "$SUMS_FILE"
    diff -u "$SUMS_FILE" "$WORK/SHA256SUMS" || true
    status=1
  fi
fi

if [ "$VERIFY_HASHES" = "1" ]; then
  printf '  verifying the sha256 of every attached file\n'
  while IFS="$(printf '\t')" read -r want name; do
    id="$(awk -F'\t' -v n="$name" '$2 == n { print $1; exit }' "$WORK/assets.tsv")"
    if [ -z "$id" ]; then
      printf '    %s: not attached, nothing to verify\n' "$name"
      continue
    fi
    code="$(fetch_asset "$id" "$WORK/asset.bin")"
    if [ "$code" != "200" ]; then
      printf '    %s: cannot download (HTTP %s)\n' "$name" "$code"
      status=1
      continue
    fi
    got="$(sha256sum "$WORK/asset.bin" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
      printf '    %s: ok\n' "$name"
    else
      printf '    %s: MISMATCH want=%s got=%s\n' "$name" "$want" "$got"
      status=1
    fi
  done < "$WORK/sums.tsv"
fi

if [ "$status" = "0" ]; then
  printf 'ok: release %s matches its SHA256SUMS\n' "$TAG"
fi
exit "$status"
