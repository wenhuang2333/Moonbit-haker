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

## MCP

`interjson mcp` is a local MCP server over stdio (JSON-RPC 2.0): no socket, no
network, no API key. The binary under the alias `interjson-mcp` starts the same
server with no arguments. The server implements `initialize`, `tools/list`,
`tools/call` and `ping`, and exposes four read-only tools:

| Tool | Use |
| --- | --- |
| `interjson_gate` | **the gate**: decision, exactness, ambiguity, schema, retry hint. Defaults to the `agent` profile |
| `interjson_repair` | repair text and return the repaired document |
| `interjson_validate` | check without repairing |
| `interjson_readiness` | when each declared field becomes final |

A successful result carries `content[0].text` (the JSON as a string) and
`structuredContent` (the same object); a tool failure carries `isError: true`
and no `structuredContent`. Tools are annotated
`readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`,
`openWorldHint: false`.

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
> engine); install from the repository path until the registry publication.
> The Python import name is `interjson`.

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
npm install ./code/npm
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
