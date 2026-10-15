# GitHub evidence: issue, pull request, nightly run and CI logs

All of the activity below was driven through the REST API at `api.github.com`
with the repository admin token that is already in this machine's keychain
(`security find-internet-password -s github.com -w`, 40 characters — the one
`code/docs/PROVIDER_PROBE.md` lists). The token is never printed, never written
to a file and never put into a process argument: the helper in `test/gh_api.py`
hands it to `curl` through a mode-0600 config file that is unlinked immediately.
`github.com` itself (the HTML site) times out from this machine; the API does not.

Two environment facts shaped every command here:

* `python3`'s `urllib` against `api.github.com` fails with
  `SSL: UNEXPECTED_EOF_WHILE_READING` while `curl` succeeds, so the helper shells
  out to `curl`. A first attempt with plain `urllib` lost a 7 KB issue body.
* Issues and pull requests share one number sequence per repository, so "issue #1
  **and** PR #1" is not achievable. The issue was created first and took `#1`; the
  pull request is therefore **#2**.

## 1. Tracking issue

| field | value |
| --- | --- |
| number | **#1** |
| title | `Tracking: 0.6.0 Streaming Semantic Safety` |
| URL | <https://github.com/wenhuang2333/Moonbit-haker/issues/1> |
| created | `2026-10-15T17:37:46Z` |
| state | `open` (not closed) |
| body | 7 129 bytes: frozen decisions Q-23 / Q-26 / Q-27, the Q-28 coverage policy, the per-mode memory metric that retires NFR-PERF-04, the two blockers, and the 0.6.0 checklist |

It names the document and the command behind each piece of evidence instead of
asserting results, and it states the provider-credential blocker accurately: no
*first-party vendor* key exists here, the probe finds exactly one credential and
it is not a vendor key, and the substitutes are the loopback recordings plus the
three relay captures.

## 2. Pull request

| field | value |
| --- | --- |
| number | **#2** (see the numbering note above) |
| URL | <https://github.com/wenhuang2333/Moonbit-haker/pull/2> |
| head → base | `docs/provider-probe-0.6.0` → `main` |
| opened | `2026-10-15T17:39:32Z`, state `open` |
| merged | **no.** Nothing was merged, and `main` was never pushed to from this session. |
| final content | `code/docs/GITHUB.md` (new) + `code/docs/REPRODUCE.md` (numbers refreshed for the released revision) |

### How it was built, and how it became out of date

The branch was created with `POST /git/refs` from `main` at `f94f9121` and four
commits were added through `PUT /repos/{owner}/{repo}/contents/{path}`, one per
file change. The local working tree was never touched by any of it. `ci.yml` ran
green three times: **#19** (`9130cc85`), **#20** (`0eda6a57`), **#21**
(`a837000a`).

| commit | change |
| --- | --- |
| `a731d658` | `code/docs/PROVIDER_PROBE.md` added |
| `9130cc85` | `code/docs/REPRODUCE.md` recording step fixed |
| `0eda6a57` | `code/docs/REPRODUCE.md` coverage numbers refreshed from run #18 |
| `a837000a` | `code/tests/eval/oracle_node_bytes.mjs` Node-oracle fix (§6.1) |

While this was in flight, `main` advanced to **`cce9ba67`** (`Add streaming
semantic safety runtime`, 63 files, `+11769 −3178`) and **`Release v0.6.0`**
run #10 succeeded on the `v0.6.0` tag. That commit took the whole shared working
tree, so all four changes landed on `main` before the pull request was reviewed.
Verified by content hash: `code/docs/PROVIDER_PROBE.md`,
`code/docs/REPRODUCE.md`, `code/tests/eval/oracle_node_bytes.mjs`,
`.github/workflows/nightly.yml` and `.github/workflows/ci.yml` on `cce9ba67` are
**byte-identical** to this session's working-tree copies. Checked against the
API with `GET /repos/…/contents/<path>?ref=cce9ba67` and a SHA-256 comparison.

So the branch was rebased from `main` (`cce9ba67`), and the pull request now
carries only what is genuinely new: this document, plus the `REPRODUCE.md`
numbers refreshed for the revision that was actually released (§5). Nothing was
merged, and the branch is left open for review.

## 3. Nightly run

| field | value |
| --- | --- |
| run | **`38778966871`**, `Nightly long run` #**1** |
| URL | <https://github.com/wenhuang2333/Moonbit-haker/actions/runs/38778966871> |
| trigger | `POST /repos/wenhuang2333/Moonbit-haker/actions/workflows/nightly.yml/dispatches` with `{"ref":"main"}` → HTTP `204` |
| queued / finished | `2026-10-15T17:38:06Z` → `2026-10-15T17:43:47Z` (5 m 41 s) |
| conclusion | **`failure`** |

| job | result | detail |
| --- | --- | --- |
| `Property tests at scale` (`longrun`) | **success** | `JSONMEND_LONGRUN=1000000`, `Total tests: 129, passed: 129, failed: 0` on both `--target native` and wasm-gc |
| `Differential and evaluation` (`differential`) | **failure** after 27 s | `run_diff.py: error: the following arguments are required: --cli` (exit 2) |

### Why the differential job failed

`.github/workflows/nightly.yml` wrote its line continuations as `\\` inside a
YAML `run: |` block scalar. In a literal block scalar a backslash is literal, so
bash received each `\\` as an escaped backslash *argument*, which terminates the
command at the first line:

```
python3 tests/diff/run_diff.py \  --cli ./…jsonmend.exe \  --node-module-dir "…" \  --out "…"
```

`--cli` therefore became its own command and never reached `run_diff.py`. This
is a blocking defect on every dispatch, not an environment problem, and it had
never been exercised: this was the workflow's first run, which is also why the
schedule had never caught it.

Fixed in the working tree (single `\` in the `Differential report` and
`Ground truth evaluation` steps) and landed on `main` as part of `cce9ba67`
(`nightly.yml +4 −4`). Verified by parsing the file with PyYAML and splitting the
resulting shell string: both steps now yield `--cli` in their argv, and no
double-backslash continuation is left in any of the three workflows.

## 4. CI logs: run `38759105731` (`ci.yml` #18, `main`, `f94f9121`)

Fetched with `GET /repos/{owner}/{repo}/actions/runs/38759105731/logs`
(HTTP `200`, **30 971 bytes**) and unzipped into `test/ci_logs/`. The archive
holds the two job logs and their `system.txt` files. Its
`differential-report` artifact (id `11984163733`, 10 345 bytes) was fetched too.

### Test counts — all agree with the repository

| what | CI log says | documented where | verdict |
| --- | --- | --- | --- |
| `moon test` on wasm-gc / native / js | `Total tests: 129, passed: 129, failed: 0` (three times, once more under coverage) | `REPRODUCE.md` §2 "期望：129 个测试全部通过" | **match** |
| `bash tests/cli_smoke.sh` | `62 passed, 0 failed` | `REPRODUCE.md` §3 "62 项断言" | **match** |
| `bash tests/examples.sh` | 6 `ok` lines, `6 passed, 0 failed` | `REPRODUCE.md` examples section | **match** |
| demo bundle smoke | `demo bundle smoke test passed` | `REPRODUCE.md` §6 | **match** |

### Coverage — the documented numbers were stale

| command | CI run #18 | `REPRODUCE.md` said | verdict |
| --- | --- | --- | --- |
| `moon coverage report -f summary -p zhanshishan/jsonmend` | `Total: 2371/2661` = **89.1 %** | `2312/2651` = 87.2 % | **mismatch, stale** |
| `moon coverage report -f summary` | `Total: 2708/3469` = **78.1 %** | `2649/3415` = 77.6 % | **mismatch, stale** |
| `… -p zhanshishan/jsonmend/llm` | not run in CI | `337/391` = 86.2 % | **match**, reproducible: the six `llm/*` rows of the full report sum to 337/391 |

The library package was 59 covered lines and 10 total lines ahead of the
documented revision, and `bench/main.mbt` was 417 lines rather than 373 — the
documented figures described an earlier commit, not a different command.

`code/docs/TRACEABILITY.md` carried a much older set in `NFR-TEST-01`:
`1378/1487 = 92.7 %`, `223/243 = 91.8 %`, `1601/2002 = 80.0 %`, disagreeing with
`REPRODUCE.md` as well as with the log. That file was owned by another writer, so
the numbers were reported rather than edited.

### Independent corpus and differential report — reproduced from the artifact

* differential report: **402** cases (99 hand-written + 303 mutations), **202**
  divergences, **202** with a documented cause, **0 unexplained**,
  documented-scope agreement **100.0 %**, agreement with the Node `jsonrepair`
  oracle **236/395 = 59.7 %**. It agrees with what `REPRODUCE.md` §5 describes.
* independent corpus: 318 files (95 `y_`, 188 `n_`, 35 `i_`), `y_` false repairs
  **2**, `n_` valid-value production **jsonmend 165/188**, `json_repair`
  166/188. These match `TRACEABILITY.md` FR-38 exactly.
* **but** the CI copy of `EVAL_INDEPENDENT.md` reported the Node oracle as
  `n/a (library not installed)`, listed 0 strict-oracle disagreements instead of
  12, and dropped the 8-file table — so the committed document could not be
  reproduced by CI at all. Root cause and fix in §6.1.

### Benchmark — off the documented range on this runner

`tests/bench.sh native` in the same job: `analyze` 1.00×, `analyze for_agent`
1.47×, `analyze +schema` 1.47×, `semantic_readiness` **31.69×** `repair`.
`BENCHMARK.md` documents 1.33–1.36×, 1.38–1.45× and 32.7–34.3×, measured on this
workstation; the CI runner lands slightly outside those ranges. Informational —
no threshold is implicated except NFR-PERF-08, which has none.

## 5. The newest completed run: `38781104341` (`ci.yml` #22, `main`, `cce9ba67`, v0.6.0)

Fetched the same way (`test/ci_logs22/`, 75 257 bytes) after `main` moved. This is
the run that describes the **released** revision, and it differs from run #18 on
every headline number:

| metric | run #18 (`f94f9121`) | run #22 (`cce9ba67`, v0.6.0) | documented at `cce9ba67` |
| --- | --- | --- | --- |
| `moon test`, each backend | 129 passed | **170 passed** | `REPRODUCE.md` said 129 | 
| `tests/cli_smoke.sh` | 62 passed | **77 passed** | `REPRODUCE.md` said 62 |
| `tests/examples.sh` | 6 passed | 6 passed | 6 |
| coverage, library package | `2371/2661` = 89.1 % | **`2850/3063` = 93.0 %** | `REPRODUCE.md` said `2371/2661` |
| coverage, including bench | `2708/3469` = 78.1 % | **`3187/3907` = 81.6 %** | `REPRODUCE.md` said `2708/3469` |
| coverage, `llm` package | `337/391` = 86.2 % | `337/391` = 86.2 % | matches |
| `bench/main.mbt` in the denominator | 0/417 | 0/453 | — |

So the documents committed *in* `cce9ba67` quoted the previous revision's
measurements: the release shipped with a reproduction guide that says 129 tests
and 62 assertions while its own CI measured 170 and 77, and with coverage figures
59 lines and 4 percentage points behind. The Node oracle also appears for the
first time in a `main` differential job (`jsonrepair 144/188`), which is the fix
from §6.1 running on the released commit; run #18 logged `n/a`.

`REPRODUCE.md`'s test count, assertion count and coverage block were updated to
the run-#22 figures and now cite the run id, the SHA and the timestamp. All other
numbers in `TRACEABILITY.md`, `BENCHMARK.md` and the READMEs belong to the
writers who own those files.

Per-file rows the log does contain, for the Q-28 policy in issue #1. One caveat
first: the `-p` rows printed in run #22 sum to `2780/2993` against the same
report's `Total: 2850/3063`, so exactly 70/70 is missing from the log itself
(run #18's rows sum exactly to its total). `decision.mbt` and `policy.mbt` are the
two module rows run #18 printed and run #22 does not — run #22 replaced them with
the new `stream_readiness.mbt` row — so the missing figures are in those two
files and cannot be read from this log. Both files still exist on `main`; they
were not merged away.

| file | coverage | file | coverage |
| --- | --- | --- | --- |
| `engine.mbt` | 147/151 = 97.4 % | `schema.mbt` | 397/415 = 95.7 % |
| `error.mbt` | 220/231 = 95.2 % | `options.mbt` | 59/62 = 95.2 % |
| `engine_flow.mbt` | 749/797 = 94.0 % | `plan.mbt` | 489/526 = 93.0 % |
| `text.mbt` | 126/137 = 92.0 % | `hint.mbt` | 68/75 = 90.7 % |
| `api.mbt` | 85/94 = 90.4 % | `readiness.mbt` | 106/118 = 89.8 % |
| `stream_readiness.mbt` | 258/288 = 89.6 % | `delta.mbt` | 76/99 = 76.8 % |

The "core ≥ 90 %" rule in issue #1 is met by `plan` and `schema` at this
revision; `delta.mbt` at 76.8 % is the lowest module, and the library package as a
whole (93.0 %) clears the 85 % overall rule.

## 6. Defects found by these logs

### 6.1 The Node oracle never ran in CI (fixed; landed on `main` in `cce9ba67`)

`code/tests/eval/oracle_node_bytes.mjs` imported the package with a bare ESM
specifier:

```js
import { jsonrepair } from "jsonrepair";
```

`run_independent.py` supplies the package directory through `NODE_PATH` and
`cwd`, but **the ESM resolver ignores `NODE_PATH`** — that variable is CommonJS
only. The import therefore succeeded only when `jsonrepair` happened to sit in a
`node_modules` above the script. On this machine an unrelated
`/Users/zhanshishan/node_modules/jsonrepair` made it work by accident; in CI the
package is installed into `$RUNNER_TEMP/node-oracle`, so the oracle failed with
`ERR_MODULE_NOT_FOUND`.

`run_node_oracle` treats that as a degradation rather than a failure, so it only
printed a note and the column became `n/a`. Reproduced in a layout with no
`jsonrepair` above the script (`/var/tmp/ci-sim`, chosen because it is outside
both `/private/tmp` and `/Users/zhanshishan`):

```
before:  n_ valid-value production: jsonmend 165/188; json_repair 166/188; jsonrepair n/a (library not installed)
after:   n_ valid-value production: jsonmend 165/188; json_repair 166/188; jsonrepair 144/188
```

The fix loads the package through `createRequire`, whose resolution is CommonJS
and does honour `NODE_PATH`, over a candidate list mirroring
`code/tests/diff/run_diff.py::find_node_modules`. Both meanings of `--node-dir`
are accepted, because the scripts in that directory disagree about whether it
names `node_modules` itself or the directory holding it.

**Confirmed in real CI, twice.** PR run `38780953849` (`ci.yml` #21) was the
first run in the repository's history whose differential job logged `jsonrepair
144/188`; after `cce9ba67` carried the fix to `main`, run `38781104341` (#22)
logged the same value while run #18 had logged `n/a`. With the fix, a regenerated
report matches the committed `EVAL_INDEPENDENT.md` line for line apart from its
timestamp, the binary hash and the `NODE_PATH` label. Only the `.mjs` file was
changed; `code/tests/eval/run_independent.py` was being edited by another writer
and was left alone.

### 6.2 `--node-dir` is still passed in the wrong form (reported, not changed)

`ci.yml` still passes `--node-dir "$RUNNER_TEMP/node-oracle/node_modules"`, but
`run_independent.py` documents `--node-dir` as "directory **holding**
`node_modules/jsonrepair`" and appends `node_modules` to it, so `NODE_PATH`
becomes `…/node-oracle/node_modules/node_modules`. The correct value is
`"$RUNNER_TEMP/node-oracle"`. `run_diff.py` uses a differently named flag
(`--node-module-dir`) with the opposite convention and is correct as written.
The `.mjs` fix makes either spelling resolve, but the flag value still
mislabels the report, and a `run_ambiguity.py` call given the same value would
still fail. Left to the CI owner: the step is not mine to change.

### 6.3 The ambiguity suite's reference columns are dead in CI (reported)

`run_ambiguity.py` is called without `--node-dir`, so it uses the developer
default `/private/tmp`; in CI that fails `os.path.isdir` and both comparison
columns collapse:

```
note: jsonrepair column unavailable (node module directory /private/tmp does not exist)
note: json_repair column unavailable (module not installed)
| ambiguous cases answered silently by `jsonrepair` | n/a (library not installed) |
| ambiguous cases answered silently by `json_repair` | n/a (library not installed) |
```

`json_repair` is n/a because the `MoonBit (check, test, CLI, demo)` job never
installs it — only the differential job does. The suite still passes (its own
criteria are about JSONMend's verdicts, and 10/10 ambiguous cases are flagged and
refused by the gate), but the comparison table is empty in every CI run. Same
class as §6.1: a reference oracle degrades to `n/a` instead of failing, so the
degradation is invisible unless someone reads the log.

## 7. What is not done

* **Nothing was merged** and `main` was never pushed to from this session. PR #2
  is open for review on top of `cce9ba67`.
* **`--node-dir` in `ci.yml`** (§6.2) and the ambiguity suite's columns (§6.3) are
  reported, not fixed: existing CI steps belong to another writer.
* **The nightly workflow still has not had a green dispatch.** Its blocking bug
  is fixed and on `main`, but the run recorded here is the red one; one more
  `workflow_dispatch` against `cce9ba67` would confirm the fix end to end.
* **Coverage and test counts in `TRACEABILITY.md`, `BENCHMARK.md` and the
  READMEs** are one revision behind `main` the same way `REPRODUCE.md` was.
  Reported; those files have other owners.
* **No first-party vendor capture exists.** This work clears the process debt
  around the provider gap (`code/docs/PROVIDER_PROBE.md`); it cannot create a
  credential that is not there.
