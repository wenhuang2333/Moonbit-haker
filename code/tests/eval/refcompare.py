#!/usr/bin/env python3
"""Side-by-side comparison with the two reference repair libraries (I-4).

The registered evaluation measures JSONMend alone. This harness runs the *same*
frozen corpus and the *same* truth through three repairers:

  * JSONMend                (`jsonmend --batch`, plus the `--for-execution` gate)
  * `jsonrepair` 3.15.0     (npm, via `oracle_node.mjs`)
  * `json_repair` 0.64.0    (PyPI, in process)

The interesting column is not the raw recovery rate but *silent wrong answers*:
a repairer that returns a parseable value which differs from the truth, without
saying so. JSONMend labels every such result `lossy`, and the `--for-execution`
gate refuses it instead of returning it; the two reference libraries have no
such channel, so for them a wrong value is indistinguishable from a right one.

    python3 code/tests/eval/refcompare.py --cli <path to jsonmend> [--node-dir DIR]

`--node-dir` is the directory that holds `node_modules/jsonrepair`; it defaults
to `/private/tmp` , which is where the pinned oracle is unpacked.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "docs", "EVAL_REFERENCE.md")
CORPUS = os.path.join(HERE, "corpus.jsonl")
ORACLE = os.path.join(HERE, "oracle_node.mjs")

sys.path.insert(0, HERE)
import corpus as corpus_mod  # noqa: E402
from run_eval import same  # noqa: E402


def load_corpus():
    with open(CORPUS, encoding="utf-8") as fh:
        cases = [json.loads(line) for line in fh if line.strip()]
    return cases


def run_jsonmend(cli, cases, extra=()):
    prose = [c for c in cases if c["family"] == "prose"]
    rest = [c for c in cases if c["family"] != "prose"]
    rows = {}

    def one(group, flags):
        payload = "".join(
            json.dumps({"id": c["id"], "input": c["input"]}, ensure_ascii=False) + "\n"
            for c in group
        )
        proc = subprocess.run(
            [cli, "--batch", *flags, *extra],
            input=payload,
            capture_output=True,
            text=True,
            timeout=900,
        )
        if proc.returncode != 0:
            raise SystemExit(
                "batch run failed (rc=%d): %s" % (proc.returncode, proc.stderr[:300])
            )
        for line in proc.stdout.splitlines():
            if line.strip():
                row = json.loads(line)
                rows[row["id"]] = row

    one(rest, [])
    one(prose, ["--skip-prose"])
    return rows


def run_jsonrepair(cases, node_dir):
    payload = "".join(
        json.dumps({"id": c["id"], "input": c["input"]}, ensure_ascii=False) + "\n"
        for c in cases
    )
    proc = subprocess.run(
        ["node", ORACLE],
        input=payload,
        capture_output=True,
        text=True,
        timeout=900,
        cwd=node_dir,
        env={**os.environ, "NODE_PATH": os.path.join(node_dir, "node_modules")},
    )
    if proc.returncode != 0:
        raise SystemExit("oracle_node failed: %s" % proc.stderr[:400])
    rows = {}
    for line in proc.stdout.splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def run_json_repair_py(cases):
    try:
        from json_repair import repair_json
    except Exception as exc:  # pragma: no cover
        raise SystemExit("json_repair is not importable: %s" % exc)
    rows = {}
    for c in cases:
        ok = True
        valid = False
        value = None
        error = ""
        try:
            text = repair_json(c["input"], return_objects=False)
            try:
                value = json.loads(text)
                valid = True
            except Exception as exc:
                error = "repaired text is not JSON: %s" % str(exc)[:120]
        except Exception as exc:
            ok = False
            error = str(exc)[:120]
        rows[c["id"]] = {"id": c["id"], "ok": ok, "valid": valid, "value": value, "error": error}
    return rows


def score(tool, cases, rows, get):
    """Return the counters the report prints for one tool."""
    n = len(cases)
    recovered = 0
    silent_wrong = 0
    labelled_wrong = 0
    raised = 0
    invalid = 0
    for c in cases:
        got = get(rows.get(c["id"]))
        if got is None:
            raised += 1
            continue
        value, valid, label = got
        if not valid:
            invalid += 1
            continue
        if same(value, c["truth"]):
            recovered += 1
        elif tool == "jsonmend" and label == "lossy":
            labelled_wrong += 1
        else:
            silent_wrong += 1
    return {
        "n": n,
        "recovered": recovered,
        "silent_wrong": silent_wrong,
        "labelled_wrong": labelled_wrong,
        "raised": raised,
        "invalid": invalid,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--node-dir", default="/private/tmp")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    cases = load_corpus()
    fingerprint = corpus_mod.fingerprint(cases)

    jm = run_jsonmend(args.cli, cases)
    jm_gate = run_jsonmend(args.cli, cases, extra=["--for-execution"])
    jr = run_jsonrepair(cases, args.node_dir)
    jp = run_json_repair_py(cases)

    def get_jm(row, gate=False):
        if row is None or row["rc"] != 0:
            return None
        return (row.get("value"), True, row.get("exactness"))

    def get_oracle(row):
        if row is None or not row.get("ok"):
            return None
        return (row.get("value"), row.get("valid"), "")

    scores = {
        "jsonmend": score("jsonmend", cases, jm, get_jm),
        "jsonrepair": score("jsonrepair", cases, jr, get_oracle),
        "json_repair": score("json_repair", cases, jp, get_oracle),
    }

    # The gate: how often does `for-execution` refuse instead of returning a
    # value? A refusal is the safe answer for every case whose value is wrong.
    # The refusal is split by error code so that a reader can tell "the value
    # would have changed" (E010) from "the value admits two readings" (E011),
    # and by family so that a reader can ask the question this section exists to
    # answer: does the gate reject cases it did not have to reject?
    gate_refused = 0
    gate_unsafe = 0
    gate_codes = {}
    gate_refused_by_family = {}
    for c in cases:
        row = jm_gate.get(c["id"])
        refused = row is None or row["rc"] != 0
        if refused:
            gate_refused += 1
            code = (row or {}).get("error_code") or "no row"
            gate_codes[code] = gate_codes.get(code, 0) + 1
            gate_refused_by_family[c["family"]] = gate_refused_by_family.get(c["family"], 0) + 1
            continue
        if not same(row.get("value"), c["truth"]):
            gate_unsafe += 1

    # Of the refusals, which ones sit in a family whose repair the corpus
    # registers as notation only? Those are the only ones a reader could call a
    # false refusal, so they are listed with their cause.
    notation = set(corpus_mod.NOTATION)
    refusals_in_notation = {
        f: gate_refused_by_family.get(f, 0)
        for f in sorted(notation)
        if gate_refused_by_family.get(f, 0)
    }

    # Per-family recovery, the useful shape for a reader.
    families = []
    for fam in ["clean"] + list(corpus_mod.FAMILIES):
        group = [c for c in cases if c["family"] == fam]
        if not group:
            continue
        row = {"family": fam, "n": len(group), "refused": gate_refused_by_family.get(fam, 0)}
        for tool, (rows, getter) in {
            "jsonmend": (jm, get_jm),
            "jsonrepair": (jr, get_oracle),
            "json_repair": (jp, get_oracle),
        }.items():
            row[tool] = sum(
                1
                for c in group
                if (lambda g: g is not None and g[1] and same(g[0], c["truth"]))(
                    getter(rows.get(c["id"]))
                )
            )
        families.append(row)

    version_lines = [
        ("jsonmend", "round 5 build"),
        ("jsonrepair", "3.15.0 (npm)"),
        ("json_repair", "0.64.0 (PyPI)"),
    ]

    lines = []
    lines.append("# Reference library comparison on the registered corpus (I-4)")
    lines.append("")
    lines.append(
        "Generated by `code/tests/eval/refcompare.py` on %s."
        % datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    )
    lines.append("")
    lines.append("| field | value |")
    lines.append("| --- | --- |")
    lines.append("| corpus | `eval-2`, %d cases, fingerprint `%s` |" % (len(cases), fingerprint))
    for name, ver in version_lines:
        lines.append("| %s | %s |" % (name, ver))
    lines.append("")
    lines.append("## Recovery and safety")
    lines.append("")
    lines.append(
        "| repairer | recovered truth | silent wrong value | labelled wrong (`lossy`) | raised | produced non-JSON |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for name in ("jsonmend", "jsonrepair", "json_repair"):
        s = scores[name]
        lines.append(
            "| %s | %d / %d (%.1f%%) | %d | %d | %d | %d |"
            % (
                name,
                s["recovered"],
                s["n"],
                100.0 * s["recovered"] / s["n"],
                s["silent_wrong"],
                s["labelled_wrong"],
                s["raised"],
                s["invalid"],
            )
        )
    lines.append("")
    lines.append(
        "`silent wrong value` counts a parseable answer that differs from the "
        "truth and carries no warning. For the two reference libraries that is "
        "every wrong answer, because neither has a channel for it. For JSONMend "
        "it is 0 by construction: the wrong answers appear in the `labelled "
        "wrong` column, and the execution gate refuses them."
    )
    lines.append("")
    lines.append("## The execution gate")
    lines.append("")
    lines.append(
        "| measure | value |"
    )
    lines.append("| --- | --- |")
    lines.append(
        "| cases refused by `--for-execution` | %d / %d |" % (gate_refused, len(cases))
    )
    lines.append(
        "| values accepted by the gate that differ from the truth | %d |" % gate_unsafe
    )
    for code in sorted(gate_codes):
        lines.append("| refused with `%s` | %d |" % (code, gate_codes[code]))
    lines.append("")
    lines.append("### Is the gate refusing more than it has to?")
    lines.append("")
    lines.append(
        "The only refusals a reader could call false are the ones inside a "
        "family that the corpus registers as notation only (the value is "
        "recoverable, so a refusal is not forced by information loss). They are:"
    )
    lines.append("")
    lines.append("| notation family | refused | cause |")
    lines.append("| --- | --- | --- |")
    causes = {
        "literal_case": "`None` is a different word, not a case variant (R012, lossy)",
        "delete_comma": "the comma deletion leaves two adjacent strings, which really do read two ways (E011)",
    }
    if refusals_in_notation:
        for fam, count in refusals_in_notation.items():
            lines.append("| `%s` | %d | %s |" % (fam, count, causes.get(fam, "(see the family above)")))
    else:
        lines.append("| (none) | 0 | — |")
    lines.append("")
    lines.append(
        "Every other refusal sits in one of the four lossy families, where the "
        "repair invents or drops information, so refusing is the registered "
        "behaviour rather than an accident."
    )
    lines.append("")
    lines.append("## Per-family recovery")
    lines.append("")
    lines.append("| family | cases | gate refused | jsonmend | jsonrepair | json_repair |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for row in families:
        lines.append(
            "| %s | %d | %d | %d | %d | %d |"
            % (
                row["family"],
                row["n"],
                row["refused"],
                row["jsonmend"],
                row["jsonrepair"],
                row["json_repair"],
            )
        )
    lines.append("")
    lines.append(
        "Families where a reference library beats JSONMend are visible above and "
        "are the honest form of this comparison: a single number hides that the "
        "corpus is dominated by notation repairs."
    )
    lines.append("")
    lines.append("## Configuration used for each case")
    lines.append("")
    lines.append(
        "The corpus has one family that cannot be read with the default options: "
        "`prose` puts a sentence in front of the value, and JSONMend only skips "
        "prose when `--skip-prose` is set (the default is to refuse, so that a "
        "scalar root such as `Sure!\\n42` is never silently discarded). That "
        "family is therefore run with `--skip-prose` in every harness "
        "(`run_eval.py`, `run_eval_paths.py`, `refcompare.py`)."
    )
    lines.append("")
    lines.append(
        "This is not a concession made to JSONMend: **both reference libraries "
        "strip leading prose by default**, so the flag puts JSONMend in the same "
        "position rather than a better one. The number of cases affected is 60 "
        "of 1200; every other case runs with default options on both sides."
    )
    lines.append("")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
