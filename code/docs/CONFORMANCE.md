# Conformance: the executable part of the protocol

`tests/conformance/` is the corpus that keeps four delivery channels saying the
same thing:

| Channel | How it is checked |
| --- | --- |
| `jsonmend serve` | every case in `cases.jsonl`, over one connection per case |
| `jsonmend mcp` | the MCP half of the runner (tools, refusal, notification rule) |
| Python package | `code/python/tests/` drives `Client`, which speaks the same protocol |
| npm package | `code/npm/test/node.test.mjs` drives the same engine through the JS entry points |

The CLI's own `--batch` and one-shot paths are covered by `tests/cli_smoke.sh`;
the conformance corpus exists for the protocol layer, where a wrapper can
silently diverge.

## Running it

```bash
cd code
moon build cmd/jsonmend --target native --release
python3 tests/conformance/run_conformance.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
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

The runner also starts `jsonmend mcp` and checks:

1. `initialize` echoes the client's `protocolVersion` and reports
   `serverInfo.name == "jsonmend"`;
2. a notification (`notifications/initialized`) produces **no line** — the next
   line must be the answer to the following `ping`;
3. `tools/list` returns exactly `jsonmend_repair`, `jsonmend_analyze`,
   `jsonmend_validate`, `jsonmend_readiness`;
4. `tools/call jsonmend_analyze` on `{"words":["a" "b"]}` returns
   `decision == "ambiguous"` with `isError == false`;
5. `tools/call` with an unsupported JSON Schema keyword returns `isError: true`
   and names `E070`;
6. an unknown method returns JSON-RPC error `-32601`.

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
- Performance. `tests/bench.sh` and `docs/BENCHMARK.md` own those numbers.
- Volatile fields. Nothing in a response is time- or machine-dependent, which
  is why exact subset matching is possible.
