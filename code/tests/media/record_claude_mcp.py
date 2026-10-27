#!/usr/bin/env python3
"""Record a real Claude Code session against the InterJSON MCP server.

This script is the only producer of the judge-facing assets:

    static/demo/mcp-claude-session.txt   verbatim transcript of the capture
    static/demo/mcp-claude-session.txt   the transcript itself (committed)
    static/demo/mcp-claude-demo.gif      animation painted from the capture (not committed)
    static/demo/mcp-claude-poster.png    poster painted from the capture (not committed)

Nothing is hand-written.  Every tool input, every tool response and every
sentence of the final summary is read out of the `claude --output-format
stream-json` log that this script captured in the same run.  The script
refuses to write any asset unless the capture really contains

  1. a `interjson_gate` call whose text is truncated JSON,
  2. a tool response carrying the E010 refusal with `executable: false`,
  3. a second `interjson_gate` call with re-emitted arguments,
  4. a second tool response with `executable: true`,

so a failed or refused session produces an error message and no files, never a
plausible-looking mock.

Run from the repository root:

    python3 code/tests/media/record_claude_mcp.py

Options:
    --keep-server     leave `interjson` registered in Claude Code afterwards
    --skip-build      reuse the existing native binary
    --no-render       capture only; do not paint the gif/poster
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BIN = ROOT / "code" / "_build" / "native" / "release" / "build" / "cmd" / "interjson" / "interjson.exe"
RAW = ROOT / "code" / "tests" / "media" / "mcp-claude-raw.jsonl"
OUT_TXT = ROOT / "static" / "demo" / "mcp-claude-session.txt"
OUT_GIF = ROOT / "static" / "demo" / "mcp-claude-demo.gif"
OUT_PNG = ROOT / "static" / "demo" / "mcp-claude-poster.png"

CLAUDE = shutil.which("claude") or str(Path.home() / ".npm-global/bin/claude")
MOON = shutil.which("moon") or str(Path.home() / ".moon/bin/moon")

SERVER = "interjson"
ALLOWED_TOOLS = ",".join(
    [
        "mcp__interjson__interjson_gate",
        "mcp__interjson__interjson_repair",
        "mcp__interjson__interjson_validate",
        "mcp__interjson__interjson_readiness",
    ]
)

# The exact prompt handed to `claude -p`.  It is printed verbatim in the
# transcript; nothing downstream rewrites it.
PROMPT = """You are wiring an execution gate in front of a create_invoice tool. A model produced tool arguments, but the provider stream hit max_tokens and the JSON was cut off mid-object.

Use the interjson_gate MCP tool, and only that tool. Work in these steps:

1. Call interjson_gate with profile "agent" and with this schema_json:
{"type":"object","properties":{"amount":{"type":"number","minimum":0},"currency":{"type":"string","pattern":"^[A-Z]{3}$"}},"required":["amount","currency"]}

For the `text` argument, pass exactly this string, copied character for character:
{"amount":100,"currency":"USD"

That string is 30 characters long. It starts with an opening brace and its last character is the double quote that closes the "USD" value; the closing brace is missing on purpose. It is not valid JSON. Do not repair it before the first call.

2. Read the result. If executable is false, take the retry.prompt and re-emit the arguments as valid JSON yourself, then call interjson_gate again with the same profile and the same schema_json, using your corrected text.

3. Finish with a short summary listing: the first call's decision, the first call's executable flag, the first call's error code, the corrected text you sent on the second call, and the second call's decision and executable flag."""


# --------------------------------------------------------------------------
# process helpers
# --------------------------------------------------------------------------


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def need(proc: subprocess.CompletedProcess, what: str) -> str:
    if proc.returncode != 0:
        sys.exit(f"FAILED: {what}\n{proc.stdout}\n{proc.stderr}")
    return proc.stdout


def build_cli() -> None:
    env = dict(os.environ)
    env["PATH"] = str(Path.home() / ".moon/bin") + os.pathsep + env.get("PATH", "")
    print("[1/6] building the native CLI ...", flush=True)
    proc = subprocess.run(
        [MOON, "build", "cmd/interjson", "--target", "native", "--release"],
        cwd=ROOT / "code",
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        sys.exit(f"FAILED: moon build\n{proc.stdout}\n{proc.stderr}")
    if not BIN.exists():
        sys.exit(f"FAILED: {BIN} does not exist after the build")
    print(f"      {BIN}", flush=True)


def server_registered() -> bool:
    proc = run([CLAUDE, "mcp", "list"])
    return re.search(r"^%s:" % SERVER, proc.stdout, re.M) is not None


def mcp_add() -> str:
    proc = run([CLAUDE, "mcp", "add", SERVER, "--", str(BIN), "mcp"])
    if proc.returncode != 0:
        sys.exit(f"FAILED: claude mcp add\n{proc.stdout}\n{proc.stderr}")
    return proc.stdout + proc.stderr


def mcp_remove() -> None:
    run([CLAUDE, "mcp", "remove", SERVER])


def mcp_list() -> str:
    proc = run([CLAUDE, "mcp", "list"])
    return proc.stdout + proc.stderr


# --------------------------------------------------------------------------
# the session
# --------------------------------------------------------------------------


def record_session() -> tuple[Path, list[str]]:
    print("[4/6] running the real Claude Code session ...", flush=True)
    cmd = [
        CLAUDE,
        "-p",
        PROMPT,
        "--allowedTools",
        ALLOWED_TOOLS,
        "--output-format",
        "stream-json",
        "--verbose",
    ]
    proc = run(cmd, cwd=ROOT)
    RAW.parent.mkdir(parents=True, exist_ok=True)
    RAW.write_text(proc.stdout, encoding="utf-8")
    if proc.returncode != 0:
        sys.exit(
            "FAILED: the Claude Code session exited %d\n--- stdout ---\n%s\n--- stderr ---\n%s"
            % (proc.returncode, proc.stdout[-4000:], proc.stderr[-4000:])
        )
    return RAW, cmd


def parse_session(path: Path) -> dict:
    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            events.append(json.loads(line))
    init = next(
        (e for e in events if e.get("type") == "system" and e.get("subtype") == "init"),
        None,
    )
    final = next((e for e in events if e.get("type") == "result"), None)
    steps = []
    for ev in events:
        if ev.get("type") == "assistant":
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    steps.append(
                        {
                            "kind": "tool_use",
                            "id": block.get("id"),
                            "name": block.get("name"),
                            "input": block.get("input"),
                            "ts": ev.get("timestamp"),
                        }
                    )
                elif block.get("type") == "text" and block.get("text", "").strip():
                    steps.append(
                        {"kind": "text", "text": block["text"], "ts": ev.get("timestamp")}
                    )
        elif ev.get("type") == "user":
            content = ev.get("message", {}).get("content", [])
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    text = "".join(
                        part.get("text", "")
                        for part in block.get("content", [])
                        if isinstance(part, dict)
                    )
                    steps.append(
                        {
                            "kind": "tool_result",
                            "id": block.get("tool_use_id"),
                            "text": text,
                            "ts": ev.get("timestamp"),
                        }
                    )
    return {
        "events": events,
        "init": init,
        "final": final,
        "steps": steps,
    }


def tool_results(parsed: dict) -> list[dict]:
    out = []
    for step in parsed["steps"]:
        if step["kind"] == "tool_result":
            try:
                out.append({**step, "json": json.loads(step["text"])})
            except json.JSONDecodeError:
                out.append({**step, "json": None})
    return out


def verify(parsed: dict) -> dict:
    """Refuse to render anything unless the capture really shows the story."""
    calls = [s for s in parsed["steps"] if s["kind"] == "tool_use"]
    results = tool_results(parsed)
    if len(calls) < 2:
        sys.exit("FAILED: the capture contains fewer than two tool calls")
    if len(results) < 2:
        sys.exit("FAILED: the capture contains fewer than two tool results")
    first_in, second_in = calls[0]["input"], calls[1]["input"]
    first_out, second_out = results[0]["json"], results[1]["json"]
    if first_out is None or second_out is None:
        sys.exit("FAILED: a tool result was not JSON")
    if first_out.get("executable") is not False:
        sys.exit("FAILED: the first call was not refused (executable != false)")
    if (first_out.get("error") or {}).get("code") != "E010":
        sys.exit("FAILED: the first call did not carry the E010 refusal")
    if second_out.get("executable") is not True:
        sys.exit("FAILED: the retry did not reach executable: true")
    if first_in.get("text") == second_in.get("text"):
        sys.exit("FAILED: the retry used the same (truncated) text")
    if first_in.get("text", "").strip().endswith("}"):
        sys.exit("FAILED: the first call was not truncated (its text already ends with })")
    if not second_in.get("text", "").strip().endswith("}"):
        sys.exit("FAILED: the retry text is still truncated")
    canonical = '{"amount":100,"currency":"USD"'
    if first_in.get("text") != canonical:
        print(
            "WARNING: the first call used %r instead of the canonical %r"
            % (first_in.get("text"), canonical),
            flush=True,
        )
    return {
        "first_in": first_in,
        "first_out": first_out,
        "second_in": second_in,
        "second_out": second_out,
    }


# --------------------------------------------------------------------------
# the plain-text transcript
# --------------------------------------------------------------------------


def transcript(parsed: dict, cmd: list[str], env_info: dict) -> str:
    steps = parsed["steps"]
    init = parsed["init"] or {}
    final = parsed["final"] or {}
    mcp_status = next(
        (m for m in init.get("mcp_servers", []) if m.get("name") == SERVER), {}
    )
    out = []
    w = out.append

    w("=" * 78)
    w("InterJSON x Claude Code - a REAL recorded session")
    w("=" * 78)
    w("")
    w("Every line below was produced by the commands shown here.  The raw")
    w("`claude --output-format stream-json` event log is appended verbatim at")
    w("the end of this file, so each statement here can be diffed against the")
    w("bytes the tool actually returned.")
    w("")
    w("-" * 78)
    w("ENVIRONMENT")
    w("-" * 78)
    w(f"recorded at     : {env_info['stamp']}")
    w(f"host            : {env_info['host']}")
    w(f"claude code     : {env_info['claude_version']}")
    w(f"model           : {init.get('model')}")
    w(f"session id      : {init.get('session_id')}")
    w(f"cwd             : {init.get('cwd')}")
    w(f"mcp server      : {SERVER} {env_info['engine_version']} ({mcp_status.get('status')}, scope {mcp_status.get('source')})")
    w(f"server command  : {BIN} mcp")
    w(f"turns           : {final.get('num_turns')}   stop_reason: {final.get('stop_reason')}")
    w(f"is_error        : {final.get('is_error')}")
    w("")
    w("-" * 78)
    w("COMMANDS")
    w("-" * 78)
    w("$ claude --version")
    w(env_info["claude_version"].rstrip())
    w("")
    w("$ claude mcp add interjson -- " + str(BIN) + " mcp")
    for line in env_info["mcp_add"].rstrip().splitlines():
        w("  " + line)
    w("")
    w("$ claude mcp list")
    for line in env_info["mcp_list"].rstrip().splitlines():
        w("  " + line)
    w("")
    w("$ " + " ".join(shell_quote(c) for c in cmd))
    w("")
    w("-" * 78)
    w("THE PROMPT (the exact -p argument)")
    w("-" * 78)
    w(PROMPT)
    w("")
    w("-" * 78)
    w("THE SESSION")
    w("-" * 78)
    w("Tool inputs and tool results below are byte-for-byte what Claude Code")
    w("sent and received.  The JSON responses are shown exactly as they")
    w("arrived: one line, not re-formatted.")
    w("")
    for step in steps:
        if step["kind"] == "tool_use":
            w("-" * 78)
            w(f"assistant -> {step['name']}   (tool_use id {step['id']})")
            if step.get("ts"):
                w(f"timestamp: {step['ts']}")
            w("")
            w("input:")
            w(json.dumps(step["input"], ensure_ascii=False, indent=2))
        elif step["kind"] == "tool_result":
            w("")
            w(f"<- tool_result (for {step['id']})")
            if step.get("ts"):
                w(f"timestamp: {step['ts']}")
            w("")
            w("result (verbatim, single line, as received):")
            w(step["text"])
            w("")
        else:
            w("")
            w("-" * 78)
            w("assistant (final message, verbatim)")
            if step.get("ts"):
                w(f"timestamp: {step['ts']}")
            w("")
            w(step["text"].rstrip())
    w("")
    w("-" * 78)
    w("RESULT EVENT (verbatim summary emitted by Claude Code)")
    w("-" * 78)
    w(json.dumps(
        {k: final.get(k) for k in ("type", "subtype", "is_error", "num_turns", "stop_reason", "duration_api_ms", "total_cost_usd", "result")},
        ensure_ascii=False,
        indent=2,
    ))
    w("")
    w("-" * 78)
    w("RAW EVENT LOG (verbatim `claude --output-format stream-json` stream)")
    w("-" * 78)
    w(Path(RAW).read_text(encoding="utf-8").rstrip())
    w("")
    w("=" * 78)
    w("END OF TRANSCRIPT")
    w("=" * 78)
    return "\n".join(out) + "\n"


def shell_quote(arg: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", arg):
        return arg
    return "'" + arg.replace("'", "'\\''") + "'"


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

W, H = 1180, 760
BG = (13, 17, 23)
BAR = (22, 27, 34)
FG = (230, 237, 243)
DIM = (139, 148, 158)
CYAN = (88, 166, 255)
GREEN = (63, 185, 80)
RED = (248, 81, 73)
YELLOW = (210, 153, 34)
BLUE = (121, 192, 255)
PURPLE = (188, 140, 255)
ORANGE = (255, 166, 87)

LINE_H = 24
TOP = 66
LEFT = 30
FONT_PATH = "/System/Library/Fonts/Menlo.ttc"
FONT_SIZE = 13
COLS = 133


def wrap(text: str, width: int = COLS, prefix: str = "", cont: str = "") -> list[str]:
    if text == "":
        return [prefix.rstrip()]
    lines = []
    for para in text.split("\n"):
        if para == "":
            lines.append("")
            continue
        wrapped = textwrap.wrap(para, width=width, break_on_hyphens=False) or [""]
        for i, piece in enumerate(wrapped):
            lines.append((prefix if i == 0 else cont) + piece)
    return lines


def wrap_json(text: str, width: int) -> list[str]:
    """Wrap a single-line JSON document at safe break points only: after a
    `,`/`}`/`]` outside a string, or at a space.  An escape sequence is never
    split, so the pieces always concatenate back to the original bytes."""
    atoms: list[str] = []
    buf: list[str] = []
    in_string = False
    escaped = False
    for ch in text:
        buf.append(ch)
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            elif ch == " ":
                atoms.append("".join(buf))
                buf = []
        else:
            if ch == '"':
                in_string = True
            elif ch in ",}]":
                atoms.append("".join(buf))
                buf = []
    if buf:
        atoms.append("".join(buf))
    lines: list[str] = []
    current = ""
    for atom in atoms:
        if not current:
            current = atom
        elif len(current) + len(atom) <= width:
            current += atom
        else:
            lines.append(current)
            current = atom
    if current:
        lines.append(current)
    return lines or [""]


def json_line_spans(line: str):
    """Colour a pretty-printed JSON line: the key in blue, the rest plain."""
    m = re.match(r'^(\s*)"([^"]*)"(.*)$', line)
    if m:
        return [(m.group(1) + '"' + m.group(2) + '"', BLUE), (m.group(3), FG)]
    return [(line, FG)]


def json_spans(text: str):
    """Split a JSON string into (text, color) spans.  Colors only; the bytes
    are untouched."""
    spans = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            body = text[i:j]
            # a key is a string followed by ':'
            k = j
            while k < n and text[k] in " \n":
                k += 1
            color = BLUE if k < n and text[k] == ":" else FG
            spans.append((body, color))
            i = j
            continue
        if c.isdigit() or (c == "-" and i + 1 < n and text[i + 1].isdigit()):
            j = i
            while j < n and (text[j].isdigit() or text[j] in ".eE+-"):
                j += 1
            spans.append((text[i:j], YELLOW))
            i = j
            continue
        if text.startswith("true", i) or text.startswith("false", i) or text.startswith("null", i):
            word = "true" if text.startswith("true", i) else "false" if text.startswith("false", i) else "null"
            spans.append((word, PURPLE))
            i += len(word)
            continue
        spans.append((c, DIM))
        i += 1
    return spans


def readout(plan: dict, accent: tuple) -> list[tuple[str, tuple]]:
    """A short, mechanical extraction of the decision fields of a real
    `interjson_gate` response.  Every value is copied from the response."""
    out = []
    rows = [
        ("decision", plan.get("decision")),
        ("exactness", plan.get("exactness")),
        ("execution", plan.get("execution")),
        ("executable", plan.get("executable")),
        (
            "error",
            "{} {}".format(
                (plan.get("error") or {}).get("code", ""),
                (plan.get("error") or {}).get("message", ""),
            ).strip(),
        ),
        ("schema", "%s/%s satisfied" % (plan.get("schema_satisfied"), plan.get("schema_total"))),
    ]
    for key, value in rows:
        label = "  %-13s" % key
        body = str(value)
        first = True
        for piece in textwrap.wrap(body, width=COLS - 20) or [""]:
            out.append(((label if first else " " * 15) + piece, accent if first else DIM))
            first = False
    retry = plan.get("retry")
    if retry:
        out.append(("  retry.prompt", YELLOW))
        for piece in retry.get("prompt", "").split("\n"):
            out.append(("                " + piece, YELLOW))
    return out


def build_chapters(parsed: dict, env_info: dict, cmd: list[str]) -> list[list[tuple[str, tuple]]]:
    """Every chapter is a list of (text, colour) lines taken from the capture."""
    steps = parsed["steps"]
    init = parsed["init"] or {}
    calls = [s for s in steps if s["kind"] == "tool_use"]
    results = tool_results(parsed)
    texts = [s for s in steps if s["kind"] == "text"]
    chapters: list[list[tuple[str, tuple]]] = []

    # 1 - the setup
    c = []
    c.append(("$ claude --version", CYAN))
    c.append(("  " + env_info["claude_version"].rstrip(), FG))
    c.append(("", FG))
    c.append(("$ claude mcp add interjson -- " + str(BIN) + " mcp", CYAN))
    for line in env_info["mcp_add"].rstrip().splitlines():
        c.append(("  " + line, DIM))
    c.append(("", FG))
    c.append(("$ claude mcp list", CYAN))
    for line in env_info["mcp_list"].rstrip().splitlines():
        c.append(("  " + line, DIM))
    chapters.append(c)

    # 2 - the request
    c = []
    c.append(("$ claude -p \"<prompt>\" --allowedTools mcp__interjson__interjson_gate,... \\", CYAN))
    c.append(("    --output-format stream-json --verbose", CYAN))
    c.append(("", FG))
    for line in wrap(PROMPT, COLS - 2, "> ", "> "):
        c.append((line, FG))
    chapters.append(c)

    # 3 - the first call
    c = []
    c.append(("", FG))
    c.append(("● " + calls[0]["name"], BLUE))
    c.append(("  input:", DIM))
    for line in json.dumps(calls[0]["input"], ensure_ascii=False, indent=2).splitlines():
        c.append(([("  ", DIM)] + json_line_spans(line), FG))
    chapters.append(c)

    # 4 - the refusal
    c = []
    c.append(("  └ response (verbatim, wrapped)", DIM))
    for piece in wrap_json(results[0]["text"], COLS - 4):
        c.append(([("  ", DIM)] + json_spans(piece), FG))
    c.append(("", FG))
    c.append(("  ── key fields, read out of the response above ──", DIM))
    for line in readout(results[0]["json"], RED):
        c.append(line)
    chapters.append(c)

    # 5 - the retry
    c = []
    c.append(("", FG))
    c.append(("● " + calls[1]["name"], BLUE))
    c.append(("  input:", DIM))
    for line in json.dumps(calls[1]["input"], ensure_ascii=False, indent=2).splitlines():
        c.append(([("  ", DIM)] + json_line_spans(line), FG))
    chapters.append(c)

    # 6 - the verdict
    c = []
    c.append(("  └ response (verbatim, wrapped)", DIM))
    for piece in wrap_json(results[1]["text"], COLS - 4):
        c.append(([("  ", DIM)] + json_spans(piece), FG))
    c.append(("", FG))
    c.append(("  ── key fields, read out of the response above ──", DIM))
    for line in readout(results[1]["json"], GREEN):
        c.append(line)
    chapters.append(c)

    # 7 - what Claude Code concluded
    c = []
    c.append(("", FG))
    c.append(("● final assistant message (verbatim)", BLUE))
    for line in wrap(texts[-1]["text"], COLS - 2, "", "  "):
        c.append((line, FG))
    chapters.append(c)
    return chapters


def render_gif(chapters, out_path: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    bold = ImageFont.truetype(FONT_PATH, FONT_SIZE)

    def draw_line(d, x, y, item):
        text, color = item
        if isinstance(text, str):
            d.text((x, y), text, font=font, fill=color)
            return
        cx = x
        for span, span_color in text:
            d.text((cx, y), span, font=font, fill=span_color)
            cx += d.textlength(span, font=font)

    def screen(chapter, upto):
        img = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, W, 44], fill=BAR)
        for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
            d.ellipse([18 + i * 22, 16, 30 + i * 22, 28], fill=color)
        d.text(
            (104, 14),
            "claude  -  interjson execution gate over MCP  -  real session",
            font=bold,
            fill=DIM,
        )
        d.line([(0, 45), (W, 45)], fill=(48, 54, 61))
        y = TOP
        for item in chapter[:upto]:
            draw_line(d, LEFT, y, item)
            y += LINE_H
        return img

    frames = []
    durations = []
    for chapter in chapters:
        for i in range(1, len(chapter) + 1):
            frames.append(screen(chapter, i))
            durations.append(70)
        frames.append(screen(chapter, len(chapter)))
        durations.append(900)
    frames.append(screen(chapters[-1], len(chapters[-1])))
    durations.append(4000)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        out_path,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=1,
    )


def render_poster(parsed: dict, env_info: dict, out_path: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    results = tool_results(parsed)
    init = parsed["init"] or {}
    final = parsed["final"] or {}
    first_in = [s for s in parsed["steps"] if s["kind"] == "tool_use"][0]["input"]
    second_in = [s for s in parsed["steps"] if s["kind"] == "tool_use"][1]["input"]
    first = results[0]["json"]
    second = results[1]["json"]

    PW, PH = 1400, 920
    img = Image.new("RGB", (PW, PH), BG)
    d = ImageDraw.Draw(img)
    big = ImageFont.truetype(FONT_PATH, 30)
    mid = ImageFont.truetype(FONT_PATH, 18)
    small = ImageFont.truetype(FONT_PATH, 14)
    mono = ImageFont.truetype(FONT_PATH, 15)

    d.rectangle([0, 0, PW, 56], fill=BAR)
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([24 + i * 24, 20, 38 + i * 24, 34], fill=color)
    d.text((116, 19), "interjson x Claude Code", font=mid, fill=DIM)

    d.text((64, 96), "InterJSON x Claude Code", font=big, fill=FG)
    d.text(
        (64, 146),
        "A real session: truncated tool arguments -> E010 refusal -> retry -> executable",
        font=mid,
        fill=CYAN,
    )
    d.line([(64, 196), (PW - 64, 196)], fill=(48, 54, 61))

    # left card: the refusal
    def card(x, title, accent, lines):
        d.rounded_rectangle(
            [x, 226, x + 620, 226 + 480], radius=12, fill=(22, 27, 34), outline=(48, 54, 61)
        )
        d.text((x + 28, 252), title, font=mid, fill=accent)
        y = 296
        for text, color in lines:
            for piece in textwrap.wrap(text, width=60) or [""]:
                d.text((x + 28, y), piece, font=mono, fill=color)
                y += 22
            y += 4
        return y

    card(
        64,
        "1st call - interjson_gate",
        RED,
        [
            ("text: " + json.dumps(first_in["text"]), FG),
            ("profile: " + first_in.get("profile", ""), DIM),
            ("", FG),
            ("decision: " + str(first.get("decision")), RED),
            ("executable: " + str(first.get("executable")), RED),
            ("error.code: " + (first.get("error") or {}).get("code", ""), RED),
            ("error.message: " + (first.get("error") or {}).get("message", ""), RED),
            ("", FG),
            ("retry.prompt", YELLOW),
            ((first.get("retry") or {}).get("prompt", ""), YELLOW),
        ],
    )
    card(
        716,
        "2nd call - interjson_gate",
        GREEN,
        [
            ("text: " + json.dumps(second_in["text"]), FG),
            ("profile: " + second_in.get("profile", ""), DIM),
            ("", FG),
            ("decision: " + str(second.get("decision")), GREEN),
            ("executable: " + str(second.get("executable")), GREEN),
            ("schema: " + str(second.get("schema_satisfied")) + "/" + str(second.get("schema_total")) + " satisfied", GREEN),
            ("value: " + json.dumps(second.get("value")), GREEN),
            ("", FG),
            ("OK  execute create_invoice(" + json.dumps(second.get("value")) + ")", GREEN),
        ],
    )

    d.text(
        (64, 754),
        "Recorded with Claude Code "
        + env_info["claude_version"].split()[0]
        + "  |  model "
        + str(init.get("model"))
        + "  |  session "
        + str(init.get("session_id")),
        font=small,
        fill=DIM,
    )
    d.text(
        (64, 778),
        "MCP server: interjson "
        + env_info["engine_version"]
        + " (MoonBit engine, native build) - connected over stdio"
        + "  |  "
        + final.get("stop_reason", "")
        + ", "
        + str(final.get("num_turns"))
        + " turns",
        font=small,
        fill=DIM,
    )
    d.text(
        (64, 802),
        "Every value on this poster comes from the captured session; the full transcript is mcp-claude-session.txt",
        font=small,
        fill=(72, 79, 88),
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--keep-server", action="store_true")
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument(
        "--render-only",
        action="store_true",
        help="reuse code/tests/media/mcp-claude-raw.jsonl instead of recording a new session",
    )
    args = ap.parse_args()

    if args.render_only:
        if not RAW.exists():
            sys.exit(f"FAILED: {RAW} does not exist; run without --render-only first")
        print("[1/6] reusing the existing capture (--render-only)", flush=True)
        raw_path = RAW
        cmd = [
            CLAUDE,
            "-p",
            PROMPT,
            "--allowedTools",
            ALLOWED_TOOLS,
            "--output-format",
            "stream-json",
            "--verbose",
        ]
        add_out = "(reused capture; see the raw event log for the original run)"
        list_out = "(reused capture)"
    else:
        if not args.skip_build:
            build_cli()
        else:
            print("[1/6] reusing the existing native binary", flush=True)
            if not BIN.exists():
                sys.exit(f"FAILED: {BIN} does not exist")

        print("[2/6] registering the MCP server ...", flush=True)
        if server_registered():
            # re-register so the transcript shows a genuine `claude mcp add`
            mcp_remove()
        add_out = mcp_add()
        list_out = mcp_list()
        print(
            "      " + [l for l in list_out.splitlines() if l.startswith(SERVER)][0],
            flush=True,
        )

        try:
            raw_path, cmd = record_session()
        finally:
            if not args.keep_server:
                print("[5/6] removing the throwaway MCP registration ...", flush=True)
                mcp_remove()

    print("[3/6] parsing the capture ...", flush=True)
    parsed = parse_session(raw_path)
    facts = verify(parsed)
    print("      E010 refusal captured, retry captured, executable verdict captured", flush=True)

    env_info = {
        "stamp": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"),
        "host": " ".join(os.uname()),
        "claude_version": need(run([CLAUDE, "--version"]), "claude --version").strip(),
        "engine_version": need(run([str(BIN), "--version"]), "interjson --version").strip().split()[-1],
        "mcp_add": add_out,
        "mcp_list": list_out,
    }

    print("[6/6] writing the assets ...", flush=True)
    OUT_TXT.write_text(transcript(parsed, cmd, env_info), encoding="utf-8")
    print(f"      {OUT_TXT} ({OUT_TXT.stat().st_size} bytes)", flush=True)
    if not args.no_render:
        chapters = build_chapters(parsed, env_info, cmd)
        render_gif(chapters, OUT_GIF)
        print(f"      {OUT_GIF} ({OUT_GIF.stat().st_size} bytes)", flush=True)
        render_poster(parsed, env_info, OUT_PNG)
        print(f"      {OUT_PNG} ({OUT_PNG.stat().st_size} bytes)", flush=True)
    print(f"      raw log: {raw_path}", flush=True)
    print("done.", flush=True)


if __name__ == "__main__":
    main()
