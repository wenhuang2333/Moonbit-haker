#!/bin/bash
# TC-C-01 command line smoke test (D11). Every case asserts the exit code and,
# where it matters, the exact output. Run from anywhere:
#
#   bash code/tests/cli_smoke.sh [<interjson executable>]
#
# The default executable path is the release native build.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/llm/fixtures"
BIN="${1:-$ROOT/_build/native/release/build/cmd/interjson/interjson.exe}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
skipped=0

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
# The command forms the documents use must actually work. `serve --stdio`
# was printed all over the release notes while the CLI rejected it, and
# `interjson repair` was read as a filename; both are now real, and these
# cases keep them real.
STDIN='{"id":1,"method":"hello"}' check_has "serve speaks the protocol" 0 '"protocol":1' out -- serve
STDIN='{"id":1,"method":"hello"}' check_has "serve --stdio alias" 0 '"protocol":1' out -- serve --stdio
STDIN='{"a":1,}' check "repair subcommand" 0 '{"a":1}' "" -- repair
STDIN='{"a":1}' check "--stdio needs serve" 2 '' "只对" -- --stdio
STDIN='{"a":1}' check "--help exit code" 0 '' "" -- --help
STDIN='{"a":1} {"b":2}' check "multi-root default" 0 '{"a":1}' "R016" -- --report
STDIN='{"a":1} {"b":2}' check "--multi-root array" 0 '[{"a":1},{"b":2}]' "" -- --multi-root array
STDIN='Here you go: {"a":1}' check "prose rejected by default" 3 '' "E002" --
STDIN='Here you go: {"a":1}' check "--skip-prose" 0 '{"a":1}' "R021 1:1 leading prose skipped" -- --skip-prose --report
STDIN="'ok'" check "skip-prose recovers a repaired scalar root" 0 '"ok"' "" -- --skip-prose
STDIN='42 is the answer' check "skip-prose still refuses scalar-prefixed prose" 3 '' "E002" -- --skip-prose
STDIN='+1' check "value-preserving number is executable" 0 '1' "" -- --for-execution
STDIN='1e' check "incomplete exponent stays lossy" 5 '' "E010" -- --for-execution
STDIN='{"n":1.5}' check "schema gates the default repair path" 5 '' "schema not satisfied" -- --schema '{!n:integer}'
STDIN='{"a":"b' check "unclosed string" 0 '{"a":"b"}' "R010" -- --report
STDIN='[1,null,tru]' check "literal completion" 0 '[1,null,true]' "R012" -- --report

# --help content
if printf '{"a":1}' | "$BIN" --help | grep -qF 'interjson [选项] [文件]'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--help content"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--help content"
fi

# --version must match `version` in moon.mod (the string is hard-coded in main.mbt)
MOD_VERSION=$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$(dirname "$0")/../moon.mod")
GOT_VERSION=$(printf '{"a":1}' | "$BIN" --version)
if [ "$GOT_VERSION" = "interjson $MOD_VERSION" ]; then
  pass=$((pass + 1)); printf 'ok   %-34s %s\n' "--version matches moon.mod" "$GOT_VERSION"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s `interjson --version` says "%s" but code/moon.mod says "%s"\n' \
    "--version matches moon.mod" "$GOT_VERSION" "interjson $MOD_VERSION"
fi

# Every document that states a version must state the same one. The published
# mooncakes page renders code/README.md (`readme = "README.md"` in moon.mod),
# so a stale string there is the first thing a reader sees; root README.md is
# the repository front page. A mismatch fails loudly and names both strings.
REPO="$(cd "$ROOT/.." && pwd)"
check_doc_version() {
  local label="$1" file="$2" expr="$3" got
  # Some documents are deliberately not published (see `.gitignore`): they live
  # only on the author's machine, so a clean checkout has no such file. Absence
  # is the expected state there, not drift -- but a file that *is* present and
  # states the wrong version is still a failure.
  if [ ! -f "$REPO/$file" ]; then
    skipped=$((skipped + 1))
    printf 'skip %-34s %s is not published\n' "$label" "$file"
    return 0
  fi
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

# Every `interjson <word>` the documents tell a reader to type must be a
# subcommand the CLI actually has. Two counterexamples shipped: the release
# notes advertised `interjson serve --stdio`, which the CLI rejected with
# "unknown option", and `interjson repair`, which it read as a filename and
# failed with "cannot read repair". No gate compared the documents with the
# CLI's own vocabulary, so both looked correct in a diff and were wrong on a
# judge's machine. The vocabulary is taken from `--help` itself, so a
# subcommand that disappears also fails here.
CLI_SUBCOMMANDS="$("$BIN" --help 2>&1 | sed -n 's/^interjson \([a-z][a-z-]*\).*/\1/p' | sort -u)"
DOC_SUBCOMMANDS="$(
  for f in README.md code/README.md code/README.zh.md code/docs/ONEPAGE.md \
           code/docs/PROTOCOL.md code/docs/INTEGRATIONS.md code/docs/PITCH.md \
           产品文档-精简版.md; do
    [ -f "$REPO/$f" ] || continue
    grep -oE '(^|`)interjson [a-z][a-z0-9-]*([^a-zA-Z0-9._-]|$)' "$REPO/$f" 2>/dev/null
  done | sed -E 's/^.*interjson //; s/[^a-z0-9-].*$//' | sort -u
)"
unknown=""
for w in $DOC_SUBCOMMANDS; do
  printf '%s\n' "$CLI_SUBCOMMANDS" | grep -qx "$w" || unknown="$unknown $w"
done
if [ -z "$unknown" ]; then
  pass=$((pass + 1))
  printf 'ok   %-34s %s\n' "documented subcommands exist" "$(echo $DOC_SUBCOMMANDS)"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s the documents name%s but the CLI has no such subcommand\n' \
    "documented subcommands exist" "$unknown"
  printf '     the CLI has: %s\n' "$(echo $CLI_SUBCOMMANDS | tr '\n' ' ')"
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

# interjson llm: provider adapters over a recorded event stream
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
if printf '%s' "$out" | head -1 | grep -q '^interjson: readiness median' \
   && printf '%s' "$out" | grep -q '^field content ' \
   && printf '%s' "$out" | grep -q '^interjson: readiness' ; then
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
# interjson explain (FR-32, FR-33): one block, and an exit code that says whether
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
check_has "unreadable input" 3 "无法读取" err -- explain /nonexistent/interjson.json

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

# --- 1.0.1: the prose-buffer hint and the channel map -----------------------
#
# `E002` after a skipped prelude has two causes and they need different
# actions: "where the prose ends is undecidable" (a documented boundary) and
# "the end-of-input replay buffer was too small" (a tunable limit). The hint
# names the second one, and `--max-prose-buffer` is the knob it points at.
head -c 70000 /dev/zero | tr '\0' x >"$TMP/prose_overflow.json"
printf 'true' >>"$TMP/prose_overflow.json"
"$BIN" --skip-prose "$TMP/prose_overflow.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 3 ] && grep -qF "exceeded max_prose_buffer" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "prose overflow hint" "$rc"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s rc=%s (want 3)\n     err=%s\n' "prose overflow hint" "$rc" \
    "$(head -1 "$TMP/err")"
fi

printf 'hello world' >"$TMP/undecidable.json"
"$BIN" --skip-prose "$TMP/undecidable.json" >/dev/null 2>"$TMP/err"; rc=$?
if [ "$rc" = 3 ] && ! grep -qF "max_prose_buffer" "$TMP/err"; then
  pass=$((pass + 1)); printf 'ok   %-34s rc=%s\n' "no hint without overflow" "$rc"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s rc=%s (want 3, no hint)\n' "no hint without overflow" "$rc"
fi

STDIN='{"a":1}' check "--max-prose-buffer accepted" 0 '{"a":1}' "" -- --max-prose-buffer 1024
STDIN='{}' check "--max-prose-buffer rejects 0" 2 '' "正整数" -- --max-prose-buffer 0

# The resource limits are settable from the command line, in both directions:
# the library defaults are the starting point and the caller may tighten or
# loosen them. Each one has to actually bite, not just be accepted.
STDIN='[[[1]]]' check "--max-depth bites" 4 '' "E020" -- --max-depth 2
STDIN='[[[1]]]' check "--max-depth loosens" 0 '[[[1]]]' "" -- --max-depth 4
STDIN='{"a":1}' check "--max-input-len bites" 4 '' "E021" -- --max-input-len 4
STDIN='{"a":"xyzw"}' check "--max-token-len bites" 4 '' "E022" -- --max-token-len 3
STDIN='{}' check "--max-depth rejects out of range" 2 '' "1048576" -- --max-depth 99999999
# A digit string long enough to wrap a 32 bit accumulator must be rejected, not
# accepted as a negative limit.
STDIN='{}' check "--max-input-len rejects a wrapped value" 2 '' "正整数字面量" -- --max-input-len 99999999999

# `explain --json` carries the value and, by default, no second copy of the
# rendered text; `--with-text` asks for it back. The text block always renders
# `Repaired:` because that is its whole point.
out="$(printf '%s' '{"a":1,}' | "$BIN" explain --json)"
if printf '%s' "$out" | grep -q '"text":""' && printf '%s' "$out" | grep -q '"value":{"a":1}'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "explain --json omits text"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "explain --json omits text" "$out"
fi
out="$(printf '%s' '{"a":1,}' | "$BIN" explain --json --with-text)"
if printf '%s' "$out" | grep -qF -- '"text":"{\"a\":1}"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "explain --json --with-text"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "explain --json --with-text" "$out"
fi

# The channel map in README.md names the released version; if the row and
# code/moon.mod drift apart, the mapping table is lying. The first
# `| `vX.Y.Z` |` row wins, so the table must keep the newest release first.
MAP_VERSION="$(
  grep -m1 -o '^| `v[0-9][0-9.]*` |' "$REPO/README.md" | grep -o '[0-9][0-9.]*'
)"
if [ "$MAP_VERSION" = "$MOD_VERSION" ]; then
  pass=$((pass + 1)); printf 'ok   %-34s README=%s\n' "channel map matches moon.mod" "$MAP_VERSION"
else
  fail=$((fail + 1))
  printf 'FAIL %-34s README says "%s" but code/moon.mod says "%s"\n' \
    "channel map matches moon.mod" "$MAP_VERSION" "$MOD_VERSION"
fi

# --- MCP local deployment surface -------------------------------------------
# `mcp` is the product's primary surface; these cases keep the printed client
# configuration and the tool list from drifting away from the server.
cfg="$("$BIN" mcp --print-config=claude)"
if [ "$cfg" = 'claude mcp add interjson -- interjson mcp' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp --print-config=claude"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "mcp --print-config=claude" "$cfg"
fi
cfg="$("$BIN" mcp --print-config=cursor)"
if printf '%s' "$cfg" | grep -qF '"command":"interjson"' \
   && printf '%s' "$cfg" | grep -qF '"args":["mcp"]'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp --print-config=cursor"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "mcp --print-config=cursor" "$cfg"
fi
if "$BIN" mcp --help 2>&1 | grep -qF 'interjson_gate'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp --help names the gate"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "mcp --help names the gate" "$("$BIN" mcp --help 2>&1)"
fi
mcp_init="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | "$BIN" mcp)"
if printf '%s' "$mcp_init" | grep -qF '"name":"interjson"' \
   && printf '%s' "$mcp_init" | grep -qF '"instructions"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp initialize"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "mcp initialize" "$mcp_init"
fi

# --- 1.5 regressions --------------------------------------------------------
# Each of these is a defect that shipped in 1.4.x. They are here, in the
# cheapest gate, because each one is a one-line command away from being
# checked and each one was found by reading rather than by running.

# `--max-repairs` rejected the value its own help text recommends (the bound
# was 64, the documented default 10000).
if printf '{"a":1}' | "$BIN" --max-repairs 10000 >/dev/null 2>&1; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--max-repairs accepts 10000"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--max-repairs accepts 10000"
fi
if printf '{"a":1}' | "$BIN" --max-repairs 0 >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--max-repairs rejects 0"
else
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--max-repairs rejects 0"
fi

# `--max-prose-buffer=` sliced one character too far, so 65536 silently became
# 5536. The buffer is what bounds the replay of skipped prose, so the effect
# is a refusal on a document that should fit.
if printf '{"a":1}' | "$BIN" --max-prose-buffer=65536 >/dev/null 2>&1; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--max-prose-buffer=65536 accepted"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "--max-prose-buffer=65536 accepted"
fi

# A multi-byte character straddling the 64 KiB read boundary was decoded as
# two replacement characters. The document is written so that the character
# lands exactly on the boundary.
# `--batch` reads one envelope per line, so the document goes inside one. The
# padding puts the two bytes of e-acute across the 65536-byte read boundary.
python3 - "$BIN" <<'PYEOF'
import json, subprocess, sys
binary = sys.argv[1]

# The reader consumes 65536 bytes at a time, so the multi-byte character has
# to start at byte 65535 *of the stream* -- the batch envelope counts, and
# getting that wrong was how this test first passed against the broken code.
# The padding is therefore solved for, not guessed.
def build(pad_len):
    doc = '{"k":"' + "a" * pad_len + '\u00e9"}'
    # `ensure_ascii=False` matters: the default escapes the character into six
    # ASCII bytes and the test then checks a stream with no multi-byte
    # character in it at all.
    return json.dumps({"id": "edge", "input": doc}, ensure_ascii=False)

pad_len = 0
while True:
    envelope = build(pad_len)
    at = envelope.encode("utf-8").index("\u00e9".encode("utf-8"))
    if at >= 65535:
        break
    pad_len += 65535 - at
envelope = build(pad_len)
at = envelope.encode("utf-8").index("\u00e9".encode("utf-8"))
assert at == 65535, at
assert len(envelope.encode("utf-8")) > 65536, len(envelope.encode("utf-8"))
out = subprocess.run([binary, "--batch"], input=envelope + "\n",
                     capture_output=True, text=True)
if "\ufffd" in out.stdout or "\ufffd" in out.stderr:
    print("FAIL boundary-utf8: replacement character in the output")
    sys.exit(1)
if '"rc":0' not in out.stdout:
    print("FAIL boundary-utf8: the document was not accepted")
    print((out.stdout or out.stderr)[:300])
    sys.exit(1)
sys.exit(0)
PYEOF
if [ "$?" = 0 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "multi-byte char on the 64 KiB edge"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "multi-byte char on the 64 KiB edge"
fi

# The gate's two channels are different objects: the text channel is a
# summary for the model, `structuredContent` is the payload.
gate_out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"{\"a\":1,}"}}}' | "$BIN" mcp | tail -1)"
if printf '%s' "$gate_out" | grep -qF '"structuredContent"' \
   && printf '%s' "$gate_out" | grep -qF 'decision='; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "gate carries a summary and a payload"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "gate carries a summary and a payload" "$gate_out"
fi

# The agent profile is the agent profile: a sentence in front of the
# arguments is not part of the arguments.
if printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"Here are the args:\n{\"a\":1}"}}}' | "$BIN" mcp | tail -1 | grep -qF '"executable":true'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "agent profile skips prose"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "agent profile skips prose"
fi

# ...and `execution` is not the agent profile.
if printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"Here are the args:\n{\"a\":1}","profile":"execution"}}}' | "$BIN" mcp | tail -1 | grep -qF '"executable":false'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "execution profile refuses prose"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "execution profile refuses prose"
fi

# Every refusal carries the sentence to send back to the model, and no value.
refusal="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"{\"a\":1}","schema_json":{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}}}}' | "$BIN" mcp | tail -1)"
if printf '%s' "$refusal" | grep -qF '"executable":false' \
   && printf '%s' "$refusal" | grep -qF '"prompt"' \
   && printf '%s' "$refusal" | grep -qF '"value":null'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "refusal carries prompt, drops value"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "refusal carries prompt, drops value" "$refusal"
fi

# Two different integers that share a Double are two different values: the
# merge must be recorded as a loss, not as a no-op.
big="$(printf '{"id":9007199254740993,"id":9007199254740992}' | "$BIN" explain --json)"
if printf '%s' "$big" | grep -qF '"exactness":"lossy"' \
   && printf '%s' "$big" | grep -qF '"severity":"warning"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "unsafe-integer merge is lossy"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "unsafe-integer merge is lossy" "$big"
fi

# Two spellings of the same number are the same number: `1` and `1.0` merge
# without losing anything, so the gate must not refuse it.
spelling="$(printf '{"a":1,"a":1.0}' | "$BIN" explain --json)"
if printf '%s' "$spelling" | grep -qF '"severity":"info"'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "1 and 1.0 merge as one value"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     %s\n' "1 and 1.0 merge as one value" "$spelling"
fi

# The space form of `--print-config` used to be read as a file name.
if [ "$("$BIN" mcp --print-config claude)" = 'claude mcp add interjson -- interjson mcp' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp --print-config claude (space)"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "mcp --print-config claude (space)"
fi
if "$BIN" mcp --print-config bogus >/dev/null 2>&1; then
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "mcp --print-config rejects a typo"
else
  pass=$((pass + 1)); printf 'ok   %-34s\n' "mcp --print-config rejects a typo"
fi

# MCP is a session protocol: a request before the handshake is refused.
if printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | "$BIN" mcp | grep -qF -- '-32002'; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "tools/list before initialize"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n' "tools/list before initialize"
fi

# `--chunk N` drives the one-shot path too. It used to affect only `--batch`,
# so the flag whose whole purpose is to exercise the streaming path never
# touched it.
if [ "$(printf '{"a":1,}' | "$BIN" --chunk 1)" = '{"a":1}' ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--chunk drives the one-shot path"
else
  fail=$((fail + 1)); printf 'FAIL %-34s %s\n' "--chunk drives the one-shot path" "$(printf '{"a":1,}' | "$BIN" --chunk 1)"
fi

# Conflicting flags are refused, not silently resolved: `--policy` replaces
# the safety knobs, so `--strict --policy permissive` used to drop one of them
# without a word.
conflict_rc=0
"$BIN" --strict --policy permissive </dev/null >/dev/null 2>&1 || conflict_rc=$?
if [ "$conflict_rc" = 2 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "--strict --policy is refused"
else
  fail=$((fail + 1)); printf 'FAIL %-34s rc=%s\n' "--strict --policy is refused" "$conflict_rc"
fi

# A schema deep enough to exhaust the stack is refused, not crashed.
deep_schema="$(python3 -c 'print("[" * 400 + "]" * 400)')"
deep_rc=0
printf '{"a":1}' | "$BIN" explain --json --schema "$deep_schema" >/dev/null 2>&1 || deep_rc=$?
if [ "$deep_rc" -lt 128 ]; then
  pass=$((pass + 1)); printf 'ok   %-34s\n' "deep declaration refused, not crashed"
else
  fail=$((fail + 1)); printf 'FAIL %-34s\n     rc=%s\n' "deep declaration refused, not crashed" "$deep_rc"
fi

if [ "$skipped" -gt 0 ]; then
  printf '\n%d passed, %d failed, %d skipped (document not published)\n' \
    "$pass" "$fail" "$skipped"
else
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
fi

[ "$fail" = 0 ]
