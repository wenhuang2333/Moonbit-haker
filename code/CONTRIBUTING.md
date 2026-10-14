# Contributing

Thanks for looking at JSONMend. This file covers the environment, the test
commands and the rules a change has to follow.

## Environment

```bash
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
cd code && moon check && moon test
```

The toolchain used for 0.1.0 is `moon 0.1.20261012` / `moonc v0.10.15+943464bfa`.
Python 3 and Node.js are only needed for the differential harness.

## Layout

| Path | Contents |
| --- | --- |
| `code/*.mbt` | the library, one flat package |
| `code/*_wbtest.mbt` | whitebox tests (same package, can reach private fields) |
| `code/cmd/jsonmend/` | native command line front end |
| `code/bench/` | benchmark harness and the wasm-gc size probe |
| `code/examples/web/` | browser demo entry points (JS backend) |
| `code/tests/diff/` | differential harness against `jsonrepair` / `json-repair` |
| `code/tests/*.sh` | CLI smoke test and the benchmark driver |
| `code/docs/` | rules, errors, divergences, benchmark, reproduce, one page, traceability |
| `static/demo/` | the built browser page and its bundle |

## Tests a change must pass

```bash
cd code
moon check                     # 0 warnings — warnings are treated as failures
moon fmt --check
moon test && moon test --target native && moon test --target js
bash tests/cli_smoke.sh        # after: moon build cmd/jsonmend --target native --release
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
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
- no panic on any byte sequence: only the documented `MendError`s may escape.

## Style

- No warnings, `moon fmt` clean.
- Comments are used for the *why*, not the *what*; the engine already reads as a
  state machine.
- Public API additions need a reason: the surface is deliberately small
  (`docs/TRACEABILITY.md`, NFR-API-01).
- Commit messages: short English imperative ("Add R019 string concatenation").

## Commit and review checklist

- [ ] `moon check` reports 0 warnings
- [ ] `moon fmt --check` is clean
- [ ] tests pass on wasm-gc, native and JS
- [ ] CLI smoke test passes
- [ ] differential harness still exits 0
- [ ] docs and `CHANGELOG.md` updated with the change
- [ ] no key, token, `.env` or build artifact is committed
