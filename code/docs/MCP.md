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
| Protocol revisions | `2025-06-18`, `2025-03-26` and `2024-11-05` are all accepted verbatim; any other requested revision is answered with `2025-06-18` and is **never echoed back** |
| Server identity | `serverInfo.name = "interjson"`, `serverInfo.title = "InterJSON — the execution gate"`, `serverInfo.version` = engine version (`1.5.1`) |
| Capabilities | `tools.listChanged: false` (tools only; no resources or prompts) |
| Tools | `interjson_gate` (primary), `interjson_repair`, `interjson_validate`, `interjson_readiness` — all read-only |
| Request line limit | 8 MiB (8,388,608 bytes); a longer line is answered with JSON-RPC `-32700` and discarded through the next LF |
| Engine limits | nesting depth (`Options::max_depth`, default 512; the ceiling on it is documented in [`../SECURITY.md`](../SECURITY.md) and above it the option is refused with `E050`), input 67,108,864 UTF-16 code units, single token 16,777,216; a *declaration* deeper than the schema bound in `SECURITY.md` is refused with `E070` |
| Stdout | JSON-RPC messages only; diagnostics go to stderr |
| Notifications | never answered (`notifications/initialized`, `notifications/cancelled`) |
| State | stateless: every tool call is independent |
| Lifecycle | `initialize` first: a request that arrives before it is answered with JSON-RPC error `-32002` (only `initialize` and `ping` are exempt) |

The server is implemented once, in the native binary (`code/cmd/interjson/mcp.mbt`).
The pip launcher replaces its own process with `<binary> mcp`; the npm launcher
spawns it with inherited stdio. Neither reimplements the protocol, so there is
exactly one server and one engine.

## Install the engine

Pick one install path; each ends with a working `interjson` binary. Every
launcher and client below needs that binary, so verify it first:

```sh
interjson --version          # interjson 1.5.1
```

> **Technical preview.** The prebuilt binary comes from the GitHub release, which
> builds four binaries across three operating systems: `linux-x86_64`,
> `linux-arm64`, `macos-arm64` and `windows-x86_64`. Building
> from source needs the MoonBit toolchain `moon 0.1.20261016`. The mooncakes
> counterpart **0.13.0 was published on 2026-10-29**, and the npm package
> **`interjson-moonbit@1.5.1` on 2026-10-30**, and the same version on PyPI on
> 2026-10-30, so both language packages install with one command.

### One command: `install.sh`

`code/install.sh` is the installer the release serves as
`interjson-install.sh`. It works out the platform, downloads the matching asset,
verifies its SHA-256 against the release's own `SHA256SUMS`, installs to
`~/.local/bin` (override with `INTERJSON_DIR`) and prints the `PATH` line to add
if that directory is not already on `PATH`. A checksum that does not match is a
hard failure: the file is deleted and nothing is installed.

```sh
curl -fsSL https://github.com/wenhuang2333/Moonbit-haker/releases/latest/download/interjson-install.sh | sh
```

Environment: `INTERJSON_VERSION` (tag; default = latest release),
`INTERJSON_DIR` (default `$HOME/.local/bin`), `INTERJSON_REPO` (default
`wenhuang2333/Moonbit-haker`). Exit codes: `0` installed, `1` download or
checksum failure, `2` unsupported platform.

### Build from source

The CLI is native-only (`supported_targets = "native"`), built with the pinned
toolchain `moon 0.1.20261016`. This is the install path for the `interjson`
surface today:

```sh
git clone https://github.com/wenhuang2333/Moonbit-haker
cd Moonbit-haker/code
moon build cmd/interjson --target native --release
./_build/native/release/build/cmd/interjson/interjson.exe --version   # interjson 1.5.1
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

The published release assets are `interjson-linux-x86_64`,
`interjson-linux-arm64`, `interjson-macos-arm64`,
`interjson-windows-x86_64.exe`, `interjson-probe.wasm`,
`interjson-demo.js`, `interjson-install.sh` and `SHA256SUMS`. There is **no
Intel macOS asset**: the MoonBit toolchain publishes no `darwin-x86_64` target,
so no runner can build one. Releases before v1.4.0 were published as JSONMend
and keep the `jsonmend-*` asset prefix and the `jsonmend_*` tool names; use
v1.4.0 or later for the `interjson` CLI and `interjson_gate`.

The 1.5.1 release is tagged `v1.5.1` and is published with those eight assets;
the mooncakes counterpart `0.13.0` was published on 2026-10-29, so the installer
above installs the 1.5.1 binaries.

### pip: `interjson-moonbit`

The Python distribution is `interjson-moonbit` (the suffix identifies the
MoonBit engine); the import is `interjson`, and it installs two console
scripts.

```sh
pip install interjson-moonbit
interjson --version          # interjson 1.5.1: the engine the launcher needs
interjson-mcp --version      # same output, through the console script
interjson-http --help        # HTTP facade; not needed for MCP
```

The wheel carries the engine for every release platform, so this is the whole
install: `interjson-mcp` starts with no `INTERJSON_BIN` and no `interjson` on
`PATH`. Installing from a checkout (`python3 -m pip install ./code/python`)
builds the client without the binaries and needs one of the paths below.

`interjson-mcp` is a launcher: it resolves the engine, then replaces itself with
`<binary> mcp`, so stdin/stdout stay a clean JSON-RPC channel with no Python in
the middle. Resolution order:

1. `INTERJSON_BIN` — an absolute path to the binary;
2. `interjson` on `PATH`;
3. the bundled binary for this platform (`interjson/bin/<platform>/`), which
   the PyPI wheel carries;
4. a binary placed directly in `interjson/bin/`;
5. the development build inside this repository.

If none is found it raises `FileNotFoundError` naming the install options; on a
platform the release does not build for (Intel macOS) the message names the
platforms the wheel does carry instead of suggesting a reinstall that cannot
help.

### npm: `interjson-moonbit`

```sh
npm install -g interjson-moonbit   # or: npm install interjson-moonbit
interjson --version                # the native engine must resolve first
interjson-mcp --version            # passed through to `<binary> mcp --version`
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
process default.

That default is **exactly `Options::for_agent()`**, protocol included: the gate
resolves a profile by name through `Options::for_profile`, which applies the
safety knobs *and* the protocol the profile implies. For `agent` that means
`skip_prose: true`, so the most common shape of chat-channel output — a sentence
followed by the arguments:

```text
Here are the args:
{"a":1}
```

is **accepted by default**. Selecting `agent` by name used to apply only the
safety half, so the flagship tool refused that input with `E002`; the other four
profiles still refuse it (`execution`, `strict`, `interactive` and `permissive`
do not skip prose). `schema` is the declaration language
(`{!query:string,!limit:integer}`); `schema_json` is the tool's existing JSON
Schema subset (`type`, `properties`, `required`, `items`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
`maxLength`, `pattern`). Unsupported keywords are refused with `E070` instead
of being silently ignored.

Every `tools/list` entry carries a `title`, an `outputSchema` that is a real
per-tool schema, and annotations that say what the server can do to the world.
Each `outputSchema` is **closed** (`additionalProperties: false`) and names its
required fields:

| Tool | `outputSchema` properties | required |
| --- | --- | --- |
| `interjson_gate` | `decision`, `label`, `exactness`, `ambiguous`, `information_loss`, `valid_json`, `normalized`, `ambiguity`, `execution`, `executable`, `syntax_ready_permille`, `schema_total`, `schema_satisfied`, `schema_missing`, `error`, `repairs`, `retry`, `repairs_truncated`, `value`, `text` | all twenty |
| `interjson_repair` | `text`, `exactness`, `ambiguous`, `completeness`, `repairs`, `repairs_truncated` | all six |
| `interjson_validate` | `valid`, `schema`, `error`, `repaired`, `exactness`, `ambiguous`, `repairs` | `valid` |
| `interjson_readiness` | `syntax_permille`, `schema_permille`, `settled_permille`, `step`, `verdict` | the first four |

Before 1.5.0 the declaration was `{type: object, additionalProperties: true}`,
which told a client nothing and validated nothing. The annotations are:

```json
"annotations": {
  "title": "InterJSON",
  "readOnlyHint": true,
  "destructiveHint": false,
  "idempotentHint": true,
  "openWorldHint": false
}
```

A successful `tools/call` carries the payload **once**. The two channels are
different views of the same call, not two copies:

- **`content[0].text`** is a short summary the model can act on. For the gate it
  is `decision=… executable=… exactness=…`, then `error=…` when there is one,
  then `retry (send this back to the model): <prompt>` when the call was
  refused. For `repair` it is the exactness line plus the repaired text; for
  `validate` it is `valid=…` and the error; for `readiness` it is the three
  fractions.
- **`structuredContent`** is the machine-readable object, once. A client that
  understands `structuredContent` reads it and never parses the text channel.

Before 1.5.0 both channels carried the same complete object, so a gate response
was two full copies of the payload on the wire — including the repaired document
inside each copy. A host pays for every byte, and the model only reads the text
channel, so the text channel is now a summary.

A tool *execution* failure is `isError: true` with a message the model can read
and **no `structuredContent`** (a JSON-RPC success, as the protocol requires).
A protocol-level failure is a JSON-RPC `error` envelope — see
[JSON-RPC error codes](#json-rpc-error-codes).

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
| `value` | what the engine parsed; **`null` whenever `executable` is `false`** (see below) |
| `text` | what the engine rendered; `""` whenever `executable` is `false` (see below) |
| `schema_total`, `schema_satisfied`, `schema_missing` | declared members, how many match, which are missing |
| `error` | `{code, message}` for the first refusal, or `null` |
| `repairs` | rule, position, severity, ambiguity class, confidence per change |
| `retry` | `{code, prompt}` — the prompt to send back to the model; **non-null with a non-empty `prompt` whenever `executable` is `false`, and `null` whenever it is `true`** |

`executable` is a property of the document, not of the profile: `permissive`
will repair a truncated document for display and still answer
`executable: false`, because executing it would mean executing a value the
model never wrote.

**The refusal contract.** A non-executable result always carries
`value: null`, `text: ""` and a non-empty `retry.prompt`; an executable result
always carries a live `value` and `retry: null`. This is not a property of one
profile — it holds under every profile. Branch on `executable` alone.

1.4.x broke this in the case that matters most: a document that was *accepted*
(nothing was refused) but *not executable* — a lossy repair under `permissive`,
or a value that fails its declaration — serialised as `"retry": null` while the
tool description told the caller to send `retry.prompt` back. The refusal had no
prompt, and the object carried a live `value` next to `executable: false`, which
is the one combination a host must never see. Both halves are now fixed and
asserted by `code/regression_1_5_wbtest.mbt` (TC-R-07, TC-R-08, TC-R-09).

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

`result.content[0].text` is the summary the model reads (this is the whole
text channel, verbatim):

```text
decision=lossy_repair executable=false exactness=lossy
error=E010 E010 StrictViolation at 1:25 (offset 24): R010 CloseString: exactness lossy exceeds max_loss cosmetic
retry (send this back to the model): InterJSON refused the arguments: E010 R010 CloseString at line 1 column 25 (offset 24).
Reason: exactness lossy exceeds max_loss cosmetic
Context: {"query":"weather in Par
                                 ^
Re-emit the arguments as valid JSON with exactly one reading.
```

Response, decoded from `result.structuredContent` (the payload once;
`result.isError` is `false`):

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

## JSON-RPC error codes

Two kinds of failure look similar in a log and mean opposite things. The
distinction is the difference between "the tool ran and refused" and "the tool
was never called correctly":

| Code | When | What it means | `structuredContent`? |
| --- | --- | --- | --- |
| `-32002` | a request other than `initialize` or `ping` arrives before the handshake | the session is not initialized | no |
| `-32602` | `tools/call` with an unknown `name`, or with `arguments` that is not an object | the *call* is malformed; no tool ran | no |
| `-32602` | `tools/call` with no `name` at all | the call is malformed | no |
| `-32601` | an unknown `method` | the method does not exist on this server | no |
| `-32700` | a line that is not valid JSON, or longer than 8 MiB | framing/parse failure; the line is discarded through the next LF | no |
| (no error) | a valid call whose document is refused | **this is a success**: the tool ran, `isError` is `false`, `executable` is `false` | yes |

The last row is the one to internalise. A gate refusal is not an error — it is
the product working. `-32602` for an unknown tool used to come back as a
tool-level `isError: true` result, which told the host "the tool ran and
refused" and hid a typo in the tool name behind a document-level failure; a
non-object `arguments` used to be read as "no arguments" and produced a
confusing complaint about a missing `text`. Both are protocol errors now
(`code/cmd/interjson/mcp.mbt`).

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
model may call.

**Plain MCP is advisory.** `interjson_gate` is a tool the model *may* call. A
model can skip it, and the protocol gives the host no way to make the call
mandatory — so "the client is configured for InterJSON" means "the gate is
available", not "every tool call passed the gate". Nothing here detects or
prevents that; it is a property of MCP, not of this server.

What makes it mandatory is a host-side insertion point the model cannot route
around:

- a Claude Code **`PreToolUse` hook**, which runs on every matching tool call
  before execution and can deny it with the retry prompt;
- one **`gate(args)` call in the host SDK** on the path that turns a tool call
  into an execution;
- `interjson serve`, the npm/pip packages, or the HTTP facade, all of which run
  on the host side.

Recipes for the first two are in
[INTEGRATIONS.md](INTEGRATIONS.md#making-the-gate-mandatory).

**Resource limits:** one request line may not exceed 8 MiB; a longer line gets
`-32700` and is discarded through the next LF. The engine's own limits (depth,
input 67,108,864 code units, token 16,777,216) apply per call and are reported
as `E020`/`E021`/`E022`; a declaration past the schema bound is `E070`, and a
`max_depth` above the ceiling in [`../SECURITY.md`](../SECURITY.md) is `E050`. A
client should still run one server process per session and supervise it.

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
| `FileNotFoundError: the interjson engine was not found` | the launcher could not resolve an engine — a checkout install rather than the PyPI wheel | `pip install interjson-moonbit` from PyPI, or put `interjson` on `PATH`, or set `INTERJSON_BIN` |
| JSON-RPC `-32700 parse error` on every line | Something other than the server wrote to stdout (a wrapper banner, `print`, a shell profile) | Run `interjson mcp` directly; keep stdout for JSON-RPC and send logs to stderr |
| JSON-RPC `-32602` with ``unknown tool `…` `` | The call itself is wrong, not the document | Check `tools/list`; the tool name must be one of the four |
| JSON-RPC `-32602` with `` `arguments` must be an object `` | `arguments` was an array, a string or a number | Send `arguments` as a JSON object |
| JSON-RPC `-32002` `server not initialized` | A request arrived before `initialize` | Send `initialize` first; only `initialize` and `ping` are answered before the handshake |
| `result.isError: true` with `E070 SchemaError` | The declaration uses a keyword the subset does not support | Use the listed subset, or drop `schema_json` |
| `executable: false` and no error | This is a successful refusal: the gate did its job | Send `retry.prompt` to the model and re-emit |
| `-32700 message exceeds MAX_LINE` | One request line is over 8 MiB (8,388,608 bytes, measured on the UTF-8 line) | Split the work into smaller calls; the cap is fixed |
| Client asks for an unknown `protocolVersion` | Only `2025-06-18`, `2025-03-26` and `2024-11-05` are implemented | The server answers `2025-06-18` and never echoes the unknown string; upgrade the client or accept the negotiated revision |
| `interjson-mcp` is "not found" on Windows | A symlink is not the native way to alias an executable | Copy `interjson.exe` to `interjson-mcp.exe`, or use `interjson.exe mcp` in the config |

The server never prints a banner, a version, or a warning on stdout. If a client
reports a JSON-RPC framing error, the first thing to check is the wrapper around
the server, not the server.

## Verification

Run these from a checkout; `B` is the built binary.

```sh
B=./code/_build/native/release/build/cmd/interjson/interjson.exe

"$B" --version                     # interjson 1.5.1
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
`readOnlyHint: true` and a closed `outputSchema`.

The repository's own gates cover the same surface:

```sh
# 19 protocol/MCP conformance groups, including the mcp group
python3 code/tests/conformance/run_conformance.py --cli "$B"

# command line assertions, including --print-config and initialize
bash code/tests/cli_smoke.sh
```

`19/19 conformance groups passed` and `122 passed, 0 failed` are the expected
lines. The conformance suite starts the server itself, performs
`initialize` (including the `2024-11-05` fallback), checks that a notification
produces no response, and calls `tools/list` and each tool — it is the
executable definition of this document.

## Relationship to the other surfaces

| Surface | Side of the loop | Transport |
| --- | --- | --- |
| `interjson mcp` | model-side: the model **may** call the gate as a tool (advisory) | MCP over stdio |
| Claude Code `PreToolUse` hook | host-side: every matching tool call is gated before execution | hook process, [INTEGRATIONS.md](INTEGRATIONS.md#claude-code-pretooluse-hook) |
| `interjson serve` | host-side: the application gates every tool call | versioned JSONL, [PROTOCOL.md](PROTOCOL.md) |
| npm / pip packages | host-side: in-process or one long-lived client | JS bundle / stdio client |
| `interjson-http` | host-side: gateways and no-code tools | HTTP, [INTEGRATIONS.md](INTEGRATIONS.md) |

MCP is the discovery surface: it works with any MCP client without code. The
host-side surfaces are where the guarantee is strongest, because they run
whether or not the model chose to ask — MCP alone is advisory, and this document
says so rather than implying otherwise.
