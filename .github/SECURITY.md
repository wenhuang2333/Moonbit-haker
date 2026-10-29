# Security

InterJSON is built to process **untrusted input**: model output, logs, partial
network payloads, user files. The threat model is therefore about what hostile
or damaged input can make the parser do, not about authentication.

## What the library guarantees

- **No panic observed, and the claim is bounded by the budget that was run.**
  Every byte sequence either produces a result or raises one of the documented
  `InterJSONError`s — that is the design, and these are the tests behind it.
  They are empirical, so the honest claim is "no panic observed in N cases", not
  "no panic on any input"; the budget is stated with each suite below and again
  in the paragraph after the table. Two suites cover it:

  | Suite | What it generates | Default budget | CI | Nightly |
  | --- | --- | --- | --- | --- |
  | `prop_wbtest.mbt` (TC-P-00…09) | *strings* that look like damaged JSON: valid documents, mutated documents, truncated documents, token soup | 400 cases per property, 8 properties | 400 | 1 000 000 (`INTERJSON_LONGRUN`) |
  | `fuzz_wbtest.mbt` (TC-F-01…05) | *arbitrary bytes* — pure noise, noise around JSON syntax, and valid UTF-8 cut at arbitrary offsets — fed at chunk sizes 1, 2, 3, 5, 7, 13, 16 and 64 so a boundary lands inside every multi-byte sequence | 300 cases per property, 5 properties | 2 000 (`INTERJSON_FUZZ=2000`) | 100 000 (`INTERJSON_FUZZ=100000`) |

  TC-F-01 is the panic gate: 3 byte shapes × 5 chunk sizes × the case count, per
  run. The property suite's token-soup property (TC-P-06) additionally asserts
  that no internal error (`E030`) escapes.

  The default local run is 300 fuzz cases × 15 (3 shapes × 5 chunk
  sizes) = 4 500 byte-level parses per property, plus the property suite's
  400 cases per property. CI raises the fuzz budget to 2 000 cases (30 000
  byte-level parses) and the nightly to 100 000. Every generator is seeded, so
  a failure is reproducible from the printed bytes. The claim is a strong
  empirical one, and it is bounded by the budget that was actually run.
- **Bounded work.** `max_depth`, `max_input_len` and `max_token_len` cap nesting,
  total input and single-token size; exceeding them raises `E020`/`E021`/`E022`
  instead of allocating without limit. The record list is capped at 10 000
  entries.
- **Recursion is bounded by construction, and the bound is not a stack bound.**
  Every walk over a value — the copy, the comparison, the schema evaluation and
  the renderer — carries an explicit work list instead of recursing, so the
  depth a caller may configure is bounded by the heap and not by the native
  stack. `Options::max_depth` can therefore be loosened: a 100 000-level
  document parses, renders and compares on every backend. The ceiling that
  remains (`MAX_VALUE_DEPTH`, `MAX_SCHEMA_DEPTH` in `code/options.mbt`) is a
  sanity bound, so that a typo cannot ask for an allocation the machine cannot
  make; a value above it is refused with `E050`.
  Declarations (JSON Schema or the library's skeleton language) are still read
  by two recursive parsers, so they keep a real bound and are refused with
  `E070` past `MAX_SCHEMA_DEPTH`.
  This used to be the other way round: the walks were recursive, the wasm
  backend's stack overflowed between 896 and 1024 frames, and `max_depth` had
  to be capped at 512 to keep "a refusal, never a crash" true — which meant a
  caller could tighten the limit but never loosen it. `code/docs/NOTREE.md`
  records that history and what is still open.
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
- The CLI reads the whole input into memory and builds a tree, so peak usage is a
  multiple of the input size (measured by `tests/memory_gate.py`; the full report is
  in `docs/MEMORY.md`, maintained in the repository and not published); do not point it
  at an unbounded stream.
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
