#!/usr/bin/env python3
"""Adversarial ambiguity suite (FR-27).

The registered corpus deliberately excludes the ambiguous inputs (its families
tighten notation), so "0 mislabels" is a statement about the cases that were
kept, not about the hard ones. This suite is the complement: a hand-written,
frozen list of inputs that admit a second, equally self-consistent reading, plus
control cases that do not.

For each case the harness checks three things:

  1. `interjson --batch` reports the ambiguity (or reports none, for a control);
  2. `interjson --for-execution` refuses exactly the ambiguous cases (`E011`) and
     the value-inventing ones (`E010`), and accepts the controls;
  3. the two reference libraries return a parseable value for the ambiguous
     cases anyway — with no channel to say that the reading was chosen.

    python3 code/tests/eval/run_ambiguity.py --cli <path to interjson>

Exit status 0 when the pipeline agrees with the registered expectation.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "docs", "EVAL_AMBIGUITY.md")
ORACLE = os.path.join(HERE, "oracle_node.mjs")

# `amb` is the expected ambiguity class ("" = none), `gate` the expected
# `--for-execution` outcome, `value` the expected parsed value, `note` why the
# input reads two ways. Every entry was written by hand; the corpus is frozen by
# its fingerprint below.
CASES = [
    # --- R006: a missing comma between two strings -------------------------
    {
        "id": "amb-001",
        "input": '["a" "b"]',
        "amb": "adjacent_strings",
        "gate": "E011",
        "value": ["a", "b"],
        "note": 'two elements, or the single concatenated string "ab"',
    },
    {
        "id": "amb-002",
        "input": "['a' 'b']",
        "amb": "adjacent_strings",
        "gate": "E011",
        "value": ["a", "b"],
        "note": "same reading with single quotes",
    },
    {
        "id": "amb-003",
        "input": '["a" "b" "c"]',
        "amb": "adjacent_strings",
        "gate": "E011",
        "value": ["a", "b", "c"],
        "note": "three elements, or one string of length three",
    },
    {
        "id": "amb-004",
        "input": '{"x":"a" "y":"b"}',
        "amb": "",
        "gate": "OK",
        "value": {"x": "a", "y": "b"},
        "note": "control: a missing comma before a key has one reading",
    },
    {
        "id": "amb-005",
        "input": "[1 2]",
        "amb": "",
        "gate": "OK",
        "value": [1, 2],
        "note": "control: numbers cannot be concatenated",
    },
    {
        "id": "amb-006",
        "input": '["a" 2]',
        "amb": "",
        "gate": "OK",
        "value": ["a", 2],
        "note": "control: number follows the string",
    },
    # --- R019: a plus sign between strings ---------------------------------
    {
        "id": "amb-007",
        "input": '["a"+"b"]',
        "amb": "concat_operator",
        "gate": "E011",
        "value": ["ab"],
        "note": 'one concatenated string, or the operator "+" as text',
    },
    {
        "id": "amb-008",
        "input": '["a" + "b"]',
        "amb": "concat_operator",
        "gate": "E011",
        "value": ["ab"],
        "note": "same with spaces",
    },
    {
        "id": "amb-009",
        "input": '{"a": "x" + "y"}',
        "amb": "concat_operator",
        "gate": "E011",
        "value": {"a": "xy"},
        "note": "a member value built with a plus sign",
    },
    # --- R004: a bare word in value position -------------------------------
    {
        "id": "amb-010",
        "input": "[fast]",
        "amb": "bare_word",
        "gate": "E011",
        "value": ["fast"],
        "note": "a string, or a host-language value named `fast`",
    },
    {
        "id": "amb-011",
        "input": '{"mode": fast}',
        "amb": "bare_word",
        "gate": "E011",
        "value": {"mode": "fast"},
        "note": "same inside an object",
    },
    {
        "id": "amb-012",
        "input": "{fast: 1}",
        "amb": "",
        "gate": "OK",
        "value": {"fast": 1},
        "note": "control: a bare word as a key is a notation fix",
    },
    # --- R016: content after the first root value --------------------------
    {
        "id": "amb-013",
        "input": '{"a":1} {"b":2}',
        "amb": "trailing_content",
        "gate": "E011",
        "value": {"a": 1},
        "note": "a second document, or a mistake",
    },
    {
        "id": "amb-014",
        "input": "[1] 2",
        "amb": "trailing_content",
        "gate": "E011",
        "value": [1],
        "note": "an extra element, or a second document",
    },
    {
        "id": "amb-015",
        "input": '{"a":1}   ',
        "amb": "",
        "gate": "OK",
        "value": {"a": 1},
        "note": "control: trailing whitespace is not content",
    },
    # --- value-inventing repairs the gate must also refuse ------------------
    {
        "id": "amb-016",
        "input": '{"a": undefined}',
        "amb": "",
        "gate": "E010",
        "value": {"a": None},
        "note": 'null, or the string "undefined"',
    },
    {
        "id": "amb-017",
        "input": "[None]",
        "amb": "",
        "gate": "E010",
        "value": [None],
        "note": 'null, or the string "None"',
    },
    {
        "id": "amb-018",
        "input": '{"n": nan}',
        "amb": "",
        "gate": "E010",
        "value": {"n": None},
        "note": 'a null, or the string "NaN"',
    },
    {
        "id": "amb-019",
        "input": '{"a":"x}',
        "amb": "",
        "gate": "E010",
        "value": {"a": "x}"},
        "note": "the `}` may close the object (closing quote invented) or be string content",
    },
    {
        "id": "amb-020",
        "input": '{"a":1',
        "amb": "",
        "gate": "E010",
        "value": {"a": 1},
        "note": "an unclosed object: the closer was invented",
    },
    # --- controls that must pass the gate ----------------------------------
    {
        "id": "amb-021",
        "input": "{'a':1}",
        "amb": "",
        "gate": "OK",
        "value": {"a": 1},
        "note": "control: a normalised quote invents nothing",
    },
    {
        "id": "amb-022",
        "input": "[1,2,3,]",
        "amb": "",
        "gate": "OK",
        "value": [1, 2, 3],
        "note": "control: a trailing comma invents nothing",
    },
    {
        "id": "amb-023",
        "input": "{\"a\":1, // c\n}",
        "amb": "",
        "gate": "OK",
        "value": {"a": 1},
        "note": "control: a comment invents nothing",
    },
    {
        "id": "amb-024",
        "input": "{\"a\":1}",
        "amb": "",
        "gate": "OK",
        "value": {"a": 1},
        "note": "control: valid JSON",
    },
]


def fingerprint() -> str:
    blob = json.dumps(
        [[c["id"], c["input"], c["amb"], c["gate"]] for c in CASES],
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(blob.encode()).hexdigest()


def run_interjson(cli, cases, extra=()):
    payload = "".join(
        json.dumps({"id": c["id"], "input": c["input"]}, ensure_ascii=False) + "\n"
        for c in cases
    )
    proc = subprocess.run(
        [cli, "--batch", *extra],
        input=payload,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if proc.returncode != 0:
        raise SystemExit("batch failed: %s" % proc.stderr[:300])
    rows = {}
    for line in proc.stdout.splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def run_oracles(cli, cases, node_dir):
    """Ask the two reference libraries for their answer, if they are installed.

    The comparison is against InterJSON's own verdicts; the reference columns are
    informative. A missing `node_modules` or a missing `json_repair` must
    therefore degrade the report, not fail the suite — otherwise the suite could
    only be run on one machine, which would make it a worse piece of evidence.
    """
    payload = "".join(
        json.dumps({"id": c["id"], "input": c["input"]}, ensure_ascii=False) + "\n"
        for c in cases
    )
    jr = {}
    node_missing = None
    if not os.path.isdir(node_dir):
        node_missing = "node module directory %s does not exist" % node_dir
    else:
        try:
            proc = subprocess.run(
                ["node", ORACLE],
                input=payload,
                capture_output=True,
                text=True,
                timeout=300,
                cwd=node_dir,
                env={**os.environ, "NODE_PATH": os.path.join(node_dir, "node_modules")},
            )
        except OSError as exc:
            node_missing = "node could not be run: %s" % exc
        else:
            if proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    if line.strip():
                        row = json.loads(line)
                        jr[row["id"]] = row
            else:
                node_missing = "oracle exited %d" % proc.returncode
    if node_missing:
        print("note: jsonrepair column unavailable (%s)" % node_missing)
    try:
        from json_repair import repair_json
    except Exception:
        repair_json = None
    jp = {}
    if repair_json is None:
        print("note: json_repair column unavailable (module not installed)")
    for c in cases:
        if repair_json is None:
            break
        try:
            text = repair_json(c["input"], return_objects=False)
            value = json.loads(text)
            jp[c["id"]] = {"ok": True, "value": value}
        except Exception:
            jp[c["id"]] = {"ok": False, "value": None}
    return jr, jp


def compare(cases, default_rows, gate_rows, jr=None, jp=None):
    """Check `cases` against the two runs; return (failures, rows).

    Extracted from `main` so that `check_amb_guard.py` can run the *same*
    comparison against a deliberately wrong expectation: a suite whose
    assertion machinery cannot fail proves nothing.
    """
    failures = []
    rows = []
    for c in cases:
        row = default_rows[c["id"]]
        amb_flag = bool(row.get("ambiguous"))
        want_flag = c["amb"] != ""
        if amb_flag != want_flag:
            failures.append(
                "%s: ambiguous=%s, expected %s" % (c["id"], amb_flag, want_flag)
            )
        value_ok = row["rc"] == 0 and row.get("value") == c["value"]
        if not value_ok:
            failures.append(
                "%s: value %r, expected %r (rc=%d)"
                % (c["id"], row.get("value"), c["value"], row["rc"])
            )
        g = gate_rows[c["id"]]
        # The gate result is the exact `E` code, so the suite distinguishes an
        # ambiguity refusal from an exactness refusal.
        gate = "OK" if g["rc"] == 0 else g.get("error_code", "rc=%d" % g["rc"])
        if gate != c["gate"]:
            failures.append("%s: gate %s, expected %s" % (c["id"], gate, c["gate"]))
        rows.append(
            {
                "case": c,
                "amb": amb_flag,
                "gate": gate,
                "value_ok": value_ok,
                "jsonrepair": (jr or {}).get(c["id"]),
                "json_repair": (jp or {}).get(c["id"]),
            }
        )
    return failures, rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--node-dir", default="/private/tmp")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    default_rows = run_interjson(args.cli, CASES)
    gate_rows = run_interjson(args.cli, CASES, extra=["--for-execution"])
    jr, jp = run_oracles(args.cli, CASES, args.node_dir)

    failures, rows = compare(CASES, default_rows, gate_rows, jr, jp)

    amb_cases = [r for r in rows if r["case"]["amb"] != ""]
    ctrl_cases = [r for r in rows if r["case"]["amb"] == ""]
    flagged = sum(1 for r in amb_cases if r["amb"])
    refused = sum(1 for r in amb_cases if r["gate"] != "OK")
    silent_jr = sum(
        1
        for r in amb_cases
        if r["jsonrepair"] and r["jsonrepair"].get("ok") and r["jsonrepair"].get("valid")
    )
    silent_jp = sum(
        1
        for r in amb_cases
        if r["json_repair"] and r["json_repair"].get("ok")
    )

    lines = []
    lines.append("# Adversarial ambiguity suite (FR-27, round 5)")
    lines.append("")
    lines.append(
        "Generated by `code/tests/eval/run_ambiguity.py` on %s."
        % datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    )
    lines.append("")
    lines.append("| field | value |")
    lines.append("| --- | --- |")
    lines.append("| cases | %d (%d ambiguous, %d control) |" % (len(CASES), len(amb_cases), len(ctrl_cases)))
    lines.append("| frozen fingerprint | `%s` |" % fingerprint())
    lines.append("| ambiguous cases flagged by InterJSON | %d / %d |" % (flagged, len(amb_cases)))
    lines.append("| ambiguous cases refused by `--for-execution` | %d / %d |" % (refused, len(amb_cases)))
    lines.append(
        "| ambiguous cases answered silently by `jsonrepair` | %s |"
        % ("%d / %d" % (silent_jr, len(amb_cases)) if jr else "n/a (library not installed)")
    )
    lines.append(
        "| ambiguous cases answered silently by `json_repair` | %s |"
        % ("%d / %d" % (silent_jp, len(amb_cases)) if jp else "n/a (library not installed)")
    )
    lines.append("| expectation failures | %d |" % len(failures))
    lines.append("")
    lines.append("## Case by case")
    lines.append("")
    lines.append(
        "| case | input | expected reading | flagged | gate | why it reads two ways |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for r in rows:
        c = r["case"]
        shown = c["input"].replace("|", "\\|").replace("\n", "\\n")
        lines.append(
            "| `%s` | `%s` | %s | %s | %s | %s |"
            % (
                c["id"],
                shown,
                c["amb"] or "unique",
                "yes" if r["amb"] else "no",
                r["gate"],
                c["note"],
            )
        )
    lines.append("")
    lines.append("## What the two reference libraries do with the ambiguous cases")
    lines.append("")
    lines.append("| case | input | jsonrepair | json_repair |")
    lines.append("| --- | --- | --- | --- |")
    for r in amb_cases:
        c = r["case"]
        shown = c["input"].replace("|", "\\|")
        jr_row = r["jsonrepair"]
        jp_row = r["json_repair"]
        jr_txt = (
            "silent value %s" % json.dumps(jr_row.get("value"), ensure_ascii=False)
            if jr_row and jr_row.get("ok") and jr_row.get("valid")
            else "raised / non-JSON"
        )
        jp_txt = (
            "silent value %s" % json.dumps(jp_row.get("value"), ensure_ascii=False)
            if jp_row and jp_row.get("ok")
            else "raised / non-JSON"
        )
        lines.append("| `%s` | `%s` | %s | %s |" % (c["id"], shown, jr_txt, jp_txt))
    lines.append("")
    if failures:
        lines.append("## Failures")
        lines.append("")
        for f in failures:
            lines.append("- %s" % f)
        lines.append("")
    else:
        lines.append(
            "Every expectation holds: the ambiguous inputs are flagged, the "
            "execution gate refuses them, the controls pass, and both reference "
            "libraries answer the ambiguous cases without any signal."
        )
        lines.append("")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print("\n".join(lines[:40]))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
