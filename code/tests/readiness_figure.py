#!/usr/bin/env python3
"""Draw the field readiness curve for the README (FR-29).

The metric the fifth-round review asked for is "for every field, what fraction of
the input had been consumed when its value became final", with 1.0 (the value is
final exactly when its share of the input has been read) as the ideal baseline.
This script asks the `readiness` subcommand for the real numbers and draws them;
nothing in the figure is hand-written.

    python3 code/tests/readiness_figure.py [--cli <path>] [--out static/readiness-curve.svg]

The figure has two panels:

* left: the per-field points of a tool-call document (x = field order, y = the
  permille at which the field was final), with the ideal diagonal drawn through
  the middle of each field's own input span;
* right: the decile curve of a flat 200-member record, which is where the metric
  is at its most informative — and where the ideal diagonal is nearly reached.

Both panels state the measured number, not a smoothed one, and the caption in the
README repeats the caveat that the metric covers top-level members only.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORKSPACE = os.path.abspath(os.path.join(ROOT, ".."))
DEFAULT_CLI = os.path.join(
    ROOT, "_build", "native", "release", "build", "cmd", "jsonmend", "jsonmend.exe"
)
DEFAULT_OUT = os.path.join(WORKSPACE, "static", "readiness-curve.svg")

TOOL_CALL = {
    "name": "get_weather",
    "arguments": {"city": "Paris", "units": "metric", "days": 3, "verbose": True},
    "id": "call_1",
}


def flat_record(members: int) -> dict:
    return {"field_%03d" % i: i for i in range(members)}


def run_readiness(cli: str, doc) -> dict:
    with open("/tmp/_readiness_input.json", "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    out = subprocess.run(
        [cli, "readiness", "/tmp/_readiness_input.json"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    result = {"fields": [], "median": None, "deciles": [], "curve": []}
    for line in out.splitlines():
        if line.startswith("jsonmend: readiness"):
            # `... median 855/1000 fields 3 early-stop-saving 17/1000 curve 0 0 ...`
            toks = line.split()
            result["median"] = int(toks[toks.index("median") + 1].split("/")[0])
            curve = toks[toks.index("curve") + 1 :]
            result["curve"] = [int(c) for c in curve]
            result["deciles"] = result["curve"]
            saving = toks[toks.index("early-stop-saving") + 1]
            result["saving"] = int(saving.split("/")[0])
        elif line.startswith("field "):
            _, name, permille = line.split()
            result["fields"].append((name, int(permille)))
    return result


def build_svg(tool, flat) -> str:
    W, H = 960, 420
    pad = 46
    half = (W - 3 * pad) / 2
    top = 78
    bottom = H - 52
    parts = []
    parts.append(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" font-family="-apple-system,Helvetica,Arial,sans-serif">'
        % (W, H, W, H)
    )
    parts.append('<rect width="%d" height="%d" fill="#ffffff"/>' % (W, H))
    parts.append(
        '<text x="%d" y="34" font-size="19" font-weight="600" fill="#111">'
        "Field readiness: when is each top-level field final?</text>" % pad
    )
    parts.append(
        '<text x="%d" y="56" font-size="13" fill="#555">'
        "y = permille of the input consumed when the field stopped changing "
        "(1000 = the whole document). The diagonal is the ideal baseline: a field "
        "final at its own share of the input.</text>" % pad
    )

    def frame(x0, title, note):
        parts.append(
            '<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="#fafafa" '
            'stroke="#e2e2e2"/>' % (x0, top, half, bottom - top)
        )
        parts.append(
            '<text x="%.1f" y="%d" font-size="14" font-weight="600" fill="#222">%s</text>'
            % (x0 + 12, top + 22, title)
        )
        parts.append(
            '<text x="%.1f" y="%d" font-size="12" fill="#666">%s</text>'
            % (x0 + 12, top + 40, note)
        )
        # y grid at 0 / 500 / 1000
        for pm in (0, 250, 500, 750, 1000):
            y = bottom - (bottom - (top + 56)) * pm / 1000.0
            parts.append(
                '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#ececec"/>'
                % (x0 + 44, y, x0 + half - 14, y)
            )
            parts.append(
                '<text x="%.1f" y="%.1f" font-size="10" fill="#999" text-anchor="end">%d</text>'
                % (x0 + 40, y + 3, pm)
            )
        # ideal diagonal
        parts.append(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#b9c6d6" '
            'stroke-width="2" stroke-dasharray="5 4"/>'
            % (x0 + 44, bottom, x0 + half - 14, top + 56)
        )

    # Left panel: the tool call.
    frame(pad, "Tool call (3 top-level fields)", "nested `arguments` cannot settle early")
    inner_x = pad + 44
    inner_w = half - 58
    inner_h = bottom - (top + 56)
    n = max(1, len(tool["fields"]))
    for i, (name, pm) in enumerate(tool["fields"]):
        x = inner_x + inner_w * (i + 0.5) / n
        y = bottom - inner_h * pm / 1000.0
        parts.append('<circle cx="%.1f" cy="%.1f" r="5" fill="#d64545"/>' % (x, y))
        parts.append(
            '<text x="%.1f" y="%.1f" font-size="11" fill="#333" text-anchor="middle">%s %d</text>'
            % (x, y - 10, name, pm)
        )
    parts.append(
        '<text x="%.1f" y="%.1f" font-size="11" fill="#666">median %d/1000</text>'
        % (pad + 12, bottom - 8, tool["median"])
    )

    # Right panel: the flat record's deciles.
    x0 = pad * 2 + half
    frame(x0, "Flat record (%d top-level members)" % len(flat["fields"]), "decile curve: nearly the ideal diagonal")
    deciles = flat["deciles"]
    inner_x = x0 + 44
    inner_w = half - 58
    path = []
    for k, pm in enumerate(deciles):
        x = inner_x + inner_w * k / (len(deciles) - 1)
        y = bottom - inner_h * pm / 1000.0
        path.append(("%.1f,%.1f" % (x, y)))
    parts.append(
        '<polyline fill="none" stroke="#2f6f4f" stroke-width="2.5" points="%s"/>'
        % " ".join(path)
    )
    for k, pm in enumerate(deciles):
        x = inner_x + inner_w * k / (len(deciles) - 1)
        y = bottom - inner_h * pm / 1000.0
        parts.append('<circle cx="%.1f" cy="%.1f" r="3.5" fill="#2f6f4f"/>' % (x, y))
    parts.append(
        '<text x="%.1f" y="%.1f" font-size="11" fill="#666">deciles %s</text>'
        % (x0 + 12, bottom - 8, " ".join(str(d) for d in deciles))
    )
    parts.append(
        '<text x="%d" y="%d" font-size="11" fill="#888">'
        "generated by code/tests/readiness_figure.py from `jsonmend readiness` output</text>"
        % (pad, H - 16)
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    tool = run_readiness(args.cli, TOOL_CALL)
    flat = run_readiness(args.cli, flat_record(200))
    svg = build_svg(tool, flat)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(svg)
    print("tool call : median %d/1000, fields %s" % (tool["median"], tool["fields"]))
    print("flat      : deciles %s, early-stop saving %d/1000" % (flat["deciles"], flat["saving"]))
    print("written   : %s (%d bytes)" % (args.out, len(svg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
