#!/usr/bin/env python3
"""Run the registered corpus through the streaming paths and the adapter path.

The registered evaluation (`run_eval.py`) drives `interjson --batch`, which feeds
each document in one piece. That leaves two claim gaps:

  * the *streaming* path is never exercised, although it is the path a model
    drives;
  * the `interjson/llm` adapters are only checked against synthetic fixtures.

This harness closes both, against the same frozen corpus and the same truth:

  1. `--batch --chunk K` for K in {1, 3, 7} and for a pseudo-random K per case,
     so chunk boundaries fall inside tokens, escapes, surrogate pairs and
     multi-byte UTF-8 sequences;
  2. the adapter path: the same fragments are wrapped in Anthropic and
     OpenAI-compatible tool-call events and read back with `interjson llm
     --batch`.

    python3 code/tests/eval/run_eval_paths.py --cli <path to interjson>

Exit status 0 when every path recovers the same value as the registered
one-shot path.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "docs", "EVAL_PATHS.md")
CHUNK_SEED = 20261016

sys.path.insert(0, HERE)
import corpus as corpus_mod  # noqa: E402
from run_eval import same  # noqa: E402


def run_batch(cli, cases, extra=()):
    payload = "".join(
        json.dumps({"id": c["id"], "input": c["input"]}, ensure_ascii=False) + "\n"
        for c in cases
    )
    proc = subprocess.run(
        [cli, "--batch", *extra],
        input=payload,
        capture_output=True,
        text=True,
        timeout=1800,
    )
    if proc.returncode != 0:
        raise SystemExit(
            "batch run failed (rc=%d): %s" % (proc.returncode, proc.stderr[:400])
        )
    out = {}
    for line in proc.stdout.splitlines():
        if line.strip():
            row = json.loads(line)
            out[row["id"]] = row
    return out


def run_llm_batch(cli, cases, provider):
    payload = "".join(
        json.dumps(
            {"id": c["id"], "events": c["events"]},
            ensure_ascii=False,
        )
        + "\n"
        for c in cases
    )
    # `prose` is the one family that needs a flag: the adapter path must see the
    # same options as the one-shot baseline, or the comparison is meaningless.
    prose = [c for c in cases if c["family"] == "prose"]
    rest = [c for c in cases if c["family"] != "prose"]

    def one(group, extra):
        body = "".join(
            json.dumps({"id": c["id"], "events": c["events"]}, ensure_ascii=False) + "\n"
            for c in group
        )
        p = subprocess.run(
            [cli, "llm", "--provider", provider, "--batch", *extra],
            input=body,
            capture_output=True,
            text=True,
            timeout=1800,
        )
        if p.returncode != 0:
            raise SystemExit(
                "llm batch run failed (rc=%d): %s" % (p.returncode, p.stderr[:400])
            )
        out = {}
        for line in p.stdout.splitlines():
            if line.strip():
                row = json.loads(line)
                out[row["id"]] = row
        return out

    merged = one(rest, [])
    merged.update(one(prose, ["--skip-prose"]))
    return merged, None


def text_chunks(text: str, rng: random.Random, lo=1, hi=8):
    """Split `text` into random chunks without breaking a surrogate pair."""
    chunks = []
    i = 0
    n = len(text)
    while i < n:
        k = rng.randint(lo, hi)
        j = min(n, i + k)
        # never cut between a high and a low surrogate
        if 0 < j < n and 0xD800 <= ord(text[j - 1]) <= 0xDBFF and 0xDC00 <= ord(text[j]) <= 0xDFFF:
            j += 1
        chunks.append(text[i:j])
        i = j
    return chunks


def anthropic_events(fragments):
    events = [
        json.dumps(
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "tool_use", "id": "toolu_x", "name": "f", "input": {}},
            }
        )
    ]
    for f in fragments:
        events.append(
            json.dumps(
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": f},
                }
            )
        )
    events.append(json.dumps({"type": "content_block_stop", "index": 0}))
    return events


def openai_events(fragments):
    events = []
    for i, f in enumerate(fragments):
        call = {"index": 0, "function": {"arguments": f}}
        if i == 0:
            call["id"] = "call_x"
            call["function"] = {"name": "f", "arguments": f}
        events.append(json.dumps({"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]}))
    events.append(json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}))
    return events


def openai_text_events(fragments):
    """The same fragments as a chat answer: `choices[].delta.content`."""
    events = [
        json.dumps({"choices": [{"index": 0, "delta": {"content": f}}]}) for f in fragments
    ]
    events.append(json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}))
    return events


def anthropic_text_events(fragments):
    """The same fragments as an Anthropic text block."""
    events = [
        json.dumps(
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": f},
            }
        )
        for f in fragments
    ]
    events.append(json.dumps({"type": "message_delta", "delta": {"stop_reason": "end_turn"}}))
    events.append(json.dumps({"type": "message_stop"}))
    return events


def run_llm_text_batch(cli, cases, provider):
    """Run the text path over `{"id","events"}` lines.

    A prose case is one where the model wraps the value in a sentence, so it is
    the case that needs `--skip-prose`; every other family is read with the same
    options as the tool-call path. The split matters: `--skip-prose` only starts
    a value at `{` or `[`, so leaving it on would lose every scalar root.
    """
    rows = {}
    for group, extra in (
        ([c for c in cases if c["family"] != "prose"], []),
        ([c for c in cases if c["family"] == "prose"], ["--skip-prose"]),
    ):
        body = "".join(
            json.dumps({"id": c["id"], "events": c["events"]}, ensure_ascii=False) + "\n"
            for c in group
        )
        proc = subprocess.run(
            [cli, "llm", "--provider", provider, "--text", "--batch", *extra],
            input=body,
            capture_output=True,
            text=True,
            timeout=1800,
        )
        if proc.returncode != 0:
            raise SystemExit(
                "llm --text batch failed (rc=%d): %s" % (proc.returncode, proc.stderr[:400])
            )
        for line in proc.stdout.splitlines():
            if line.strip():
                row = json.loads(line)
                rows[row["id"]] = row
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--target", type=int, default=corpus_mod.TARGET)
    ap.add_argument("--seed", type=int, default=corpus_mod.SEED)
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    cases, skipped = corpus_mod.build(args.target, args.seed)
    # The generator counts a rejected candidate as "skipped"; a clean corpus
    # still leaves a few, because the retry loop overshoots the target. The
    # number is reported so that it cannot silently drift.

    data_hash = corpus_mod.fingerprint(cases)
    rng = random.Random(CHUNK_SEED)

    prose = [c for c in cases if c["family"] == "prose"]
    rest = [c for c in cases if c["family"] != "prose"]
    base = run_batch(args.cli, rest)
    base.update(run_batch(args.cli, prose, extra=["--skip-prose"]))

    def baseline(case):
        row = base.get(case["id"])
        return row is not None and row["rc"] == 0 and same(row.get("value"), case["truth"])

    base_hits = sum(1 for c in cases if baseline(c))

    # ---- streaming: fixed and per-case random byte chunk sizes --------------
    sizes = [1, 3, 7]
    per_case = {c["id"]: rng.choice([1, 2, 4, 5, 11, 13, 16]) for c in cases}
    groups = {}
    for c in cases:
        key = (per_case[c["id"]], c["family"] == "prose")
        groups.setdefault(key, []).append(c)

    stream_rows = {s: {} for s in sizes}
    for s in sizes:
        stream_rows[s] = {}
        stream_rows[s].update(run_batch(args.cli, rest, extra=["--chunk", str(s)]))
        stream_rows[s].update(
            run_batch(args.cli, prose, extra=["--chunk", str(s), "--skip-prose"])
        )
    rand_rows = {}
    for (k, is_prose), group in groups.items():
        extra = ["--chunk", str(k)]
        if is_prose:
            extra.append("--skip-prose")
        rand_rows.update(run_batch(args.cli, group, extra=extra))

    # ---- adapter path, on both providers ----------------------------------
    # The events of one provider overwrite the events of the other, so each
    # provider is built and run before the next one is built.
    llm_rows = {}
    for provider, builder in (("anthropic", anthropic_events), ("openai", openai_events)):
        for c in cases:
            c["events"] = builder(text_chunks(c["input"], rng))
        rows, _ = run_llm_batch(args.cli, cases, provider)
        llm_rows[provider] = rows

    # ---- text path: the JSON arrives as ordinary text, not as tool arguments
    # The prose family is the one that needs `--skip-prose`; `run_llm_text_batch`
    # splits the corpus accordingly.
    text_rows = {}
    for provider, builder in (
        ("anthropic", anthropic_text_events),
        ("openai", openai_text_events),
    ):
        for c in cases:
            c["events"] = builder(text_chunks(c["input"], rng))
        text_rows[provider] = run_llm_text_batch(args.cli, cases, provider)

    def stream_ok(row, case):
        if row is None or row["rc"] != 0:
            return False
        return same(row.get("value"), case["truth"])

    def llm_ok(row, case):
        if row is None or row["rc"] != 0:
            return False
        calls = row.get("calls") or []
        if len(calls) != 1:
            return False
        call = calls[0]
        if call.get("value") is None and case["truth"] is None:
            return True
        return same(call.get("value"), case["truth"])

    paths = []
    for label, table in [
        ("chunk=1", stream_rows[1]),
        ("chunk=3", stream_rows[3]),
        ("chunk=7", stream_rows[7]),
        ("chunk=random", rand_rows),
    ]:
        hits = sum(1 for c in cases if stream_ok(table.get(c["id"]), c))
        paths.append((label, hits, len(cases)))

    for provider in ("anthropic", "openai"):
        rows = llm_rows[provider]
        hits = sum(1 for c in cases if llm_ok(rows.get(c["id"]), c))
        paths.append(("llm/" + provider + " (tool args)", hits, len(cases)))
    for provider in ("anthropic", "openai"):
        rows = text_rows[provider]
        hits = sum(1 for c in cases if llm_ok(rows.get(c["id"]), c))
        paths.append(("llm/" + provider + " (text)", hits, len(cases)))

    # Does any path recover more than the one-shot path? A path that disagrees
    # with the one-shot path on a case the one-shot path got right is a
    # regression, and is reported separately.
    regressions = []
    for c in cases:
        if not baseline(c):
            continue
        for label, table in [
            ("chunk=1", stream_rows[1]),
            ("chunk=3", stream_rows[3]),
            ("chunk=7", stream_rows[7]),
            ("chunk=random", rand_rows),
        ]:
            if not stream_ok(table.get(c["id"]), c):
                regressions.append((c["id"], c["family"], label))
        for provider in ("anthropic", "openai"):
            if not llm_ok(llm_rows[provider].get(c["id"]), c):
                regressions.append((c["id"], c["family"], "llm/" + provider))
        for provider in ("anthropic", "openai"):
            if not llm_ok(text_rows[provider].get(c["id"]), c):
                regressions.append((c["id"], c["family"], "text/" + provider))

    # ---- ambiguity census on the same corpus ------------------------------
    amb = {}
    for c in cases:
        row = base.get(c["id"]) or {}
        flag = bool(row.get("ambiguous"))
        fam = c["family"]
        n, k = amb.get(fam, (0, 0))
        amb[fam] = (n + 1, k + (1 if flag else 0))

    lines = []
    lines.append("# Evaluation of the streaming and adapter paths (I-4, round 5)")
    lines.append("")
    lines.append(
        "Generated by `code/tests/eval/run_eval_paths.py` on %s."
        % datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    )
    lines.append("")
    lines.append("| field | value |")
    lines.append("| --- | --- |")
    lines.append("| corpus | `eval-2`, %d cases |" % len(cases))
    lines.append("| corpus fingerprint | `%s` |" % data_hash)
    lines.append("| random chunk seed | `%d` |" % CHUNK_SEED)
    # `skipped` counts candidates the generator rejected (a mutation that could
    # not be applied, or one that left valid JSON), not lost cases: the corpus
    # still has exactly the requested size.
    lines.append("| candidates rejected by the generator | %d |" % skipped)
    lines.append("| one-shot baseline hits | %d / %d |" % (base_hits, len(cases)))
    lines.append("")
    lines.append("## Every path against the same truth")
    lines.append("")
    lines.append("| path | recovered truth | rate |")
    lines.append("| --- | --- | --- |")
    for label, hits, n in paths:
        lines.append("| %s | %d / %d | %.2f%% |" % (label, hits, n, 100.0 * hits / n))
    lines.append("")
    lines.append(
        "`chunk=random` uses a pseudo-random chunk size per case drawn from "
        "1, 2, 4, 5, 11, 13, 16 bytes, so token boundaries, escapes, surrogate "
        "pairs and multi-byte sequences are split at a different place in every "
        "case. `llm/* (tool args)` wraps the same fragments in provider tool "
        "call events (`input_json_delta` / `delta.tool_calls`) and reads them "
        "back through the adapter. `llm/* (text)` wraps them in text deltas "
        "(`delta.text` / `delta.content`) instead, which is the path a structured "
        "output request takes; the prose family is the one that needs "
        "`--skip-prose` there."
    )
    lines.append("")
    lines.append("## Disagreements with the one-shot path")
    lines.append("")
    if regressions:
        lines.append("| case | family | path |")
        lines.append("| --- | --- | --- |")
        for cid, fam, label in regressions[:60]:
            lines.append("| `%s` | %s | %s |" % (cid, fam, label))
        if len(regressions) > 60:
            lines.append("")
            lines.append("(%d more)" % (len(regressions) - 60))
    else:
        lines.append(
            "None: every chunking and both adapters recover exactly the value "
            "the one-shot path recovers, on every case."
        )
    lines.append("")
    lines.append("## Ambiguity census (FR-27)")
    lines.append("")
    lines.append("| family | cases | flagged ambiguous |")
    lines.append("| --- | --- | --- |")
    for fam in sorted(amb):
        n, k = amb[fam]
        lines.append("| %s | %d | %d |" % (fam, n, k))
    lines.append("")
    lines.append(
        "The flag is informational by default; `--for-execution` turns a flagged "
        "case into `E011`. A family with no flagged cases repairs without a "
        "second reading, which is what the exactness labels assume."
    )
    lines.append("")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print("\n".join(lines))
    ok = all(hits == n for _l, hits, n in paths) and not regressions
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
