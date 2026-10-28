# InterJSON

**The execution gate for LLM output — a local MCP server, one native binary.**

InterJSON answers the only question between a model's tool call and the code
that would run it: *may I execute this?* `interjson mcp` serves that decision
over stdio as a Model Context Protocol server — no socket, no network, no API
key, no model output leaving the machine. The engine underneath is pure MoonBit
with wasm-gc, native, JS and wasm backends, and the same engine answers the same
question for host-side callers (`serve`, npm, pip, HTTP).

| | |
| --- | --- |
| Module | `zhanshishan/interjson` |
| Version | 1.5.0 |
| License | Apache-2.0 |
| MCP server | `interjson mcp`, also `interjson-mcp`; JSON-RPC 2.0 over stdio, protocol `2025-06-18` (`2025-03-26` and `2024-11-05` accepted) |
| Backends | wasm-gc, native, JS, wasm — one test suite, all four |
| Prebuilt binaries | The GitHub release — Linux x86_64, macOS arm64 and Windows x86_64 `interjson` CLIs, wasm probe, browser bundle, `SHA256SUMS`, plus the `interjson-install.sh` one-command installer. Older releases were published under the former name and keep the old asset prefix |
| Registry | [`mooncakes.io zhanshishan/interjson`](https://mooncakes.io/docs/zhanshishan/interjson) — 0.12.0 is the 1.5.0 correspondence and is **not published yet**; 0.11.0 (the 1.4.0 correspondence) is published; older releases are under the former name `zhanshishan/jsonmend` |
| Deployment guide | [`docs/MCP.md`](docs/MCP.md) for the MCP server; [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) for host-side recipes |

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
(`Here are the args:\n{"a":1}`) is skipped, not refused. Every tool is
annotated read-only, idempotent, non-destructive and closed-world; the server
never executes the JSON it inspects.

**The refusal contract:** a result with `executable == false` always carries a
non-empty `retry.prompt` and `value: null`; an executable result always
carries a live `value` and `retry: null`. `content[0].text` is a summary the
model can act on; `structuredContent` is the payload, once.

**MCP is advisory.** `interjson_gate` is a tool the model *may* call, and
nothing in MCP makes the host check the answer — a model can decline to call
it. What makes the gate mandatory is a host-side insertion point: a Claude Code
`PreToolUse` hook, a `gate(args)` call in the host SDK, or `interjson serve` /
npm / pip / HTTP. Recipes:
[`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md#making-the-gate-mandatory).

### 60-second setup

Install the binary — `moon build cmd/interjson --target native --release` gives
you the `interjson` CLI; older release assets are the same engine
under the old name — then:

```sh
claude mcp add interjson -- interjson mcp
```

For any other client, ask the binary for the snippet it needs:

```sh
interjson mcp --print-config=cursor    # mcpServers JSON (Cursor, Cline, Windsurf)
interjson mcp --print-config=vscode    # servers JSON
interjson mcp --print-config=codex     # TOML
interjson mcp --print-config=zed       # context_servers JSON
interjson mcp --print-config=claude    # Claude Code command
```

For example, Cursor/Cline/Windsurf read:

```json
{
  "mcpServers": {
    "interjson": { "command": "interjson", "args": ["mcp"] }
  }
}
```

### The loop

```text
model   : {"query":"weather in Par          <- truncated at max_tokens
gate    : executable false, E010, retry.prompt
model   : {"query":"weather in Paris","limit":3}
gate    : executable true, decision safe, value
execute : the value, not the string
```

The full session — a real truncated call, the returned prompt, the corrected
call, per-client configuration, the security model and troubleshooting — is in
[`docs/MCP.md`](docs/MCP.md). The deployment rule is one sentence: execute only
when `executable` is true, otherwise send `retry.prompt` back and use the
re-emitted arguments.

The interactive demo is
<https://wenhuang2333.github.io/Moonbit-haker/mcp.html>: a recorded Claude Code
session where a truncated tool call is refused with `E010`, the model re-emits,
and the second call passes the gate. The browser page replays the same four
tools; the decision in it is the real engine's.

## Features

### One call: "may I execute this"

- **`SafetyPolicy`**: five named profiles — `permissive`, `interactive`, `execution`, `agent`,
  `strict` — over the safety-relevant `Options`. `Options::with_policy` replaces only the safety
  knobs and keeps the protocol ones (delta stream, prose handling), and
  `SafetyPolicy::of_options` reads a set of options back to the profile it is (or `None`).
- **`analyze` returns the whole plan**:

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

  `analyze` never raises — a refusal is part of the return value — and costs 1.00–1.03× a plain
  `repair` call.
- **`Schema` + `semantic_readiness`**: declare `{!query:string,!limit:integer}` and get two
  fractions for the same stream — syntax ready and schema ready — plus the members that are
  missing or of the wrong kind.
- **Self-healing loop example**: `code/examples/agent_loop` feeds `plan.prompt()` back to a
  scripted "model" and retries; four episodes cover `E011` ambiguity, `E010` truncation,
  `E070` skeleton mismatch, and giving up when a retry makes no progress.
- **Live demo**: `static/demo/live.html` replays four real scenarios frame by frame
  (truncated → retry → executed; ambiguous → retry → executed; single reading → executed;
  long tail → ready at 19%).

### Everything else

- **One-shot repair** with `repair`: repaired text, a list of repair records, and the completeness of the input.
- **One-shot parsing** with `parse`: the repaired input as a `Json` tree plus the same records.
- **Streaming partial parsing** with `PartialParser`: `feed` (or `feed_bytes`) any number of chunks, take `snapshot()` at any time, then `finish()`.
- **Repair records** for every change: stable code (`R001`…`R022`), position (UTF-16 offset plus 1-based line/column), severity, and a fixed English message.
- **Exactness labels**: every result carries `Exact` / `Cosmetic` / `Lossy`, derived from the severities of the records. `Options::max_loss` turns the first repair that exceeds the budget into a fatal `E010`, so "repair, then execute the arguments" cannot happen silently.
- **Ambiguity gate**: a repair that admits a second, equally self-consistent reading (`["a" "b"]`, `["a"+"b"]`, `[fast]`, `{"a":1} {"b":2}`) is recorded with an `Ambiguity` class and refused with `E011` under `Options::reject_ambiguous` / `Options::for_execution()`, before the exactness gate. 10/10 adversarial cases are flagged and refused, while both reference libraries answer all 10 with a silent value (`docs/EVAL_AMBIGUITY.md`).
- **Reject as feedback**: `InterJSONError::retry_hint` (and `--retry-hint`) turns a refusal into a prompt fragment — error code, repair code, position, the second reading, a bounded context window with a caret — that can be fed straight back to the model that produced the input.
- **Field readiness (FR-29)**: `field_readiness` reports, for every top-level member, the input fraction at which its value is already final, and `FieldTracker` does the same from the delta stream, so a caller can stop the generation as soon as the fields it needs are settled. The decile curve replaces the "95% coverage" figure that an object made structurally uninformative.
- **Incremental deltas**: with `Options::collect_deltas`, `drain_deltas()` returns `Set` / `AppendText` / `Close` operations with RFC 6901 JSON Pointer paths, so a consumer can patch its own view instead of re-reading snapshots.
- **LLM provider adapters** in the `interjson/llm` sub-package (*experimental*): Anthropic fine-grained tool streaming and OpenAI-compatible tool-call deltas, an SSE framer, and a text stream that reads the JSON out of `delta.text` / `delta.content`. The end of a call is reported as `Complete`, `MaxTokens`, `Interrupted` or `ProviderError` with the provider's own `stop_reason` verbatim; `ping` and unknown event types are counted and ignored. `interjson llm` on the command line.
- **Strict mode** (`Mode::Strict`) turns the first repair into a fatal `E010`, and per-rule switches disable individual rules the same way.
- **Resource limits**: nesting depth, total input length, and single-token length (`E020`/`E021`/`E022`).
- **Policies** for duplicate keys, non-finite numbers, multiple root values, Markdown fences, leading prose, ambiguous quotes, and output indentation.
- **Multi-backend**: the library is pure MoonBit with no regex and no recursion; the same engine compiles to wasm-gc, native, JS and wasm, and `bench` runs on `native` and `js`.
- **CLI and browser demo**: `cmd/interjson` for the command line, `examples/web` for the browser.

## Why you need it

LLM applications stream JSON token by token, and the stream is routinely cut off mid-value, wrapped in a Markdown fence, written with single quotes, or padded with prose and comments. A strict parser rejects the whole payload, so the application shows nothing until the end — and sometimes never. InterJSON keeps the last confirmed prefix available after every chunk and repairs the flaws along the way, so a partial result is usable immediately and the final result is valid JSON. The same engine drives both the one-shot and the streaming paths, so they cannot drift apart.

Repairing is necessary but not sufficient once the result is about to be executed. A repair can be cosmetic, can invent or drop a value, or can admit a second reading; a truncated `{"query":"weather in Par` becomes a string the model never finished. InterJSON labels every repair Exact / Cosmetic / Lossy, detects ambiguity, checks the declared schema, and refuses with `E010` / `E011` instead of guessing. The refusal is a ready-to-send prompt. That is the gate, and it is the same decision whether it arrives through MCP, `serve`, npm, pip or the CLI.

## Install

### The MCP server

Build the binary (older release assets predate the InterJSON name; the
engine is the same):

```sh
cd code
moon build cmd/interjson --target native --release
./_build/native/release/build/cmd/interjson/interjson.exe mcp --print-config=claude
```

Nothing else is required: the server is a single native binary and needs no
runtime, no API key and no network. Install paths for pip (`interjson-mcp`),
npm (`interjson-mcp`, which still needs the native binary) and per-client
configuration are in [`docs/MCP.md`](docs/MCP.md).

### The MoonBit library

Add the dependency with the MoonBit toolchain:

```sh
moon add zhanshishan/interjson
```

Then import the package in your `moon.pkg` with the alias used throughout this document:

```
import {
  "zhanshishan/interjson" @interjson,
}
```

`moon add` records the dependency in the module manifest (this repository uses `code/moon.mod`). The exact registry syntax and the current toolchain command follow the mooncakes.io instructions; verify them against the released package page.

## Integration surfaces

The library is the engine; the delivery surfaces wrap it without changing the semantics:

| Surface | Use |
| --- | --- |
| `moon add zhanshishan/interjson` | MoonBit projects (this package) |
| `interjson mcp` (alias `interjson-mcp`) | Claude Code, Cursor, Cline, Windsurf, VS Code, Codex CLI, Zed: four read-only tools over stdio |
| `interjson serve` | any language; versioned JSONL host-side protocol (`docs/PROTOCOL.md`) |
| `npm install ./code/npm` | Node and browser hosts (`interjson-moonbit`; its `interjson-mcp` bin starts the server) |
| `pip install ./code/python` | Python hosts (`interjson-moonbit`; console scripts `interjson-mcp` and `interjson-http`) |
| `interjson-http` (Python package) | n8n, Dify, Coze, gateways |

The execution gate is the same call everywhere: `analyze(text, profile="agent",
schema_json=tool.inputSchema)` returns `executable`; when it is false,
`retry.prompt` is the text to send back to the model. Over MCP the tool is
`interjson_gate` and the profile defaults to `agent`. Deployment is in
[`docs/MCP.md`](docs/MCP.md); host-side recipes for each surface are in
[`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Quick start

`repair` raises `InterJSONError`, so wrap the calls in `try`/`catch` (the three statements below are the whole example):

```moonbit
try {
  let result = @interjson.repair("{'a': 1,}")   // RepairResult
  println(result.text)                         // {"a":1}
  println(result.repairs.length())             // number of repair records
} catch {
  e => println(e.to_string())
}
```

Use `@interjson.parse` instead when you want the `Json` tree rather than the text; it returns the same `repairs` and `completeness` alongside a `value`. `repair` returns a `RepairResult` with the fields `text`, `repairs`, and `completeness`.

## Streaming example

`PartialParser` accepts any number of chunks. A chunk may split any token, including an escape sequence or a surrogate pair.

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

`feed_bytes` takes raw UTF-8 and can be mixed with `feed`; invalid or truncated UTF-8 raises `E040`. Options are passed by keyword:

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

`snapshot()` returns a `Snapshot` whose fields are `value` (`Json?`), `completeness`, and `open_path`; `finish()` returns a `FinalResult` with `text`, `value`, `repairs`, and `completeness`. `snapshot()` never raises and never mutates the parser; `finish()` may be called once and raises `E030` on a second call or after a fatal error.

## End-to-end example: refuse, feed back, then execute

`examples/agent_gate/` is a runnable program (`moon run examples/agent_gate --target native --release`)
that walks the whole loop for a tool call whose arguments admit two readings:

```text
== first attempt
model   : {"city":["Paris" "London"]}
gate    : E011 adjacent_strings - the gate cannot pick a reading
refused : the gate refused to pick a reading
prompt  :
  InterJSON refused the arguments: E011 R006 InsertComma at line 1 column 18 (offset 17).
  Reason: two adjacent strings may be two elements or one concatenated string
  Ambiguity: adjacent_strings
  Re-emit the arguments as valid JSON with exactly one reading.

== re-emitted
model   : {"city":["Paris","London"]}
execute : {"city":["Paris","London"]}
```

`Options::for_execution()` checks ambiguity before exactness: repairs such as
`["Paris" "London"]` and `"Par" + "is"` keep the value the same but admit two readings,
so only the ambiguity gate stops them, while a truncation such as `"Par` is `E010`.
Either refusal turns into a prompt the model can be given again (`RetryHint::to_prompt()`).
Without the gate the same input still repairs, with `ambiguous` set to `true` — the gate
is opt-in.

## Options

Every field of `Options`. `@interjson.Options::default()` is the documented default set.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `mode` | `Mode` | `Lenient` | `Lenient` records repairs; `Strict` raises `E010` at the first one. |
| `max_depth` | `Int32` | `512` | Maximum container nesting; exceeding it raises `E020`. The ceiling is `MAX_VALUE_DEPTH = 512`, which is also the default, so a caller can tighten it but not loosen it: a larger value is refused with `E050` (see [Known limitations](#known-limitations)). |
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
| `rules` | `RuleSet` | `RuleSet::all()` | Per-rule switches; disabling a rule makes that code raise `E010`. |
| `indent` | `Int32` | `0` | Output indentation in spaces; `0` renders compact JSON. |
| `max_repairs` | `Int32` | `10000` | Maximum number of repair records kept; beyond it repairs still apply but the result sets `repairs_truncated`. |
| `reject_ambiguous` | `Bool` | `false` | Refuse a repair that admits a second reading (`E011`) instead of applying it. `Options::for_execution()` sets it. |
| `max_loss` | `Exactness` | `Lossy` | Highest acceptable exactness. The first record that exceeds it raises `E010` with that code and position. `Options::for_execution()` sets `Cosmetic`. |
| `collect_deltas` | `Bool` | `false` | Collect incremental deltas; read them with `PartialParser::drain_deltas()`. Cannot be combined with `duplicate_keys: KeepFirst` or `incomplete_number: TrimToValid`. |

Invalid values (`max_depth <= 0` or `> MAX_VALUE_DEPTH`, `max_input_len <= 0`, `max_token_len <= 0`, `max_repairs <= 0`, `indent < 0`) raise `E050` from `Options::validate`, which `repair`, `parse`, and `PartialParser::new` call for you. A declaration (JSON Schema or the skeleton language) deeper than `MAX_SCHEMA_DEPTH = 256` raises `E070`.

## Repair rules overview

Every change is one record whose code is stable. The full dictionary, with examples and the requirement each rule implements, is in `docs/RULES.md`.

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

Two signal families are kept apart: repair records are informational and travel with the result; fatal errors abort processing and are raised as `InterJSONError`.

A `Repair` carries `code : RepairCode`, `position : Position`, `severity : Severity`, and `message : String`. `repair`, `parse`, and `finish` also return `repairs_truncated : Bool`, which is `true` when the record array hit `max_repairs`. `Position.offset` counts UTF-16 code units from 0, while `line` and `column` are 1-based. `Severity::Info` means the value is unchanged and only the notation was normalized; `Severity::Warning` means content may have been invented, dropped, or altered. Messages are fixed templates and never embed user input.

| Code | Error | Raised when |
| --- | --- | --- |
| `E001` | `EmptyInput` | The input is empty or whitespace only. |
| `E002` | `NoJsonFound` | No JSON value can be found (payload is the offset). |
| `E010` | `StrictViolation` | Strict mode, or a disabled rule, rejects a repair (payload is the code, position, and message). |
| `E020` | `DepthLimit` | Nesting exceeds `max_depth`. The bound exists because three recursive walks (`copy_json`, `json_equal`, `walk_schema`) and the engine's frame stack are bounded by `MAX_VALUE_DEPTH = 512`; the wasm backend's stack overflows in a recursive walk between 896 and 1024 frames. |
| `E021` | `SizeLimit` | Input exceeds `max_input_len`. |
| `E022` | `TokenLimit` | A token exceeds `max_token_len`. |
| `E030` | `InvalidState` | `feed` after `finish`, or `finish` called twice or after a fatal error. |
| `E040` | `InvalidUtf8` | Invalid or truncated UTF-8 in `feed_bytes` (payload is the byte offset). |
| `E050` | `InvalidOption` | An option value is out of range, or a combination is invalid (`collect_deltas` with `KeepFirst`/`TrimToValid`). |
| `E060` | `InvalidEvent` | `interjson/llm` received an event payload it cannot interpret. |

`RepairCode::code`, `InterJSONError::code`, and `InterJSONError::to_string` produce the stable strings (`R005`, `E020`, and a one-line diagnostic respectively). The full reference is in `docs/ERRORS.md`.

## Snapshot semantics

`snapshot()` returns a non-destructive view of the value parsed so far, without raising and without changing parser state:

- **Stable prefix.** Values that are already closed — complete strings, numbers, literals, and containers — never change in later snapshots. Only the last unfinished element can change.
- **Monotonicity.** The snapshot sequence grows monotonically. Choosing `TrimToValid` deliberately breaks monotonicity for unfinished numbers (a snapshot showing `12` can later become `123`); this is documented behaviour, not a bug.
- **Unfinished number.** With the default `incomplete_number = Drop`, an unfinished number is not shown at all. With `TrimToValid`, the longest valid prefix is shown, or nothing if there is no valid prefix.
- **Unfinished key.** A key whose closing quote has not arrived never appears. A dangling key (key plus colon, no value) is omitted with the default `pending_key = OmitKey`, or shown as `"key": null` with `NullKey`.
- **Unfinished string.** The received prefix appears; an incomplete escape sequence is held back until it is complete.
- **Literal prefix.** A partial literal such as `tr` is not shown in a snapshot; it is completed at `finish`.
- **Open containers.** An open array or object appears with the content confirmed so far, and `completeness` is `Partial`.
- **`open_path`** locates the value currently being built as `Array[PathSegment]`, where a segment is `Key(String)` or `Index(Int32)`. Synthetic frames, such as the array wrapper added by `multi_root = AsArray`, are skipped.

A snapshot differs from the final result by design: the preview omits what is not yet decided, while `finish` closes containers (`R009`), closes strings (`R010`), trims numbers (`R011`), completes literals (`R012`), and fills a dangling key with `null` (`R008`). A value omitted from a preview can therefore appear in the finished result.

## Command line and demo

Build and run the CLI:

```sh
moon build cmd/interjson --target native --release
echo "{'a': 1,}" | ./_build/native/release/build/cmd/interjson/interjson.exe
```

The CLI has six subcommands; the default action, with no subcommand, is
`repair`. `interjson --help` prints the full help, which is in Chinese; the
table below is the English reference.

| Command | Use |
| --- | --- |
| `interjson [file]` | Read a file or stdin, write the repaired JSON to stdout (the default action). |
| `interjson repair [file]` | The default action, spelled out: the document and nothing else. |
| `interjson explain [file]` | Full analysis: what was repaired, why, how risky, and whether it may execute; on a refusal, the retry hint. Exit code 0 when executable, 5 when refused. |
| `interjson readiness [file]` | Field-readiness curve: when each top-level field becomes final. |
| `interjson llm [file]` | Feed a provider event stream through the adapter; one result JSON per tool call. |
| `interjson serve` | Long-lived stdio protocol (`docs/PROTOCOL.md`): one request JSON per line, one response JSON per line. |
| `interjson mcp` | MCP stdio server (JSON-RPC 2.0) exposing `interjson_gate`, `interjson_repair`, `interjson_validate`, `interjson_readiness`; `--print-config[=CLIENT]` prints a client configuration and exits. |

Flags and their meanings:

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
| `--max-depth N` | Maximum container nesting (default 512; `E020`). Above `MAX_VALUE_DEPTH = 512` the option itself is refused with `E050` — the ceiling is the default, so the flag can only tighten. |
| `--max-token-len N` | Maximum length of one token (default 16777216; `E022`). |
| `--max-prose-buffer N` | With `--skip-prose`, how many code units of prelude may be buffered for the end replay (default 65536). |
| `--chunk N` | Feed the input in N-code-unit chunks (≤1048576) to exercise the streaming path. |
| `--batch` | Read `{"id","input"}` objects line by line and write one result object per line. |
| `llm` (subcommand) | Feed a provider event stream through the adapter: `interjson llm [--provider anthropic\|openai] [--sse] [--follow] [file]`. |
| `serve` (subcommand) | The versioned JSONL protocol; `--stdio` is accepted and selects nothing, because stdio is the only transport. |
| `mcp` (subcommand) | The MCP server. `interjson mcp --help` documents it; `--print-config[=CLIENT]` prints a client configuration (`claude`, `cursor`, `vscode`, `codex`, `windsurf`, `zed`, `json`). |
| `-h`, `--help` | Show help. |
| `--version` | Show the version (`interjson 1.5.0`). |
| file, or `-` | Read a file; `-` or an omitted argument reads standard input. |

`--indent=N`, `--multi-root=MODE`, and `--max-repairs=N` are accepted as equivalent to the space-separated forms.

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Success; the output may still contain repairs. |
| `1` | `--check` found that repairs are needed. |
| `2` | Usage error (unknown flag, bad option value, or `E050`). |
| `3` | Invalid input (`E001`/`E002`/`E040`/`E060`, or an unreadable file). |
| `4` | Resource limit reached (`E020`/`E021`/`E022`). |
| `5` | Strict-mode violation (`E010`, including a `--max-loss` breach). |
| `70` | Internal error (`E030`). |

The browser demo lives in `examples/web`; the built page is `static/demo/index.html` and can be opened directly from disk. The demo's MoonBit entry points are plain `String`-in/`String`-out functions (`repair_text`, `report_text`, `snapshot_text`, `analyze_text`, `readiness_text`, `deltas_text`, …) registered on the host page through `globalThis.interjsonRegister*`, so the page contains no second implementation. The same bundle backs `static/demo/interjson.js` and the npm package. Rebuild the bundle with `bash static/demo/build.sh`; the steps and the headless check are in `docs/REPRODUCE.md`.

## Testing

```bash
cd code
moon test                      # default backend (wasm-gc)
moon test --target native      # host backend
moon test --target js          # JavaScript backend
moon test --target wasm        # wasm backend
bash tests/cli_smoke.sh        # 120 command line assertions, including the MCP checks
bash tests/examples.sh         # example inputs vs code/examples/cases/*.expected
node ../code/tests/demo_smoke.mjs   # the committed browser bundle still answers
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/run_eval.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/run_eval_paths.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/check_amb_guard.py    # the adversarial suite's guard still fires
python3 tests/eval/run_ambiguity.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/refcompare.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/gen_llm_fixtures.py --check
python3 tests/memory_baseline.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
python3 tests/eval/run_independent.py    # vendored nst/JSONTestSuite, independent of our own corpus
python3 tests/eval/run_readiness.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe --check
python3 tests/conformance/run_conformance.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe   # 19 groups, including mcp
moon run examples/agent_loop --target native --release
```

| Suite | Size | Result (1.5.0) |
| --- | --- | --- |
| Golden cases (spec appendices A and B) | 126 | pass |
| Documented streaming cases (S-001…S-021) + chunk invariance | 21 + invariance checks | pass |
| Property and fuzz tests (TC-P-01…TC-P-06) | 8 groups × 400 cases (`INTERJSON_LONGRUN` raises it; nightly runs 1 000 000) | pass, no counterexample |
| Exactness labels | hand-written table + 240 property cases + the `max_loss` gate | pass |
| Incremental deltas (replay == snapshot) | 400 generated + 400 mutated documents | pass |
| LLM adapters (both providers, 9 generated fixtures + documented event shapes) | 30 tests | pass |
| Adapter path against the ground-truth corpus | 1200 cases × (both providers × tool args and text) | **1200/1200 on all four** ([docs/EVAL_PATHS.md](docs/EVAL_PATHS.md)) |
| Adversarial ambiguity suite `amb-1` | 24 handwritten cases, frozen fingerprint | 10/10 flagged and refused, 14/14 controls pass, 0 failures ([docs/EVAL_AMBIGUITY.md](docs/EVAL_AMBIGUITY.md)) |
| Reference libraries on the same corpus | 1200 cases × (`jsonrepair` 3.15.0, `json_repair` 0.64.0) | InterJSON silent wrong values 0, `jsonrepair` 122, `json_repair` 189 ([docs/EVAL_REFERENCE.md](docs/EVAL_REFERENCE.md)) |
| Chunked paths against the ground-truth corpus | 1200 cases × chunk 1/3/7/random | 1200/1200 each, 0 regressions |
| Safety profiles, repair plans, schemas | 34 tests (7 + 22 + 5) | pass |
| Independent third-party corpus (`nst/JSONTestSuite`) | 318 files (95 `y_` / 188 `n_` / 35 `i_`) | `y_` false repairs 2/95 (both duplicate keys), `n_` valid values 165/188 vs `json_repair` 166/188 and `jsonrepair` 144/188 ([docs/EVAL_INDEPENDENT.md](docs/EVAL_INDEPENDENT.md)) |
| Schema readiness table | 10 scenarios | 6 with a gap (713‰–908‰), 4 where both fractions arrive at the end ([docs/READINESS.md](docs/READINESS.md)) |
| Public surface (every `R` code and `E` code) | 22 + 12 codes checked field by field | pass |
| Ground-truth evaluation (protocol frozen first) | 1200 cases (19 mutation families + 1 control × 60) | recovery **100.00%**, 0 mislabelled, 4/4 pre-registered criteria PASS |
| Command line smoke (exit codes 0/1/2/3/4/5/70) | 120 assertions, including the `explain` surface and the MCP config/initialize checks | pass |
| Differential corpus against `jsonrepair` / `json-repair` | 402 cases | 202 divergences, all documented, 0 unexplained |
| Line coverage of the library | 3851/4115 lines (root), 337/391 (`llm`) | 93.6% / 86.2% (`moon coverage` cannot instrument the `cmd` package, which calls `quit()`; within the root package the weakest file is `llm/text.mbt` at 72.5% across the library and `hint.mbt` at 90.7% inside the root package) |

Cross-backend results are identical: 243/243 tests pass on each of wasm-gc,
native, JS and wasm (868 runs). `.github/workflows/ci.yml` runs the same commands on every push, so
the numbers above are re-derived rather than trusted. Reproduction steps,
thresholds and the known shortfalls are in
`docs/REPRODUCE.md` and `docs/TRACEABILITY.md`.
The evaluation protocol and its revision history are in
[docs/EVAL_REGISTRATION.md](docs/EVAL_REGISTRATION.md) and
[docs/EVAL.md](docs/EVAL.md); how AI tooling was used is in
`docs/AI_USAGE.md`.

## Differences from jsonrepair

InterJSON is not a port of `jsonrepair` and does not aim for byte-identical output. Several differences are deliberate, documented policy choices: trailing content after the root value keeps the first value by default instead of merging it, Markdown fences are stripped by default, duplicate keys keep the last value, unfinished numbers are dropped from snapshots, and strict mode plus per-rule switches have no direct equivalent. The 0.3.0 changes did not move the report by a single byte: exactness labels and rule renumbering do not change any value. A differential harness runs `jsonrepair` (TypeScript/Node) and `json-repair` (Python) over a corpus of hand-written and mutated inputs, compares parsed values, and classifies every divergence. In the committed 0.3.0 report, all 202 divergences had a documented cause and none was unexplained. The method, the classification, and the reference-library versions are in [docs/DIVERGENCES.md](docs/DIVERGENCES.md); rule-to-requirement mapping is in `docs/TRACEABILITY.md`.

## Performance

![Field readiness curve](../static/readiness-curve.svg)

The figure is produced by `code/tests/readiness_figure.py` from the real output of
`interjson readiness`: the left panel is a tool-call document (`name` 198,
`arguments` 858, `id` 990, median 858/1000) and the right panel is the decile
curve of a flat 200-member record (`0 10 21 31 41 51 61 71 80 90 100`). The
dashed line is the ideal baseline — a field final when its own share of the input
has been read. This replaces the previous "95% coverage" figure, which an object
made structurally uninformative (it sat at 95.3% regardless of quality). The
limitation is on the figure too: the metric covers **top-level** members only, so
`arguments` cannot settle before its container closes, which is the only reason
the left panel leaves the diagonal.

`bench/main.mbt` measures one-shot repair throughput over valid, flawed, deeply nested, and long-string corpora, plus parse-only cost, scaling at n/2n/4n, and streaming overhead as a function of chunk size and snapshot frequency:

```sh
moon run bench --target native --release
moon run bench --target js --release
moon run bench --target native --release -- longtext   # the long-text arms only
```

On a 2026 Apple-silicon laptop, native measured 38–40 MB/s (valid), 74–80 MB/s
(flawed) and 832 MB/s (one long string); js measured 19–33 MB/s. The same run
also measures two things that matter for streaming: the **first visible value**
appears at 0.7% of the document (median over tool-call payloads), and enabling
`collect_deltas` costs 1.40–1.46 × the baseline time on a 1 MB document — that number is a
**known shortfall**, not a win. The 1.1.x CLI batches plain ASCII string runs in
`feed_bytes` and skips rendering for `--check`: a 10 MB single string drops from
398.6 MB / 38.0 × to 99.0 MB / 9.4 ×, and a 13 MB object array `--check` from
219.5 MB / 16.9 × to 146.2 MB / 11.3 ×. `repair()` still renders the output and
remains at 13.7 ×.

**Long text** — the shape where one string token *is* the document, which is what
a model writes when it emits a file, a markdown answer or a translation — has its
own arms (`longtext`: a 4 Mi code unit plain-ASCII string, the same length filled with
CJK text, and an escape-dense markdown-shaped string, each through both entry
points). They exist because the byte entry point used to batch only ASCII: every
non-ASCII byte fell through to `push_char`, which allocated one `String` per
character. That cost 5.4 × (native) / 7.1 × (JS) per code unit and grew with the
text, while the parsed result was already correct — no functional test could see
it. Since 1.3.0 the engine batches complete multi-byte UTF-8 sequences in the same run batching the
ASCII path uses, so a CJK long string now costs the same per *byte* as ASCII
(662 MB/s vs 599 MB/s; 209.7-220.8 Mu/s vs 38.5-39.6 before). The 25.17 MB single-CJK-string
file measures 0.04 s and 53.7 MB peak RSS with `--check` (2.2 × input, down from
228.0 MB / 9.5 ×). Two floors remain, both documented rather than hidden: an
escape-dense string is 311.6 Mu/s because every `\n` ends a run, and feeding one
byte at a time defeats the batching entirely (0.43 s instead of 0.04 s) — real
provider events are tens to thousands of bytes, so the second floor is only
reachable from the CLI's `--chunk 1`.

These figures are observations, not a guarantee: throughput depends on the input
shape, chunk size, snapshot frequency, and the toolchain version. Memory
(13.7 × input; Node is 10.6 × and Python 14.3 × on the same file, so the 4 × budget itself is unrealistic) and artifact size are measured
separately from the process. The full method, tables and decision records are in
`docs/BENCHMARK.md`, and
`docs/REPRODUCE.md` explains how to rerun the benchmarks.

## Known limitations

- **The `FR-16` event interface is a thin wrapper.** `feed_with` / `feed_bytes_with` iterate `drain_deltas`, and the callback runs inside `feed`, so a callback must not feed the same parser again. It is not a separate push interface (the reasoning is in `docs/ONEPAGE.md`).
- **Only `...` in a value position is dropped.** `R020` handles `[1,...,3]` and `{"a":1,...}`; an ellipsis anywhere else is not treated as a placeholder.
- **A truncated literal prefix is completed regardless of the following character.** For example, a bare `tru` followed by an unexpected character is completed to `true` and the unexpected character is handled separately.
- **`incomplete_number` and `pending_key` only affect snapshots.** They do not change `finish`: the final result trims the number (`R011`) and fills a dangling key with `null` (`R008`) under their own rules.
- **Lone surrogates differ by backend.** On the wasm backend, `\uD800`-style lone surrogates survive in the output; on the other backends the `InvalidUtf8` (`E040`) path substitutes U+FFFD.
- **The `interjson/llm` and delta sub-packages are experimental.** Their APIs may change in a minor release; the core `repair` / `parse` / `PartialParser` surface is the stable one.
- **The CLI is native-only.** `cmd/interjson/moon.pkg` declares `supported_targets = "native"`.
- **Recovery guarantees are heuristic, not a conformance claim.** InterJSON is not a JSON standard, and it does not guarantee a particular interpretation for every malformed input; the differential report is the evidence for the behaviour it does document.
- **`Json` numbers follow the core representation.** Very large integers may lose precision in the tree, although the repaired text keeps the number's original digits.
- **`quote_lookahead` is off by default.** When enabled, a sequence of strings that is missing commas is biased toward being read as string content.
- **Repair records are capped by `max_repairs` (default 10000).** Further repairs are applied but not recorded, and the result sets `repairs_truncated`; the CLI prints a note to standard error.
- **Incremental deltas are correct but not cheap.** Each change allocates one `Delta` plus a path array, so a 1 MB document produces ~195 000 records and takes 1.40–1.46 × the baseline. The text tail now uses a cursor, so draining a long string in small chunks no longer rescans the prefix (1 MiB / 64-code-unit chunks: 374 ms → 201 ms); the per-delta allocation is unchanged. In the agent scenario (4 KB, 3-code-unit chunks) the whole stream is 0.115 ms, so the overhead is not on the critical path and the compact buffer is no longer the next thing to build.
- **`--skip-prose` recovers a bare scalar root, not prose followed by one.** `'ok'`, `True`, `+1`, `42 // done` and a fenced `42` are recovered; prose followed by a scalar (`Sure!\n42`) still raises `E002`, and so does a scalar with a tail (`42 is the answer`).
- **Memory is 13.7 × the input for `repair()`** (177.9 MB for a 12.95 MB document). On the same input Node's `JSON.parse` is 10.6 × and Python's `json.loads` is 14.3 ×, so **a 4 × budget is not realistic for any tree-building parser**, Node included. `--check` skips rendering and peaks at 8.0 × (103.6 MB, a single-machine observation on the same input); the byte fast path cuts a 10 MB single string from 38 × to 9.4 ×. Reaching 4 × still requires a "render text without building a tree" mode ([docs/MEMORY.md](docs/MEMORY.md)).
- **The per-feed p99 is only an upper bound.** The runtime clock is millisecond-resolution and exposes no allocation counter, so the scenario benchmark reports an amortised µs/feed plus the count of feeds that reached the clock resolution (`docs/BENCHMARK.md`).
- **The readiness curve covers top-level members only.** A nested member (`{"arguments":{…}}`) is ready only when its container closes; the curve costs ~1.8 ms/KiB, and early stopping saves ~0 on flat records by construction.
- **Text mode does not skip prose by default.** `--skip-prose` starts a value at `{` or `[`, and a scalar root is recovered by the `finish` replay; prose followed by a scalar root still raises `E002` because where the prose ends is undecidable.
- **The JS backend still allocates one `Position` per code unit.** The n/2n/4n ratio therefore reaches 2.3–2.8 against a 2.3 target. Absolute throughput is well above the 5 MB/s floor, so this is recorded as a decision rather than fixed.
- **Parser instances are not thread-safe.** Use one instance per input stream.
- **`max_depth` can only be tightened, not loosened.** `Options::max_depth` is capped at `MAX_VALUE_DEPTH = 512`, which is also the documented default, so a caller can ask for less nesting but a larger value is refused with `E050` instead of being honoured. The ceiling is not a policy choice: three recursive walks (`copy_json`, `json_equal`, `walk_schema`) and the engine's own frame stack are bounded by it, and the wasm backend's stack overflows in a recursive walk between 896 and 1024 frames — a higher ceiling would turn the documented `E020` back into the crash it exists to prevent. Declarations have a tighter, separate bound: `MAX_SCHEMA_DEPTH = 256`, refused with `E070`.
- **The refusal contract changed in 1.5.0.** In 1.4.x a plan that was *accepted* but not executable (a lossy repair under `permissive`, or a value that fails its declaration) serialised as `"retry": null` while still carrying a live `value` — the one shape a host must never see, and a refusal with no prompt to send back. Now `executable == false` implies `value: null`, `text: ""` and a non-empty `retry.prompt`, under every profile. A 1.4.x caller that branched on `retry == null` must branch on `executable` instead; one that branched on `value != null` gets the same answer as before.
- **`json_equal` compared numbers as `Double` in 1.4.x**, so `9007199254740993` and `9007199254740992` (adjacent integers past 2^53) were treated as the same value and a duplicate-key merge that silently changed one was recorded as harmless (`Info`). It now compares exact decimal values: that case is `Warning` and refused. Merging `1` with `1.0` is still cosmetic.
- **The rule table was one slot short in 1.4.x.** `RuleSet::all()` used a literal 22 while `RepairCode::number()` is 1-based, so `R022 NormalizeLiteral` fell outside the table; `is_enabled` returned `true` for an out-of-range code, which made `disable(R022)` a silent no-op. The table is now sized from `RepairCode::count()` and out-of-range is fail-closed.
- **MCP is advisory.** `interjson_gate` is a tool the model may call; a model can skip it and the protocol gives the host no way to require it. A Claude Code `PreToolUse` hook or a host-SDK `gate()` is what makes the gate mandatory — see `docs/INTEGRATIONS.md`.

## Roadmap

- ~~Publish on mooncakes.io~~: the published history (0.3.0 … **0.8.1**) is under the former package name `zhanshishan/jsonmend`; the renamed `zhanshishan/interjson` starts at **0.11.0** (the registry counterpart of 1.4.0), published on 2026-10-27. **1.5.0 / 0.12.0 is not published yet** — no tag, no release, no registry upload; `1.5.x` ↔ `0.12.x`. `1.x` cannot be published because mooncakes currently only accepts `0.x.y`; patch and minor digits follow the release order (`1.1.x` ↔ `0.8.x`, `1.2.x` ↔ `0.9.x`, `1.3.x` ↔ `0.10.x`, `1.4.x` ↔ `0.11.x`). The bytes are identical except for the version string and the registry package name.
- ~~A browser tab that plays a model stream~~: `static/demo/live.html`, also published at <https://wenhuang2333.github.io/Moonbit-haker/live.html>.
- ~~Readiness for the members the caller actually needs~~: `Schema` + `semantic_readiness`.
- ~~Constraints in the declaration~~: `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` / `minLength` / `maxLength` / `enum` / `pattern` (a character-class subset, not a regex) landed in 0.7.0.
- ~~Make `semantic_readiness` incremental~~: done via the `Delta.at` timeline (1.1–1.7× `repair`); the streaming runtime is `SemanticWatcher` (1.64–2.00×).
- Make the delta stream cheap: encode operations into a reusable buffer and share path prefixes, targeting ≤ 1.11 × the baseline instead of 1.40–1.46 × (lower priority now that the scenario benchmark shows it is off the critical path).
- ~~The `FR-16` event interface~~: done as the `feed_with` thin wrapper.
- Record real provider streams to replace the documented event shapes (needs credentials; `tests/record_stream.py` is ready).
- Extend the readiness curve to nested members and give it a zero-sampling, delta-driven implementation.
- Add a text-only mode (`want_value = false`). The cross-implementation baseline shows the 4 × budget is unrealistic for any tree builder (Node itself is 10.6 ×), so this needs the metric changed first.
- Add a fourth panel to the browser demo that plays a recorded LLM event stream, so the label and the growing arguments are visible without a terminal.
- Split the engine's current position from its recorded positions to remove the per-code-unit allocation on the JS backend.
- Widen the differential corpus further and add memory-budget tests for the streaming path.
- Keep `docs/RULES.md`, `docs/ERRORS.md`, `docs/DIVERGENCES.md`, `docs/BENCHMARK.md`, and `docs/TRACEABILITY.md` in sync with the code.

## Contributing

- `CONTRIBUTING.md` (part of the release checklist) covers the development environment, how to run the tests, commit conventions, and how to add a repair rule — a rule change must update `docs/RULES.md`, `docs/TRACEABILITY.md`, and the golden tests together.
- Issue templates cover defects (input, options, expected versus actual output, and backend) and new-rule proposals.
- `SECURITY.md` (part of the release checklist) describes how to report a problem: this library processes untrusted input.

## License and acknowledgements

InterJSON is released under the Apache License 2.0 (`license = "Apache-2.0"` in `code/moon.mod`). A `LICENSE`/`NOTICE` pair is part of the release checklist.

- [jsonrepair](https://github.com/josdejong/jsonrepair) (TypeScript) and [json-repair](https://github.com/mangiucugna/json_repair) (Python) are used as behavioural oracles in the differential report. They are used only for comparison; no code from either project is vendored.
- The MoonBit core library (`moonbitlang/core/json`, `moonbitlang/core/string`) provides the `Json` type and string handling.

See `docs/ONEPAGE.md` for a one-page project summary.
