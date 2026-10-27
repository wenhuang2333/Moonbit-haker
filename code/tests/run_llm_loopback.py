#!/usr/bin/env python3
"""Replay the loopback and live LLM fixtures through the real adapter.

`code/tests/record_stream.py --loopback` records four scenarios as raw SSE bytes
(*`transport: loopback-sse`*, produced by a local HTTP server and read back over
a real socket — not a vendor capture). `code/llm/fixtures/live_relay_*` are real
live captures from an Anthropic-compatible endpoint (*`transport: live-http-sse`*
with `vendor_capture` recorded per file).

This script is the replay half of that chain. For every fixture it:

  1. re-runs the loopback recorder into a temporary directory and byte-compares
     the result with the committed fixture, so the evidence is reproducible and
     a hand edit cannot survive;
  2. checks the raw `.sse` bytes and the `.jsonl` payload lines agree, and that
     the provenance line says which transport it is;
  3. feeds the fixture to the real CLI twice — through `--sse` (the raw bytes)
     and through the newline-delimited `.jsonl` — and requires both to produce
     the same calls as the golden `.expect.json`.

    python3 code/tests/run_llm_loopback.py
    python3 code/tests/run_llm_loopback.py --cli <path to interjson> --no-regenerate

Exit status 0 only when every scenario matches.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
FIXTURES = os.path.join(ROOT, "llm", "fixtures")
DEFAULT_CLI = os.path.join(
    ROOT, "_build", "native", "release", "build", "cmd", "interjson",
    "interjson.exe",
)

# The scenarios the loopback recorder must produce.
SCENARIOS = ["tool_call", "escape_split", "truncated", "parallel"]

# The fields `interjson llm` prints for one call, and the ones an expectation
# file pins down.
CALL_FIELDS = ["index", "id", "name", "done", "exactness", "end",
               "stop_reason", "value"]


class Failure(Exception):
    pass


def sse_payloads(raw: str) -> list:
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data = line[len("data:"):].strip()
        if data and data != "[DONE]":
            out.append(data)
    return out


def run_cli(cli: str, fixture: str, style: str) -> list:
    """Run the real adapter over one fixture. `style` is `sse` or `jsonl`."""
    cmd = [cli, "llm", "--provider", "anthropic"]
    if style == "sse":
        cmd.append("--sse")
    with open(fixture, "r", encoding="utf-8") as fh:
        proc = subprocess.run(cmd, stdin=fh, capture_output=True, text=True,
                              timeout=120)
    if proc.returncode != 0:
        raise Failure("cli rc=%d: %s" % (proc.returncode, proc.stderr.strip()[:200]))
    calls = []
    for line in proc.stdout.splitlines():
        if line.strip():
            calls.append(json.loads(line))
    return calls


def compare_calls(name: str, got: list, want: list) -> list:
    """Return a list of human readable mismatches."""
    bad = []
    if len(got) != len(want):
        bad.append("%s: %d call(s), expected %d" % (name, len(got), len(want)))
        return bad
    for i, (g, w) in enumerate(zip(got, want)):
        for field in CALL_FIELDS:
            if g.get(field) != w.get(field):
                bad.append("%s[%d].%s: %r != %r"
                           % (name, i, field, g.get(field), w.get(field)))
    return bad


def check_provenance(name: str, sse_text: str, jsonl_text: str) -> None:
    if "transport=loopback-sse" not in sse_text:
        raise Failure("%s: the .sse has no loopback provenance comment" % name)
    first = json.loads(jsonl_text.splitlines()[0])
    if first.get("type") != "interjson.provenance":
        raise Failure("%s: the first .jsonl line is not the provenance event"
                      % name)
    if first.get("transport") != "loopback-sse":
        raise Failure("%s: provenance says %r, not loopback-sse"
                      % (name, first.get("transport")))
    if first.get("vendor_capture") is not False:
        raise Failure("%s: a loopback fixture must not claim a vendor capture"
                      % name)


def check_raw_matches_jsonl(name: str, sse_text: str, jsonl_text: str) -> None:
    payloads = sse_payloads(sse_text)
    lines = [l for l in jsonl_text.splitlines() if l]
    if payloads != lines:
        raise Failure("%s: .jsonl is not exactly the payloads of the .sse "
                      "(%d vs %d lines)" % (name, len(payloads), len(lines)))


def scenario_rules(name: str, calls: list) -> list:
    """Checks that say *why* the scenario matters, beyond the golden file."""
    bad = []
    if name == "tool_call":
        if len(calls) != 1 or calls[0]["end"] != "complete":
            bad.append("tool_call: a normal call must end complete")
        if calls[0]["value"] != {"location": "Paris", "unit": "celsius"}:
            bad.append("tool_call: the argument object was not recovered")
    elif name == "escape_split":
        if len(calls) != 1:
            bad.append("escape_split: expected one call")
        else:
            note = (calls[0].get("value") or {}).get("note")
            if note != "caf\u00e9 \U0001f600 done":
                bad.append("escape_split: a split inside \\uXXXX and between "
                           "surrogates must decode to the exact original "
                           "string, got %r" % (note,))
            if calls[0]["exactness"] != "exact":
                bad.append("escape_split: the value is complete, so it must be "
                           "exact")
    elif name == "truncated":
        if len(calls) != 1:
            bad.append("truncated: expected one call")
        else:
            if calls[0]["end"] != "interrupted":
                bad.append("truncated: a stream with no message_stop must end "
                           "interrupted, got %r" % calls[0]["end"])
            if calls[0]["exactness"] != "lossy":
                bad.append("truncated: closing an unterminated object loses "
                           "information, so it must be lossy")
            if calls[0]["done"] is not True:
                bad.append("truncated: finish() must still close the call")
            if calls[0]["value"] != {"location": "Paris", "unit": "cei"}:
                bad.append("truncated: the arriving prefix must be repaired by "
                           "closing the open string and object")
    elif name == "parallel":
        if len(calls) != 2:
            bad.append("parallel: two interleaved tool_use blocks must yield "
                       "two records, got %d" % len(calls))
        else:
            if [c["index"] for c in calls] != [0, 1]:
                bad.append("parallel: the provider indices must be kept")
            if calls[0]["value"] != {"q": "alpha"}:
                bad.append("parallel: call 0 arguments were mixed up with 1")
            if calls[1]["value"] != {"path": "/tmp/notes.md"}:
                bad.append("parallel: call 1 arguments were mixed up with 0")
    return bad


def regenerate(cli: str, fixtures: str, tmp: str) -> None:
    """Re-record the loopback fixtures and byte-compare them with the repo."""
    script = os.path.join(HERE, "record_stream.py")
    fixdir = os.path.join(fixtures, "")
    argv = [sys.executable, script, "--loopback", "--out", tmp]
    if cli:
        argv += ["--cli", cli]
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise Failure("the recorder failed: %s"
                      % (proc.stderr.strip()[-300:] or proc.stdout[-300:]))
    for name in SCENARIOS:
        for suffix in (".sse", ".jsonl", ".expect.json"):
            a = os.path.join(fixdir, "loopback_%s%s" % (name, suffix))
            b = os.path.join(tmp, "loopback_%s%s" % (name, suffix))
            if not os.path.exists(a):
                raise Failure("missing committed fixture %s" % a)
            with open(a, "rb") as fa, open(b, "rb") as fb:
                if fa.read() != fb.read():
                    raise Failure("loopback_%s%s drifted from a fresh recording"
                                  % (name, suffix))


def live_fixtures(fixtures: str) -> list:
    """Captured streams: any `.jsonl` with a sibling `.provenance.json`."""
    out = []
    for entry in sorted(os.listdir(fixtures)):
        if not entry.endswith(".jsonl") or entry.endswith(".adapter.jsonl"):
            continue
        base = entry[: -len(".jsonl")]
        if entry.startswith("loopback_"):
            continue
        if os.path.exists(os.path.join(fixtures, base + ".provenance.json")):
            out.append(base)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--fixtures", default=FIXTURES)
    ap.add_argument("--no-regenerate", action="store_true",
                    help="skip re-recording the loopback fixtures")
    args = ap.parse_args()

    if not os.path.exists(args.cli):
        print("interjson binary not found at %s; build it with "
              "`moon build cmd/interjson --target native --release`" % args.cli,
              file=sys.stderr)
        return 2

    problems = []
    rows = []

    if not args.no_regenerate:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                regenerate(args.cli, args.fixtures, tmp)
            except Failure as exc:
                problems.append(str(exc))

    for name in SCENARIOS:
        base = os.path.join(args.fixtures, "loopback_%s" % name)
        sse, jsonl = base + ".sse", base + ".jsonl"
        expect = base + ".expect.json"
        for path in (sse, jsonl, expect):
            if not os.path.exists(path):
                problems.append("missing %s" % path)
        if problems and not os.path.exists(expect):
            continue
        with open(sse, encoding="utf-8") as fh:
            sse_text = fh.read()
        with open(jsonl, encoding="utf-8") as fh:
            jsonl_text = fh.read()
        with open(expect, encoding="utf-8") as fh:
            want = json.load(fh)["calls"]
        try:
            check_provenance(name, sse_text, jsonl_text)
            check_raw_matches_jsonl(name, sse_text, jsonl_text)
            via_sse = run_cli(args.cli, sse, "sse")
            via_jsonl = run_cli(args.cli, jsonl, "jsonl")
            problems += compare_calls("%s --sse" % name, via_sse, want)
            problems += compare_calls("%s .jsonl" % name, via_jsonl, want)
            problems += scenario_rules(name, via_sse)
            rows.append((name, len(sse_payloads(sse_text)), len(via_sse),
                         via_sse[0]["end"] if via_sse else "-",
                         via_sse[0]["exactness"] if via_sse else "-"))
        except (Failure, ValueError) as exc:
            problems.append("%s: %s" % (name, exc))
            rows.append((name, 0, 0, "error", "error"))

    for name in live_fixtures(args.fixtures):
        base = os.path.join(args.fixtures, name)
        sse, jsonl = base + ".sse", base + ".jsonl"
        prov = base + ".provenance.json"
        golden = base + ".adapter.jsonl"
        try:
            with open(prov, encoding="utf-8") as fh:
                meta = json.load(fh)
            if meta.get("transport") != "live-http-sse":
                raise Failure("live provenance transport is %r"
                              % meta.get("transport"))
            if meta.get("vendor_capture") is not True:
                raise Failure("a live capture must be marked vendor_capture")
            got = run_cli(args.cli, sse, "sse")
            if os.path.exists(golden):
                with open(golden, encoding="utf-8") as fh:
                    want = [json.loads(l) for l in fh if l.strip()]
                problems += compare_calls(name, got, want)
            if not got:
                raise Failure("the live capture produced no call")
            rows.append((name, len(sse_payloads(open(sse, encoding="utf-8").read())),
                         len(got), got[0]["end"], got[0]["exactness"]))
        except (Failure, ValueError, OSError) as exc:
            problems.append("%s: %s" % (name, exc))
            rows.append((name, 0, 0, "error", "error"))

    print("%-26s %6s %5s  %-14s %-9s" % ("fixture", "events", "calls", "end",
                                         "exactness"))
    print("-" * 66)
    for row in rows:
        print("%-26s %6d %5d  %-14s %-9s"
              % (row[0], row[1], row[2], row[3], row[4]))
    print("-" * 66)
    if problems:
        print("FAIL (%d problem(s)):" % len(problems))
        for p in problems:
            print("  " + p)
        return 1
    print("ok: %d fixture(s) replayed through the real adapter" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
