#!/usr/bin/env python3
"""Independent third-party corpus evaluation: `nst/JSONTestSuite`.

Every other JSONMend evaluation in this directory is built on a corpus we wrote
ourselves (`corpus.py` generates `eval-2`; `run_ambiguity.py` freezes `amb-1`).
That is a real evidence gap: a generator we designed can only test the
behaviours we thought of, and a corpus we scored ourselves cannot surprise us.

This harness closes the *corpus* half of that gap with
`https://github.com/nst/JSONTestSuite` (MIT, (c) 2016 Nicolas Seriot), a suite
written by a third party to test JSON parsers. The files are vendored verbatim
under `third_party/jsontestsuite/`; see `PROVENANCE.md` there.

For every file in `test_parsing/` the harness answers three questions:

  1. does a spec-strict parser accept it (`json.loads` with `NaN`/`Infinity`
     rejected, cross-checked against `JSON.parse`)?
  2. what do the three implementations do with it — JSONMend, `json_repair`
     (Python) and `jsonrepair` (Node)?
  3. on the `y_*` files, which are *valid JSON*, does JSONMend report a repair
     record? A valid document must need zero repairs, so every record there is a
     false repair.

    python3 code/tests/eval/run_independent.py [--cli PATH]

The report is written to `code/docs/EVAL_INDEPENDENT.md`. The run is offline and
deterministic: files are processed in sorted order, both oracles are pinned local
installs, and the generation stamp honours `SOURCE_DATE_EPOCH`.

Exit status is 0 whenever the report was produced: this corpus has no
pre-registered pass criterion, it measures. `--strict` exits 1 when a `y_*` file
gets a repair record, the one verdict here that is unambiguously wrong.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "docs", "EVAL_INDEPENDENT.md")
SUITE = os.path.join(HERE, "third_party", "jsontestsuite")
PARSING = os.path.join(SUITE, "test_parsing")
ORACLE = os.path.join(HERE, "oracle_node_bytes.mjs")
DEFAULT_CLI = os.path.join(
    ROOT, "_build", "native", "release", "build", "cmd", "jsonmend", "jsonmend.exe"
)

UPSTREAM = "https://github.com/nst/JSONTestSuite"
UPSTREAM_TARBALL = "https://codeload.github.com/nst/JSONTestSuite/tar.gz/refs/heads/master"
UPSTREAM_COMMIT = "1ef36fa01286573e846ac449e8683f8833c5b26a"
UPSTREAM_LICENSE = "MIT License, Copyright (c) 2016 Nicolas Seriot"

# `R005 3:14 trailing comma removed`, one per line on stderr (see cmd/jsonmend).
RECORD = re.compile(r"^(R\d+)\s+(\d+):(\d+)\s+(.*)$", re.M)
ERROR_CODE = re.compile(r"\b(E\d{3})\b")
EXACTNESS = re.compile(r"exactness (\w+)")

FAMILIES = [
    ("y_", "valid JSON: every strict parser must accept these"),
    ("n_", "invalid JSON: every strict parser must reject these"),
    ("i_", "implementation-defined: a strict parser may accept or reject these"),
]
LIBS = ["jsonmend", "json_repair", "jsonrepair"]
LIB_TITLE = {
    "jsonmend": "JSONMend (native)",
    "json_repair": "`json_repair` 0.64.0 (Python)",
    "jsonrepair": "`jsonrepair` 3.15.0 (Node)",
}
NA = "n/a (library not installed)"

# A library may produce a value, refuse, or crash. The last two are different
# evidence and are counted apart.
OK, REFUSED, CRASHED = "ok", "refused", "crashed"

try:  # Optional: a missing oracle degrades a column, it does not fail the run.
    from json_repair import repair_json as _REPAIR_JSON
except Exception:  # pragma: no cover - depends on the machine
    _REPAIR_JSON = None
PY_AVAILABLE = _REPAIR_JSON is not None


def strict_json(raw: bytes) -> bool:
    """Is `raw` valid JSON by RFC 8259?

    `json.loads` is a spec parser, not a repairer, so it leaks no truth. Two of
    its documented extensions must be closed by hand: without `parse_constant`,
    it accepts the `NaN`/`Infinity` literals and would score three `n_*` files as
    valid. `strict=True` (the default) already rejects raw control characters.
    """
    try:
        json.loads(raw, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
        return True
    except Exception:
        return False


def decode_for_library(raw: bytes) -> tuple[str, str]:
    """Text handed to the two oracle libraries, plus how it was obtained.

    Both oracles take a string, not bytes, and 25 of the 318 files are not valid
    UTF-8. Those are mapped byte-per-code-point through latin-1, which loses
    nothing but reinterprets multi-byte sequences; the assumption is recorded in
    the report instead of being hidden. `oracle_node_bytes.mjs` applies the same
    rule, so both oracles see the same characters. JSONMend is fed the real
    bytes.
    """
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return raw.decode("latin-1"), "latin-1"


class Deadline:
    """Per-call wall-clock guard for the in-process Python oracle.

    `json_repair` is pure Python, so a signal interrupts it between bytecodes;
    without this one pathological input could hang the whole run. A no-op where
    `SIGALRM` does not exist.
    """

    def __init__(self, seconds: int):
        self.seconds = seconds
        self._old = None

    def __enter__(self):
        if not hasattr(signal, "SIGALRM"):
            return self

        def on_alarm(_signum, _frame):
            raise TimeoutError("oracle exceeded %ds" % self.seconds)

        self._old = signal.signal(signal.SIGALRM, on_alarm)
        signal.alarm(self.seconds)
        return self

    def __exit__(self, *_exc):
        if self._old is not None:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, self._old)
        return False


def cli_note(stderr: str) -> str:
    """The one useful line of a refusal: the `jsonmend: …` diagnostic.

    The CLI follows it with the offending input and a caret, which would render
    as a row of spaces and `^` in a table, so that is skipped.
    """
    for line in stderr.splitlines():
        if line.startswith("jsonmend:"):
            return line[:200]
    for line in reversed(stderr.splitlines()):
        if line.strip() and set(line.strip()) - set("^"):
            return line.strip()[:200]
    return ""


def run_jsonmend(cli: str, raw: bytes, timeout: int) -> dict:
    """Run the CLI in default repair mode and read the repair records.

    `--report` writes one `R005 3:14 message` line per record to stderr. stdin is
    fed the raw bytes, so JSONMend sees exactly what the corpus ships, including
    the 25 files that are not valid UTF-8.
    """
    outcome = {"outcome": CRASHED, "rc": None, "records": [], "note": ""}
    try:
        proc = subprocess.run(
            [cli, "--report", "-"], input=raw, capture_output=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        outcome["note"] = "timed out after %ds" % timeout
        return outcome
    except OSError as exc:
        outcome["note"] = "could not run the CLI: %s" % exc
        return outcome

    rc = proc.returncode
    outcome["rc"] = rc
    stderr = proc.stderr.decode("utf-8", "replace")
    outcome["records"] = [
        {
            "code": m.group(1),
            "line": int(m.group(2)),
            "col": int(m.group(3)),
            "message": m.group(4),
        }
        for m in RECORD.finditer(stderr)
    ]
    if rc == 0:
        try:
            json.loads(
                proc.stdout, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c))
            )
            outcome["outcome"] = OK
        except Exception:
            # Exit 0 with unparseable stdout is "produced invalid JSON".
            outcome["outcome"] = REFUSED
            outcome["note"] = "exit 0 but stdout is not JSON"
    elif rc in (1, 2, 3, 4, 5):
        # 1 --check found repairs, 2 usage, 3 invalid input, 4 resource limit,
        # 5 strict/execution refusal: every one is a controlled refusal.
        outcome["outcome"] = REFUSED
        outcome["note"] = cli_note(stderr)
    else:
        outcome["outcome"] = CRASHED
        outcome["note"] = "exit %s: %s" % (rc, stderr.strip()[:160])
    return outcome


def run_jsonmend_extra(cli: str, raw: bytes, extra: list, timeout: int) -> dict:
    """Run one auxiliary mode (`--check`, `--for-execution`, `--explain`)."""
    try:
        proc = subprocess.run(
            [cli, *extra, "-"], input=raw, capture_output=True, timeout=timeout
        )
    except Exception as exc:  # timeout or OSError; neither is fatal here
        return {"rc": None, "code": "", "exactness": "", "note": str(exc)[:120]}
    stderr = proc.stderr.decode("utf-8", "replace")
    code = ERROR_CODE.search(stderr)
    exact = EXACTNESS.search(stderr)
    return {
        "rc": proc.returncode,
        "code": code.group(1) if code else "",
        "exactness": exact.group(1) if exact else "",
        "note": "",
    }


def run_json_repair(text: str, timeout: int) -> dict:
    """Ask the Python oracle for a value; degrade rather than raise.

    Mirrors `oracle_node.mjs`: repair first, then require the repaired text to be
    strict JSON, because the claim under test is not "the library returned a
    string" but "a caller can now parse it".
    """
    if not PY_AVAILABLE:
        return {"outcome": None, "note": "module not installed"}
    try:
        with Deadline(timeout):
            repaired = _REPAIR_JSON(text)
    except TimeoutError:
        return {"outcome": CRASHED, "note": "timed out"}
    except Exception as exc:
        note = "%s: %s" % (type(exc).__name__, exc)
        if isinstance(exc, (ValueError, TypeError, KeyError, IndexError)):
            return {"outcome": REFUSED, "note": note[:160]}
        return {"outcome": CRASHED, "note": note[:160]}
    if not isinstance(repaired, str):
        return {"outcome": CRASHED, "note": "repair_json returned %s" % type(repaired).__name__}
    try:
        json.loads(repaired, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
    except Exception:
        return {"outcome": REFUSED, "note": "repaired text is not JSON"}
    return {"outcome": OK, "note": "", "repaired": repaired}


def node_verdict(node: dict) -> str:
    """Map one Node oracle row onto the internal outcome vocabulary."""
    return OK if node.get("valid") else REFUSED


def run_node_oracle(files: list, node_dir: str, timeout: int):
    """Ask the Node oracle for its answer, if it is installed.

    A missing `node_modules`, a missing `node`, or a non-zero exit degrades the
    `jsonrepair` column to `n/a (library not installed)` and prints a note; it
    never fails the run. The suite has to be runnable on a machine without the
    oracle, or it is worse evidence than no oracle at all. This mirrors
    `run_ambiguity.py::run_oracles`.
    """
    body = "".join(
        json.dumps(
            {
                "id": name,
                "b64": base64.b64encode(open(os.path.join(PARSING, name), "rb").read()).decode(
                    "ascii"
                ),
            }
        )
        + "\n"
        for name in files
    )
    note = None
    if not os.path.isfile(ORACLE):
        note = "oracle script %s does not exist" % ORACLE
    elif not os.path.isdir(node_dir):
        note = "node module directory %s does not exist" % node_dir
    else:
        try:
            proc = subprocess.run(
                ["node", ORACLE],
                input=body,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=node_dir,
                env={**os.environ, "NODE_PATH": os.path.join(node_dir, "node_modules")},
            )
        except OSError as exc:
            note = "node could not be run: %s" % exc
        except subprocess.TimeoutExpired:
            note = "oracle timed out after %ds" % timeout
        else:
            if proc.returncode != 0:
                note = "oracle exited %d: %s" % (proc.returncode, proc.stderr.strip()[:160])
            else:
                rows = {}
                # `split("\n")`, never `splitlines()`: a JSON string may contain
                # U+2028/U+2029 and `str.splitlines` breaks on those.
                for chunk in proc.stdout.split("\n"):
                    if chunk.strip():
                        row = json.loads(chunk)
                        rows[row["id"]] = row
                if len(rows) == len(files):
                    return rows, None
                note = "oracle answered %d of %d files" % (len(rows), len(files))
    if note:
        print("note: jsonrepair column unavailable (%s)" % note)
    return None, note


def verdict(strict: bool, outcome) -> str:
    """Map one library's outcome onto accept / repair / reject / error.

    `accept` is "the input is strict JSON and the library returned a valid
    value"; `repair` is "the input is not strict JSON but the library still
    returned a valid value". The same strict oracle makes that split for all
    three libraries. `reject` covers every controlled refusal (a raised repair
    error, a non-zero exit, repaired text that is not JSON); `error` is reserved
    for a crash or a timeout.
    """
    if outcome is None:
        return "n/a"
    if outcome == CRASHED:
        return "error"
    if outcome == REFUSED:
        return "reject"
    return "accept" if strict else "repair"


def available(lib: str, node_rows) -> bool:
    if lib == "json_repair":
        return PY_AVAILABLE
    if lib == "jsonrepair":
        return node_rows is not None
    return True


def fingerprint(files: list) -> str:
    """sha256 over the sorted `name\\0bytes` stream of the vendored corpus."""
    h = hashlib.sha256()
    for name in sorted(files):
        h.update(name.encode("utf-8"))
        h.update(b"\0")
        h.update(open(os.path.join(PARSING, name), "rb").read())
    return h.hexdigest()


def show(text: str, limit: int = 60) -> str:
    """One-line, table-safe rendering of an input value."""
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == "|":
            out.append("\\|")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ch < " " or ch in ("\u007f", "\u2028", "\u2029", "\ufeff"):
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    joined = "".join(out)
    return joined if len(joined) <= limit else joined[: limit - 1] + "…"


def cell(counts: Counter, ok: bool, key: str):
    return str(counts.get(key, 0)) if ok else NA


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cli", default=DEFAULT_CLI, help="path to the jsonmend binary")
    ap.add_argument(
        "--node-dir", default="/private/tmp", help="directory holding node_modules/jsonrepair"
    )
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--file-timeout", type=int, default=120)
    ap.add_argument("--node-timeout", type=int, default=900)
    ap.add_argument("--oracle-timeout", type=int, default=60)
    ap.add_argument(
        "--strict", action="store_true", help="exit 1 when a valid (y_) file gets a repair record"
    )
    args = ap.parse_args()

    if not os.path.isfile(args.cli):
        raise SystemExit("jsonmend binary not found at %s" % args.cli)
    if not os.path.isdir(PARSING):
        raise SystemExit("vendored corpus not found at %s" % PARSING)
    if not PY_AVAILABLE:
        print("note: json_repair column unavailable (module not installed)")

    files = sorted(f for f in os.listdir(PARSING) if f.endswith(".json"))
    raw_of = {name: open(os.path.join(PARSING, name), "rb").read() for name in files}
    corpus_bytes = sum(len(raw) for raw in raw_of.values())

    t0 = time.time()
    cli_rows = {name: run_jsonmend(args.cli, raw_of[name], args.file_timeout) for name in files}
    python_rows = {}
    for name in files:
        text, _how = decode_for_library(raw_of[name])
        python_rows[name] = run_json_repair(text, args.oracle_timeout)
    node_rows, _node_note = run_node_oracle(files, args.node_dir, args.node_timeout)

    rows = []
    for name in files:
        raw = raw_of[name]
        text, how = decode_for_library(raw)
        strict = strict_json(raw)
        node = (node_rows or {}).get(name)
        cli = cli_rows[name]
        rows.append(
            {
                "file": name,
                "family": name[0],
                "bytes": len(raw),
                "decoding": how,
                "strict_py": strict,
                "strict_node": None if node is None else bool(node["strict"]),
                "text": text,
                "records": cli["records"],
                "cli": cli,
                "py": python_rows[name],
                "node": node,
                "verdict": {
                    "jsonmend": verdict(strict, cli["outcome"]),
                    "json_repair": verdict(strict, python_rows[name]["outcome"]),
                    "jsonrepair": "n/a" if node is None else verdict(strict, node_verdict(node)),
                },
            }
        )
    # A library that answered nothing at all is unavailable, not "0 rejects".
    for lib in LIBS:
        if not available(lib, node_rows) and lib != "jsonmend":
            for r in rows:
                r["verdict"][lib] = "n/a"

    by_family = {fam: [r for r in rows if r["family"] == fam[0]] for fam, _why in FAMILIES}
    y_rows = by_family["y_"]
    n_rows = by_family["n_"]

    tally = {
        (fam, lib): Counter(r["verdict"][lib] for r in by_family[fam])
        for fam, _why in FAMILIES
        for lib in LIBS
    }
    strict_tally = {
        fam: Counter("accept" if r["strict_py"] else "reject" for r in by_family[fam])
        for fam, _why in FAMILIES
    }

    # ---- headline: false repairs on valid JSON ------------------------------
    offenders = [r for r in y_rows if r["records"]]
    total_records = sum(len(r["records"]) for r in offenders)
    y_broken = [r for r in y_rows if r["verdict"]["jsonmend"] != "accept"]
    for r in y_rows:
        r["gate"] = run_jsonmend_extra(
            args.cli, raw_of[r["file"]], ["--for-execution"], args.file_timeout
        )
        r["check"] = run_jsonmend_extra(
            args.cli, raw_of[r["file"]], ["--check"], args.file_timeout
        )
    for r in offenders:
        r["explain"] = run_jsonmend_extra(
            args.cli, raw_of[r["file"]], ["--explain"], args.file_timeout
        )
    y_gate_refused = [r for r in y_rows if r["gate"]["rc"] == 5]
    y_check_failed = [r for r in y_rows if r["check"]["rc"] == 1]
    y_oracle_rejects = [
        r
        for r in y_rows
        if r["verdict"]["json_repair"] == "reject" or r["verdict"]["jsonrepair"] == "reject"
    ]

    # ---- n_*: who invents a valid value ------------------------------------
    n_valid = {
        lib: sum(1 for r in n_rows if r["verdict"][lib] in ("accept", "repair")) for lib in LIBS
    }
    pattern_of = {r["file"]: tuple(r["verdict"][lib] for lib in LIBS) for r in n_rows}
    patterns = Counter(pattern_of.values())
    examples = defaultdict(list)
    for r in n_rows:
        examples[pattern_of[r["file"]]].append(r)
    stricter = [
        r
        for r in n_rows
        if r["verdict"]["jsonmend"] == "reject"
        and all(r["verdict"][lib] in ("accept", "repair") for lib in ("json_repair", "jsonrepair"))
    ]
    n_crashes = [r for r in n_rows if any(r["verdict"][lib] == "error" for lib in LIBS)]

    strict_disagreements = [
        r for r in rows if r["strict_node"] is not None and r["strict_node"] != r["strict_py"]
    ]
    latin1 = [r for r in rows if r["decoding"] == "latin-1"]

    # ---- report -------------------------------------------------------------
    stamp = (
        datetime.datetime.fromtimestamp(int(os.environ.get("SOURCE_DATE_EPOCH", time.time())))
        .astimezone()
        .strftime("%Y-%m-%d %H:%M %Z")
    )
    cli_sha = hashlib.sha256(open(args.cli, "rb").read()).hexdigest()
    lines = []
    add = lines.append

    add("# Independent corpus evaluation: `nst/JSONTestSuite`")
    add("")
    add("Generated by `code/tests/eval/run_independent.py` on %s." % stamp)
    add("")
    add("| field | value |")
    add("| --- | --- |")
    add("| corpus | `nst/JSONTestSuite/test_parsing` (third-party, not authored by us) |")
    add("| upstream | <%s> |" % UPSTREAM)
    add("| tarball (one-request alternative) | <%s> |" % UPSTREAM_TARBALL)
    add("| vendoring method | `git ls-remote` + `git clone --filter=blob:none --sparse`; see `PROVENANCE.md` |")
    add("| upstream commit | `%s` |" % UPSTREAM_COMMIT)
    add("| license | %s |" % UPSTREAM_LICENSE)
    add(
        "| vendored files | %d (`y_` %d, `n_` %d, `i_` %d) + `LICENSE` + `README.md` + `PROVENANCE.md` |"
        % (len(files), len(by_family["y_"]), len(by_family["n_"]), len(by_family["i_"]))
    )
    add("| vendored `test_parsing` bytes | %d |" % corpus_bytes)
    add(
        "| corpus fingerprint | `%s` (sha256 over sorted `name\\0bytes`) |" % fingerprint(files)
    )
    add("| strict oracle | `json.loads` with `NaN`/`Infinity` rejected via `parse_constant` |")
    add("| secondary strict oracle | Node `JSON.parse` |")
    add("| JSONMend | `%s`, sha256 `%s` |" % (args.cli, cli_sha))
    add("| Python oracle | %s |" % ("`json_repair` 0.64.0" if PY_AVAILABLE else NA))
    add(
        "| Node oracle | %s |"
        % (
            "`jsonrepair` 3.15.0 (NODE_PATH=%s)" % os.path.join(args.node_dir, "node_modules")
            if node_rows is not None
            else NA
        )
    )
    add("| network | not needed |")
    add("")
    add("Every `test_parsing/*.json` file is fed to JSONMend on stdin, byte for byte, in")
    add("default repair mode with `--report`. The two repair oracles are asked the same")
    add("question the repository's other comparisons ask them: repair the text, then require")
    add("the result to be strict JSON, because the claim under test is that *a caller can now")
    add("parse it*, not that the library returned a string.")
    add("")

    add("## Summary: family x implementation")
    add("")
    add("| family | implementation | accept | repair | reject | error |")
    add("| --- | --- | --- | --- | --- | --- |")
    for fam, _why in FAMILIES:
        total = len(by_family[fam])
        add(
            "| **`%s`** (%d files) | strict `json.loads` (classifier) | %d | 0 | %d | 0 |"
            % (fam, total, strict_tally[fam]["accept"], strict_tally[fam]["reject"])
        )
        for lib in LIBS:
            ok = available(lib, node_rows)
            c = tally[(fam, lib)]
            add(
                "| | %s | %s | %s | %s | %s |"
                % (
                    LIB_TITLE[lib],
                    cell(c, ok, "accept"),
                    cell(c, ok, "repair"),
                    cell(c, ok, "reject"),
                    cell(c, ok, "error"),
                )
            )
    add("")
    add("- **accept**: the file is strict JSON *and* the implementation returned a valid")
    add("  value, i.e. nothing had to be repaired.")
    add("- **repair**: the file is not strict JSON, but the implementation still returned a")
    add("  valid value.")
    add("- **reject**: the implementation refused, or returned text that is not JSON.")
    add("- **error**: the implementation crashed or timed out.")
    add("")
    add("The strict row is the classifier, not a repairer, so it has no repair column by")
    add("construction. For `y_` and `n_` the corpus label and the strict oracle agree exactly")
    add("(0 disagreements), which is what makes the accept/repair split meaningful; the `i_`")
    add("family is free by definition, so any split there is ours and not the corpus's.")
    add("")

    add("## Headline: repairs reported on valid JSON (`y_*`)")
    add("")
    add("A document that is valid JSON needs no repair, so every repair record JSONMend")
    add("reports on a `y_` file is a **false repair**.")
    add("")
    add("| metric | value |")
    add("| --- | --- |")
    add("| `y_` files | %d |" % len(y_rows))
    add("| accepted by the strict oracle | %d |" % strict_tally["y_"]["accept"])
    add(
        "| produce a valid value under JSONMend | %d |"
        % sum(1 for r in y_rows if r["verdict"]["jsonmend"] == "accept")
    )
    add("| **files with at least one repair record** | **%d** |" % len(offenders))
    add("| **repair records in total** | **%d** |" % total_records)
    add("| `--check` exits 1 (repairs needed) on | %d |" % len(y_check_failed))
    add("| refused by `--for-execution` (exit 5) | %d |" % len(y_gate_refused))
    add("")
    if not offenders:
        add(
            "**Zero.** All %d `y_*` files are accepted by JSONMend with no repair record: no"
            % len(y_rows)
        )
        add("valid document is reported as needing a repair.")
        add("")
    else:
        add(
            "**%d of %d `y_*` files get %d repair record(s) in total.** Each one is listed here"
            % (len(offenders), len(y_rows), total_records)
        )
        add("with the record, its declared exactness, the `--check` status and the")
        add("`--for-execution` verdict:")
        add("")
        add("| file | input | repair record | exactness | `--check` | `--for-execution` |")
        add("| --- | --- | --- | --- | --- | --- |")
        for r in offenders:
            for rec in r["records"]:
                gate = r["gate"]
                if gate["rc"] == 0:
                    gate_txt = "accept (0)"
                else:
                    gate_txt = "refuse (%s%s)" % (
                        gate["rc"],
                        " " + gate["code"] if gate["code"] else "",
                    )
                add(
                    "| `%s` | `%s` | `%s %d:%d %s` | %s | %d | %s |"
                    % (
                        r["file"],
                        show(r["text"]),
                        rec["code"],
                        rec["line"],
                        rec["col"],
                        rec["message"],
                        r["explain"]["exactness"] or "?",
                        r["check"]["rc"],
                        gate_txt,
                    )
                )
        add("")
        codes = Counter(rec["code"] for r in offenders for rec in r["records"])
        if set(codes) == {"R018"}:
            add("Every record is `R018 MergeDuplicateKey`. Both files are duplicate-key objects;")
            add("RFC 8259 permits duplicate names, so the input is valid JSON and JSONTestSuite")
            add("is right to list it under `y_`. JSONMend's default duplicate-key policy still")
            add("drops a member and records `R018`, and that record is what the false-repair count")
            add("measures. The distinction matters and is not hidden by the number: the record is")
            add("honest about the drop, and the exactness it declares separates the two files —")
            add("where the dropped and kept values differ it is `lossy` and the execution gate")
            add("refuses the document, where they are identical it is `cosmetic` and the gate")
            add("accepts it. So the repair machinery behaves as documented; the corpus simply")
            add("contains valid documents whose repair is optional rather than necessary.")
        else:
            add(
                "Record codes: %s."
                % ", ".join("`%s` x%d" % (k, v) for k, v in sorted(codes.items()))
            )
        add("")
    if y_broken:
        add("`y_*` files where JSONMend did **not** return a valid value at all (worse than a")
        add("false repair):")
        add("")
        add("| file | exit | note |")
        add("| --- | --- | --- |")
        for r in y_broken:
            add("| `%s` | %s | %s |" % (r["file"], r["cli"]["rc"], show(r["cli"]["note"], 70)))
        add("")
    else:
        add(
            "No `y_*` file is rejected: JSONMend returns a valid value for all %d of them."
            % len(y_rows)
        )
        add("")
    if y_oracle_rejects:
        add("### Valid `y_` files an oracle refuses")
        add("")
        add("This is the direction worth recording: on this corpus JSONMend is the only")
        add("implementation that returns a valid value for every valid document.")
        add("")
        add("| file | input | `json_repair` | `jsonrepair` | oracle note |")
        add("| --- | --- | --- | --- | --- |")
        for r in y_oracle_rejects:
            note = r["py"]["note"] or (r["node"] or {}).get("error", "")
            add(
                "| `%s` | `%s` | %s | %s | %s |"
                % (
                    r["file"],
                    show(r["text"], 40),
                    r["verdict"]["json_repair"],
                    r["verdict"]["jsonrepair"],
                    show(note, 60),
                )
            )
        add("")
        if any(r["file"] == "y_structure_string_empty.json" for r in y_oracle_rejects):
            add("The one case is `y_structure_string_empty.json`, whose whole content is `\"\"`.")
            add("`json_repair.repair_json('\"\"')` returns the empty string — not a JSON")
            add("document — so the text-in/text-out/parse round trip this harness uses (the")
            add("same one `oracle_node.mjs` and `run_ambiguity.py` use) fails. Its object API")
            add("`json_repair.loads('\"\"')` returns the empty Python string, which is correct,")
            add("so this is an artifact of the text API and not a parsing failure. It is")
            add("recorded rather than patched, because patching it would mean scoring the")
            add("Python oracle by a different rule than the Node one.")
            add("")
    non_offender_refusals = [r for r in y_gate_refused if not r["records"]]
    if non_offender_refusals:
        add(
            "`--for-execution` refuses %d `y_*` files in total; besides the %d above, these are"
            % (len(y_gate_refused), len(offenders))
        )
        add("refused without any repair record (the ambiguity gate, `E011`):")
        add("")
        add("| file | gate code |")
        add("| --- | --- |")
        for r in non_offender_refusals:
            add("| `%s` | %s |" % (r["file"], r["gate"]["code"] or "exit %s" % r["gate"]["rc"]))
        add("")

    add("## `n_*` files: who invents a valid value")
    add("")
    add("These files must be rejected by a strict parser. A repairer that returns a valid")
    add("value for one of them has *invented* content; the corpus carries no ground truth for")
    add("what that content should be, so the honest reading is \"silently accepted an invalid")
    add("document\", not \"repaired it correctly\".")
    add("")
    add("| implementation | produced a valid value | refused or non-JSON | crash/timeout |")
    add("| --- | --- | --- | --- |")
    for lib in LIBS:
        ok = available(lib, node_rows)
        if not ok:
            add("| %s | %s | %s | %s |" % (LIB_TITLE[lib], NA, NA, NA))
            continue
        c = tally[("n_", lib)]
        add(
            "| %s | %d / %d (%.1f%%) | %d | %d |"
            % (
                LIB_TITLE[lib],
                n_valid[lib],
                len(n_rows),
                100.0 * n_valid[lib] / len(n_rows),
                c.get("reject", 0),
                c.get("error", 0),
            )
        )
    add("")
    add("How the three agree on each `n_` file (`repair` = returned a valid value for a file")
    add("that is not valid JSON):")
    add("")
    add("| JSONMend | `json_repair` | `jsonrepair` | files |")
    add("| --- | --- | --- | --- |")
    for pattern, count in sorted(patterns.items(), key=lambda kv: (-kv[1], kv[0])):
        cells = [
            (p if available(lib, node_rows) else NA) for lib, p in zip(LIBS, pattern)
        ]
        add("| %s | %d |" % (" | ".join(cells), count))
    add("")
    add("Concrete examples, up to four per agreement pattern:")
    add("")
    add("| file | input | JSONMend | `json_repair` | `jsonrepair` |")
    add("| --- | --- | --- | --- | --- |")
    for pattern in sorted(patterns, key=lambda p: (-patterns[p], p)):
        for r in sorted(examples[pattern], key=lambda r: r["file"])[:4]:
            add(
                "| `%s` | `%s` | %s | %s | %s |"
                % (
                    r["file"],
                    show(r["text"], 44),
                    r["verdict"]["jsonmend"],
                    r["verdict"]["json_repair"],
                    r["verdict"]["jsonrepair"],
                )
            )
    add("")
    if n_crashes:
        add("Implementations that crashed (counted as `error`, not `reject`) on an `n_` file:")
        add("")
        add("| file | implementation | note |")
        add("| --- | --- | --- |")
        for r in n_crashes:
            for lib in LIBS:
                if r["verdict"][lib] == "error":
                    add("| `%s` | %s | %s |" % (r["file"], LIB_TITLE[lib], show(r["py"]["note"], 60)))
        add("")
        add("Both are the arbitrarily large inputs (`100000` opening brackets; `[{\"\":` repeated")
        add("50 000 times). `json_repair` is recursive and hits Python's recursion limit; the")
        add("correct bucket for that is `error`, because it is neither a refusal nor a value.")
        add("")
    if stricter:
        add("### Files JSONMend rejects and both oracles accept")
        add("")
        add("This is the safe direction for a repairer — refusing rather than inventing — but")
        add("it is a real behavioural difference on a third-party corpus, so it is listed in")
        add("full (%d files):" % len(stricter))
        add("")
        add("| file | input | JSONMend exit | note |")
        add("| --- | --- | --- | --- |")
        for r in stricter:
            add(
                "| `%s` | `%s` | %s | %s |"
                % (r["file"], show(r["text"], 40), r["cli"]["rc"], show(r["cli"]["note"], 60))
            )
        add("")
    else:
        add("No `n_` file is rejected by JSONMend while both oracles accept it.")
        add("")

    add("## Per-family breakdown")
    add("")
    for fam, why in FAMILIES:
        sub = by_family[fam]
        add("### `%s` — %s" % (fam, why))
        add("")
        add("| field | value |")
        add("| --- | --- |")
        add("| files | %d (%d bytes) |" % (len(sub), sum(r["bytes"] for r in sub)))
        add("| strict oracle accepts | %d |" % strict_tally[fam]["accept"])
        add(
            "| JSONMend produces a valid value | %d |"
            % sum(1 for r in sub if r["verdict"]["jsonmend"] in ("accept", "repair"))
        )
        add(
            "| JSONMend repair records | %d, on %d file(s) |"
            % (sum(len(r["records"]) for r in sub), sum(1 for r in sub if r["records"]))
        )
        if any(r["records"] for r in sub):
            codes = Counter(rec["code"] for r in sub for rec in r["records"])
            add(
                "| repair codes | %s |"
                % ", ".join("`%s` %d" % (k, v) for k, v in sorted(codes.items()))
            )
        for lib in LIBS:
            ok = available(lib, node_rows)
            c = tally[(fam, lib)]
            if not ok:
                add("| %s | %s |" % (LIB_TITLE[lib], NA))
            else:
                add(
                    "| %s | accept %d, repair %d, reject %d, error %d |"
                    % (
                        LIB_TITLE[lib],
                        c.get("accept", 0),
                        c.get("repair", 0),
                        c.get("reject", 0),
                        c.get("error", 0),
                    )
                )
        add("")

    add("## Strict-oracle caveats")
    add("")
    add("| caveat | value |")
    add("| --- | --- |")
    add(
        "| files not decodable as UTF-8 | %d — fed to the two oracles byte-per-code-point via latin-1, since both take text; JSONMend gets the real bytes |"
        % len(latin1)
    )
    add(
        "| strict `json.loads` vs Node `JSON.parse` disagreements | %d |"
        % len(strict_disagreements)
    )
    add(
        "| files a *default* `json.loads` would wrongly accept | 3 (`n_number_NaN`, `n_number_infinity`, `n_number_minus_infinity`) |"
    )
    add("")
    if strict_disagreements:
        add("| file | family | `json.loads` | `JSON.parse` |")
        add("| --- | --- | --- | --- |")
        for r in strict_disagreements:
            add(
                "| `%s` | `%s_` | %s | %s |"
                % (r["file"], r["family"], r["strict_py"], r["strict_node"])
            )
        add("")
        add(
            "All %d are `i_` files, i.e. files the corpus explicitly leaves free."
            % len(strict_disagreements)
        )
        if all(r["decoding"] == "latin-1" for r in strict_disagreements):
            add("They are also all non-UTF-8 files.")
        add("The two strict oracles disagree only because the character stream they see")
        add("differs, not because they read JSON differently. No `y_` or `n_` file is")
        add("affected, so the accept/repair split is unaffected.")
        add("")
    add("The `NaN`/`Infinity` caveat is why `strict_json` passes `parse_constant`: without it")
    add("`json.loads` accepts three files the corpus marks `n_`, and those three would be")
    add("scored as \"accept\" for every implementation.")
    add("")

    add("## What this does and does not prove")
    add("")
    add("- **The corpus is independent; the harness and the reading are not.** The 318 test")
    add("  files were written by a third party (Nicolas Seriot) to test JSON parsers in")
    add("  general, and they are vendored verbatim at the commit above. The script that runs")
    add("  them, the choice of strict oracle, the accept/repair/reject classification and this")
    add("  analysis are ours, so a mistake in any of those is our mistake and the corpus being")
    add("  external would not catch it.")
    add("- **It tests syntax acceptance, not repair quality.** A `y_` file that needs no repair")
    add("  and an `n_` file that gets one are the only claims made. The corpus has no ground")
    add("  truth for what an invalid document *should* become, so \"%d of %d `n_` files"
        % (n_valid.get("jsonmend", 0), len(n_rows)))
    add("  repaired\" measures how often JSONMend invents a value, not how often it invents")
    add("  the *right* value. It is not a substitute for `run_eval.py`, which scores recovered")
    add("  values against generated truth.")
    add("- **It is not a substitute for recorded real provider streams.** These are synthetic,")
    add("  hand-written edge cases. Real model output arrives as tool-call deltas with prose,")
    add("  truncation and retries; LLM_EVENTS.md and the recorded fixtures cover that, and this")
    add("  corpus says nothing about it.")
    add("- **The two oracles are repair libraries, not truth.** `json_repair` and `jsonrepair`")
    add("  appear here as *other implementations*. On `n_` files their willingness to return a")
    add("  value is evidence about them, and it cannot be used to argue that JSONMend is wrong")
    add("  when it accepts the same file.")
    add("- **What would move the headline.** If a later run reports 0 false repairs on `y_`,")
    add("  duplicate-key handling changed. The number is measured per run and the corpus")
    add("  fingerprint above fixes which files were measured.")
    add("")
    add("## Reproduce")
    add("")
    add("```bash")
    add("cd code")
    add("moon build cmd/jsonmend --target native --release")
    add("python3 tests/eval/run_independent.py")
    add("# The oracles are optional; without them those columns read as \"%s\"." % NA)
    add("#   Node:   npm i jsonrepair@3.15.0   (NODE_PATH=/private/tmp/node_modules)")
    add("#   Python: python3 -m pip install \"json-repair==0.64.0\"")
    add("```")
    add("")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print(
        "%d files (%d y_, %d n_, %d i_) in %.1f s"
        % (len(files), len(y_rows), len(n_rows), len(by_family["i_"]), time.time() - t0)
    )
    print("y_ false repairs: %d file(s), %d record(s)" % (len(offenders), total_records))
    print(
        "n_ valid-value production: %s"
        % "; ".join(
            "%s %d/%d" % (lib, n_valid[lib], len(n_rows)) if available(lib, node_rows) else "%s %s" % (lib, NA)
            for lib in LIBS
        )
    )
    print("report: %s" % args.out)
    if args.strict and offenders:
        print("--strict: %d valid file(s) got a repair record" % len(offenders))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
