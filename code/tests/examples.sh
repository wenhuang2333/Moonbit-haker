#!/bin/bash
# Runs the CLI over code/examples/cases/*.json and compares stdout with the
# matching .expected file (D12 12.8 step 4).
#
#   bash code/tests/examples.sh [<interjson executable>]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/_build/native/release/build/cmd/interjson/interjson.exe}"
CASES="$ROOT/examples/cases"

[ -x "$BIN" ] || { echo "error: $BIN not found (build it first)" >&2; exit 2; }

pass=0
fail=0
for input in "$CASES"/*.json; do
  name="$(basename "$input" .json)"
  expected="$CASES/$name.expected"
  extra=""
  # 06 is the prose case: it needs the opt-in prose skipper
  [ "$name" = "06-prose" ] && extra="--skip-prose"
  out="$("$BIN" $extra "$input")"
  want="$(cat "$expected")"
  if [ "$out" = "$want" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$name" "$want" "$out"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
