# Pitch and judge Q&A

This is the 3-minute script and the answer sheet for the questions that
actually get asked. Every number has a command or a document behind it; do not
quote one you cannot reproduce.

## One sentence

**JSONMend turns "almost correct" LLM JSON into a value you can execute — and
when it cannot do that safely, it refuses and tells the model exactly what to
change.**

## 30 seconds

> Models emit JSON that is *almost* right: fences, single quotes, trailing
> commas, and — the expensive one — truncation at `max_tokens`. jsonrepair and
> json_repair fix the text. JSONMend answers the next question: **may I execute
> this?** It labels every repair Exact/Cosmetic/Lossy, detects two-reading
> ambiguity, checks the tool's schema, and in execution mode refuses instead of
> guessing. The refusal is a prompt you can send straight back to the model.
> One engine, pure MoonBit, four backends, zero dependencies.

## 3 minutes

| Time | Beat | What to show |
| --- | --- | --- |
| 0:00–0:20 | The problem | A truncated tool call: `{"amount":100,"currency":"USD"` — parsing fails, retrying is expensive, guessing is worse |
| 0:20–0:50 | The wedge | `live.html`: four scenes frame by frame; the gate says `lossy_repair`, `E010`, and prints the retry prompt |
| 0:50–1:30 | The difference | `execution` vs `permissive`: the same document is repaired for display and refused for execution; exactness + ambiguity + schema are one call |
| 1:30–2:10 | The agent path | `mcp.html`: `claude mcp add jsonmend -- jsonmend mcp`; model args refused; retry; execute. Then `npm`/`pip`/`serve` as the host-side path |
| 2:10–2:40 | The evidence | 210 tests on each of four backends; 1200-case preregistered eval at 100%; 402 differential cases with 202/202 explained; 18 protocol conformance groups; coverage gate 93.2% |
| 2:40–3:00 | Why MoonBit | one engine → wasm-gc 101.4 KiB library, native CLI, browser bundle, protocol process; `moon info` freezes the public surface |

Close on the sentence, not on a feature list.

## Judge Q&A

**"Why not just use jsonrepair?"**
It repairs finished text. JSONMend is an execution gate: `safe /
cosmetic_repair / lossy_repair / ambiguous / invalid`, plus `valid_json` vs
`normalized` (a document can be legal JSON and still have no single meaning —
duplicate keys), plus schema readiness. The two are complementary; the
differential report tells you exactly where they differ and why.

**"How do you know it doesn't silently produce a wrong value?"**
In execution mode it refuses anything that invents or drops information
(`E010`), anything with two readings (`E011`), and anything that violates the
declared schema (`E070`). The refusal carries a position, a context snippet
and a ready-to-send retry prompt. The `agent_loop` example runs the whole
refuse → feed back → re-emit → execute loop four times.

**"What is your evidence?"**
- 210/210 tests on each of wasm-gc, native, JS and wasm (840 runs).
- Three property invariants: output is valid JSON, repair is idempotent,
  chunking does not change the result.
- 1200-case preregistered ground-truth evaluation: 100.00% recovery, 0 missed
  labels, all four criteria pass.
- 402 differential cases against jsonrepair and json-repair: 202 divergences,
  all classified and explained.
- Independent `nst/JSONTestSuite`: 318 files, results in
  `docs/EVAL_INDEPENDENT.md`.
- 18 protocol/MCP conformance groups, run on Linux, macOS and Windows.

**"Why MoonBit?"**
One source, four backends: a 101.4 KiB wasm-gc library, a native CLI, a
browser bundle, and a protocol process. No third-party runtime dependencies.
The compiler-generated `.mbti` is committed and CI-checked, so the public API
is a reviewable artifact — which is what makes the 1.0 compatibility promise
mean something.

**"Memory is 18× the input."**
That is the cost of building a `Json` tree; Node's `JSON.parse` is 10.6× and
Python's `json.loads` is 14.3× on the same file. The 4× budget is not
achievable for any tree-building parser; reaching it requires a text-only mode,
which is documented as future work rather than hidden.

**"Is the protocol/ MCP server production-ready?"**
It is v1, single-stream per connection, stdio only, no network surface. The
conformance suite pins the wire format; unknown fields are ignored and major
version mismatches are refused. The HTTP facade is deliberately a separate,
stateless Python wrapper so the binary stays network-free.

**"What did you not do?"**
Full JSON Schema (`$ref`, `oneOf`, `format`), HTTP proxy rewriting provider
streams, multi-stream protocol v2, a no-tree text mode, and rule-count parity
with jsonrepair. Each is a deliberate boundary, documented in
`README.md#known-limitations` and `docs/SPEC.md`.

## Demo checklist

- `live.html` opens with no console errors; four tabs work.
- `mcp.html` shows a refusal (`E010`) and then `executable: true` after
  "模型重发".
- `python3 code/tests/conformance/run_conformance.py` prints
  `18/18 conformance groups passed`.
- `moon test` prints `Total tests: 210, passed: 210`.
- The five entry links are 200: README → live demo → mcp demo → mooncakes →
  Release.

## Don't say

- "100% accurate." Say: **100% recovery on the preregistered corpus; zero
  silent execution in the execution profile.**
- "Fixes any JSON." Say: **repairs or refuses, never guesses.**
- "Production-ready at any scale." Say: **v1, single stream, local process.**
