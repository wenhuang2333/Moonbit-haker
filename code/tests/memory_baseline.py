#!/usr/bin/env python3
"""Peak memory of the same parse in JSONMend, Node and Python (NFR-PERF-04).

The 0.3.0 report only compared JSONMend 0.3.0 with 0.2.0, which cannot answer
"is the 4x input budget reasonable": for that the same document has to be parsed
by the other implementations a caller would actually use. This harness does
exactly that, on one file, in one process at a time:

    python3 code/tests/memory_baseline.py [--size-mb 12.95] [--out code/docs/MEMORY.md]

Every arm reads the same file and then keeps the parsed value alive while a
result is derived from it, so the peak covers "text + value tree". Peak RSS is
read from `/usr/bin/time -l` (macOS) or `/usr/bin/time -v` (Linux); Python also
reports `tracemalloc` peak, which is exact for its own allocation and shows how
much of the RSS is the garbage collector's slack rather than live data.

The MoonBit *core* `@json.parse` is not measured separately: core has no file
reading entry point, and the library package deliberately does not expose one,
so the closest reachable arm is `jsonmend parse`, which is this library's own
(value tree building) parse. The difference is stated in the output rather than
hidden.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
DEFAULT_OUT = os.path.join(ROOT, "docs", "MEMORY.md")

NODE_SCRIPT = (
    "const fs=require('fs');"
    "const t=fs.readFileSync(process.argv[1],'utf8');"
    "const v=JSON.parse(t);"
    "console.log(JSON.stringify(v).length);"
)
PY_SCRIPT = """
import json, sys, tracemalloc
tracemalloc.start()
with open(sys.argv[1], encoding="utf-8") as fh:
    t = fh.read()
v = json.loads(t)
cur, peak = tracemalloc.get_traced_memory()
print(len(json.dumps(v)), file=sys.stderr)
print(peak, file=sys.stdout)
"""


def make_document(target_bytes: int) -> str:
    """A deterministic object-array document, the shape the 0.3.0 table used."""
    parts = []
    n = 0
    i = 0
    while n < target_bytes:
        item = json.dumps(
            {
                "id": i,
                "name": "record-%d" % i,
                "score": i % 100 / 3.0,
                "tags": ["alpha", "beta", "gamma"],
                "note": "the quick brown fox jumps over the lazy dog %d" % i,
            },
            separators=(",", ":"),
        )
        parts.append(item)
        n += len(item) + 1
        i += 1
    return "[" + ",".join(parts) + "]"


def peak_rss(command, stdin=None):
    """Run `command` under `/usr/bin/time` and return (peak MiB, stdout, rc)."""
    time_bin = "/usr/bin/time"
    flag = "-l" if sys.platform == "darwin" else "-v"
    proc = subprocess.run(
        [time_bin, flag, *command],
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL if stdin is None else subprocess.PIPE,
        input=stdin,
        timeout=1800,
    )
    # The measurement goes to stderr, mixed with the program's own stderr.
    text = proc.stderr
    peak = None
    if flag == "-l":
        m = re.search(r"(\d+)\s+maximum resident set size", text)
        if m:
            peak = int(m.group(1)) / 1048576.0
    else:
        m = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
        if m:
            peak = int(m.group(1)) / 1024.0
    return peak, proc.stdout.strip(), proc.returncode, text


def python_peak(command, stdin=None):
    """Peak of a Python command, plus its own tracemalloc figure in MiB."""
    peak, out, rc, err = peak_rss(command, stdin)
    traced = None
    try:
        traced = int(out.splitlines()[-1]) / 1048576.0
    except (ValueError, IndexError):
        pass
    return peak, traced, rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--size-mb", type=float, default=12.95)
    ap.add_argument("--cli", default=os.path.join(
        ROOT, "_build", "native", "release", "build", "cmd", "jsonmend", "jsonmend.exe"
    ))
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    size = int(args.size_mb * 1048576)
    doc = make_document(size)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fh:
        fh.write(doc)
        path = fh.name
    actual = len(doc.encode())
    try:
        arms = []

        def add(name, value, note):
            arms.append({"name": name, "peak": value, "note": note})

        peak, out, rc, _ = peak_rss([sys.executable, "-c", PY_SCRIPT, path])
        py_peak = None
        try:
            body = subprocess.run(
                [sys.executable, "-c", PY_SCRIPT, path],
                capture_output=True, text=True, timeout=1800,
            )
            py_peak = int(body.stdout.strip().splitlines()[-1]) / 1048576.0
            py_rc = body.returncode
        except Exception:
            py_rc = rc
        add(
            "python3 json.loads + json.dumps",
            peak,
            "tracemalloc peak %.1f MB, i.e. %.0f%% of the RSS is interpreter + GC slack"
            % (py_peak, 100.0 * (peak - py_peak) / peak) if py_peak else "",
        )

        peak, out, rc, _ = peak_rss(["node", "-e", NODE_SCRIPT, path])
        add("node JSON.parse + JSON.stringify", peak, "")

        for label, argv in [
            ("jsonmend (default repair)", [args.cli, path]),
            ("jsonmend --chunk 65536 (streaming)", [args.cli, "--chunk", "65536", path]),
            ("jsonmend --check (no output written)", [args.cli, "--check", path]),
        ]:
            peak, out, rc, err = peak_rss(argv)
            if peak is None or rc not in (0, 1):
                add(label, None, "failed (rc=%d): %s" % (rc, err.strip().splitlines()[-1:] or ""))
            else:
                add(label, peak, "")

        baseline = next((a["peak"] for a in arms if a["name"].startswith("node")), None)

        lines = []
        lines.append("# 内存基线：与 Node / Python 的横向对照（NFR-PERF-04）")
        lines.append("")
        lines.append(
            "由 `code/tests/memory_baseline.py` 在 %s 生成。"
            % datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
        )
        lines.append("")
        lines.append("| 项 | 值 |")
        lines.append("| --- | --- |")
        lines.append("| 输入 | 同一份对象数组文档，%d B（%.2f MB） |" % (actual, actual / 1048576.0))
        lines.append("| 计时工具 | `/usr/bin/time %s` |" % ("-l" if sys.platform == "darwin" else "-v"))
        lines.append("| JSONMend | `%s` |" % os.path.relpath(args.cli, ROOT))
        lines.append("| Node | %s |" % subprocess.run(["node", "--version"], capture_output=True, text=True).stdout.strip())
        lines.append("| Python | %s |" % sys.version.split()[0])
        lines.append("")
        lines.append("## 峰值 RSS")
        lines.append("")
        lines.append("| 实现 | 峰值 RSS | 相对输入 | 相对 Node | 备注 |")
        lines.append("| --- | --- | --- | --- | --- |")
        for a in arms:
            if a["peak"] is None:
                lines.append("| %s | 未测得 | — | — | %s |" % (a["name"], a["note"]))
                continue
            rel_in = a["peak"] / (actual / 1048576.0)
            rel_node = (a["peak"] / baseline) if baseline else None
            lines.append(
                "| %s | %.1f MB | %.1f × | %s | %s |"
                % (
                    a["name"],
                    a["peak"],
                    rel_in,
                    ("%.2f ×" % rel_node) if rel_node else "—",
                    a["note"],
                )
            )
        lines.append("")
        lines.append("## 这张表能回答什么，不能回答什么")
        lines.append("")
        lines.append(
            "能回答：**同样的文档、同样的「读入 + 建树 + 保留」工作负载**下，JSONMend 的峰值"
            "内存与调用方本来就会用的两个运行时相比是高还是低、差多少倍。NFR-PERF-04 的"
            "「≤ 4 × 输入」是否现实，取决于这个差距，而不是取决于 0.3.0 与 0.2.0 的自比。"
        )
        lines.append("")
        lines.append(
            "不能回答：MoonBit **core** 的 `@json.parse` 单独占多少。core 没有文件读取入口，"
            "本库也刻意不暴露一个，所以能测到的最接近的两臂是 `jsonmend --check`（建树但不渲染输出）与 `jsonmend`（建树并渲染），"
            "两者峰值相同即说明峰值来自值树而不是输出。两者的差异是引擎的记录数组与位置对象，"
            "量级远小于此处比较的实现间差异，但如果需要一个精确的 core 基线，"
            "需要给基准程序加一个 FFI 读文件入口（core 自身没有文件读取 API）。"
        )
        lines.append("")
        lines.append(
            "另外，Python 一行的注释给出 `tracemalloc` 峰值：它是 Python **自身分配**的精确值，"
            "与 RSS 的差额是解释器与 GC 的空闲内存。把这个差值当成「实现效率」是不对的，"
            "这也是为什么同一张表里既给 RSS 也给 tracemalloc。"
        )
        lines.append("")

        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
        print("\n".join(lines))
    finally:
        os.unlink(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
