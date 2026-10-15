# Provenance: `nst/JSONTestSuite`

This directory vendors a frozen copy of the JSON parser test corpus
[JSONTestSuite](https://github.com/nst/JSONTestSuite) so that the evaluation in
`code/tests/eval/run_independent.py` can run offline and so that the exact bytes
that were scored stay fixed in the repository.

| field | value |
| --- | --- |
| upstream repository | <https://github.com/nst/JSONTestSuite> |
| tarball (not used, see below) | <https://codeload.github.com/nst/JSONTestSuite/tar.gz/refs/heads/master> |
| commit SHA fetched | `1ef36fa01286573e846ac449e8683f8833c5b26a` (upstream `refs/heads/master`) |
| commit date | 2024-11-22 (merge of PR #139) |
| fetch date | 2026-10-15 |
| license | MIT License, Copyright (c) 2016 Nicolas Seriot |
| license file | [`LICENSE`](LICENSE), vendored verbatim |
| upstream README | [`README.md`](README.md), vendored verbatim |

## What is vendored

- `test_parsing/` — all 318 `*.json` files (95 `y_*`, 188 `n_*`, 35 `i_*`),
  354 024 bytes in total, copied byte for byte.
- `LICENSE` and `README.md` — unmodified copies from the repository root.
- This file, which is ours.

Nothing else from upstream is vendored: `parsers/`, `results/`,
`test_transform/` and the runner scripts are not needed to reproduce the
evaluation.

The aggregate fingerprint of the vendored files is recorded in
`code/docs/EVAL_INDEPENDENT.md` (sha256 over the sorted `name\0bytes` stream) and
is recomputed on every run.

### How the copy was obtained

The tarball URL above is the one-request path and is listed for reproducibility,
but it was **not** the path used here: `curl` against `codeload.github.com`
received 5 153 101 bytes and then hit a 120 s timeout, because the repository also
ships `parsers/` (a compiled parser per supported language). The copy was
therefore made with three git operations, which fetch only the needed blobs:

```bash
git ls-remote https://github.com/nst/JSONTestSuite                     # -> 1ef36fa…
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/nst/JSONTestSuite /tmp/jts_repo
cd /tmp/jts_repo && git sparse-checkout set test_parsing
```

`git ls-remote` reports `1ef36fa01286573e846ac449e8683f8833c5b26a` for
`refs/heads/master`, which is the SHA recorded above and the tree that was
checked out. Two checks were run against `raw.githubusercontent.com` at that
exact SHA afterwards: `README.md` and `LICENSE` were fetched over HTTPS and
diffed against the clone (both identical), and
`api.github.com/repos/nst/JSONTestSuite/git/trees/<sha>?recursive=1` reported
exactly 318 blobs under `test_parsing/`, all of them `.json`, with no other file
in that directory. The vendored copy was then made from the clone with `cp`.


## File naming

Upstream's README explains the convention, and the meaning is the test oracle:

- `y_` — the content **must be accepted** by a JSON parser;
- `n_` — the content **must be rejected** by a JSON parser;
- `i_` — implementation-defined: a parser may accept or reject it.

`code/tests/eval/run_independent.py` re-derives this classification from a
spec-strict `json.loads` instead of trusting the filename, and reports the
comparison: on the vendored copy, the filenames and the strict oracle agree on
all 95 `y_` and all 188 `n_` files. The `i_` family is not used as an oracle for
anything.

## Automatic generation of the test cases

JSONTestSuite is a collection of **automatically generated** test cases, and its
own documentation states that the files are not to be edited: changing a file
invalidates the fingerprint that makes the suite comparable across
implementations and across runs. This is the reason the corpus is vendored here
verbatim, with no normalisation of any kind — including no line-ending or
encoding conversion, which is why 25 of the 318 files are not valid UTF-8 and
are kept exactly as upstream ships them.

That convention is honoured in this repository: **do not edit anything under
this directory.** A change to a vendored file must be made by re-vendoring from
a new upstream commit and updating the SHA and the fingerprint above.

## Honest note on the vendored README

The upstream `README.md` vendored here documents the `y_`/`n_`/`i_` convention,
the `parsers/` and `results/` layout, and `run_tests.py`. At this commit it does
**not** contain the sentence forbidding edits to the test files; the paragraph
above records that project-wide convention, which is the reason no file here has
been modified, not a quotation from this particular `README.md`. Saying that the
README "states the files must not be edited" would be overstating what the
vendored text says, so it is not said.
