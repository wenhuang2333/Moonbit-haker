#!/bin/bash
# TC-C-01 command line smoke test (D11). Every case asserts the exit code and,
# where it matters, the exact output. Run from anywhere:
#
#   bash code/tests/cli_smoke.sh [<jsonmend executable>]
#
# The default executable path is the release native build.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/llm/fixtures"
BIN="${1:-$ROOT/_build/native/release/build/cmd/jsonmend/jsonmend.exe}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# check_has <name> <expected exit> <needle> <out|err> -- <args...>
# Like `check`, but asserts that one substring appears on the chosen stream,
# which is what `explain` needs: its block is long by design.
check_has() {
  local name="$1" want_rc="$2" needle="$3" stream="$4"
  shift 4
  if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then shift; fi
  local out err rc
  out="$(printf '%s' "$STDIN" | "$BIN" "$@" 2>"$TMP/err")"
  rc=$?
  err="$(cat "$TMP/err")"
  local hay="$out"
  [ "$stream" = err ] && hay="$err"
  if [ "$rc" = "$want_rc" ] && printf '%s' "$hay" | grep -qF -- "$needle"; then
    pass=$((pass + 1))
    printf 'ok   %-34s rc=%s\n' "$name" "$rc"
  else
    fail=$((fail + 1))
    printf 'FAIL %-34s rc=%s (want %s)\n     out=%s\n     err=%s\n' \
      "$name" "$rc" "$want_rc" "$out" "$err"
  fi
}

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
GOT_VERSION=$(printf '{"a":1}' | "$BIN" --version)
if [ "$GOT_VERSION" = "jsonmend $MOD_VERSION" ]; then
  pass=$((pass + 1)); printf 'ok   %-34s %s\n' "--version matches moon.mod" "$GOT_VERSION"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s `jsonmend --version` says "%s" but code/moon.mod says "%s"\n' \
    "--version matches moon.mod" "$GOT_VERSION" "jsonmend $MOD_VERSION"
fi

# Every document that states a version must state the same one. The published
# mooncakes page renders code/README.md (`readme = "README.md"` in moon.mod),
# so a stale string there is the first thing a reader sees; root README.md is
# the repository front page. A mismatch fails loudly and names both strings.
REPO="$(cd "$ROOT/.." && pwd)"
check_doc_version() {
  local label="$1" file="$2" expr="$3" got
  got="$(sed -n "$expr" "$REPO/$file" | head -1)"
  if [ "$got" = "$MOD_VERSION" ]; then
    pass=$((pass + 1)); printf 'ok   %-34s %s=%s\n' "$label" "$file" "$got"
  elif [ -z "$got" ]; then
    fail=$((fail + 1))
    printf 'FAIL %-34s %s states no version; code/moon.mod says "%s"\n' \
      "$label" "$file" "$MOD_VERSION"
  else
    fail=$((fail + 1))
    printf 'FAIL %-34s %s says "%s" but code/moon.mod says "%s"\n' \
      "$label" "$file" "$got" "$MOD_VERSION"
  fi
}
check_doc_version "README version" "README.md" 's/^\*\*版本\*\*：\(.*\)$/\1/p'
check_doc_version "package README version" "code/README.md" \
  's/^| Version | \(.*\) |$/\1/p'
check_doc_version "package README.zh version" "code/README.zh.md" \
  's/^| 版本 | \(.*\) |$/\1/p'
# The delivery document repeats the version in its header prose and in the
# evolution table. Same rule: it must not drift from moon.mod.
check_doc_version "condensed doc version" "产品文档-精简版.md" \
  's/^> \*\*版本\*\*：\([0-9.]*\).*$/\1/p'

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
if [ "$(printf '%s' "$out" | head -1)" = '{"id":"a","rc":0,"exactness":"lossy","ambiguous":false,"codes":["R009"],"value":[1,2],"text":"[1,2]"}' ] \
   && [ "$(printf '%s' "$out" | tail -1)" = '{"id":"b","rc":0,"exactness":"exact","ambiguous":false,"codes":[],"value":{},"text":"{}"}' ]; then
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
out="$("$BIN" llm --provider anthropic "$FIX/anthropic_parallel.jsonl")"
if [ "$(printf '%s\n' "$out" | grep -c '"index"')" = 3 ] \
   && printf '%s' "$out" | head -1 | grep -q '"name":"search"' \
   && printf '%s' "$out" | tail -1 | grep -q '"path":"/tmp/x"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm anthropic"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm anthropic" "$out"
fi

# a truncated call is closed and labelled lossy
out="$("$BIN" llm --provider anthropic "$FIX/anthropic_truncated.jsonl")"
if printf '%s' "$out" | grep -q '"exactness":"lossy"' && printf '%s' "$out" | grep -q '"done":true'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm truncated is lossy"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm truncated is lossy" "$out"
fi

# --sse reads the same events with SSE framing
out="$(sed 's/^/data: /' "$FIX/anthropic_single.jsonl" | awk '{print; print ""}' | "$BIN" llm --sse)"
if printf '%s' "$out" | grep -q '"unit":"celsius"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm --sse"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm --sse" "$out"
fi

# --follow shows every intermediate value
n="$("$BIN" llm --follow "$FIX/anthropic_single.jsonl" | wc -l | tr -d ' ')"
if [ "$n" -ge 4 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s %s lines\n' "llm --follow" "$n"
else
  fail=$((fail + 1)); printf 'FAIL %-34s %s lines\n' "llm --follow" "$n"
fi

# --- round 5 -----------------------------------------------------------------
# An ambiguous input is repaired by default and flagged.
STDIN='["a" "b"]'
check "ambiguous is flagged" 0 '["a","b"]' "adjacent_strings" -- --explain
# ... and refused when the caller is going to execute the value.
STDIN='["a" "b"]'
check "for-execution refuses E011" 5 "" "E011" -- --for-execution
STDIN='["a" "b"]'
check "reject-ambiguous refuses E011" 5 "" "E011" -- --reject-ambiguous
# A unique reading still passes the execution gate.
STDIN='{"a":1,}'
check "for-execution accepts uniquely" 0 '{"a":1}' "" -- --for-execution
# --retry-hint writes a re-ask prompt to stderr and keeps the exit code.
STDIN='["a" "b"]'
check "retry-hint prompt" 5 "" "Re-emit the arguments as valid JSON" -- --for-execution --retry-hint

# --chunk feeds the same document in byte sized pieces.
out="$(printf '%s' '{"a":[1,2,{"b":"x"}]}' | "$BIN" --chunk 1)"
if [ "$out" = '{"a":[1,2,{"b":"x"}]}' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--chunk 1"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "--chunk 1" "$out"
fi

# --batch reports the ambiguity flag and the error code per line.
out="$(printf '%s\n' '{"id":"a","input":"[1,2]"}' '{"id":"b","input":"[\"a\" \"b\"]"}' \
  | "$BIN" --batch --for-execution)"
if printf '%s' "$out" | head -1 | grep -q '"rc":0' \
   && printf '%s' "$out" | tail -1 | grep -q '"error_code":"E011"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--batch error_code"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "--batch error_code" "$out"
fi

# readiness reports a median, a field count and a monotone curve.
out="$(printf '%s' '{"path":"/tmp","old":"x","content":"long enough to matter"}' | "$BIN" readiness)"
if printf '%s' "$out" | head -1 | grep -q '^jsonmend: readiness median' \
   && printf '%s' "$out" | grep -q '^field content ' \
   && printf '%s' "$out" | grep -q '^jsonmend: readiness' ; then
  mono="$(printf '%s' "$out" | head -1 | sed 's/.*curve //')"
  if [ "$(printf '%s' "$mono" | tr ' ' '\n' | sort -n | tr '\n' ' ')" = "$mono " ]; then
    pass=$((pass + 1)); printf 'ok   %-34s\n' "readiness"
  else
    fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "readiness curve not monotone" "$mono"
  fi
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "readiness" "$out"
fi

# A re-ask hint for a non repair error is absent, not empty.
STDIN='{"a":1}'
check "retry-hint absent on success" 0 '{"a":1}' "" -- --for-execution --retry-hint

# llm --text reads the JSON out of a chat answer.
events='{"choices":[{"index":0,"delta":{"content":"Sure: {\"a\":1}"}}]}
{"choices":[{"index":0,"delta":{"content":"{\"b\":"}}]}
{"choices":[{"index":0,"delta":{"content":"2}"},"finish_reason":"stop"}]}'
out="$(printf '%s\n' "$events" | "$BIN" llm --provider openai --text --skip-prose)"
if printf '%s' "$out" | grep -q '"value":{"a":1}' \
   && printf '%s' "$out" | grep -q '"stop_reason":"stop"' \
   && printf '%s' "$out" | grep -q '"end":"complete"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm --text"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm --text" "$out"
fi

# llm --batch carries the end reason through the adapter.
out="$(printf '%s\n' '{"id":"t","events":[{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"f"}},{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":"}},{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}]}' \
  | "$BIN" llm --provider anthropic --batch)"
if printf '%s' "$out" | grep -q '"end":"max_tokens"' && printf '%s' "$out" | grep -q '"stop_reason":"max_tokens"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm --batch max_tokens"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm --batch max_tokens" "$out"
fi

# A ping is ignored, a future event type is ignored, neither is an error.
out="$(printf '%s\n' '{"type":"ping"}' '{"type":"future_event"}' '{"type":"message_stop"}' | "$BIN" llm --provider anthropic)"
if [ "$(printf '%s' "$out" | grep -c '"index"')" = 0 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "llm ignores ping/unknown"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "llm ignores ping/unknown" "$out"
fi

# ---------------------------------------------------------------------------
# jsonmend explain (FR-32, FR-33): one block, and an exit code that says whether
# the value may be executed.
# ---------------------------------------------------------------------------

STDIN='{"name":"Alice","age":18,}'
check_has "explain cosmetic repair" 0 "SAFE TO EXECUTE" out -- explain
check_has "explain prints the repaired value" 0 '"name":"Alice","age":18' out -- explain

STDIN='{"words":["colour" "color"]}'
check_has "explain blocks two readings" 5 "BLOCKED (two readings)" out -- explain --policy execution
check_has "explain prints the retry prompt" 5 "E011" out -- explain --policy execution

STDIN='{"name":"Alice'
check_has "explain refuses a truncated value" 5 "REJECT (a value was changed)" out -- explain
check_has "explain says what the model should change" 5 "Do not truncate string values." out -- explain

STDIN='{"query":"MoonBit","limit":10}'
check_has "explain passes the skeleton" 0 "SAFE TO EXECUTE" out -- explain --schema '{!query:string,!limit:integer}'
STDIN='{"query":"MoonBit"}'
check_has "explain refuses a missing member" 5 "missing limit" out -- explain --schema '{!query:string,!limit:integer}'
check_has "explain reports both readiness numbers" 5 "syntax-ready" out -- explain --schema '{!query:string,!limit:integer}'
STDIN='{"query":"MoonBit"}'
check_has "bad skeleton is a usage error" 2 "E070" err -- explain --schema '{!a:'
check_has "unknown policy is a usage error" 2 "permissive" err -- explain --policy lenient
check_has "unreadable input" 3 "无法读取" err -- explain /nonexistent/jsonmend.json

STDIN='{"query":"MoonBit","limit":10}'
out="$(printf '%s' "$STDIN" | "$BIN" explain --json --schema '{!query:string,!limit:integer}')"
if printf '%s' "$out" | grep -q '"decision":"safe"' &&
   printf '%s' "$out" | grep -q '"schema_satisfied":2' &&
   printf '%s' "$out" | grep -q '"schema_missing":\[\]'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "explain --json carries the plan"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "explain --json carries the plan" "$out"
fi

# `readiness --schema` prints the two fractions next to the field curve.
STDIN='{"a":1,"b":2222222222}'
check_has "readiness --schema" 0 "schema-ready" out -- readiness --schema '{!a:integer,!b:integer}'

# --- 0.6.0: scalar roots, semantic ambiguity, the runtime number -----------
#
# A scalar root is valid JSON (RFC 8259) and has to survive the agent protocol's
# prose skipping, which looks for the first `{` or `[` and finds none. Before
# 0.6.0 every one of these cases was refused with E002.
STDIN='true' check "scalar root (true)" 0 'true' "" --
STDIN='42' check "scalar root (42)" 0 '42' "" --
STDIN='null' check "scalar root (null)" 0 'null' "" --
STDIN='"a"' check "scalar root (string)" 0 '"a"' "" --
STDIN='true' check "scalar root with --skip-prose" 0 'true' "" -- --skip-prose
STDIN='true' check_has "explain: scalar root is valid JSON" 0 '"valid_json":true' out -- explain --json
STDIN='true' check_has "explain: scalar root is safe" 0 '"decision":"safe"' out -- explain --json

# Valid JSON with no single meaning: the distinction the product is about.
STDIN='{"a":"b","a":"c"}'
check_has "dup key is valid_json" 5 '"valid_json":true' out -- explain --json --policy execution
STDIN='{"a":"b","a":"c"}'
check_has "dup key is semantic ambiguity" 5 '"ambiguity":"semantic"' out -- explain --json --policy execution
STDIN='{"a":"b","a":"c"}'
check_has "dup key is blocked" 5 '"execution":"blocked"' out -- explain --json --policy execution
STDIN='{"a":"b","a":"c"}'
check_has "dup key is normalised" 5 '"normalized":true' out -- explain --json --policy execution
STDIN='{"a":1}' check_has "plain JSON is allowed" 0 '"execution":"allowed"' out -- explain --json
STDIN='{"words":["colour" "color"]}'
check_has "adjacent strings are syntactic" 5 '"ambiguity":"syntactic"' out -- explain --json

# `settled` is the runtime number: when the answer arrived, even when the answer
# is no. `schema-ready` is 1000 here because the skeleton is never satisfied.
STDIN='{"limit":"ten","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'
check_has "readiness reports settled" 0 "settled" out -- readiness --schema '{!limit:integer}'
STDIN='{"limit":"ten","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'
check_has "invalid settles before the end" 0 "settled 218/1000" out -- readiness --schema '{!limit:integer}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
