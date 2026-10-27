#!/usr/bin/env python3
"""Render static/demo/mcp-demo.gif from the real `interjson mcp` transcript.

The responses in the transcript are the ones the server actually produced
(captured with a reference MCP client); this script only paints them. Run from
the repository root:

    python3 code/tests/media/render_mcp_gif.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "static" / "demo" / "mcp-demo.gif"

W, H = 1000, 650
BG = (13, 17, 23)
BAR = (22, 27, 34)
FG = (230, 237, 243)
DIM = (139, 148, 158)
CYAN = (88, 166, 255)
GREEN = (63, 185, 80)
RED = (248, 81, 73)
YELLOW = (210, 153, 34)
BLUE = (121, 192, 255)

FONT = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15)
BOLD = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 15)

# (text, color) — the real MCP values are quoted from the captured session.
LINES = [
    ("$ claude mcp add interjson -- interjson mcp", CYAN),
    ('  Added MCP server "interjson" (stdio)', DIM),
    ("", FG),
    ("$ # model -> tool call create_invoice; max_tokens cuts the args", DIM),
    ('  {"amount":100,"currency":"USD"', FG),
    ("", FG),
    ("  -> tools/call  interjson_gate", BLUE),
    ("  <- decision: lossy_repair      executable: false", RED),
    ("     error: E010  CloseContainer at 1:31", RED),
    ('     retry: "InterJSON refused the arguments: E010 ..."', YELLOW),
    ('            "Re-emit the arguments as valid JSON ..."', YELLOW),
    ("", FG),
    ("$ # the model re-emits", DIM),
    ('  {"amount":100,"currency":"USD"}', FG),
    ("", FG),
    ("  -> tools/call  interjson_gate", BLUE),
    ("  <- decision: safe              executable: true", GREEN),
    ("", FG),
    ('  OK  execute create_invoice({"amount":100,"currency":"USD"})', GREEN),
    ("", FG),
    ("  real `interjson mcp` session · schema = tool.inputSchema", DIM),
]

LINE_H = 26
TOP = 78


def frame(upto: int, cursor: bool = True) -> Image.Image:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    # title bar
    d.rectangle([0, 0, W, 44], fill=BAR)
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([18 + i * 22, 16, 30 + i * 22, 28], fill=color)
    d.text((104, 13), "interjson mcp  —  execution gate over MCP", font=BOLD, fill=DIM)
    y = TOP
    for i, (text, color) in enumerate(LINES):
        if i < upto:
            d.text((34, y), text, font=FONT, fill=color)
        y += LINE_H
    if cursor:
        # cursor at the line after the last visible one
        cy = TOP + min(upto, len(LINES)) * LINE_H
        d.rectangle([34, cy + 2, 43, cy + 20], fill=(88, 166, 255))
    return img


def main() -> None:
    frames = []
    durations = []
    for i in range(1, len(LINES) + 1):
        frames.append(frame(i))
        durations.append(90 if i < len(LINES) else 2600)
    # A short hold on the finished frame makes the last state readable.
    for _ in range(6):
        frames.append(frame(len(LINES), cursor=False))
        durations.append(180)
    frames.append(frame(len(LINES), cursor=False))
    durations.append(3000)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=1,
    )
    # A still for README fallbacks.
    frame(len(LINES), cursor=False).save(OUT.with_suffix(".png"))
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
