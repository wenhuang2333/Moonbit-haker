#!/bin/bash
# TC-C-01 command line smoke test (D11). Every case asserts the exit code and,
# where it matters, the exact output. Run from anywhere:
#
#   bash code/tests/cli_smoke.sh [<jsonmend executable>]
#
# The default executable path is the release native build.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/_build/native/release/build/cmd/jsonmend/jsonmend.exe}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# check <name> <expected exit> <expected stdout> <expected stderr substring> -- <args...>
# stdin is $STDIN.
check() {
  local name="$1" want_rc="$2" want_out="$3" want_err="$4"
  shift 4
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then shift; fi
  local out err rc
  out="$(printf '%s' "$STDIN" | "$BIN" "$@" 2>"$TMP/err")"
  rc=$?
  err="$(cat "$TMP/err")"
  local ok=1
  [ "$rc" = "$want_rc" ] || ok=0
  if [ -n "$want_out" ] && [ "$out" != "$want_out" ]; then ok=0; fi
  if [ -n "$want_err" ] && ! printf '%s' "$err" | grep -qF "$want_err"; then ok=0; fi
  if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    printf 'ok   %-34s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail + 1))
    printf 'FAIL %-34s rc=%s (want %s)\n     stdout=%s\n     stderr=%s\n' \
      "$name" "$rc" "$want_rc" "$out" "$err"
  fi
}

[ -x "$BIN" ] || { echo "error: $BIN not found (build it first)" >&2; exit 2; }

STDIN="{'a':1,}" check "single quotes + trailing comma" 0 '{"a":1}' "" --
STDIN="{'a':1,}" check "report records" 0 '{"a":1}' "R003 1:2 quote normalized to double quote" -- --report
STDIN="{'a':1,}" check "--report" 0 '{"a":1}' "R005 1:7 extra comma removed" -- --report
STDIN='{"a":{"b":[1,2' check "truncated input" 0 '{"a":{"b":[1,2]}}' "" --
STDIN='{"a":1}' check "--check on valid input" 0 '' "" -- --check
STDIN='{"a":1,}' check "--check on flawed input" 1 '' "" -- --check
STDIN='{"a":1,}' check "--strict rejects repairs" 5 '' "E010" -- --strict
STDIN='' check "empty input" 3 '' "E001" --
STDIN='hello world' check "no JSON value" 3 '' "E002" --
STDIN='{"a":1}' check "unknown option" 2 '' "未知选项" -- --bogus
STDIN='{"a":1}' check "--help exit code" 0 '' "" -- --help
STDIN='{"a":1}' check "--version" 0 'jsonmend 0.3.0' "" -- --version
STDIN='{"a":1} {"b":2}' check "multi-root default" 0 '{"a":1}' "R016" -- --report
STDIN='{"a":1} {"b":2}' check "--multi-root array" 0 '[{"a":1},{"b":2}]' "" -- --multi-root array
STDIN='Here you go: {"a":1}' check "prose rejected by default" 3 '' "E002" --
STDIN='Here you go: {"a":1}' check "--skip-prose" 0 '{"a":1}' "R021 1:1 leading prose skipped" -- --skip-prose --report
STDIN='{"a":"b' check "unclosed string" 0 '{"a":"b"}' "R010" -- --report
STDIN='[1,null,tru]' check "literal completion" 0 '[1,null,true]' "R012" -- --report

# --help content
if printf '{"a":1}' | "$BIN" --help | grep -qF 'jsonmend [选项] [文件]'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--help content"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--help content"
fi

# --version must match `version` in moon.mod (the string is hard-coded in main.mbt)
MOD_VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$(dirname "$0")/../moon.mod")
if [ "$(printf '{"a":1}' | "$BIN" --version)" = "jsonmend $MOD_VERSION" ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--version matches moon.mod"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--version matches moon.mod"
fi

# --indent
out="$(printf '%s' '{"a":[1,2]}' | "$BIN" --indent 2)"
expect='{
  "a": [
    1,
    2
  ]
}'
if [ "$out" = "$expect" ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--indent 2"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "--indent 2" "$out"
fi

# file input
printf '%s' "{'a':1,}" >"$TMP/in.json"
out="$("$BIN" "$TMP/in.json")"
if [ "$out" = '{"a":1}' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "file argument"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "file argument" "$out"
fi

# missing file
out="$("$BIN" "$TMP/nope.json" 2>"$TMP/err")"; rc=$?
if [ "$rc" = 3 ] && grep -q "nope.json" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "unreadable file" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s\n' "unreadable file" "$rc"
fi

# invalid UTF-8 on stdin
printf '\x7b\x22\xff\x22\x7d' | "$BIN" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 3 ] && grep -q "E040" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "invalid UTF-8" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s %s\n' "invalid UTF-8" "$rc" "$(cat "$TMP/err")"
fi

# depth limit: 600 nested arrays (max_depth 512)
python3 -c "print('['*600 + ']'*600)" >"$TMP/deep.json"
"$BIN" "$TMP/deep.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 4 ] && grep -q "E020" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "depth limit" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s %s\n' "depth limit" "$rc" "$(cat "$TMP/err")"
fi

# stdin is not required when a file is given, and `-` means stdin
out="$(printf '%s' '{"a":1,}' | "$BIN" -)"
if [ "$out" = '{"a":1}' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "- reads stdin"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "- reads stdin" "$out"
fi

# --max-loss gates the result before it can be executed (I-1)
printf '%s' '{"a":1,}' | "$BIN" --max-loss exact >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 5 ] && grep -q "E010" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "--max-loss exact rejects" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s %s\n' "--max-loss exact rejects" "$rc" "$(cat "$TMP/err")"
fi

# a notation-only repair is accepted at `cosmetic`
printf '%s' '{"a":1,}' | "$BIN" --max-loss cosmetic >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "--max-loss cosmetic accepts" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s\n' "--max-loss cosmetic accepts" "$rc"
fi

# an invented value is rejected at `cosmetic`
printf '%s' '{"a":"x}' | "$BIN" --max-loss cosmetic >/dev/null 2>&1; rc=$?
if [ "$rc" = 5 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "--max-loss cosmetic rejects" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s\n' "--max-loss cosmetic rejects" "$rc"
fi

# --explain prints severity and the exactness summary
printf '%s' '{"a":1,}' | "$BIN" --explain >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 0 ] && grep -q "R005 info" "$TMP/err" && grep -q "exactness cosmetic" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "--explain" "$rc"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s %s\n' "--explain" "$rc" "$(cat "$TMP/err")"
fi

# --batch reads JSONL and reports value, label and codes per line
out="$(printf '%s\n' '{"id":"a","input":"[1,2"}' '{"id":"b","input":"{}"}' | "$BIN" --batch)"
if [ "$(printf '%s' "$out" | head -1)" = '{"id":"a","rc":0,"exactness":"lossy","codes":["R009"],"value":[1,2],"text":"[1,2]"}' ] \
   && [ "$(printf '%s' "$out" | tail -1)" = '{"id":"b","rc":0,"exactness":"exact","codes":[],"value":{},"text":"{}"}' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--batch"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "--batch" "$out"
fi

# R022: a re-cased literal is notation, not an invented value
printf '%s' '{"a":True}' | "$BIN" --report 2>"$TMP/err" >/dev/null
if grep -q "^R022 1:6" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "R022 re-cased literal"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "R022 re-cased literal" "$(cat "$TMP/err")"
fi

# jsonmend llm: provider adapters over a recorded event stream
out="$("$BIN" llm --provider anthropic llm/fixtures/anthropic_parallel.jsonl)"
if [ "$(printf '%s\n' "$out" | grep -c '"index"')" = 3 ] \
   && printf '%s' "$out" | head -1 | grep -q '"name":"search"' \
   && printf '%s' "$out" | tail -1 | grep -q '"path":"/tmp/x"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm anthropic"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm anthropic" "$out"
fi

# a truncated call is closed and labelled lossy
out="$("$BIN" llm --provider anthropic llm/fixtures/anthropic_truncated.jsonl)"
if printf '%s' "$out" | grep -q '"exactness":"lossy"' && printf '%s' "$out" | grep -q '"done":true'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm truncated is lossy"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm truncated is lossy" "$out"
fi

# --sse reads the same events with SSE framing
out="$(sed 's/^/data: /' llm/fixtures/anthropic_single.jsonl | awk '{print; print ""}' | "$BIN" llm --sse)"
if printf '%s' "$out" | grep -q '"unit":"celsius"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm --sse"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm --sse" "$out"
fi

# --follow shows every intermediate value
n="$("$BIN" llm --follow llm/fixtures/anthropic_single.jsonl | wc -l | tr -d ' ')"
if [ "$n" -ge 4 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s %s lines\n' "llm --follow" "$n"
else
  fail=$((fail + 1)); printf 'FAIL %-34s %s lines\n' "llm --follow" "$n"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
