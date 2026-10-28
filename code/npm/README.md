# interjson-moonbit (npm)

InterJSON is the **execution gate for LLM output**: it decides whether a model's
JSON may be executed, and when it may not, returns the sentence to send back to
the model. This package is the MoonBit engine compiled to JavaScript — streaming
repair, partial parsing, and the gate for in-process callers — plus a launcher
that starts the local MCP server from the native binary.

```bash
npm install ./code/npm      # from the repository root
```

> The package name is **`interjson-moonbit`** on npm (the suffix identifies the
> MoonBit engine); the import name is `interjson`. **Publication is pending**:
> version 1.5.0 is not on the npm registry yet, so install from the repository
> path above. Nothing on this page claims the package is installable with
> `npm install interjson-moonbit`.

```js
import { analyze, repair } from "interjson-moonbit";

// The gate: decide before executing tool arguments.
const plan = analyze(modelOutput, {
  profile: "agent",
  schemaJson: tool.inputSchema, // the declaration you already have
});
if (!plan.executable) {
  throw new Error(plan.retry.prompt); // or re-emit `plan.retry.prompt` to the model
}

// The convenience: repair and return text.
const text = repair(modelOutput, { profile: "execution" });
```

## MCP server

The package declares a bin named **`interjson-mcp`**, which runs `mcp.cjs`. It
resolves the native engine and then spawns `<binary> mcp` with inherited stdio,
so the JSON-RPC channel stays clean (no Node process in the middle, nothing on
stdout but protocol messages). Resolution order:

1. `INTERJSON_BIN` — an absolute path to the binary;
2. `interjson` on `PATH`;
3. the development build inside this repository.

```bash
npm install -g ./code/npm
interjson --version              # interjson 1.5.0: the native engine must resolve first
interjson-mcp --version          # passed through to `<binary> mcp --version`
interjson-mcp --print-config=claude
```

`npm install` installs the JS engine and the launcher, not the native binary.
If the binary is missing, `interjson-mcp` exits `127` with the install options
on stderr — the first command above must succeed before the others can.

**The npm package is the JS engine, not the MCP server.** The server itself is
the native binary; the launcher only finds it and hands it this process's
stdin/stdout. MCP therefore requires the native engine: build it with
`moon build cmd/interjson --target native --release`, or point `INTERJSON_BIN`
at a binary. With no binary the launcher exits `127` and prints those options
on stderr rather than starting a half-working server.

Configuration for Claude Code, Cursor, Cline, Windsurf, VS Code, Codex CLI and
Zed, with the privacy model and troubleshooting, is in
[`docs/MCP.md`](../docs/MCP.md). The shortest form, with the binary on `PATH`:

```json
{
  "mcpServers": {
    "interjson": { "command": "interjson-mcp" }
  }
}
```

The server exposes four read-only tools: `interjson_gate` (the gate; `executable`,
`decision`, `exactness`, `value`, `retry.prompt`), `interjson_repair`,
`interjson_validate`, and `interjson_readiness`. The gate defaults to the
`agent` profile, which equals `Options::for_agent()` — prose before the
arguments is skipped rather than refused. A refused result always carries a
non-empty `retry.prompt` and `value: null`; `content[0].text` is a summary and
`structuredContent` is the payload. **MCP is advisory**: the model can decline
to call the gate, so the host must gate the call itself (a Claude Code
`PreToolUse` hook or a host-SDK `gate()` — see
[`docs/INTEGRATIONS.md`](../docs/INTEGRATIONS.md#making-the-gate-mandatory)).

## Exports

| Export | Returns | Use |
| --- | --- | --- |
| `repair(input, options?)` | repaired text | a document you will parse yourself |
| `repairResult(input, options?)` | `{text, exactness, ambiguous, repairs, decision, executable, error, retry}` | text plus the decision |
| `analyze(input, options?)` | the full `RepairPlan` | **the gate**; never throws on malformed JSON |
| `report(input)` | `R005 3:14 message` lines, or `-` | diagnostics |
| `snapshot(input, upto)` | `value \| state \| path` | partial parse of a prefix |
| `live(input, upto, schema?)` | one streaming frame object | a UI that renders a model stream |

`options.profile` is one of `permissive`, `interactive`, `execution`, `agent`,
`strict`. `execution` and `agent` refuse a lossy or ambiguous repair instead of
inventing content; `repair` then throws, and `analyze` returns
`executable: false` with `error.code` and `retry`.

`options.schema` is the library's declaration language
(`{!query:string,!limit:integer}`). `options.schemaJson` is a JSON Schema
subset — `type`, `properties`, `required`, `items`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
`maxLength`, `pattern` — so a tool's existing `inputSchema` can be passed
directly. Unsupported keywords raise `E070` rather than being silently
dropped.

## Streaming

`live` is the same frame the [demo page](https://wenhuang2333.github.io/Moonbit-haker/live.html)
draws: `consumed`, `total`, `completeness`, `snapshot`, `open_path`, `members`,
and (with a schema) `syntax_ready`, `schema_ready`, `settled_ready`,
`execution_ready`. It is stateless, so a caller can re-render on every frame;
for a token-by-token feed use the CLI protocol (`interjson serve`) or
the MoonBit `PartialParser`.

## Scope

This package wraps the same bundle as `static/demo/interjson.js`; it does not
reimplement the engine. The version is the engine version (`1.5.0`). The
MoonBit package on mooncakes is `0.12.0` because the registry currently accepts
only `0.x.y`; the bytes are the same. **Neither is published yet**: the npm
package and the 0.12.0 mooncakes upload are both pending, and the published
mooncakes history stops at `0.11.0` (the 1.4.0 correspondence).

License: Apache-2.0.
