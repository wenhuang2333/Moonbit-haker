# Contributing

Thanks for looking at InterJSON. This file covers the environment, the test
commands and the rules a change has to follow.

## Environment

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
cd code && moon check && moon test
```

The toolchain used for 1.1.0 is `moon 0.1.20261016` / `moonc v0.10.16+b1a0e846e`. Bundle artifacts must be rebuilt with the same toolchain as CI (latest).
Python 3 and Node.js are only needed for the differential harness.

## Layout

| Path | Contents |
| --- | --- |
| `code/*.mbt` | the library, one flat package |
| `code/*_wbtest.mbt` | whitebox tests (same package, can reach private fields) |
| `code/cmd/interjson/` | native command line front end |
| `code/bench/` | benchmark harness and the wasm-gc size probe |
| `code/examples/web/` | browser demo entry points (JS backend) |
| `code/tests/diff/` | differential harness against `jsonrepair` / `json-repair` |
| `code/tests/*.sh` | CLI smoke test and the benchmark driver |
| `code/docs/` | rules, errors, divergences, benchmark, reproduce, one page, traceability, protocol, MCP deployment |
| `static/demo/` | the built browser page and its bundle |

## MCP surface

`interjson mcp` (alias `interjson-mcp`) is the primary way the product is used:
a local stdio MCP server, no network, no API key, exposing four read-only tools
— `interjson_gate` (primary, defaults to the `agent` profile),
`interjson_repair`, `interjson_validate`, `interjson_readiness`. The server
speaks protocol `2025-06-18` (accepting `2024-11-05`), returns text plus
`structuredContent`, and `interjson mcp --print-config=claude|cursor|vscode|codex|windsurf|zed|json`
prints the client configuration.

A change to a tool name, an input schema or the result envelope is a
public-surface change: update `docs/MCP.md`, `docs/CONFORMANCE.md`, the
`static/demo/*.html` pages and `CHANGELOG.md` in the same commit, and run
`python3 tests/conformance/run_conformance.py` (it starts `interjson mcp` and
checks the MCP half as well as `serve`).

## Tests a change must pass

```bash
cd code
moon check                     # 0 warnings — warnings are treated as failures
moon fmt --check
moon test && moon test --target native && moon test --target js
bash tests/cli_smoke.sh        # after: moon build cmd/interjson --target native --release
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe
```

The differential script must exit 0: every divergence from the reference
implementations has to be explained by the repair rules that fired. If your
change adds a new divergence, add the rule or state why the difference is
intended in `docs/DIVERGENCES.md` (the file is generated; put the explanation in
`tests/diff/run_diff.py`'s classification instead).

## Adding a repair rule

1. Add the variant to `RepairCode` in `error.mbt` **at the end of the enum** —
   `number()` is the table index and the existing golden cases encode it.
2. Give it a name, a severity and a fixed English message. Messages must never
   embed user input: they are written to logs.
3. Emit it through `Engine::report(code, position)`. The severity comes from
   `RepairCode::severity()` — do not pass a level at the call site.
4. Add golden cases to `golden_wbtest.mbt`, a property-test angle to
   `prop_wbtest.mbt` if it changes output shape, and a streaming case to
   `stream_wbtest.mbt` if it can fire across a chunk boundary.
5. Update `docs/RULES.md`, `docs/ERRORS.md` (if the code list changes) and
   `docs/TRACEABILITY.md`, and add a line to `CHANGELOG.md`.

## Invariants that must not regress

- repaired output is always valid JSON (`is_valid_json`);
- repair is idempotent: `repair(repair(x).text).text == repair(x).text` with zero
  records on the second pass;
- streaming is chunk invariant: one-shot and any chunking agree on text,
  records and errors;
- snapshots are a stable prefix: once `Complete`, they never change again;
- no panic on any byte sequence: only the documented `InterJSONError`s may escape.

## Style

- No warnings, `moon fmt` clean.
- Comments are used for the *why*, not the *what*; the engine already reads as a
  state machine.
- Public API additions need a reason: the surface is deliberately small
  (`docs/TRACEABILITY.md`, NFR-API-01).
- Commit messages: short English imperative ("Add R019 string concatenation").

## Commit and review checklist

CI (`.github/workflows/ci.yml`) runs the same list; a red job is a blocker.

- [ ] `moon check --deny-warn` reports 0 warnings
- [ ] `moon fmt --check` is clean
- [ ] tests pass on wasm-gc, native and JS
- [ ] CLI smoke test passes (`bash tests/cli_smoke.sh`)
- [ ] example inputs match (`bash tests/examples.sh`)
- [ ] the browser bundle is rebuilt when the engine changed (`bash static/demo/build.sh`,
      then `node code/tests/demo_smoke.mjs`)
- [ ] demo media refreshed before a release (`bash code/tests/media/refresh.sh`)
- [ ] differential harness still exits 0
- [ ] docs and `CHANGELOG.md` updated with the change
- [ ] no key, token, `.env` or build artifact is committed
- [ ] after publishing, local build/temp artifacts are removed (see `AGENTS.md`); old
      versions are kept only by GitHub history and Releases
