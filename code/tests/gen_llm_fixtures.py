#!/usr/bin/env python3
"""Generate the LLM stream fixtures and their MoonBit embedding.

The fixtures are the evidence for FR-23: one JSON event payload per line, in the
order a provider would send them. Both artifacts are produced from this file, so
the `.jsonl` files (replayed by the demo page) and the embedded copies used by
`moon test` cannot drift apart.

    python3 tests/gen_llm_fixtures.py            # write
    python3 tests/gen_llm_fixtures.py --check    # verify, non-zero on drift
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FIXDIR = ROOT / "llm" / "fixtures"
MBT = ROOT / "llm" / "fixtures_wbtest.mbt"

# ---------------------------------------------------------------------------
# Event builders
# ---------------------------------------------------------------------------


def anth_start(index: int, name: str, cid: str) -> dict:
    return {
        "type": "content_block_start",
        "index": index,
        "content_block": {"type": "tool_use", "id": cid, "name": name, "input": {}},
    }


def anth_delta(index: int, text: str) -> dict:
    return {
        "type": "content_block_delta",
        "index": index,
        "delta": {"type": "input_json_delta", "partial_json": text},
    }


def anth_stop(index: int) -> dict:
    return {"type": "content_block_stop", "index": index}


def oai_chunk(calls: list[dict], finish: str | None = None) -> dict:
    delta: dict = {}
    if calls:
        delta["tool_calls"] = calls
    choice: dict = {"index": 0, "delta": delta}
    if finish is not None:
        choice["finish_reason"] = finish
    return {"id": "chatcmpl-1", "object": "chat.completion.chunk", "choices": [choice]}


def oai_call(index: int, cid: str | None = None, name: str | None = None,
             args: str | None = None) -> dict:
    fn: dict = {}
    if name is not None:
        fn["name"] = name
    if args is not None:
        fn["arguments"] = args
    call: dict = {"index": index, "type": "function", "function": fn}
    if cid is not None:
        call["id"] = cid
    return call


def split(text: str, n: int) -> list[str]:
    """Split `text` into `n` pieces, as evenly as possible."""
    if n <= 1:
        return [text]
    size = max(1, (len(text) + n - 1) // n)
    return [text[i : i + size] for i in range(0, len(text), size)]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def f_anthropic_single() -> tuple[list[dict], list[dict]]:
    args = '{"location":"Paris","unit":"celsius"}'
    events = [anth_start(0, "get_weather", "toolu_01")]
    events += [anth_delta(0, p) for p in split(args, 4)]
    events.append(anth_stop(0))
    return events, [{"index": 0, "name": "get_weather", "args": args}]


def f_anthropic_escape_split() -> tuple[list[dict], list[dict]]:
    # Cuts inside a `\uXXXX` escape and between the two halves of a surrogate
    # pair, which is the hardest split for an incremental scanner.
    args = '{"note":"caf\\u00e9 \\ud83d\\ude00 done"}'
    fragments = ['{"note":"caf\\', "u00e9 \\ud83d", '\\ude00 done"}']
    assert "".join(fragments) == args
    events = [anth_start(0, "note", "toolu_02")]
    events += [anth_delta(0, p) for p in fragments]
    events.append(anth_stop(0))
    return events, [{"index": 0, "name": "note", "args": args}]


def f_anthropic_parallel() -> tuple[list[dict], list[dict]]:
    specs = [
        (0, "search", "toolu_10", '{"q":"alpha"}'),
        (1, "search", "toolu_11", '{"q":"beta","limit":3}'),
        (2, "read_file", "toolu_12", '{"path":"/tmp/x"}'),
    ]
    events: list[dict] = []
    for index, name, cid, _args in specs:
        events.append(anth_start(index, name, cid))
    pieces = {index: split(args, 3) for index, _n, _c, args in specs}
    for step in range(3):
        for index, _n, _c, _args in specs:
            chunk = pieces[index][step] if step < len(pieces[index]) else ""
            if chunk:
                events.append(anth_delta(index, chunk))
    for index, _n, _c, _args in specs:
        events.append(anth_stop(index))
    return events, [
        {"index": i, "name": n, "args": a} for i, n, _c, a in specs
    ]


def f_anthropic_truncated() -> tuple[list[dict], list[dict]]:
    args = '{"location":"Paris","unit":"celsius"}'
    sent = "".join(split(args, 4)[:2])
    events = [anth_start(0, "get_weather", "toolu_20")]
    events += [anth_delta(0, p) for p in split(args, 4)[:2]]
    # No content_block_stop: the response hit max_tokens. The expected
    # argument text is the prefix that actually arrived.
    return events, [{"index": 0, "name": "get_weather", "args": sent}]


def f_anthropic_mixed() -> tuple[list[dict], list[dict]]:
    args = '{"path":"/etc/hosts"}'
    events = [
        {"type": "message_start", "message": {"id": "msg_1", "role": "assistant"}},
        {"type": "content_block_start", "index": 0,
         "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0,
         "delta": {"type": "text_delta", "text": "Let me look "}},
        {"type": "content_block_delta", "index": 0,
         "delta": {"type": "text_delta", "text": "that up."}},
        anth_stop(0),
        anth_start(1, "read_file", "toolu_30"),
        anth_delta(1, args),
        anth_stop(1),
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}},
        {"type": "message_stop"},
    ]
    return events, [{"index": 1, "name": "read_file", "args": args}]


def f_openai_single() -> tuple[list[dict], list[dict]]:
    args = '{"location":"Berlin","unit":"celsius"}'
    events = [
        oai_chunk([oai_call(0, cid="call_1", name="get_weather", args="")]),
    ]
    events += [oai_chunk([oai_call(0, args=p)]) for p in split(args, 3)]
    events.append(oai_chunk([], finish="tool_calls"))
    return events, [{"index": 0, "name": "get_weather", "args": args}]


def f_openai_parallel() -> tuple[list[dict], list[dict]]:
    specs = [
        (0, "search", "call_a", '{"q":"one"}'),
        (1, "search", "call_b", '{"q":"two","n":2}'),
    ]
    events = [
        oai_chunk(
            [
                oai_call(0, cid="call_a", name="search", args=""),
                oai_call(1, cid="call_b", name="search", args=""),
            ]
        )
    ]
    pieces = {index: split(args, 2) for index, _n, _c, args in specs}
    for step in range(2):
        events.append(
            oai_chunk(
                [
                    oai_call(index, args=pieces[index][step])
                    for index, _n, _c, _a in specs
                    if step < len(pieces[index])
                ]
            )
        )
    events.append(oai_chunk([], finish="tool_calls"))
    return events, [{"index": i, "name": n, "args": a} for i, n, _c, a in specs]


def f_openai_truncated() -> tuple[list[dict], list[dict]]:
    args = '{"location":"Berlin","unit":"celsius"}'
    sent = split(args, 3)[0]
    events = [
        oai_chunk([oai_call(0, cid="call_9", name="get_weather", args="")]),
        oai_chunk([oai_call(0, args=sent)]),
        oai_chunk([], finish="length"),
    ]
    return events, [{"index": 0, "name": "get_weather", "args": sent}]


def f_openai_name_only() -> tuple[list[dict], list[dict]]:
    # The name arrives in one chunk and the arguments never do.
    events = [
        oai_chunk([oai_call(0, cid="call_x", name="noop")]),
        oai_chunk([], finish="tool_calls"),
    ]
    return events, [{"index": 0, "name": "noop", "args": ""}]


FIXTURES = {
    "anthropic_single": f_anthropic_single,
    "anthropic_escape_split": f_anthropic_escape_split,
    "anthropic_parallel": f_anthropic_parallel,
    "anthropic_truncated": f_anthropic_truncated,
    "anthropic_mixed": f_anthropic_mixed,
    "openai_single": f_openai_single,
    "openai_parallel": f_openai_parallel,
    "openai_truncated": f_openai_truncated,
    "openai_name_only": f_openai_name_only,
}


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------


def mbt_escape(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        else:
            out.append(ch)
    return "".join(out)


def build() -> dict[str, tuple[str, str]]:
    """Return {name: (jsonl_text, mbt_block)}."""
    out: dict[str, tuple[str, str]] = {}
    for name, make in FIXTURES.items():
        events, calls = make()
        lines = [json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in events]
        jsonl = "\n".join(lines) + "\n"
        block = []
        block.append(f"///|\n/// Events of the `{name}` fixture, one payload per line.")
        block.append(f'let fx_{name} : String = "{mbt_escape(chr(10).join(lines))}"')
        block.append("")
        block.append(f"///|\n/// Expected calls of the `{name}` fixture.")
        block.append(f"let fx_{name}_calls : Array[(Int32, String, String)] = [")
        for c in calls:
            block.append(
                f'  ({c["index"]}, "{mbt_escape(c["name"])}", "{mbt_escape(c["args"])}"),'
            )
        block.append("]")
        block.append("")
        out[name] = (jsonl, "\n".join(block))
    return out


HEADER = """// Generated by `tests/gen_llm_fixtures.py`; do not edit by hand.
//
// Each `fx_*` string holds the event payloads of one fixture, one complete JSON
// document per line, in the order the provider sends them. `fx_*_calls` holds
// the expected `(index, name, arguments)` of every tool call in that fixture.
//
// The matching `.jsonl` files under `llm/fixtures/` are byte identical to the
// embedded copy; `tests/llm_fixtures.sh` checks that.

///|
/// Split an embedded fixture into its non-empty lines.
fn fx_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  for line in s.split("\\n") {
    if line.length() > 0 {
      out.push(line.to_owned())
    }
  }
  out
}

"""


def main() -> int:
    check = "--check" in sys.argv
    built = build()
    problems = []
    if not check:
        FIXDIR.mkdir(parents=True, exist_ok=True)
    for name, (jsonl, _block) in built.items():
        path = FIXDIR / f"{name}.jsonl"
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != jsonl:
                problems.append(str(path))
        else:
            path.write_text(jsonl, encoding="utf-8")
    body = HEADER + "\n".join(built[name][1] for name in FIXTURES)
    if check:
        if not MBT.exists() or MBT.read_text(encoding="utf-8") != body:
            problems.append(str(MBT))
        if problems:
            print("fixture drift:", ", ".join(problems))
            return 1
        print(f"fixtures up to date ({len(built)} files)")
        return 0
    MBT.write_text(body, encoding="utf-8")
    print(f"wrote {len(built)} fixtures to {FIXDIR} and {MBT.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
