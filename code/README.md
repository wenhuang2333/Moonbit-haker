# InterJSON

**The execution gate for LLM output — a local MCP server, one native binary.**

InterJSON answers the only question between a model's tool call and the code that
would run it: *may I execute this?* `interjson mcp` serves that decision over
stdio as a Model Context Protocol server — no socket, no network, no API key, no
model output leaving the machine. The engine underneath is pure MoonBit with
wasm-gc, native, JS and wasm backends, and the same engine answers the same
question for host-side callers (`serve`, npm, pip, HTTP).

| | |
| --- | --- |
| Module | `zhanshishan/interjson` |
| Version | 1.5.1 |
| License | Apache-2.0 |
| MCP server | `interjson mcp`, also `interjson-mcp`; JSON-RPC 2.0 over stdio, protocol `2025-06-18` (`2025-03-26` and `2024-11-05` accepted) |
| Backends | wasm-gc, native, JS, wasm — one test suite, all four |
| Registry | [`mooncakes.io zhanshishan/interjson`](https://mooncakes.io/docs/zhanshishan/interjson) — 0.13.0 is the 1.5.1 correspondence and **was published on 2026-10-29**; 0.12.0 (the 1.5.0 correspondence) was published on 2026-10-28; 0.11.0 (the 1.4.0 correspondence) was published on 2026-10-27; older releases are under the former name `zhanshishan/jsonmend` |
| Prebuilt binaries | The GitHub release `v1.5.1`: four binaries across three operating systems (`linux-x86_64`, `linux-arm64`, `macos-arm64`, `windows-x86_64.exe`), the wasm probe, the browser bundle, `SHA256SUMS` and the `interjson-install.sh` one-command installer. There is **no Intel macOS build** — the MoonBit toolchain publishes no `darwin-x86_64` target. Older releases keep the `jsonmend-*` asset prefix |
| Docs | [`docs/MCP.md`](docs/MCP.md) (deployment), [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) (host-side recipes), [`docs/SPEC.md`](docs/SPEC.md) (the normative contract), [../README.md](../README.md) (project front page) |

This page is the package page for mooncakes.io and the **API reference**: the
engine's public surface, its options, its repair rules, its errors, and the CLI.
The 60-second path, the evidence tables and the release/version mapping live in
the [repository front page](../README.md); the MCP deployment guide is
[`docs/MCP.md`](docs/MCP.md).

## The gate

`interjson mcp` exposes four read-only tools. A client — Claude Code, Cursor,
Cline, Windsurf, VS Code, Codex CLI, Zed, or anything that speaks MCP — starts
the server locally and can then ask:

| Tool | What it answers |
| --- | --- |
| `interjson_gate` | **may I execute this?** `decision`, `executable`, `exactness`, ambiguity, schema satisfaction, `value`, and `retry.prompt` when refused |
| `interjson_repair` | what is the repaired document, and what changed? |
| `interjson_validate` | is this legal JSON, and does it satisfy the declaration? |
| `interjson_readiness` | at which input fraction is each declared field final? |

`interjson_gate` defaults to the `agent` profile when the caller omits one:
a lossy or ambiguous repair is refused instead of guessed, and the refusal
carries a prompt that can be sent straight back to the model. That default is
exactly `Options::for_agent()`, protocol included: prose before the arguments
(`Here are the args:\n{"a":1}`) is skipped, not refused.

**The refusal contract:** a result with `executable == false` always carries a
non-empty `retry.prompt` and `value: null`; an executable result always carries a
live `value` and `retry: null`. `content[0].text` is a summary the model can act
on; `structuredContent` is the payload, once.

**MCP is advisory.** `interjson_gate` is a tool the model *may* call, and nothing
in MCP makes the host check the answer. What makes the gate mandatory is a
host-side insertion point: a Claude Code `PreToolUse` hook, a `gate(args)` call in
the host SDK, or `interjson serve` / npm / pip / HTTP. Recipes:
[`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md#making-the-gate-mandatory).

## Install

### The MoonBit library

```sh
moon add zhanshishan/interjson
```

Then import the package in your `moon.pkg` with the alias used throughout this
document:

```
import {
  "zhanshishan/interjson" @interjson,
}
```

### The MCP server

The server is a single native binary: no runtime, no API key, no network.

```sh
cd code
moon build cmd/interjson --target native --release
./_build/native/release/build/cmd/interjson/interjson.exe mcp --print-config=claude
```

The installer, the per-client configuration, the pip/npm launchers and the
security model are in [`docs/MCP.md`](docs/MCP.md).

## Public API

Four entry points, one engine:

| Entry point | Returns |
| --- | --- |
| `repair(input, options?)` | `RepairResult`: `text`, `repairs`, `completeness`, `repairs_truncated` |
| `parse(input, options?)` | `ParseResult`: the `Json` value plus the same records |
| `analyze(input, options?, readiness?, schema?)` | `RepairPlan`: decision, operations, retry prompt, JSON channel — **never raises** |
| `PartialParser` | `feed` / `feed_bytes` / `snapshot` / `finish` / `drain_deltas` |

`repair` raises `InterJSONError`, so wrap the calls in `try`/`catch` (the three
statements below are the whole example):

```moonbit
try {
  let result = @interjson.repair("{'a': 1,}")   // RepairResult
  println(result.text)                         // {"a":1}
  println(result.repairs.length())             // number of repair records
} catch {
  e => println(e.to_string())
}
```

Use `@interjson.parse` instead when you want the `Json` tree rather than the text;
it returns the same `repairs` and `completeness` alongside a `value`.

### One call: "may I execute this"

```moonbit
let plan = @interjson.analyze(text,
  options=@interjson.Options::for_agent(),
  schema=@interjson.Schema::parse("{!query:string,!limit:integer}"))
plan.decision          // Safe | CosmeticRepair | LossyRepair | Ambiguous | Invalid
plan.is_executable()   // the only question a gate has to ask
plan.repairs           // rule, action, position, confidence class, information loss
plan.prompt()          // ready to feed back to the model when it is not executable
plan.to_json()         // machine channel: decision/exactness/value/retry/repairs
```

`analyze` never raises — a refusal is part of the return value — and costs
1.00–1.03× a plain `repair` call.

- **`SafetyPolicy`**: five named profiles — `permissive`, `interactive`,
  `execution`, `agent`, `strict` — over the safety-relevant `Options`.
  `Options::with_policy` replaces only the safety knobs and keeps the protocol
  ones (delta stream, prose handling); `Options::with_profile` applies both halves,
  which is how a profile selected *by name* (MCP tool, `--policy`, `serve`) means
  the same thing as the library preset; `SafetyPolicy::of_options` reads a set of
  options back to the profile it is (or `None`).
- **`Schema` + `semantic_readiness`**: declare `{!query:string,!limit:integer}` and
  get two fractions for the same stream — syntax ready and schema ready — plus the
  members that are missing or of the wrong kind. `Schema::of_json_schema` and
  `parse_json_schema` accept a tool's existing JSON Schema subset directly.
- **Exactness labels**: every result carries `Exact` / `Cosmetic` / `Lossy`,
  derived from the severities of the records. `Options::max_loss` turns the first
  repair that exceeds the budget into a fatal `E010`.
- **Ambiguity gate**: a repair that admits a second, equally self-consistent
  reading (`["a" "b"]`, `["a"+"b"]`, `[fast]`, `{"a":1} {"b":2}`) is recorded with
  an `Ambiguity` class and refused with `E011` under
  `Options::reject_ambiguous` / `Options::for_execution()`, before the exactness
  gate. 10/10 adversarial cases are flagged and refused, while both reference
  libraries answer all 10 with a silent value (`docs/EVAL_AMBIGUITY.md`).
- **Reject as feedback**: `InterJSONError::retry_hint` (and `--retry-hint`) turns a
  refusal into a prompt fragment — error code, repair code, position, the second
  reading, a bounded context window with a caret.
- **Field readiness (FR-29)**: `field_readiness` reports, for every top-level
  member, the input fraction at which its value is already final, and
  `FieldTracker` does the same from the delta stream.
- **Incremental deltas**: with `Options::collect_deltas`, `drain_deltas()` returns
  `Set` / `AppendText` / `Close` operations with RFC 6901 JSON Pointer paths;
  `drain_views()` / `for_each_delta()` are the zero-path-allocation entry points.
- **LLM provider adapters** in the `interjson/llm` sub-package (*experimental*):
  Anthropic fine-grained tool streaming and OpenAI-compatible tool-call deltas, an
  SSE framer, and a text stream that reads the JSON out of `delta.text` /
  `delta.content`. The end of a call is reported as `Complete`, `MaxTokens`,
  `Interrupted` or `ProviderError` with the provider's own `stop_reason` verbatim.

## Streaming example

`PartialParser` accepts any number of chunks. A chunk may split any token,
including an escape sequence or a surrogate pair.

```moonbit
try {
  let p = @interjson.PartialParser::new()
  p.feed("{\"name\":\"Mo")
  let s1 = p.snapshot()
  match s1.value {
    Some(v) => println(v.stringify())          // {"name":"Mo"}
    None => println("<none>")
  }
  println(s1.completeness is @interjson.Partial) // true
  p.feed("n\"}")
  let done = p.finish()
  println(done.text)                            // {"name":"Mon"}
  println(done.completeness is @interjson.Complete) // true
} catch {
  e => println(e.to_string())
}
```

`feed_bytes` takes raw UTF-8 and can be mixed with `feed`; invalid or truncated
UTF-8 raises `E040`. Options are passed by keyword:

```moonbit
try {
  let p = @interjson.PartialParser::new(options={
    ..@interjson.Options::default(),
    incomplete_number: @interjson.TrimToValid,
    pending_key: @interjson.NullKey,
  })
  p.feed_bytes(b"[1, 1.")
  let s = p.snapshot()
  // s.value is [1,1]: the unfinished number is trimmed to its longest valid prefix.
  p.feed_bytes(b"5]")
  let done = p.finish()
  println(done.text)  // [1,1.5]
} catch {
  e => println(e.to_string())
}
```

`snapshot()` returns a `Snapshot` whose fields are `value` (`Json?`),
`completeness`, and `open_path`; `finish()` returns a `FinalResult` with `text`,
`value`, `repairs`, and `completeness`. `snapshot()` never raises and never
mutates the parser; `finish()` may be called once and raises `E030` on a second
call or after a fatal error.

An end-to-end gate loop that refuses, feeds the prompt back, and then executes is
`examples/agent_gate/` (`moon run examples/agent_gate --target native --release`);
the four-episode self-healing loop is `examples/agent_loop/`.

## Options

Every field of `Options`. `@interjson.Options::default()` is the documented
default set.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `mode` | `Mode` | `Lenient` | `Lenient` records repairs; `Strict` raises `E010` at the first one. |
| `max_depth` | `Int32` | `512` | Maximum container nesting; exceeding it raises `E020`. The ceiling is `MAX_VALUE_DEPTH`, which is also the default, so a caller can tighten it but not loosen it: a larger value is refused with `E050` (the ceiling and its reason are documented in [`SECURITY.md`](SECURITY.md); see [Known limitations](#known-limitations)). |
| `max_input_len` | `Int32` | `67108864` | Maximum input length in UTF-16 code units; exceeding it raises `E021`. |
| `max_token_len` | `Int32` | `16777216` | Maximum length of one token in code units; exceeding it raises `E022`. |
| `duplicate_keys` | `DuplicateKeys` | `KeepLast` | `KeepLast`, `KeepFirst`, or `AsError` for duplicate object keys (`R018`). |
| `incomplete_number` | `IncompleteNumber` | `Drop` | Snapshot policy for an unfinished number: `Drop` or `TrimToValid`. |
| `pending_key` | `PendingKey` | `OmitKey` | Snapshot policy for a dangling key: `OmitKey` or `NullKey`. |
| `non_finite` | `NonFinite` | `AsNull` | `NaN`/`Infinity`/`-Infinity` become `AsNull`, `AsString`, or `AsError` (`R012`). |
| `strip_fence` | `Bool` | `true` | Strip Markdown code fences (`R001`). |
| `collect_repairs` | `Bool` | `true` | Record repairs in the result; when `false` the array stays empty, but strict mode and disabled rules still raise. |
| `want_text` | `Bool` | `true` | Produce repaired text in `FinalResult.text`; when `false` only the `Json` value is built. |
| `skip_prose` | `Bool` | `false` | Skip leading prose before the first `{` or `[` (`R021`). With no container root, `finish` replays the prelude as a scalar root; a value-preserving repair is accepted, dropped trailing content (`R016`) is not. |
| `quote_lookahead` | `Bool` | `false` | Enable quote-ambiguity lookahead for missing commas between strings (`R003`). |
| `multi_root` | `MultiRoot` | `KeepFirst` | Policy for content after the first root value: `KeepFirst`, `AsArray`, or `AsError` (`R016`). |
| `rules` | `RuleSet` | `RuleSet::all()` | Per-rule switches; disabling a rule makes that code raise `E010`. The table is sized from `RepairCode::count()`, and an out-of-range code is fail-closed. |
| `indent` | `Int32` | `0` | Output indentation in spaces; `0` renders compact JSON. |
| `max_repairs` | `Int32` | `10000` | Maximum number of repair records kept; beyond it repairs still apply but the result sets `repairs_truncated`. |
| `reject_ambiguous` | `Bool` | `false` | Refuse a repair that admits a second reading (`E011`) instead of applying it. `Options::for_execution()` sets it. |
| `max_loss` | `Exactness` | `Lossy` | Highest acceptable exactness. The first record that exceeds it raises `E010` with that code and position. `Options::for_execution()` sets `Cosmetic`. |
| `collect_deltas` | `Bool` | `false` | Collect incremental deltas; read them with `PartialParser::drain_deltas()`. Cannot be combined with `duplicate_keys: KeepFirst` or `incomplete_number: TrimToValid`. |

Invalid values (`max_depth <= 0` or above the ceiling, `max_input_len <= 0`,
`max_token_len <= 0`, `max_repairs <= 0`, `indent < 0`) raise `E050` from
`Options::validate`, which `repair`, `parse`, and `PartialParser::new` call for
you. A declaration (JSON Schema or the skeleton language) deeper than
`MAX_SCHEMA_DEPTH` raises `E070`; the depth ceilings are stated in
[`SECURITY.md`](SECURITY.md).

## Repair rules overview

Every change is one record whose code is stable. The table below is the complete
list of codes; the dictionary that adds worked examples and the requirement each
rule implements is maintained in the repository but is not part of the published
package.

| Code | Name | Meaning |
| --- | --- | --- |
| `R001` | `StripFence` | Remove a Markdown code fence. |
| `R002` | `StripComment` | Remove a line or block comment. |
| `R003` | `NormalizeQuote` | Normalize a quote to a double quote. |
| `R004` | `QuoteBareWord` | Quote a bare word (Info in key position, Warning in value position). |
| `R005` | `RemoveExtraComma` | Remove a trailing, leading, or repeated comma. |
| `R006` | `InsertComma` | Insert a missing comma. |
| `R007` | `InsertColon` | Insert a missing colon. |
| `R008` | `FillNull` | Fill `null` for a missing value. |
| `R009` | `CloseContainer` | Close an unclosed array or object. |
| `R010` | `CloseString` | Close an unclosed string. |
| `R011` | `FixNumber` | Normalize or trim a number. Value-preserving rewrites (`+1`, `01`, `1.`, `.5`, `-01`) are `Cosmetic`; a trimmed exponent (`1e`, `1e+`) is `Lossy`. |
| `R012` | `ConvertLiteral` | Convert or complete a literal (`True`, `None`, `undefined`, non-finite values). |
| `R013` | `EscapeControl` | Escape a control character inside a string. |
| `R014` | `FixEscape` | Repair an invalid or truncated escape, or a lone surrogate. |
| `R015` | `MismatchedCloser` | Replace a closer whose type does not match the open container. |
| `R016` | `DropUnexpected` | Drop unrecognized or surplus content, including trailing content after the root value. |
| `R017` | `DropExtraCloser` | Drop a surplus closer. |
| `R018` | `MergeDuplicateKey` | Merge a duplicate key according to `duplicate_keys`. |
| `R019` | `ConcatStrings` | Merge adjacent string concatenation (`["a" + "b"]` becomes `["ab"]`). |
| `R020` | `DropEllipsis` | Drop an `...` placeholder in a value position. |
| `R021` | `SkipProse` | Skip leading prose before the JSON value. |
| `R022` | `NormalizeLiteral` | Re-case a literal (`True`, `NULL`) without changing which value it denotes. `Info` when only the case changes; `Warning` when characters are also added or dropped (`R012`). |

## Repair records and error codes

Two signal families are kept apart: repair records are informational and travel
with the result; fatal errors abort processing and are raised as
`InterJSONError`.

A `Repair` carries `code : RepairCode`, `position : Position`,
`severity : Severity`, and `message : String`. `repair`, `parse`, and `finish`
also return `repairs_truncated : Bool`. `Position.offset` counts UTF-16 code
units from 0, while `line` and `column` are 1-based. `Severity::Info` means the
value is unchanged and only the notation was normalized; `Severity::Warning`
means content may have been invented, dropped, or altered. Messages are fixed
templates and never embed user input.

| Code | Error | Raised when |
| --- | --- | --- |
| `E001` | `EmptyInput` | The input is empty or whitespace only. |
| `E002` | `NoJsonFound` | No JSON value can be found (payload is the offset). |
| `E010` | `StrictViolation` | Strict mode, or a disabled rule, rejects a repair (payload is the code, position, and message). |
| `E011` | `Ambiguous` | The repair admits a second reading and `reject_ambiguous` is set. |
| `E020` | `DepthLimit` | Nesting exceeds `max_depth`. |
| `E021` | `SizeLimit` | Input exceeds `max_input_len`. |
| `E022` | `TokenLimit` | A token exceeds `max_token_len`. |
| `E030` | `InvalidState` | `feed` after `finish`, or `finish` called twice or after a fatal error. |
| `E040` | `InvalidUtf8` | Invalid or truncated UTF-8 in `feed_bytes` (payload is the byte offset). |
| `E050` | `InvalidOption` | An option value is out of range, or a combination is invalid (`collect_deltas` with `KeepFirst`/`TrimToValid`). |
| `E060` | `InvalidEvent` | `interjson/llm` received an event payload it cannot interpret. |
| `E070` | `SchemaError` | The declaration itself is malformed, or uses a keyword outside the supported subset. |

`RepairCode::code`, `InterJSONError::code`, and `InterJSONError::to_string`
produce the stable strings (`R005`, `E020`, and a one-line diagnostic
respectively). The tables above are the complete set of both families, and the
exit codes are in the [Command line](#command-line) section. The longer
reference — per-code payloads, the strict-mode escalation rules and the failure
modes — is maintained in the repository but is not published. The normative
contract is [`docs/SPEC.md`](docs/SPEC.md).

## Snapshot semantics

`snapshot()` returns a non-destructive view of the value parsed so far, without
raising and without changing parser state:

- **Stable prefix.** Values that are already closed — complete strings, numbers,
  literals, and containers — never change in later snapshots. Only the last
  unfinished element can change.
- **Monotonicity.** The snapshot sequence grows monotonically. Choosing
  `TrimToValid` deliberately breaks monotonicity for unfinished numbers (a
  snapshot showing `12` can later become `123`); this is documented behaviour,
  not a bug.
- **Unfinished number.** With the default `incomplete_number = Drop`, an unfinished
  number is not shown at all. With `TrimToValid`, the longest valid prefix is
  shown, or nothing if there is no valid prefix.
- **Unfinished key.** A key whose closing quote has not arrived never appears. A
  dangling key (key plus colon, no value) is omitted with the default
  `pending_key = OmitKey`, or shown as `"key": null` with `NullKey`.
- **Unfinished string.** The received prefix appears; an incomplete escape
  sequence is held back until it is complete.
- **Literal prefix.** A partial literal such as `tr` is not shown in a snapshot; it
  is completed at `finish`.
- **Open containers.** An open array or object appears with the content confirmed
  so far, and `completeness` is `Partial`.
- **`open_path`** locates the value currently being built as
  `Array[PathSegment]`, where a segment is `Key(String)` or `Index(Int32)`.
  Synthetic frames, such as the array wrapper added by `multi_root = AsArray`, are
  skipped.

A snapshot differs from the final result by design: the preview omits what is not
yet decided, while `finish` closes containers (`R009`), closes strings (`R010`),
trims numbers (`R011`), completes literals (`R012`), and fills a dangling key with
`null` (`R008`).

## Command line

Build and run the CLI (native-only; `cmd/interjson/moon.pkg` declares
`supported_targets = "native"`):

```sh
moon build cmd/interjson --target native --release
echo "{'a': 1,}" | ./_build/native/release/build/cmd/interjson/interjson.exe
```

The CLI has six subcommands (`repair` is the default action; `interjson --help`
prints the full help, which is in Chinese). The English reference:

| Command | Use |
| --- | --- |
| `interjson [file]` | Read a file or stdin, write the repaired JSON to stdout. |
| `interjson repair [file]` | The default action, spelled out: the document and nothing else. |
| `interjson explain [file]` | Full analysis: what was repaired, why, how risky, and whether it may execute; on a refusal, the retry hint. Exit code 0 when executable, 5 when refused. |
| `interjson readiness [file]` | Field-readiness curve: when each top-level field becomes final. |
| `interjson llm [file]` | Feed a provider event stream through the adapter; one result JSON per tool call. |
| `interjson serve` | Long-lived stdio protocol ([`docs/PROTOCOL.md`](docs/PROTOCOL.md)): one request JSON per line, one response JSON per line. |
| `interjson mcp` | MCP stdio server (JSON-RPC 2.0) exposing the four tools; `--print-config[=CLIENT]` prints a client configuration and exits. |

Flags:

| Flag | Meaning |
| --- | --- |
| `--strict` | Strict mode: any needed repair is an error (exit code 5). |
| `--check` | Check only, no output; exit code 1 when repairs are needed. |
| `--report` | Write the repair records to standard error. |
| `--indent N` | Output indentation in spaces (0 to 64); the default is compact output. |
| `--multi-root MODE` | `first`, `array`, or `error`; the default is `first`. |
| `--skip-prose` | Skip prose before the JSON value. |
| `--quote-lookahead` | Enable quote-ambiguity lookahead. |
| `--max-repairs N` | Maximum number of repair records to keep (default 10000); a truncated run also prints a note to standard error. |
| `--max-loss LEVEL` | Exactness ceiling: `exact`, `cosmetic`, or `lossy` (default). Exceeding it exits with code 5. |
| `--for-execution` | Equivalent to `--max-loss cosmetic --reject-ambiguous`. |
| `--reject-ambiguous` | Refuse a repair with a second reading (`E011`, exit code 5). |
| `--retry-hint` | On a refusal, print the ready-to-feed-back prompt to standard error. |
| `--explain` | Print every record with severity, position and a caret snippet, plus an exactness summary, to standard error. |
| `--policy NAME` | Safety profile: `permissive`, `interactive`, `execution`, `agent` or `strict`. |
| `--schema DECL` | Skeleton declaration such as `{!query:string,!limit:integer}`; with `explain` it also prints the syntax-ready and schema-ready fractions. |
| `--json` | With `explain`: the machine-readable plan instead of the text block. |
| `--with-text` | With `explain --json`: include the repaired text, which the plan otherwise omits. |
| `--max-input-len N` | Maximum input length in UTF-16 code units (default 67108864; `E021`). |
| `--max-depth N` | Maximum container nesting (default 512; `E020`). Above the ceiling in [`SECURITY.md`](SECURITY.md) the option itself is refused with `E050` — the ceiling is the default, so the flag can only tighten. |
| `--max-token-len N` | Maximum length of one token (default 16777216; `E022`). |
| `--max-prose-buffer N` | With `--skip-prose`, how many code units of prelude may be buffered for the end replay (default 65536). |
| `--chunk N` | Feed the input in N-code-unit chunks (≤1048576) to exercise the streaming path. |
| `--batch` | Read `{"id","input"}` objects line by line and write one result object per line. |
| `-h`, `--help` | Show help. |
| `--version` | Show the version (`interjson 1.5.1`). |
| file, or `-` | Read a file; `-` or an omitted argument reads standard input. |

`--indent=N`, `--multi-root=MODE`, and `--max-repairs=N` are accepted as
equivalent to the space-separated forms.

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Success; the output may still contain repairs. |
| `1` | `--check` found that repairs are needed. |
| `2` | Usage error (unknown flag, bad option value, or `E050`). |
| `3` | Invalid input (`E001`/`E002`/`E040`/`E060`, or an unreadable file). |
| `4` | Resource limit reached (`E020`/`E021`/`E022`). |
| `5` | Refused (`E010` over budget, `E011` ambiguity, `E070` declaration mismatch). |
| `70` | Internal error (`E030`). |

The browser demo lives in `examples/web`; the built page is `static/demo/index.html`
and can be opened directly from disk. The demo's MoonBit entry points are plain
`String`-in/`String`-out functions registered on the host page through
`globalThis.interjsonRegister*`, so the page contains no second implementation.
The same bundle backs `static/demo/interjson.js` and the npm package. Rebuild it
with `bash static/demo/build.sh`; the build steps and how to open the page are in
[`static/demo/README.md`](../static/demo/README.md), and
`node code/tests/demo_smoke.mjs` checks the committed bundle still answers.

## Testing

```bash
cd code
moon test                      # default backend (wasm-gc)
moon test --target native      # host backend
moon test --target js          # JavaScript backend
moon test --target wasm        # wasm backend
bash tests/cli_smoke.sh        # command line assertions, including the MCP checks
bash tests/examples.sh         # example inputs vs code/examples/cases/*.expected
node ../code/tests/demo_smoke.mjs   # the committed browser bundle still answers
python3 tests/conformance/run_conformance.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/run_eval.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
moon run examples/agent_loop --target native --release
```

Cross-backend results are identical: **249/249** tests pass on each of wasm-gc,
native, JS and wasm. `.github/workflows/ci.yml` runs the same commands on every
push, so the numbers are re-derived rather than trusted. The commands above are
the reproduction path; the figures they produce are in the [repository front
page's evidence table](../README.md#质量与证据), and the components that fall short
of their budgets are listed as known limitations there and in
[Known limitations](#known-limitations) below. The evaluation protocol and its
revision history are in [`docs/EVAL_REGISTRATION.md`](docs/EVAL_REGISTRATION.md)
and [`docs/EVAL.md`](docs/EVAL.md).

## Differences from jsonrepair

InterJSON is not a port of `jsonrepair` and does not aim for byte-identical
output. Several differences are deliberate, documented policy choices: trailing
content after the root value keeps the first value by default instead of merging
it, Markdown fences are stripped by default, duplicate keys keep the last value,
unfinished numbers are dropped from snapshots, and strict mode plus per-rule
switches have no direct equivalent. A differential harness runs `jsonrepair`
(TypeScript/Node) and `json-repair` (Python) over a corpus of hand-written and
mutated inputs, compares parsed values, and classifies every divergence; all 202
divergences in the committed report have a documented cause and none is
unexplained. The method and the reference-library versions are in
[`docs/DIVERGENCES.md`](docs/DIVERGENCES.md), which classifies each divergence
against the rule and error codes listed earlier on this page.

## Performance

`bench/main.mbt` measures one-shot repair throughput over valid, flawed, deeply
nested, and long-string corpora, plus parse-only cost, scaling at n/2n/4n, and
streaming overhead as a function of chunk size and snapshot frequency:

```sh
moon run bench --target native --release
moon run bench --target js --release
moon run bench --target native --release -- longtext   # the long-text arms only
```

The same run also measures the **first visible value**: it appears at 0.7% of the
document (median over tool-call payloads). Enabling `collect_deltas` costs
1.40–1.46 × the baseline time on a 1 MB document — a **known shortfall**, not a
win.

The measured figures for the current release (throughput, first visible value,
memory and artifact size) are in the [repository front page's evidence
table](../README.md#质量与证据); this page does not restate them, so the two cannot
drift apart. These figures are observations, not a guarantee: throughput depends
on the input shape, chunk size, snapshot frequency, and the toolchain version.
The benches above are the method; the longer historical tables and the decision
records behind the budgets are maintained in the repository but are not
published.

## Known limitations

- **The `FR-16` event interface is a thin wrapper.** `feed_with` /
  `feed_bytes_with` iterate `drain_deltas`, and the callback runs inside `feed`, so
  a callback must not feed the same parser again. It is not a separate push
  interface.
- **Only `...` in a value position is dropped.** `R020` handles `[1,...,3]` and
  `{"a":1,...}`; an ellipsis anywhere else is not treated as a placeholder.
- **A truncated literal prefix is completed regardless of the following
  character.** A bare `tru` followed by an unexpected character is completed to
  `true` and the unexpected character is handled separately.
- **`incomplete_number` and `pending_key` only affect snapshots.** They do not
  change `finish`: the final result trims the number (`R011`) and fills a dangling
  key with `null` (`R008`) under their own rules.
- **Lone surrogates differ by backend.** On the wasm backend, `\uD800`-style lone
  surrogates survive in the output; on the other backends the `InvalidUtf8`
  (`E040`) path substitutes U+FFFD.
- **The `interjson/llm` and delta sub-packages are experimental.** Their APIs may
  change in a minor release; the core `repair` / `parse` / `PartialParser` surface
  is the stable one.
- **The CLI is native-only**, and **parser instances are not thread-safe**: use one
  instance per input stream.
- **Recovery guarantees are heuristic, not a conformance claim.** InterJSON is not
  a JSON standard, and it does not guarantee a particular interpretation for every
  malformed input; the differential report is the evidence for the behaviour it
  does document.
- **`Json` numbers follow the core representation.** Very large integers may lose
  precision in the tree, although the repaired text keeps the number's original
  digits.
- **`quote_lookahead` is off by default.** When enabled, a sequence of strings that
  is missing commas is biased toward being read as string content.
- **Repair records are capped by `max_repairs` (default 10000).** Further repairs
  are applied but not recorded, and the result sets `repairs_truncated`.
- **Incremental deltas are correct but not cheap.** Each change allocates one
  `Delta` plus a path array, so a 1 MB document produces ~195 000 records and takes
  1.40–1.46 × the baseline. In the agent scenario (4 KB, 3-code-unit chunks) the
  whole stream is 0.115 ms, so the overhead is not on the critical path.
- **`--skip-prose` recovers a bare scalar root, not prose followed by one.**
  `'ok'`, `True`, `+1`, `42 // done` and a fenced `42` are recovered; prose followed
  by a scalar (`Sure!\n42`) still raises `E002`, and so does a scalar with a tail
  (`42 is the answer`).
- **Memory depends on the shape, and value-dense containers are the worst case.**
  On the benchmark document (a 12.95 MB array of 12-member objects) `repair()`
  peaks at 13.2 × and `--check` at 7.5 ×; the same number of bytes as one long
  text peaks at 3.6 ×. On a *value-dense* document — 200 000 one-key objects,
  which is 7 bytes per value — the ratio is 24 ×, because the cost is per value
  and not per byte: `{}` is a `Map` allocation and `[1]` is an `Array` plus a
  boxed `Json`. Reaching 4 × for those needs a mode that does not build the
  value at all; there is not one, and the design is in
  [`docs/NOTREE.md`](docs/NOTREE.md). The ratios are measured and gated by
  `tests/memory_gate.py`.
- **The per-feed p99 is only an upper bound.** The runtime clock is
  millisecond-resolution and exposes no allocation counter.
- **The readiness curve covers top-level members only.** A nested member is ready
  only when its container closes; the curve costs ~1.8 ms/KiB.
- **The `max_depth` ceiling is a hard upper bound, not a policy choice.** It is
  documented in [`SECURITY.md`](SECURITY.md): three recursive walks and the engine's
  frame stack are bounded by it, and the wasm backend's stack overflows in a
  recursive walk between 896 and 1024 frames. Declarations have a tighter,
  separate bound, refused with `E070`.
- **The refusal contract changed in 1.5.0** (and is unchanged in 1.5.1). In 1.4.x a plan that was *accepted*
  but not executable serialised as `"retry": null` while still carrying a live
  `value`. Now `executable == false` implies `value: null`, `text: ""` and a
  non-empty `retry.prompt`, under every profile. A 1.4.x caller that branched on
  `retry == null` must branch on `executable` instead.
- **`json_equal` compared numbers as `Double` in 1.4.x**, so adjacent integers past
  2^53 were treated as the same value and a duplicate-key merge that silently
  changed one was recorded as harmless (`Info`). It now compares exact decimal
  values: that case is `Warning` and refused.
- **The rule table was one slot short in 1.4.x.** `R022 NormalizeLiteral` fell
  outside a literal-22 table, so `disable(R022)` was a silent no-op. The table is
  now sized from `RepairCode::count()` and out-of-range is fail-closed.
- **MCP is advisory.** The protocol gives the host no way to require the gate; a
  `PreToolUse` hook or a host-SDK `gate()` is what makes it mandatory — see
  [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Contributing

- `CONTRIBUTING.md` covers the development environment, how to run the tests,
  commit conventions, and how to add a repair rule — a rule change must update the
  rule and error tables above and the golden tests together; the internal
  requirement matrix is maintained with the code but is not published.
- Issue templates cover defects (input, options, expected versus actual output, and
  backend) and new-rule proposals.
- `SECURITY.md` describes how to report a problem: this library processes untrusted
  input.

## License and acknowledgements

InterJSON is released under the Apache License 2.0 (`license = "Apache-2.0"` in
`code/moon.mod`).

- [jsonrepair](https://github.com/josdejong/jsonrepair) (TypeScript) and
  [json-repair](https://github.com/mangiucugna/json_repair) (Python) are used as
  behavioural oracles in the differential report. They are used only for
  comparison; no code from either project is vendored.
- The MoonBit core library (`moonbitlang/core/json`, `moonbitlang/core/string`)
  provides the `Json` type and string handling.
