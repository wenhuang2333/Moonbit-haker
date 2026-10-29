# Conformance: the executable part of the protocol

`tests/conformance/` is the corpus that keeps four delivery channels saying the
same thing:

| Channel | How it is checked |
| --- | --- |
| `interjson serve` | every case in `cases.jsonl`, over one connection per case |
| `interjson mcp` | the MCP half of the runner (four tools, safe gate default, the closed per-tool `outputSchema`, the summary text channel vs `structuredContent`, three accepted protocol revisions, `-32002` before `initialize`, `-32602` for an unknown tool or non-object `arguments`, notification rules) |
| Python package | `code/python/tests/` drives `Client`, which speaks the same protocol |
| npm package | `code/npm/tests/node.test.mjs` drives the same engine through the JS entry points |

The CLI's own `--batch` and one-shot paths are covered by `tests/cli_smoke.sh`;
the conformance corpus exists for the protocol layer, where a wrapper can
silently diverge.

## Running it

```bash
cd code
moon build cmd/interjson --target native --release
python3 tests/conformance/run_conformance.py \
  --cli ./_build/native/release/build/cmd/interjson/interjson.exe
```

Exit status is 0 only when every group passes. The runner prints one `ok`/`FAIL`
line per group; a failure prints the expected subset and the actual object.

CI runs it on Linux, macOS and Windows (`ci.yml`, job `windows`).

## Case format

`cases.jsonl` is one JSON object per line.

Single request:

```json
{"name":"repair-simple","steps":[{"request":{"id":2,"method":"repair","params":{"text":"{a:1,}"}},"expect":{"ok":true,"result":{"text":"{\"a\":1}","exactness":"cosmetic"}}}]}
```

Multi-step (one connection, so stream state is exercised):

```json
{"name":"watch-stream","steps":[
  {"request":{"id":12,"method":"watch.start","params":{"schema":"{!a:string}"}},"expect":{"ok":true}},
  {"request":{"id":13,"method":"watch.feed","params":{"chunk":"{\"a\":\"x\"}"}},"expect":{"ok":true,"result":{"events":[{"kind":"field_ready","path":"a"}]}}},
  {"request":{"id":14,"method":"watch.finish"},"expect":{"ok":true}}
]}
```

A raw line, for framing errors:

```json
{"name":"malformed-line","raw":"{not json","expect":{"ok":false,"error":{"code":"E060"}}}
```

`expect` is matched as a **subset**: every key present in `expect` must be
present and equal in the response; extra response fields are allowed. Lists are
compared element by element and must have the same length. That way a new
response field is a non-event, while a changed value or a removed field is a
failure.

## The MCP half

The runner also starts `interjson mcp` and checks:

1. each supported legacy `protocolVersion` (`2024-11-05` and `2025-03-26`) is
   echoed, and `serverInfo.name == "interjson"` with a title and instructions
   that name `interjson_gate`;
2. an unsupported `protocolVersion` is answered with `2025-06-18`, never echoed
   back;
3. a request before `initialize` (for example `tools/list`) is JSON-RPC error
   `-32002`;
3. a notification (`notifications/initialized`, or any message without an
   `id`, including `tools/list`) produces **no line** — the next line must be
   the answer to the following `ping`;
4. `tools/list` returns exactly `interjson_gate`, `interjson_repair`,
   `interjson_validate`, `interjson_readiness`, each with `outputSchema` and
   `annotations.readOnlyHint == true`;
5. `tools/call interjson_gate` on a truncated document with **no** `profile`
   refuses (`executable == false`, E010 in `retry.prompt`) with `value: null`;
6. a prose-prefixed document (`Here are the args:\n{"a":1}`) is **accepted** by
   the default `agent` profile, because that profile is `Options::for_agent()`
   including `skip_prose`, while `profile: "execution"` still refuses it;
7. `tools/call interjson_gate` on `{"words":["a" "b"]}` with
   `profile: "execution"` returns `decision == "ambiguous"` and
   `isError == false`;
8. `tools/call` with an unsupported JSON Schema keyword returns `isError: true`,
   names `E070`, and carries no `structuredContent`;
9. an unknown tool returns JSON-RPC error `-32602`, a non-object `arguments`
   returns `-32602`, and an unknown method returns `-32601`;
10. `mcp --print-config=claude` prints the exact one-line command, and
    `--print-config=cursor` prints a usable `mcpServers` object; an unknown
    client name exits `2`;
11. an executable named `interjson-mcp` starts the server with no arguments
    (the alias path a client config actually uses).

## Adding a case

1. Add a line to `cases.jsonl` with the smallest `expect` that would catch the
   regression you care about.
2. Run the runner; if the actual value differs, decide whether the code or the
   expectation is wrong — the corpus is a spec, not a snapshot.
3. If the case belongs to a wrapper (npm/Python), add it to that package's test
   file too; the wrapper must not diverge from `serve`.

## What is intentionally not in the corpus

- Repair-rule coverage. That is `prop_wbtest.mbt`, the golden suite, the
  differential report and the ground-truth evaluation; the conformance corpus
  only pins the protocol surface.
- Performance. `tests/bench.sh` owns those numbers; the measurement log is in
  `docs/BENCHMARK.md`, maintained in the repository and not published.
- Volatile fields. Nothing in a response is time- or machine-dependent, which
  is why exact subset matching is possible.
