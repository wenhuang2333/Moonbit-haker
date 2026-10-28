// The version, in one place.
//
// It used to live in five: this library had `ENGINE_VERSION` in the CLI's
// `serve.mbt`, the CLI's `--version` had a literal in `main.mbt`, `moon.mod`
// had its own `version`, and `code/npm/package.json` and
// `code/python/pyproject.toml` had theirs. Four of the five were checked
// against `moon.mod` by `tests/cli_smoke.sh`, which is why they stayed in
// step -- but a check that compares five literals is a check that can only
// tell you they disagree, never which one is right, and the version is read
// by `mooncakes`, by npm, by PyPI and by the MCP `serverInfo` handshake, so
// "which one is right" is a question with consequences.
//
// The library is now the source: everything in MoonBit reads `VERSION` from
// here, and `moon.mod`, `package.json` and `pyproject.toml` are the three
// remaining literals -- the three that no compiler can reach, because they
// are read by other package managers. `tests/cli_smoke.sh` asserts all four
// agree, and `tests/claims.sh` asserts the documents quote the same number.

///|
/// The version of this release. GitHub tags it `v1.5.0`.
pub const VERSION : String = "1.5.0"

///|
/// The mooncakes version that corresponds to `VERSION`.
///
/// mooncakes currently refuses a major version other than `0`
/// (`In this very early stage, the major version must be '0'`), so the
/// registry counterpart of `1.5.0` is `0.12.0`. The mapping is fixed by the
/// release order -- `1.1.x` ↔ `0.8.x`, `1.2.x` ↔ `0.9.x`, `1.3.x` ↔ `0.10.x`,
/// `1.4.x` ↔ `0.11.x`, `1.5.x` ↔ `0.12.x` -- and `serve`'s `hello` reports
/// both, so a client can always tell which registry build it is talking to.
pub const REGISTRY_VERSION : String = "0.12.0"
