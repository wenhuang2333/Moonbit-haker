# jsonmend-moonbit (Python)

The MoonBit JSON engine for Python: streaming repair, partial parsing, and the
**execution gate** for LLM tool calls. No third-party dependencies; the engine
is the same native binary the CLI uses, reached over a versioned stdio
protocol.

```bash
pip install ./code/python          # from the repository root
export JSONMEND_BIN=/path/to/jsonmend   # or put it on PATH
```

> The PyPI name `jsonmend` is already taken by an unrelated package. This
> distribution is `jsonmend-moonbit`; the import name remains `jsonmend`.
> It is installed from the repository until a registry publication.

```python
import json
from jsonmend import Client

with Client() as jm:
    plan = jm.analyze(
        model_output,
        profile="agent",
        schema_json=tool["inputSchema"],  # the declaration you already have
    )
    if plan["executable"]:
        args = json.loads(plan["text"])
    else:
        print(plan["retry"]["prompt"])    # feed this back to the model
```

`Client` keeps one `jsonmend serve` process alive, so a loop pays the spawn
cost once. `repair`, `analyze` and `validate` are one-shot convenience
functions that spawn a process per call.

## Methods

| Method | Returns | Use |
| --- | --- | --- |
| `repair(text, profile=..., schema=...)` | `{text, exactness, ambiguous, repairs, ...}` | repair a document |
| `analyze(text, profile=..., schema=..., schema_json=...)` | the full plan | **the gate**; `executable` decides |
| `validate(text, schema=...)` | `{valid, error?, repaired?, schema?}` | check without repairing |
| `readiness(text, schema=...)` | syntax/schema/settled fractions | when fields become final |
| `watch_start` / `watch_feed` / `watch_finish` | deltas + readiness events | token-by-token |
| `llm_open` / `llm_feed` / `llm_close` | per-tool-call state | Anthropic/OpenAI event streams |

`profile` is one of `permissive`, `interactive`, `execution`, `agent`, `strict`.
`execution` and `agent` refuse a lossy or ambiguous repair instead of
inventing content; `JsonMendError` carries `code`, `message`, `exit_code`,
`retry_hint` and `offset`.

`schema` is the library's declaration language (`{!query:string,!limit:integer}`).
`schema_json` is a JSON Schema subset — `type`, `properties`, `required`,
`items`, `enum`, `const`, `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `minLength`, `maxLength`, `pattern` — so a tool's existing
`inputSchema` can be passed directly. Unsupported keywords raise `E070` rather
than being silently dropped.

## MCP and HTTP

```bash
jsonmend-mcp                    # MCP stdio server, for Claude Code/Cursor/...
jsonmend-http --port 8080       # POST /repair /analyze /validate /readiness
```

`jsonmend-http` is stateless: one engine process per request, closed after it.
It is the path for n8n, Dify, Coze or a gateway; for throughput, use `Client`.

## Version

The Python package is `1.1.0`, the engine version. The MoonBit package on
mooncakes is `0.8.0` because the registry currently accepts only `0.x.y`; the
bytes are the same. `Client.hello()` reports both.

License: Apache-2.0.
