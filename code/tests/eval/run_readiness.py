#!/usr/bin/env python3
"""Schema readiness: how much of a tool-call stream a gate really needs.

Drives the release CLI and parses the three readiness numbers it prints next to
the field curve. The point of the measurement is the gap between them: a document
is "syntax ready" only when the value InterJSON has committed to is the value the
document ends with, whereas a declared argument is "settled" as soon as its own
value can no longer change, and "schema ready" only once every declared argument
is settled *and* has the declared kind. A caller that knows its skeleton can
therefore stop reading (and stop generating) long before the JSON is closed.

Since 0.6.0 the CLI prints `settled` between the two, because the batch reading
conflated two different questions: a document whose declared member settles early
but with the wrong kind is decidable *and invalid*, and `schema ready` reports it
as `1000` — "not before the end" — when the truth is "this was decided long ago,
and the answer is no" (FR-39).

    python3 code/tests/eval/run_readiness.py --cli /tmp/interjson
    python3 code/tests/eval/run_readiness.py --cli /tmp/interjson --check
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

READY = re.compile(
    r"syntax-ready (\d+)/1000 settled (\d+)/1000 schema-ready (\d+)/1000 "
    r"declared (\d+)/(\d+) ok=(true|false) step (\d+)"
)

# The three 0.6.0 cases are addressed by name in `--check`, so keep them here.
WRONG_KIND = "declared member, wrong kind"
ABSENT_INNER = "declared member, absent in a container"
ABSENT_ROOT = "declared member, absent at the root"

# The long tail every "the model keeps talking" case ends with.
TAIL = "The user asked for the language home page, not the package registry. " * 3

# (name, what the case is for, schema declaration, payload)
#
# A `what it shows` note may use `{bytes}`, `{syntax}`, `{settled}`, `{schema}`,
# `{declared}` and `{total}`: they are filled from the measured row, so the note
# can name the number it is explaining instead of gesturing at it.
CASES = [
    (
        "search, long tail",
        "the two arguments are done a fifth of the way in",
        "{!query:string,!limit:integer}",
        '{"query":"MoonBit","limit":10,"note":"' + TAIL + '"}',
    ),
    (
        "search, tight",
        "nothing after the last argument, so there is nothing to save",
        "{!query:string,!limit:integer}",
        '{"query":"MoonBit","limit":10}',
    ),
    (
        "required argument last",
        "the arguments a gate needs are the last thing the model writes",
        "{!path:string,!pattern:string}",
        '{"note":"'
        + "A long preamble that no tool needs. " * 6
        + '","path":"/srv/app","pattern":"**/*.mbt"}',
    ),
    (
        "three arguments",
        "the third argument is long and optional",
        "{!function:string,!args:{!file:string}}",
        '{"function":"read_file","args":{"file":"/srv/app/main.mbt"},"reason":"'
        + "explain the entry point. " * 8
        + '"}',
    ),
    (
        "nested arguments",
        "a nested object is only ready when its own closer arrives",
        "{!tool:string,!input:{!file:string,!limit:integer}}",
        '{"tool":"read","input":{"file":"/srv/app/main.mbt","limit":200},"trace":'
        + json.dumps("x" * 240)
        + "}",
    ),
    (
        "truncated by max_tokens",
        "the stream stops before the value is closed",
        "{!function:string,!args:{!query:string}}",
        '{"function":"search","args":{"query":"MoonBit tools"',
    ),
    (
        "fenced and prefixed",
        "a chatty model: a sentence, then a fence",
        "{!city:string,!units:string}",
        "Sure, here you go:\n```json\n"
        '{"city":"Osaka","units":"metric","wordy":"'
        + "Some prose the tool never asked for. " * 4
        + '"}\n```',
    ),
    (
        WRONG_KIND,
        "`limit` is final at {settled}‰ and it is a string where an integer was "
        "declared, so `schema ready` never fires and stays at 1000‰ — which "
        "reads as \u201cnot before the end\u201d when the truth is \u201cdecided, and the answer is "
        "no\u201d. The runtime number is `settled`: the answer arrived at {settled}‰, the "
        "answer is no, and a streaming caller can cancel there instead of reading "
        "the {bytes}-byte tail. This is the case 0.6.0 was written for (FR-39).",
        "{!query:string,!limit:integer}",
        '{"query":"MoonBit","limit":"ten","pad":"' + TAIL + '"}',
    ),
    (
        ABSENT_INNER,
        "`a.c` is never written, but the closer of `a` decides what is inside it, "
        "so the refusal is final at {settled}‰ — while `schema ready` stays 1000‰ "
        "because the skeleton is never satisfied. Together with the wrong-kind "
        "row and the absent-at-the-root row this is a three-way contract: a "
        "wrong kind is decided by its own value, an absent member inside a "
        "container by that container's closer, and an absent root member only by "
        "the end of the input.",
        "{!a:{!b:integer,!c:string}}",
        '{"a":{"b":1},"pad":"' + "y" * 120 + '"}',
    ),
    (
        ABSENT_ROOT,
        "`limit` never appears, and that is *not* decidable early: an open "
        "stream cannot rule out the model writing it, so `settled` is 1000‰ too "
        "and both numbers agree. Unlike `a.c` above there is no container closer "
        "to decide it — only the end of the input does. The three rows together "
        "are the contract: a runtime that treats them the same is either "
        "cancelling too late or too early.",
        "{!query:string,!limit:integer}",
        '{"query":"MoonBit","pad":"' + TAIL + '"}',
    ),
]


def run(cli: str, payload: str, schema: str) -> tuple[str, int]:
    proc = subprocess.run(
        [cli, "explain", "--schema", schema, "--policy", "execution"],
        input=payload,
        capture_output=True,
        text=True,
    )
    return proc.stdout + proc.stderr, proc.returncode


def note(text: str, row: dict) -> str:
    """Fill a note's `{settled}`-style placeholders from the measured row."""
    try:
        return text.format(**row)
    except (KeyError, IndexError):
        return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--out", default=str(Path(__file__).resolve().parents[2] / "docs" / "READINESS.md"))
    ap.add_argument("--check", action="store_true", help="fail on a case with no gap")
    args = ap.parse_args()

    rows = []
    failures = 0
    for name, why, schema, payload in CASES:
        out, rc = run(args.cli, payload, schema)
        m = READY.search(out)
        if not m:
            print(f"FAIL {name}: no readiness line\n{out}", file=sys.stderr)
            failures += 1
            continue
        syntax, settled, schema_p, declared, total, ok, step = (
            int(m.group(1)),
            int(m.group(2)),
            int(m.group(3)),
            int(m.group(4)),
            int(m.group(5)),
            m.group(6) == "true",
            int(m.group(7)),
        )
        executable = '"decision":"safe"' in out or "SAFE TO EXECUTE" in out
        if rc not in (0, 5):
            print(f"FAIL {name}: unexpected exit {rc}\n{out}", file=sys.stderr)
            failures += 1
        rows.append(
            {
                "name": name,
                "why": why,
                "bytes": len(payload),
                "syntax": syntax,
                "settled": settled,
                "schema": schema_p,
                "declared": declared,
                "total": total,
                "ok": ok,
                "step": step,
                "executable": executable,
                "rc": rc,
            }
        )

    def settled_of(name: str) -> str:
        """The measured `settled` of a named row, for the contract table."""
        r = next((x for x in rows if x["name"] == name), None)
        return "n/a" if r is None else f"{r['settled']}\u2030"

    lines = [
        "# Schema readiness",
        "",
        "Generated by `python3 code/tests/eval/run_readiness.py --cli <interjson>`;",
        "do not edit by hand.",
        "",
        "Three different questions, measured on the same stream (FR-36, FR-39):",
        "",
        "- **syntax ready** — the first input fraction at which the value InterJSON",
        "  has *committed* to is the value the document ends with. A member is",
        "  committed once the token after it settles it: a comma, or the closing",
        "  brace. This number is close to 100% for any document, which is why",
        "  valid JSON is the wrong readiness signal.",
        "- **settled** — the first input fraction at which every argument the",
        "  caller *declared* already holds the value it will end up with,",
        "  **whether or not that value has the declared kind**. This is the number",
        "  a runtime acts on: it says when the answer — yes or no — arrived. On a",
        "  long stream it is the moment the caller may cancel the generation.",
        "- **schema ready** — the first input fraction at which every declared",
        "  argument is settled **and** the skeleton is satisfied. It answers \u201cmay I",
        "  execute\u201d, not \u201cdo I know yet\u201d: a document that is decidable and invalid",
        "  never fires it, so it reads `1000‰` — the same value as \u201cnot before the",
        "  end\u201d — even though the refusal was final long before. `settled` is the",
        "  column that tells those two apart, and it was added in 0.6.0 for",
        "  exactly that reason.",
        "",
        "`step` is the sampling granularity (one code unit here, `auto_step` in the",
        "library). Fractions are per mille of the input.",
        "",
        "| case | bytes | syntax ready | settled | schema ready | declared | ok | executable | what it shows |",
        "|---|---:|---:|---:|---:|---:|:--:|:--:|---|",
    ]
    for r in rows:
        lines.append(
            "| {name} | {bytes} | {syntax}‰ | {settled}‰ | {schema}‰ | {declared}/{total} | {ok} | {exe} | {why} |".format(
                name=r["name"],
                bytes=r["bytes"],
                syntax=r["syntax"],
                settled=r["settled"],
                schema=r["schema"],
                declared=r["declared"],
                total=r["total"],
                ok="yes" if r["ok"] else "no",
                exe="yes" if r["executable"] else "no",
                why=note(r["why"], r),
            )
        )
    lines += [
        "",
        "## What the numbers say",
        "",
        "- Where the declared arguments are written early and the model keeps",
        "  talking, a gate can act after a small fraction of the stream: the",
        "  `search, long tail` case is settled at a fraction of the syntax",
        "  fraction, and the syntax fraction stays above 90%.",
        "- Where the last declared argument is the last thing written",
        "  (`search, tight`, `required argument last`), the numbers meet at",
        "  the end. Nothing can be saved, and the table says so instead of",
        "  promising an early stop that is not there.",
        "- The three 0.6.0 rows are the reason `settled` exists, and together they",
        "  read as one three-way contract on the same stream. In all three",
        "  `schema ready` is 1000\u2030, so the batch number alone cannot tell them",
        "  apart; `settled` says when the answer arrived, and the answer is no.",
        "",
        "  | declared member | decided by | `settled` |",
        "  | --- | --- | ---: |",
        f"  | present, wrong kind | its own value | {settled_of(WRONG_KIND)} |",
        f"  | absent inside `a` | the closer of `a` | {settled_of(ABSENT_INNER)} |",
        f"  | absent at the root | the end of the input | {settled_of(ABSENT_ROOT)} |",
        "",
        "  A streaming caller cancels at `settled` in the first two cases; in the",
        "  third there is nothing to cancel early, because an open root may still",
        "  contain the member the model has not written yet. Treating the three the",
        "  same is either cancelling too late or too early.",
        "- A stream that never closes (`truncated by max_tokens`) is still schema",
        "  ready — if its declared arguments arrived — but not executable: the",
        "  JSON itself is not valid, so the gate refuses with `E010`. Readiness",
        "  is about *when*, the gate is about *whether*.",
        "",
        "The measurement is a property of the input and the declaration, not of a",
        "model: it says how early a gate *could* decide, not how early a particular",
        "provider would have emitted the bytes.",
        "",
    ]
    Path(args.out).write_text("\n".join(lines))
    print(f"readiness table: {len(rows)} cases -> {args.out}")
    for r in rows:
        print(
            f"  {r['name']:<32} syntax={r['syntax']:>4} settled={r['settled']:>4} "
            f"schema={r['schema']:>4} declared={r['declared']}/{r['total']} "
            f"exe={'yes' if r['executable'] else 'no'}"
        )
    if args.check:
        # The table is only worth publishing if at least one case shows a gap and
        # at least one shows none: a harness that always reports the same number
        # would prove nothing.
        gaps = [r for r in rows if r["syntax"] - r["schema"] > 100]
        flat = [r for r in rows if r["syntax"] == r["schema"]]
        if not gaps or not flat:
            print(f"check: gaps={len(gaps)} flat={len(flat)}", file=sys.stderr)
            return 1
        # The regression 0.6.0 exists to prevent: a declared member that is final
        # and wrong, or that is provably absent because its container closed, must
        # not be reported as "decided only at the end". The third row (absent at
        # the root) does not belong here: there the end of the input *is* the
        # honest answer.
        for name in (WRONG_KIND, ABSENT_INNER):
            row = next((r for r in rows if r["name"] == name), None)
            if row is None or row["schema"] != 1000 or row["settled"] >= 500:
                print(
                    f"check: {name} must report schema=1000 and settled<500, "
                    f"got {row}",
                    file=sys.stderr,
                )
                return 1
        early_no = [r for r in rows if r["schema"] == 1000 and r["settled"] < 500]
        if len(early_no) < 2:
            print(
                "check: expected the wrong-kind and the absent-in-a-container "
                f"rows to be decidable early, got {len(early_no)}",
                file=sys.stderr,
            )
            return 1
        root = next((r for r in rows if r["name"] == ABSENT_ROOT), None)
        if root is None or root["schema"] != 1000 or root["settled"] != 1000:
            print(
                "check: the absent-at-the-root row must report schema=1000 and "
                f"settled=1000, got {root}",
                file=sys.stderr,
            )
            return 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
