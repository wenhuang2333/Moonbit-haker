## What changed

## Why

## Evidence

- [ ] `moon check` reports 0 warnings
- [ ] `moon fmt --check` is clean
- [ ] `moon test`, `moon test --target native`, `moon test --target js` pass
- [ ] `bash code/tests/cli_smoke.sh` passes (if the CLI changed)
- [ ] `python3 code/tests/diff/run_diff.py --cli <exe>` exits 0 (if repair behaviour changed)
- [ ] `docs/RULES.md` / `docs/ERRORS.md` / `docs/TRACEABILITY.md` (maintained locally, not published) / `CHANGELOG.md` updated as needed. If a rule or code changed, the tables in `README.md` and `README.zh.md` are updated too.

## Backends checked

- [ ] wasm-gc
- [ ] native
- [ ] JS
