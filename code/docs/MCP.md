# InterJSON MCP server: local deployment guide

InterJSON is the execution gate for LLM output. `interjson mcp` runs that gate
as a Model Context Protocol server on your own machine: one native binary,
JSON-RPC 2.0 over stdin/stdout, no socket, no network, no API key, and no model
output leaving the machine.

This document is the canonical deployment guide. The host-side surfaces
(Python, Node, HTTP, the versioned `serve` protocol) are in
[INTEGRATIONS.md](INTEGRATIONS.md); the engine and its guarantees are in
[../README.md](../README.md).

## Why local

The gate sits between a model's raw output and the tool call a host is about to
execute. That position has three consequences:

- **The input is the sensitive part.** Tool arguments routinely contain user
  data, internal identifiers, and names that have not been authorized yet.
  Sending them to a remote validator would leak exactly what the gate is
  supposed to protect. `interjson mcp` opens no socket and makes no request, so
  the data path is `client → local process → client`.
- **There is no secret to manage.** No account, no token, no quota, no
  telemetry. A client starts the server with nothing but an executable path, so
  there is nothing to leak, rotate, or accidentally commit.
- **The decision does not depend on the network.** The same engine that the
  test suite pins makes the decision, offline, on every call. An outage cannot
  silently turn the gate into a pass-through, and an air-gapped machine gets
  the same behaviour as a connected one.

The trade-off is explicit: availability is the local machine's problem, and the
server never executes the JSON it inspects. It only decides, and returns the
sentence to send back to the model when the answer is no.

## What the server is

| Property | Value |
| --- | --- |
| Command | `interjson mcp` |
| Alias | `interjson-mcp` — the same binary under that name starts the MCP server with no arguments |
| Transport | stdio: one JSON-RPC 2.0 object per line on stdin, one per line on stdout |
| Protocol revision | `2025-06-18`; `2024-11-05` is accepted verbatim; any other requested revision is answered with `2025-06-18` |
| Server identity | `serverInfo.name = "interjson"`, `serverInfo.title = "InterJSON — the execution gate"`, `serverInfo.version` = engine version (`1.4.0`) |
| Capabilities | `tools.listChanged: false` (tools only; no resources or prompts) |
| Tools | `interjson_gate` (primary), `interjson_repair`, `interjson_validate`, `interjson_readiness` — all read-only |
| Request line limit | 8 MiB (8,388,608 bytes); a longer line is answered with JSON-RPC `-32700` and discarded through the next LF |
| Engine limits | nesting depth 512, input 67,108,864 UTF-16 code units, single token 16,777,216 |
| Stdout | JSON-RPC messages only; diagnostics go to stderr |
| Notifications | never answered (`notifications/initialized`, `notifications/cancelled`) |
| State | stateless: every tool call is independent |

The server is implemented once, in the native binary (`code/cmd/interjson/mcp.mbt`).
The pip launcher replaces its own process with `<binary> mcp`; the npm launcher
spawns it with inherited stdio. Neither reimplements the protocol, so there is
exactly one server and one engine.

## Install the engine

Pick one install path; each ends with a working `interjson` binary. Every
launcher and client below needs that binary, so verify it first:

```sh
interjson --version          # interjson 1.4.0
```

### Build from source

The CLI is native-only (`supported_targets = "native"`), built with the pinned
toolchain `moon 0.1.20261016`. This is the install path for the `interjson`
surface today:

```sh
git clone https://github.com/wenhuang2333/Moonbit-haker
cd Moonbit-haker/code
moon build cmd/interjson --target native --release
./_build/native/release/build/cmd/interjson/interjson.exe --version   # interjson 1.4.0
```

Put the binary on `PATH` under the name `interjson` (or point
`INTERJSON_BIN` at it); a second copy or symlink named `interjson-mcp` starts
the MCP server with no arguments:

```sh
ln -s "$PWD/_build/native/release/build/cmd/interjson/interjson.exe" /usr/local/bin/interjson
ln -s /usr/local/bin/interjson /usr/local/bin/interjson-mcp           # macOS / Linux
```

On Windows, copy `interjson.exe` to `interjson-mcp.exe` instead of creating a
symlink.

### Release assets

The current release is
[`v1.4.0`](https://github.com/wenhuang2333/Moonbit-haker/releases/tag/v1.4.0),
published under the InterJSON name:
`interjson-linux-x86_64`, `interjson-macos-arm64`,
`interjson-windows-x86_64.exe`, `interjson-probe.wasm`,
`interjson-demo.js` and `SHA256SUMS`. Releases before it were published as
JSONMend and keep the `jsonmend-*` asset prefix and the `jsonmend_*` tool
names; use v1.4.0 or later for the `interjson` CLI and `interjson_gate`.

### pip: `interjson-moonbit`

The Python distribution is `interjson-moonbit` (the suffix identifies the
MoonBit engine); the import is `interjson`, and it installs two console
scripts.

```sh
python3 -m pip install ./code/python
interjson --version          # interjson 1.4.0: the engine the launcher needs
interjson-mcp --version      # same output, through the console script
interjson-http --help        # HTTP facade; not needed for MCP
```

`pip install` installs the client and the two launchers, not the engine; the
first command must succeed before the launchers can answer.

`interjson-mcp` is a launcher: it resolves the engine, then replaces itself with
`<binary> mcp`, so stdin/stdout stay a clean JSON-RPC channel with no Python in
the middle. Resolution order:

1. `INTERJSON_BIN` — an absolute path to the binary;
2. `interjson` on `PATH`;
3. a binary bundled next to the package (`interjson/bin/`);
4. the development build inside this repository.

If none is found it raises `FileNotFoundError` naming the install options. The
launcher and the engine are separate installs: `pip install` gives you the
client and the scripts, and the engine comes from the source build above (or a
release asset, until the next release renames them).

### npm: `interjson-moonbit`

```sh
npm install -g ./code/npm     # or: npm install ./code/npm
interjson --version           # interjson 1.4.0: the native engine must resolve first
interjson-mcp --version       # passed through to `<binary> mcp --version`
```

Without a resolvable engine, `interjson-mcp --version` exits `127` with the
install instructions on stderr.

The package is `interjson-moonbit` (the suffix identifies the MoonBit engine);
its bin is `interjson-mcp`, which runs
`mcp.cjs`. **The npm package is the JS engine — repair, partial parsing, and the
gate for in-process callers — not the MCP server. The server is the native
binary.** The launcher resolves the engine in this order:

1. `INTERJSON_BIN`;
2. `interjson` on `PATH`;
3. the development build inside this repository.

It then spawns `<binary> mcp` with inherited stdio. With no binary it exits
`127` and prints the install options on stderr. An npm-only install therefore
gives you the library; build the native engine (or point `INTERJSON_BIN` at a
release asset) as well before configuring a client.

## Configure a client

Every client below runs the same command. `interjson mcp --print-config=CLIENT`
prints the exact snippet, so prefer copying it:

```sh
interjson mcp --print-config=claude     # Claude Code command
interjson mcp --print-config=cursor     # mcpServers JSON (Cursor, Cline, Windsurf)
interjson mcp --print-config=vscode     # servers JSON
interjson mcp --print-config=codex      # TOML
interjson mcp --print-config=zed        # context_servers JSON
interjson mcp --print-config=json       # generic mcpServers JSON (the default)
```

`--print-config` prints `interjson` as the command, so it assumes the binary is
on `PATH`. If the client cannot see your shell `PATH` — common for GUI apps on
macOS — replace the command with an absolute path, or set `INTERJSON_BIN` in
the environment the client starts the server with.

### Claude Code

```sh
claude mcp add interjson -- interjson mcp
claude mcp list          # shows `interjson` and whether it connected
```

Add `--scope project` to write `.mcp.json` into the repository instead of the
default local scope.

### Cursor, Cline, Windsurf (JSON, `mcpServers`)

```json
{
  "mcpServers": {
    "interjson": { "command": "interjson", "args": ["mcp"] }
  }
}
```

Cursor reads a global `mcp.json` (typically `~/.cursor/mcp.json`) or a project
`.cursor/mcp.json`; Windsurf reads its MCP config (typically
`~/.codeium/windsurf/mcp_config.json`); Cline uses the same `mcpServers` shape
in its MCP settings. The server name is a label only — the
tool names themselves are always `interjson_*`.

### VS Code

`.vscode/mcp.json` uses a `servers` object and requires an explicit transport
type:

```json
{
  "servers": {
    "interjson": {
      "type": "stdio",
      "command": "interjson",
      "args": ["mcp"]
    }
  }
}
```

### Codex CLI

`~/.codex/config.toml`:

```toml
[mcp_servers.interjson]
command = "interjson"
args = ["mcp"]
```

### Zed

`settings.json`:

```json
{
  "context_servers": {
    "interjson": {
      "command": {
        "path": "interjson",
        "args": ["mcp"]
      }
    }
  }
}
```

### Any other MCP client

```json
{
  "mcpServers": {
    "interjson": { "command": "/absolute/path/to/interjson", "args": ["mcp"] }
  }
}
```

Nothing in the configuration is InterJSON-specific beyond the command: the
server speaks plain MCP over stdio. If a client starts the server through
`interjson-mcp` instead, drop the `args` entry.

## The four tools

All four accept `text` (the raw model output) and optional `schema` /
`schema_json`. `interjson_gate` and `interjson_repair` also accept `profile`;
`interjson_validate` and `interjson_readiness` do not, because they never
repair.

| Tool | Title | Answers |
| --- | --- | --- |
| `interjson_gate` | Gate: may I execute this? | May this output be executed? `decision`, `executable`, `exactness`, ambiguity, schema satisfaction, `value`, `retry` |
| `interjson_repair` | Repair malformed JSON | What is the repaired document, and what was changed? |
| `interjson_validate` | Validate without repairing | Is this legal JSON, and does it satisfy the declaration? |
| `interjson_readiness` | When do fields become final? | At which input fraction is each declared field final? |

`profile` is one of `permissive`, `interactive`, `execution`, `agent`, `strict`.
**`interjson_gate` defaults to `agent` when the caller omits `profile`**, so a
host that never sets it still gets refusal instead of invention — even if the
server was started with a looser `--policy`. The other three tools use the
process-level `--policy` when one was given, and the engine default
(`permissive`) otherwise; an explicit `profile` argument always wins over the
process default. `schema` is the declaration language
(`{!query:string,!limit:integer}`); `schema_json` is the tool's existing JSON
Schema subset (`type`, `properties`, `required`, `items`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
`maxLength`, `pattern`). Unsupported keywords are refused with `E070` instead
of being silently ignored.

Every `tools/list` entry carries a `title`, an `outputSchema`, and annotations
that say what the server can do to the world:

```json
"annotations": {
  "title": "InterJSON",
  "readOnlyHint": true,
  "destructiveHint": false,
  "idempotentHint": true,
  "openWorldHint": false
}
```

A successful `tools/call` carries the same result twice: `content[0].text` is
the JSON as a string, and `structuredContent` is the object itself. A client
that understands MCP `2025-06-18` can read the object and skip the parse; an
older client reads the text. A tool *execution* failure is `isError: true` with
a message the model can read (a JSON-RPC success, as the protocol requires);
a protocol-level failure is a JSON-RPC `error` envelope.

### `interjson_gate` result fields

| Field | Meaning |
| --- | --- |
| `decision` | `safe`, `cosmetic_repair`, `lossy_repair`, `ambiguous`, `invalid` |
| `executable` | the only field a host has to branch on; true only when the decision is `safe` or `cosmetic_repair` and a value exists |
| `exactness` | `exact`, `cosmetic`, `lossy` |
| `ambiguity` | `none`, `syntactic`, `semantic` |
| `information_loss` | true when a repair invented, dropped, or changed content |
| `valid_json` | whether the input was legal JSON as written |
| `normalized` | true when the value changed only in notation |
| `execution` | `allowed` or `blocked`; follows `executable` |
| `value` | what the engine parsed; present in the refusal case under some profiles (see below) |
| `text` | what the engine rendered; present in the refusal case under some profiles (see below) |
| `schema_total`, `schema_satisfied`, `schema_missing` | declared members, how many match, which are missing |
| `error` | `{code, message}` for the first refusal, or `null` |
| `repairs` | rule, position, severity, ambiguity class, confidence per change |
| `retry` | `{code, prompt}` — the prompt to send back to the model |

`executable` is a property of the document, not of the profile: `permissive`
will repair a truncated document for display and still answer
`executable: false`, because executing it would mean executing a value the
model never wrote.

`value` and `text` are what the engine parsed and rendered, and their presence
does **not** follow `executable`. Under the default `agent` profile a refused
document drops them (`value: null`, `text: ""`); under `permissive` the same
truncated document returns `executable: false` with
`value: {"query":"weather in Par"}` and
`text: "{\"query\":\"weather in Par\"}"`, because the lenient profile repairs
for display without authorizing execution. **A host must branch on `executable`
alone — never on the presence of `value` or `text`.**

### `interjson_repair`

Returns `text`, `exactness`, `ambiguous`, `completeness`, `repairs[]`, and
`repairs_truncated`. A profile that refuses a repair (`execution` or `agent`
with a lossy or ambiguous change) turns the call into `isError: true` with the
error code and message.

### `interjson_validate`

Returns `valid`, and when the text is repairable also `error`, `repaired`,
`exactness`, `ambiguous`, and `repairs`. With a declaration, a valid document
also gets `schema`: `{total, satisfied, missing, mismatched, ok}`.

### `interjson_readiness`

Returns `syntax_permille`, `schema_permille`, `settled_permille`, `step`, and
`schema`-style `verdict`: the input fraction, in per mille, at which the
document's syntax, its declared members, and both together are already final.
This is the call a host uses to stop a generation early.

## A real gate call

The model was asked for tool arguments and was cut off at `max_tokens`. The
host sends the raw text to the gate before executing anything, with the tool's
`inputSchema` as `schema_json`. No `profile` is sent, so the gate applies its
own default, `agent`.

Request (`id: 2`; the session's `initialize` is elided):

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"{\"query\":\"weather in Par","schema_json":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}}}}
```

Response, decoded from `result.structuredContent` (`result.content[0].text`
carries the same JSON as a string, `result.isError` is `false`):

```json
{
  "decision": "lossy_repair",
  "label": "REJECT (a value was changed)",
  "exactness": "lossy",
  "ambiguous": false,
  "information_loss": true,
  "valid_json": false,
  "normalized": true,
  "ambiguity": "none",
  "execution": "blocked",
  "executable": false,
  "error": {
    "code": "E010",
    "message": "E010 StrictViolation at 1:25 (offset 24): R010 CloseString: exactness lossy exceeds max_loss cosmetic"
  },
  "retry": {
    "code": "E010",
    "prompt": "InterJSON refused the arguments: E010 R010 CloseString at line 1 column 25 (offset 24).\nReason: exactness lossy exceeds max_loss cosmetic\nContext: {\"query\":\"weather in Par\n                                 ^\nRe-emit the arguments as valid JSON with exactly one reading."
  },
  "value": null,
  "text": ""
}
```

`retry.prompt` is the message to hand back to the model, unchanged:

```text
InterJSON refused the arguments: E010 R010 CloseString at line 1 column 25 (offset 24).
Reason: exactness lossy exceeds max_loss cosmetic
Context: {"query":"weather in Par
                                 ^
Re-emit the arguments as valid JSON with exactly one reading.
```

The host re-sends it, the model re-emits complete arguments, and the second call
is the one that may execute:

```json
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"interjson_gate","arguments":{"text":"{\"query\":\"weather in Paris\",\"limit\":3}","schema_json":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}}}}
```

```json
{
  "decision": "safe",
  "label": "SAFE TO EXECUTE",
  "exactness": "exact",
  "executable": true,
  "execution": "allowed",
  "schema_total": 2,
  "schema_satisfied": 2,
  "schema_missing": [],
  "error": null,
  "retry": null,
  "value": { "query": "weather in Paris", "limit": 3 }
}
```

The loop is the whole interface: execute only when `executable` is `true`;
otherwise send `retry.prompt` back and try the re-emitted arguments. A
conforming host applies the same rule to every tool call, not just to the ones
where the model remembered to ask.

## Privacy and security model

**What leaves the machine:** nothing. `interjson mcp` is a stdio process. It
creates no listening socket, resolves no host name, and issues no request; the
MCP input is the only data it reads, and the answer is the only data it writes.
You can confirm the absence of a network surface from the process itself:

```sh
lsof -p "$(pgrep -f 'interjson mcp' | head -1)"     # no TCP/UDP entries
```

**What it stores:** nothing. There is no cache, no temp file, no database, and
no state between calls. The text lives in process memory and dies with the
process. The server writes diagnostics to stderr only; whether a client keeps
those logs is the client's decision.

**What it can do:** only answer. All four tools are annotated read-only,
idempotent, non-destructive, and closed-world. The server never evaluates,
executes, or interpolates the JSON it inspects — it parses it, and returns a
verdict plus, when refused, a sentence describing what to change. A model that
calls the gate cannot use it to run a command, read a file, or reach a host.

**What it does not protect you from:** a model that emits *valid* JSON with the
wrong values. The gate checks syntax, exactness, ambiguity, and the declared
schema; it cannot know that `{"amount": 100}` should have been `1000`. Treat
`executable: true` as "safe to hand to the tool", not as "semantically correct".
It is also not an authorization system: the host still decides which tools a
model may call, and must still gate the host-side path (see
[INTEGRATIONS.md](INTEGRATIONS.md)) because a model can always skip the MCP
tool.

**Resource limits:** one request line may not exceed 8 MiB; a longer line gets
`-32700` and is discarded through the next LF. The engine's own limits (depth
512, input 67,108,864 code units, token 16,777,216) apply per call and are
reported as `E020`/`E021`/`E022`. A client should still run one server process
per session and supervise it.

**Hardening notes:** run the server as the user who owns the data, not as root;
point `INTERJSON_BIN` (or the client's command) at an absolute path you control
rather than trusting a writable `PATH` entry; verify `SHA256SUMS` for a
downloaded binary. Do not bridge stdio to a TCP port without adding
authentication and TLS — MCP over stdio has no authentication because there is
no network peer to authenticate.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Client shows no tools / "server failed to start" | The client cannot find `interjson` (GUI apps often do not inherit the shell `PATH`) | Use an absolute path in the client config, or set `INTERJSON_BIN` for the client's environment |
| `interjson-mcp: the InterJSON engine was not found.` (exit `127`) | npm bin installed without the native engine | Build the native engine or set `INTERJSON_BIN` |
| `FileNotFoundError: the interjson engine was not found` | pip launcher could not resolve the engine (`pip install` installs the launcher, not the engine) | Build the engine, put `interjson` on `PATH`, or set `INTERJSON_BIN` |
| JSON-RPC `-32700 parse error` on every line | Something other than the server wrote to stdout (a wrapper banner, `print`, a shell profile) | Run `interjson mcp` directly; keep stdout for JSON-RPC and send logs to stderr |
| `result.isError: true` with ``unknown tool `…` `` or `missing `text`` | The call itself is wrong, not the document | Check `tools/list`; always pass `text` |
| `result.isError: true` with `E070 SchemaError` | The declaration uses a keyword the subset does not support | Use the listed subset, or drop `schema_json` |
| `executable: false` and no error | This is a successful refusal: the gate did its job | Send `retry.prompt` to the model and re-emit |
| `-32700 message exceeds MAX_LINE` | One request line is over 8 MiB (8,388,608 bytes, measured on the UTF-8 line) | Split the work into smaller calls; the cap is fixed |
| Client asks for an unknown `protocolVersion` | Only `2025-06-18` and `2024-11-05` are implemented | The server answers `2025-06-18`; upgrade the client or accept the negotiated revision |
| `interjson-mcp` is "not found" on Windows | A symlink is not the native way to alias an executable | Copy `interjson.exe` to `interjson-mcp.exe`, or use `interjson.exe mcp` in the config |

The server never prints a banner, a version, or a warning on stdout. If a client
reports a JSON-RPC framing error, the first thing to check is the wrapper around
the server, not the server.

## Verification

Run these from a checkout; `B` is the built binary.

```sh
B=./code/_build/native/release/build/cmd/interjson/interjson.exe

"$B" --version                     # interjson 1.4.0
"$B" mcp --print-config=claude     # claude mcp add interjson -- interjson mcp
"$B" mcp --help                    # names interjson_gate and the six named clients
```

A full handshake without a client library:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$B" mcp
```

The first line must report `"name":"interjson"`, `"protocolVersion":"2025-06-18"`,
and a non-empty `instructions`; the second must list the four tools with
`readOnlyHint: true`.

The repository's own gates cover the same surface:

```sh
# 19 protocol/MCP conformance groups, including the mcp group
python3 code/tests/conformance/run_conformance.py --cli "$B"

# 106 command line assertions, including --print-config and initialize
bash code/tests/cli_smoke.sh
```

`19/19 conformance groups passed` and `106 passed, 0 failed` are the expected
lines. The conformance suite starts the server itself, performs
`initialize` (including the `2024-11-05` fallback), checks that a notification
produces no response, and calls `tools/list` and each tool — it is the
executable definition of this document.

## Relationship to the other surfaces

| Surface | Side of the loop | Transport |
| --- | --- | --- |
| `interjson mcp` | model-side: the model may call the gate as a tool | MCP over stdio |
| `interjson serve` | host-side: the application gates every tool call | versioned JSONL, [PROTOCOL.md](PROTOCOL.md) |
| npm / pip packages | host-side: in-process or one long-lived client | JS bundle / stdio client |
| `interjson-http` | host-side: gateways and no-code tools | HTTP, [INTEGRATIONS.md](INTEGRATIONS.md) |

MCP is the discovery surface: it works with any MCP client without code. The
host-side surfaces are where the guarantee is strongest, because they run
whether or not the model chose to ask.
