# Security

JSONMend is built to process **untrusted input**: model output, logs, partial
network payloads, user files. The threat model is therefore about what hostile
or damaged input can make the parser do, not about authentication.

## What the library guarantees

- **No panic on any input.** Every byte sequence either produces a result or
  raises one of the documented `MendError`s. The fuzz suite (TC-P-06, 100 000
  random token sequences) asserts that no internal error (`E030`) escapes and
  that no process crash occurs.
- **Bounded work.** `max_depth`, `max_input_len` and `max_token_len` cap nesting,
  total input and single-token size; exceeding them raises `E020`/`E021`/`E022`
  instead of allocating without limit. The record list is capped at 10 000
  entries.
- **No code execution, no I/O.** Repair is pure text transformation. There is no
  `eval`, no dynamic loading, and the library never opens files or sockets.
- **Log injection is not possible through messages.** Repair messages are fixed
  English templates; they never interpolate input text. Error messages embed
  positions and codes only.
- **No third-party runtime dependencies.** The only dependency is the MoonBit
  standard library. `jsonrepair` and `json-repair` are used exclusively as
  out-of-process test oracles and are never linked into the product.

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
