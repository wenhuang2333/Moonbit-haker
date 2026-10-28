# Security

InterJSON is built to process **untrusted input**: model output, logs, partial
network payloads, user files. The threat model is therefore about what hostile
or damaged input can make the parser do, not about authentication.

## What the library guarantees

- **No panic on any input — and this one is tested, not asserted.** Every byte
  sequence either produces a result or raises one of the documented
  `InterJSONError`s. Two suites cover it:

  | Suite | What it generates | Default budget | CI | Nightly |
  | --- | --- | --- | --- | --- |
  | `prop_wbtest.mbt` (TC-P-00…09) | *strings* that look like damaged JSON: valid documents, mutated documents, truncated documents, token soup | 400 cases per property, 8 properties | 400 | 1 000 000 (`INTERJSON_LONGRUN`) |
  | `fuzz_wbtest.mbt` (TC-F-01…05) | *arbitrary bytes* — pure noise, noise around JSON syntax, and valid UTF-8 cut at arbitrary offsets — fed at chunk sizes 1, 2, 3, 5, 7, 13, 16 and 64 so a boundary lands inside every multi-byte sequence | 300 cases per property, 5 properties | 2 000 (`INTERJSON_FUZZ=2000`) | 100 000 (`INTERJSON_FUZZ=100000`) |

  TC-F-01 is the panic gate: 3 byte shapes × 5 chunk sizes × the case count, per
  run. The property suite's token-soup property (TC-P-06) additionally asserts
  that no internal error (`E030`) escapes.

  **The honest claim is "no panic observed in N cases", not "no panic on any
  input".** The default local run is 300 fuzz cases × 15 (3 shapes × 5 chunk
  sizes) = 4 500 byte-level parses per property, plus the property suite's
  400 cases per property. CI raises the fuzz budget to 2 000 cases (30 000
  byte-level parses) and the nightly to 100 000. Every generator is seeded, so
  a failure is reproducible from the printed bytes. The claim is a strong
  empirical one, and it is bounded by the budget that was actually run.
- **Bounded work.** `max_depth`, `max_input_len` and `max_token_len` cap nesting,
  total input and single-token size; exceeding them raises `E020`/`E021`/`E022`
  instead of allocating without limit. The record list is capped at 10 000
  entries.
- **Recursion is bounded by construction.** `Options::max_depth` has a hard
  ceiling of `MAX_VALUE_DEPTH = 512` — which is also the documented default, so
  a caller can tighten it but not loosen it; a larger value is refused with
  `E050` rather than risking a stack overflow. Declarations (JSON Schema or the
  library's skeleton language) are bounded by `MAX_SCHEMA_DEPTH = 256` and
  refused with `E070`. The reason for the ceiling is measured, not guessed: the
  wasm backend's stack overflows in a recursive walk somewhere between 896 and
  1024 frames.
- **No code execution, no I/O.** Repair is pure text transformation. There is no
  `eval`, no dynamic loading, and the library never opens files or sockets.
- **Log injection is not possible through messages.** Repair messages are fixed
  English templates; they never interpolate input text. Error messages embed
  positions and codes only.
- **No third-party runtime dependencies.** The only dependency is the MoonBit
  standard library. `jsonrepair` and `json-repair` are used exclusively as
  out-of-process test oracles and are never linked into the product.

## The MCP server

`interjson mcp` is a **local** stdio server: it opens no sockets, makes no
network calls and needs no API key, so inputs and tool declarations never leave
the machine. It exposes four **read-only** tools — `interjson_gate` (primary,
defaults to the `agent` profile), `interjson_repair`, `interjson_validate` and
`interjson_readiness` — and none of them writes files or executes the repaired
value; the host decides what to do with an allowed result. stdout carries
JSON-RPC only and diagnostics go to stderr, so a client cannot mistake a log
line for a protocol message. The untrusted-input guarantees above apply
unchanged, including panic-freedom and the bounded-work limits.

**MCP is advisory, and that is a security property a reader should know.**
`interjson_gate` is a tool the model *may* call. A model can decline to call it,
and the MCP protocol gives the host no way to make the call mandatory — so
"the client is configured for InterJSON" means "the gate is available", not
"every tool call passed the gate". There is no configuration of this server
that changes that. What makes the gate mandatory is a host-side insertion point
the model cannot route around: a Claude Code `PreToolUse` hook, a `gate(args)`
call in the host SDK, or `interjson serve` / the npm and pip packages / the HTTP
facade. Recipes are in `code/docs/INTEGRATIONS.md`.

The server also does not protect you from *valid* JSON with the wrong values:
it checks syntax, exactness, ambiguity and the declared schema, and it cannot
know that `{"amount": 100}` should have been `1000`.

## Known limits

- The parser is **not thread-safe**: one `PartialParser` per stream.
- `snapshot()` copies the current tree; calling it per byte on a large document
  is O(tree) per call and can be used for a denial of service by the *caller*.
  Poll at a sane rate (the benchmark measures 1 KB and 64 KB intervals).
- The CLI reads the whole input into memory. Peak usage is roughly 18 times the
  input size (see `docs/BENCHMARK.md`); do not point it at an unbounded stream.
- Lone surrogates and invalid UTF-8 are replaced rather than rejected in some
  paths; the `E040` code only covers byte-level decoding failures.

## Reporting a problem

Open a private security advisory on the repository, or, if that is not
available, an issue that states only that you have a security report and how to
reach you. Please include:

- the exact input (as bytes if it is not valid UTF-8) and the options used;
- the backend (wasm-gc / native / JS) and the toolchain version;
- what happened and what you expected;
- whether it is a crash, an unbounded allocation, or incorrect output.

There is no bug bounty. Acknowledgement is best effort, but reports about
crashes, unbounded memory use and output that is not valid JSON are always
prioritised.
