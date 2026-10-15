# 0.6.0 release readiness: what `main` measures, and what it claims

Written against `main` = **`cce9ba67`** (`Add streaming semantic safety runtime`,
63 files, `+11769 −3178`), the commit that `Release v0.6.0` run #10 built
successfully. Everything here comes from published CI artifacts — the log
archives and the `differential-report` artifact of `ci.yml` runs **#18**
(`38759105731`, `f94f9121`) and **#22** (`38781104341`, `cce9ba67`), and the jobs
of `nightly.yml` run **#1** (`38778966871`). Nothing here is an estimate; every
number has a run id next to it, and the full narrative is in
`code/docs/GITHUB.md`.

The short version: **the pipeline is green and the code is a real improvement,
but three documents committed inside the release make false quantitative claims
about the code they ship with, and the nightly workflow has never passed.** Two
of the three are one-line arithmetic; none of them requires the release to be
withdrawn, but all three should be corrected before 0.6.0 is cited anywhere.

## 1. What is genuinely good

* `ci.yml` #22 passed every step on `cce9ba67`. The 170 tests pass on all three
  backends, `cli_smoke.sh` 77/77, `examples.sh` 6/6, the demo bundle smoke test
  passes, and the browser bundle is in sync (`git diff --exit-code` clean).
* The headline performance claim reproduces in CI: `semantic_readiness` went from
  **31.69×** `repair` (run #18) to **3.08×** (run #22), with the old sampled
  implementation still measured in the same table at 32.32×. The improvement is
  visible within one run, from the same binary, which is the strongest form this
  kind of claim can take.
* The independent corpus is byte-for-byte reproducible from the artifact: 318
  files (95 `y_`, 188 `n_`, 35 `i_`), `y_` false repairs 2, `n_` valid-value
  production 165/188 — matching `TRACEABILITY.md` FR-38 exactly.
* The differential harness is honest where it easily could not be: 402 cases,
  202 divergences, **all 202 with a documented cause, 0 unexplained**,
  documented-scope agreement 100.0 %.

## 2. Three false claims committed inside the release

Each line below quotes what the committed document says, then what CI measured on
the same commit.

### 2.1 `code/docs/REPRODUCE.md` understates the test suite by 41 tests

The document says "期望：129 个测试全部通过" and "`bash tests/cli_smoke.sh` # 62
项断言". Run #22 on `cce9ba67` measured **170 tests** (`Total tests: 170, passed:
170, failed: 0` on wasm-gc, native and js) and **77 CLI assertions** (`77 passed,
0 failed`). The 0.5.0 count was 129/62; the release commit added the
`stream_readiness` and scalar-root cases without updating the guide.

*Consequence:* the document that exists to let a reader verify the release tells
them a correct release is wrong. Anyone following it and seeing 170 will suspect
their environment.

### 2.2 The same document understates library coverage by 59 lines and 3.9 points

| command | committed text | run #22 on `cce9ba67` |
| --- | --- | --- |
| `moon coverage report -f summary -p zhanshishan/jsonmend` | `2371/2661` = 89.1 % | **`2850/3063` = 93.0 %** |
| `moon coverage report -f summary` | `2708/3469` = 78.1 % | **`3187/3907` = 81.6 %** |
| `… -p zhanshishan/jsonmend/llm` | `337/391` = 86.2 % | `337/391` = 86.2 % (unchanged, correct) |

The committed figures are run #18's, i.e. the *previous* commit's. This one is
the most dangerous of the three because coverage is a gate: a reviewer checking
"does the library clear 85 %?" against the committed line sees 89.1 % and cannot
tell whether the new 288-line `stream_readiness.mbt` was tested. It was — 258/288
= 89.6 % — but that cannot be seen from the document.

### 2.3 `code/docs/TRACEABILITY.md` `NFR-TEST-01` is two releases behind

It says the library package is `1378/1487 = 92.7 %` and `llm` is `223/243 =
91.8 %`, with `1601/2002 = 80.0 %` including bench. At `cce9ba67` those are
`2850/3063`, `337/391` and `3187/3907`: the numerator is more than double, and
the completion table is the one document that is supposed to be the release's
audit trail.

## 3. The correctness baseline the release did not move

These are not new defects and 0.6.0 did not claim to fix them, but they belong in
the release note so nobody reads "independent corpus passes" as "no misses":

* **2 valid documents are repaired anyway** (`y_` false repairs: 2 files, 2
  records). Both are the duplicate-key normalisation R018. `TRACEABILITY.md`
  FR-38 records this honestly; the independent evaluation's own gate
  (`--strict`) would flag it.
* **23 of 188 invalid documents are refused rather than repaired**, 8 of them
  solely because of invalid UTF-8 (`E040`). `json_repair` accepts 166 and
  `jsonrepair` 144, so JSONMend is 1 document behind the Python oracle on
  production rate. Defensible, and documented as a deliberate difference — but
  it is the number a competitor quotes.
* **The Node oracle had never once run in CI.** The committed
  `EVAL_INDEPENDENT.md` cites `jsonrepair` 144/188 and 12 strict-oracle
  disagreements; run #18's CI copy of that same file says `n/a (library not
  installed)` and 0 disagreements, because the oracle died on
  `ERR_MODULE_NOT_FOUND` and the script degrades instead of failing. The cause
  and fix are in §4.2; until `cce9ba67` carried the fix, FR-38's evidence chain
  was unverifiable by the project's own pipeline.

## 4. Pipeline weaknesses

### 4.1 `nightly.yml` has never passed

Run #1: the `longrun` job succeeded (1 000 000 cases per property on both
backends, 129 tests), the `differential` job **failed in 27 s** with
`run_diff.py: error: the following arguments are required: --cli`. The cause is
`\\` used for line continuations inside a YAML `run: |` block scalar: a backslash
in a literal block scalar is literal, so bash saw a backslash argument, the
command ended at the first line, and `--cli` never reached the script. It is a
guaranteed failure on every dispatch, and this was the workflow's first ever run
— the schedule had never fired, so nothing had caught it.

Fixed in `cce9ba67` (`nightly.yml +4 −4`). What remains is evidence: **a green
dispatch has still not been observed.** That is one `workflow_dispatch` against
`cce9ba67`, and it is the cheapest outstanding item in this document.

### 4.2 Reference oracles degrade to `n/a` instead of failing

`oracle_node_bytes.mjs` resolved the package with a bare ESM
`import { jsonrepair } from "jsonrepair"`. The ESM resolver ignores `NODE_PATH`
— that variable is CommonJS-only — so the import only worked when `jsonrepair`
happened to sit in a `node_modules` above the script. On a developer machine that
is true by accident; in CI the package is installed under `$RUNNER_TEMP`, so the
column silently became `n/a` behind a printed note. Fixed in `cce9ba67` by
resolving through `createRequire`, and now proven in the pipeline: run #21 (this
branch) and #22 (`main`) are the first runs whose differential job logs
`jsonrepair 144/188`.

**Still open, same class, reported not fixed:**

* `ci.yml` passes `--node-dir "$RUNNER_TEMP/node-oracle/node_modules"` where
  `run_independent.py` appends `node_modules` itself, so `NODE_PATH` becomes
  `…/node_modules/node_modules`. The `.mjs` fix tolerates it; the report still
  mislabels itself.
* `run_ambiguity.py` is invoked with no `--node-dir`, so it uses the developer
  default `/private/tmp` and **both** of its reference columns print
  `n/a (library not installed)` in every CI run. The suite still passes, because
  its criteria are about JSONMend's own verdicts (10/10 ambiguous cases flagged
  and refused by the gate), but the comparison table is empty in the published
  report.

The pattern is the interesting part: a reference oracle is treated as
decoration, so its absence cannot fail anything, and the absence is invisible
unless a human reads the log. Whatever is done about the two open sites, the
principle worth adopting is that CI should print an explicit
`DEGRADED: <oracle> unavailable` marker and lint for it, so "the oracle ran" is
observable rather than inferred.

### 4.3 `moon fmt --check` fails in the working tree (not the release)

`ci.yml`'s "Formatting" step passed on `cce9ba67`, so the released commit is
clean. In the current working tree `moon fmt --check` fails on
`code/schema.mbt` (an uncommitted 31-line addition, the prose-skip scalar-root
guard). Unrelated to the release; it will block whoever next runs the gate, and
it is one `moon fmt` away from resolved.

## 5. What to do, cheapest first

| # | action | how it is verified |
| --- | --- | --- |
| 1 | Correct the three documents in §2 (test count 129 → 170, assertions 62 → 77, coverage `2850/3063` and `3187/3907`, `NFR-TEST-01` refreshed) | every number already has a run id; re-read the run #22 log |
| 2 | Dispatch `nightly.yml` once against `cce9ba67` | the differential job must reach `run_diff.py`, not argparse |
| 3 | Fix the `--node-dir` value in `ci.yml` and pass it to `run_ambiguity.py` | both reference columns stop printing `n/a` in the CI log |
| 4 | Add the `FR-40` row for the loopback SSE transport recording (§6) | `TRACEABILITY.md` gains the row; `tests/run_llm_loopback.py` exits 0 |
| 5 | Decide whether the 2 `y_` false repairs stay as R018's documented cost, or whether R018 gets a strict/lossy split | `run_independent.py --strict` is the switch that already expresses the choice |
| 6 | Run `moon fmt` in the working tree | "Formatting" stays green for the next commit |

## 6. The `FR-40` row that is still missing

`code/docs/TRACEABILITY.md` uses `FR-38` (independent corpus) and `FR-39`
(incremental streaming readiness); **`FR-40` is free and unused**. The
real-transport recording work has no row, so a reader cannot trace it. The row
below is written to match the surrounding style; the file is owned by another
writer, so this is the text to paste rather than an edit.

> | FR-40 | 真实传输 SSE 录制与回放 | P1 | — | TC-LLM-02 | `tests/record_stream.py --loopback` 在 `127.0.0.1` 起本地 HTTP 服务，按 Anthropic `/v1/messages` 线格式发出真实 SSE 字节流，再由普通 HTTP 客户端从真实 socket 读回，产出四个场景的夹具 `llm/fixtures/loopback_{tool_call,escape_split,truncated,parallel}.{sse,jsonl,expect.json,adapter.jsonl}`（正常调用、`\uXXXX` 与代理对中间切分、无 `message_stop` 的截断、交错并行调用），每个夹具在字节里自带 `transport=loopback-sse` / `vendor_capture=false` 的 provenance，且拒绝写入无 `data:` 载荷或载荷非 JSON 的响应；`tests/run_llm_loopback.py` 一条命令重录全部夹具到临时目录逐字节比对，再把每个夹具同时经原始 `.sse` 与逐行 `.jsonl` 喂给真实 CLI 并与金标准比对，7 个夹具（4 loopback + 3 live relay）全部通过、异常时以非零退出；四个预期结果分别是 `complete/exact`、`complete/exact`（`café 😀 done` 原值不变）、`interrupted/lossy`、两个 index 0/1 的 `complete/exact`。`ci.yml` 在 llm 夹具检查之后新增一步执行该脚本。另有 `llm/fixtures/live_relay_*` 三份实况录制（`transport: live-http-sse`，Anthropic 兼容中继而非第一方 endpoint）；本机凭据探测见 `docs/PROVIDER_PROBE.md`，`docs/LLM_EVENTS.md` 记录三类证据的区别 | 通过（第一方 vendor 抓包仍缺，已如实标注） |

The one-line summary for a reviewer who will not read the row: the loopback path
gives every LLM wire-format claim a real HTTP + real SSE test that runs in CI
without a vendor key, and the three relay captures are labelled as what they are
— real bytes, from a relay, not from `api.anthropic.com`.

## 7. What this document is not

It is not a claim that 0.6.0 is unsafe to ship. The code is green, the headline
performance claim reproduces within a single CI run, and the differential harness
is more honest than most. The failures are in the *record*: three documents that
quote the wrong revision, one workflow that has never passed, and two reference
oracles that have been silently missing from every published report. All three
are cheap to fix and none of them is hidden — every number above was read out of
an artifact anyone with repository access can download.
