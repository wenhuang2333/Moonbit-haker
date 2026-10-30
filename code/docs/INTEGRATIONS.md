# Integrating InterJSON into an agent

InterJSON is the execution gate for LLM output. There are two sides to
integrate with, and the right one depends on *where* in the loop you need the
gate. The distinction that matters:

- **MCP** is a tool the *model* can call. It is the widest discovery surface
  (Claude Code, Cursor, Cline, Windsurf, VS Code, Codex CLI, Zed, …) and needs
  no code, but the model decides when to use it.
- **`serve` / the language packages** are for the *host*: the application that
  receives a tool call and is about to execute it. This is where the guarantee
  is strongest, because the gate runs whether or not the model remembered to
  ask.

Both exist; use both. The MCP deployment guide — install paths, per-client
config, the privacy model, troubleshooting — is [MCP.md](MCP.md).

| Where you are | Use | Why |
| --- | --- | --- |
| Claude Code / Cursor / Cline / Windsurf / VS Code / Codex CLI / Zed | `interjson mcp` | one stdio server, no code change |
| Python application or agent SDK | `interjson-moonbit` (pip), `import interjson`, `Client` | one long-lived process, full decision object |
| Node / TypeScript application | `interjson-moonbit` (npm) | same engine as the browser bundle |
| LangChain / LlamaIndex output parsing | Python `Client` in a parser | repairs before the framework parses |
| Vercel AI SDK / raw provider stream | npm `analyze`, or `llm.*` over `serve` | gate the raw argument text |
| n8n / Dify / Coze / a gateway | `interjson-http` | one POST per call, stateless |
| Browser | npm package or `static/demo/interjson.js` | same engine, no server |
| MoonBit | `moon add zhanshishan/interjson` | in-process library |

The MCP server, the `serve` protocol, the npm package, the pip package, the
HTTP facade, and the browser bundle are all wrappers over the same engine. They
do not reimplement parsing, repair, or the decision; a wrapper that disagrees
with `serve` is a bug.

## The one pattern to remember

Everything below is a variation of this:

```python
plan = jm.analyze(model_text, profile="agent", schema_json=tool["inputSchema"])
if not plan["executable"]:
    return retry_with(plan["retry"]["prompt"])   # feed the model its own error
execute(json.loads(plan["text"]))
```

`profile="agent"` refuses a lossy or ambiguous repair instead of inventing
content. `schema_json` is the tool declaration you already have, so there is no
second source of truth to keep in sync.

`interjson mcp`'s gate tool applies the same rule with the same default: the
model or the client calls `interjson_gate` with the raw argument text, reads
`executable`, and sends `retry.prompt` back when it is false.

## Making the gate mandatory

This is the distinction that decides whether you have a gate or a suggestion:

| You wired up | The gate runs when | Is it a gate? |
| --- | --- | --- |
| `interjson mcp` only | the model chooses to call `interjson_gate` | **no — advisory** |
| a `PreToolUse` hook, or `gate()` in the host SDK | every matching tool call, before execution | **yes** |

Plain MCP is **advisory**: `interjson_gate` is one tool among many, the model can
skip it, and nothing in the protocol makes the host check the answer. A model
that never calls the gate is not violating anything — it is doing what an
optional tool allows. Every MCP client has this property; it is not specific to
InterJSON.

If the requirement is "no tool call executes without passing the gate", the check
has to live on the **host** side, at a point the model cannot route around.
Below are the two shapes that work.

### Claude Code `PreToolUse` hook

Claude Code fires `PreToolUse` after it has built a tool call and before it
executes it. The hook receives the call as JSON on stdin and can return
`permissionDecision: "deny"` to block it, with a reason the model reads. That is
exactly the shape of an execution gate.

The exchange, end to end:

```text
Claude builds a tool call
      │
      ▼
PreToolUse hook ──► interjson explain --policy agent --json
      │                       │
      │                       └─ exit 0 → executable, exit 5 → refused
      ▼
{"permissionDecision":"deny",      ┌── no decision (exit 0, no JSON):
 "permissionDecisionReason": …}    │   the tool call proceeds normally
      │                            ▼
      ▼                       tool executes
tool call blocked; Claude reads
retry.prompt as the tool result
```

Configuration, in `.claude/settings.json` (project scope; use
`~/.claude/settings.json` for every project):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__orders__.*",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/interjson-gate.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

`matcher` is a tool-name filter. `mcp__orders__.*` matches every tool from an MCP
server named `orders`; `Bash|Edit|Write` matches built-in tools by exact name.
Omitting `matcher` runs the hook on every tool call.

The script reads the call from stdin, looks the tool's declaration up in a file
you keep next to it, and asks the gate:

```bash
#!/bin/bash
# .claude/hooks/interjson-gate.sh — route a tool call through the execution gate.
set -u
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
# `tool_input` is the arguments object in the hook payload. It is unwrapped
# when it arrives as a JSON *string* instead, because a quoted string fed to
# the gate is a document whose root is a string, and it would be refused for
# the wrong reason -- a mismatch that looks like a gate decision but is a
# shape mismatch in the hook.
tool_input=$(printf '%s' "$input" |
  jq -c '.tool_input // empty | if type == "string" then (fromjson? // .) else . end')

# The declarations this project gates, keyed by the tool name the hook sees.
# A tool that is not listed is not gated: start narrow, widen deliberately.
declarations="${CLAUDE_PROJECT_DIR:-.}/.claude/interjson-schemas.json"
[ -f "$declarations" ] || exit 0
decl=$(jq -r --arg t "$tool" '.[$t] // empty' "$declarations")
[ -n "$decl" ] || exit 0

gate="${INTERJSON_BIN:-interjson}"
plan=$(printf '%s' "$tool_input" | "$gate" explain \
  --policy agent --schema "$decl" --json 2>/dev/null)
status=$?

# 5 is the CLI's documented "refused": E010 over budget, E011 ambiguity, or
# E070 declaration mismatch. 0 means executable. Anything else is the gate
# itself failing -- exit 1 there and let Claude Code surface a broken hook
# rather than silently allowing the call.
case "$status" in
  0) exit 0 ;;                       # no decision: normal permission flow
  5) ;;
  *)
    echo "interjson gate failed (exit $status); refusing to execute" >&2
    exit 1
    ;;
esac

prompt=$(printf '%s' "$plan" | jq -r '.retry.prompt // "arguments refused"')
jq -n --arg p "$prompt" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $p
  }
}'
exit 0
```

And `.claude/interjson-schemas.json`, mapping tool name → declaration. The
declaration is the library's skeleton language; a JSON Schema subset also works
via `schema_json` in the SDK path, but the CLI flag `--schema` takes the DSL:

```json
{
  "mcp__orders__create": "{!amount:integer,!currency:string}"
}
```

Make the script executable (`chmod +x .claude/hooks/interjson-gate.sh`) and
install `jq`. Three behaviours worth knowing:

- **Denial carries the retry prompt.** `permissionDecisionReason` is shown to
  Claude, so the refusal reaches the model in the same wording the MCP tool
  would have used. The model can re-emit and the call passes the next time.
- **A tool with no declaration is not gated.** `interjson explain` without
  `--schema` still checks syntax and exactness, but it cannot check a schema it
  was not given. Listing a tool is a deliberate act.
- **Fail closed on a broken hook.** A non-zero exit that is not `5` prints to
  stderr and exits `1`; Claude Code reports the hook as failed rather than
  treating the call as allowed. This is the opposite of the `exit 0` default an
  unconfigured hook has, and it is the point: a gate that fails open is not a
  gate.

> **Status of this recipe: verified by hand, not by CI.** The configuration
> schema above (event name, `matcher`, `hooks[].type: "command"`, `timeout`,
> `hookSpecificOutput.permissionDecision` / `permissionDecisionReason`) is taken
> from Claude Code's hooks reference. The script was run by hand against the
> JSON input shape that reference documents, and all three branches were
> confirmed — allow, deny, and an ungated tool — with `tool_input` given both
> as an object (the real shape) and as a JSON string: a mismatched argument
> produced
> `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`,
> and a matching one produced no output and exit 0. What is **not** tested here
> is a real Claude Code session running the hook — that needs the client, and it
> is not in this repository's test suite. Treat the wiring as a sketch to adapt,
> not as a configuration this project ships and supports.

### Host SDK: `gate(args) -> execute | retry`

Whatever the SDK, the insertion point is the same — the function that turns a
model's tool call into an execution:

```python
from interjson import Client

GATE = Client()   # one long-lived engine process for the session

def gate(tool_name: str, args_text: str, tool_spec: dict) -> dict:
    """Return the call to execute, or raise with the sentence for the model."""
    plan = GATE.analyze(args_text, profile="agent",
                        schema_json=tool_spec["inputSchema"])
    if not plan["executable"]:
        # The refusal is the program: hand it back verbatim.
        raise ToolArgumentsRefused(plan["retry"]["prompt"])
    return json.loads(plan["text"])

# In the tool-call handler, before anything runs:
args = gate(call.name, call.arguments_text, TOOLS[call.name])
execute(call.name, args)
```

The same shape in Node:

```js
import { analyze } from "interjson-moonbit";

function gate(argsText, toolSpec) {
  const plan = analyze(argsText, {
    profile: "agent",
    schemaJson: toolSpec.inputSchema,
  });
  if (!plan.executable) throw new ToolArgumentsRefused(plan.retry.prompt);
  return JSON.parse(plan.text);
}
```

Three properties this has that the MCP surface does not:

- it runs **before** execution, on a code path the model does not control;
- it sees the **raw argument text**, so a repair or a truncation is visible
  instead of already normalised by the SDK's typed parser;
- `executable: false` becomes an exception in your own code, so there is one
  place to log, count, and alert on refusals.

## MCP

`interjson mcp` is a local MCP server over stdio (JSON-RPC 2.0): no socket, no
network, no API key. The binary under the alias `interjson-mcp` starts the same
server with no arguments. It implements `initialize`, `tools/list`, `tools/call`
and `ping`, and exposes four read-only tools — `interjson_gate` (**the gate**;
`decision`, `exactness`, ambiguity, schema, retry hint, defaults to the `agent`
profile), `interjson_repair`, `interjson_validate` and `interjson_readiness`.
`content[0].text` is a summary and `structuredContent` is the payload; a tool
failure carries `isError: true` and no `structuredContent`. The tools, their
`outputSchema` fields, the protocol revisions and the JSON-RPC error codes are
in [MCP.md](MCP.md) — this section only covers wiring.

With the binary on `PATH`:

```json
{
  "mcpServers": {
    "interjson": { "command": "interjson", "args": ["mcp"] }
  }
}
```

Installed with pip, the console script resolves the engine itself (`pip
install` alone does not provide it; the binary must be on `PATH` or named by
`INTERJSON_BIN`):

```json
{
  "mcpServers": {
    "interjson": { "command": "interjson-mcp" }
  }
}
```

Installed from npm, `interjson-mcp` is the package's bin; it spawns the
resolved native binary with `mcp`. **The npm package is the JS engine; the MCP
server still needs the native binary**, so build one
(`moon build cmd/interjson --target native --release`) or set `INTERJSON_BIN`
as well. The server writes JSON-RPC to stdout and nothing else;
diagnostics go to stderr.

Print the right snippet for your client instead of transcribing it:

```sh
interjson mcp --print-config=claude    # claude mcp add interjson -- interjson mcp
interjson mcp --print-config=cursor    # mcpServers JSON (also Cline, Windsurf)
interjson mcp --print-config=vscode
interjson mcp --print-config=codex
interjson mcp --print-config=zed
interjson mcp --print-config=json      # generic
```

Version negotiation, the 8 MiB request-line cap, the security model, and
troubleshooting are in [MCP.md](MCP.md).

## Python

> Registry names: this repository ships the npm package and the PyPI
> distribution as **`interjson-moonbit`** (the suffix identifies the MoonBit
> engine). The npm package is published (`npm install interjson-moonbit`); the
> PyPI distribution is not, so install it from the repository path. The Python
> import name is `interjson`.

```bash
pip install ./code/python            # no dependencies
export INTERJSON_BIN=/path/to/interjson  # or put it on PATH
interjson-mcp --version              # the MCP console script (needs the engine)
```

Keep one client for the session; each `Client` is one `interjson serve` process.

```python
from interjson import Client

with Client() as jm:
    plan = jm.analyze(text, profile="agent", schema_json=tool["inputSchema"])
```

The package installs two console scripts: `interjson-mcp` (the MCP launcher,
see [MCP.md](MCP.md)) and `interjson-http` (below).

A LangChain output parser is a thin wrapper:

```python
import json
from langchain_core.output_parsers import BaseOutputParser
from interjson import Client

class InterJSONParser(BaseOutputParser[dict]):
    def __init__(self, schema_json: dict | None = None):
        self._jm = Client()
        self._schema = schema_json

    def parse(self, text: str) -> dict:
        plan = self._jm.analyze(text, profile="agent", schema_json=self._schema)
        if not plan["executable"]:
            raise ValueError(plan["retry"]["prompt"])
        return json.loads(plan["text"])
```

The same shape works for an LlamaIndex output parser, an OpenAI Agents SDK
guardrail, or a Claude Agent SDK hook: call `analyze`, and on
`executable == false` hand `plan["retry"]["prompt"]` back to the model. For
SDKs that hand you typed arguments rather than raw text, the useful insertion
point is the provider stream (`llm_open`/`llm_feed`/`llm_close`), not the typed
call.

## Node / TypeScript

```bash
npm install interjson-moonbit
```

```js
import { analyze, repair } from "interjson-moonbit";

const plan = analyze(rawArguments, {
  profile: "agent",
  schemaJson: tool.inputSchema,
});
if (!plan.executable) {
  throw new Error(plan.retry.prompt);
}
```

This is framework-agnostic: call it in the `onToolCall`/stream handler before
executing, whatever the SDK is. The package also exports `repair`,
`repairResult`, `report`, `snapshot` and `live` (one frame of the streaming
view for a UI), and its `interjson-mcp` bin starts the MCP server once the
native engine is installed.

## HTTP

```bash
interjson-http --port 8080
```

| Route | Body |
| --- | --- |
| `POST /analyze` | `{"text": "...", "profile": "agent", "schema_json": {…}}` |
| `POST /repair` | `{"text": "...", "profile": "execution"}` |
| `POST /validate` | `{"text": "...", "schema": "{!query:string}"}` |
| `POST /readiness` | `{"text": "...", "schema_json": {…}}` |
| `GET /healthz` | — |

Responses are `{"ok":true,"result":{…}}` or `{"ok":false,"error":{…}}` with a
4xx status for a structured refusal. CORS is open, so a browser page can call
it directly. Each request uses a fresh engine process, so one bad input cannot
poison the next call; for throughput, use the Python `Client` or the npm
package instead.

n8n/Dify/Coze: an HTTP Request node with `POST http://127.0.0.1:8080/analyze`
and the JSON body above.

## Streaming

For token-by-token work, the protocol has two stream families:

```python
with Client() as jm:
    jm.watch_start(schema_json=tool["inputSchema"])
    for chunk in model_stream:
        frame = jm.watch_feed(chunk)
        for event in frame["events"]:
            if event["kind"] == "root_ready":
                stop_generation()          # every declared field is final
    final = jm.watch_finish()
```

```python
with Client() as jm:
    jm.llm_open("anthropic")
    for event in provider_events:          # already-extracted payloads
        frame = jm.llm_feed(event)
        for call in frame["calls"]:
            render(call["name"], call["value"], call["done"])
    closed = jm.llm_close()                # end: complete / max_tokens / interrupted
```

`llm.*` understands Anthropic `input_json_delta` and OpenAI-compatible
`tool_calls` fragments, so a host does not reimplement provider parsing to get
a streaming gate.

## Choosing a profile

| Profile | Use |
| --- | --- |
| `permissive` | display, logging, best-effort repair |
| `interactive` | a human is about to look at the result |
| `execution` | tool arguments that will run: refuses lossy and ambiguous |
| `agent` | the same, tuned for a model in the loop; the MCP gate's default |
| `strict` | any repair at all is a failure |

The default in the library is permissive, because a display channel should show
what it can. **An integration that executes must pass `profile="agent"` or
`"execution"` explicitly.** A wrapper that defaults to permissive turns the
gate into a suggestion. The one exception is designed in: the MCP gate defaults
to `agent`, so a client that never sets a profile still gets a refusal instead
of a guess.

## Verifying the integration

The protocol is pinned by an executable corpus:

```bash
python3 code/tests/conformance/run_conformance.py --cli <interjson>
```

It covers `serve` and `mcp` (19 groups in total, including the MCP handshake,
notification handling, and the four tools). If your wrapper produces a
different decision than `serve` does, the wrapper is wrong.
`code/docs/CONFORMANCE.md` explains the case format and how to add one.
