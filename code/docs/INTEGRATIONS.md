# Integrating JSONMend into an agent

Four interfaces exist, and the right one depends on *where* in the loop you
need the gate. The distinction that matters:

- **MCP** is a tool the *model* can call. It is the widest discovery surface
  (Claude Code, Cursor, Codex CLI, Gemini CLI, Cline, Windsurf, Zed, …) but the
  model decides when to use it.
- **`serve --stdio` / the language packages** are for the *host*: the
  application that receives a tool call and is about to execute it. This is
  where JSONMend's value is largest, because the gate runs whether or not the
  model remembered to ask.

Both exist; use both.

| Where you are | Use | Why |
| --- | --- | --- |
| Claude Code / Cursor / Codex CLI / Gemini CLI / Cline / Windsurf | `jsonmend mcp` | one stdio server, no code change |
| Python application or agent SDK | `jsonmend` (pip) `Client` | one long-lived process, full decision object |
| Node / TypeScript application | `jsonmend` (npm) | same engine as the browser bundle |
| LangChain / LlamaIndex output parsing | Python `Client` in a parser | repairs before the framework parses |
| Vercel AI SDK / raw provider stream | npm `analyze`, or `llm.*` over `serve` | gate the raw argument text |
| n8n / Dify / Coze / a gateway | `jsonmend-http` | one POST per call, stateless |
| Browser | npm package or `static/demo/jsonmend.js` | same engine, no server |
| MoonBit | `moon add zhanshishan/jsonmend` | in-process library |

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

## MCP

The server implements `initialize`, `tools/list`, `tools/call` and `ping`, and
exposes four tools:

| Tool | Use |
| --- | --- |
| `jsonmend_analyze` | the gate: decision, exactness, ambiguity, schema, retry hint |
| `jsonmend_repair` | repair text and return the repaired document |
| `jsonmend_validate` | check without repairing |
| `jsonmend_readiness` | when each declared field becomes final |

With the binary on `PATH`:

```json
{
  "mcpServers": {
    "jsonmend": { "command": "jsonmend", "args": ["mcp"] }
  }
}
```

Installed with pip, the console script resolves the binary itself:

```json
{
  "mcpServers": {
    "jsonmend": { "command": "jsonmend-mcp" }
  }
}
```

`uvx --from jsonmend jsonmend-mcp` works the same way once the package is on
PyPI. The server writes JSON-RPC to stdout and nothing else; diagnostics go to
stderr.

## Python

> Registry names: the npm and PyPI names `jsonmend` are already taken by
> unrelated projects. This repository ships them as **`jsonmend-moonbit`**;
> install from the repository path until a registry publication exists. The
> Python import name is still `jsonmend`.

```bash
pip install ./code/python            # no dependencies
export JSONMEND_BIN=/path/to/jsonmend  # or put it on PATH
```

Keep one client for the session; each `Client` is one `jsonmend serve` process.

```python
from jsonmend import Client

with Client() as jm:
    plan = jm.analyze(text, profile="agent", schema_json=tool["inputSchema"])
```

A LangChain output parser is a thin wrapper:

```python
import json
from langchain_core.output_parsers import BaseOutputParser
from jsonmend import Client

class JsonMendParser(BaseOutputParser[dict]):
    def __init__(self, schema_json: dict | None = None):
        self._jm = Client()
        self._schema = schema_json

    def parse(self, text: str) -> dict:
        plan = self._jm.analyze(text, profile="agent", schema_json=self._schema)
        if not plan["executable"]:
            raise ValueError(plan["retry"]["prompt"])
        return json.loads(plan["text"])
```

The same shape works for a LlamaIndex output parser, an OpenAI Agents SDK
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
import { analyze, repair } from "jsonmend";

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
view for a UI).

## HTTP

```bash
jsonmend-http --port 8080
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
| `agent` | the same, tuned for a model in the loop |
| `strict` | any repair at all is a failure |

The default in the library is permissive, because a display channel should show
what it can. **An integration that executes must pass `profile="agent"` or
`"execution"` explicitly.** A wrapper that defaults to permissive turns the
gate into a suggestion.

## Verifying the integration

The protocol is pinned by an executable corpus:

```bash
python3 code/tests/conformance/run_conformance.py --cli <jsonmend>
```

If your wrapper produces a different decision than `serve` does, the wrapper is
wrong. `code/docs/CONFORMANCE.md` explains the case format and how to add one.
