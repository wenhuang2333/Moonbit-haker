#!/usr/bin/env python3
"""Peak memory per mode, and the same parse in JSONMend, Node and Python (NFR-PERF-04).

0.6.0 asks a narrower question than 0.3.0 did. The old report answered "is the
4x input budget reasonable" by comparing one JSONMend arm with Node and Python.
The frozen memory policy for this release names **modes**, because the modes
allocate differently:

    repair()      peak RSS        (value tree + rendered output)
    analyze()     peak RSS        (plan, no rendered value)
    streaming     peak working set (chunks fed through PartialParser)
    text-only     target <= 4x input   (declared, not claimed here)
    no-tree       target <= 2x input   (declared, not claimed here)

so every arm below is labelled with the mode it measures, and the two declared
targets are reported as *targets* with their real status rather than folded into
the comparison table.

    python3 code/tests/memory_baseline.py [--size-mb 12.95] [--out code/docs/MEMORY.md]

Two facts about the harness that the numbers depend on, both stated in the
output as well:

* `/usr/bin/time -l` (macOS) or `-v` (Linux) gives the process peak RSS. Python
  additionally gives `tracemalloc`, which is exact for its own allocation.
* The default `repair` / `--check` path streams 64 KiB chunks from `fread`
  straight into `PartialParser::feed_bytes`, so it never holds the whole input
  as a second `String`. `explain`, `readiness`, `batch`, and `llm` still call
  `read_all`, so their peaks include the whole input text as well. The default
  path keeps a 1 MiB prefix for error snippets; the streamed chunks themselves
  are not retained. The difference between arms is the *marginal* cost of the
  plan, the event log or the rendered output — not a demonstration that a mode
  avoids the tree.

The MoonBit *core* `@json.parse` is not measured separately: core has no file
reading entry point and this library deliberately does not expose one, so the
closest reachable arm is a JSONMend CLI arm. The difference is stated in the
output rather than hidden.
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

# Text deltas are emitted in chunks of this many characters when building the
# synthetic Anthropic event stream for the `llm --text` arm.
EVENT_CHUNK = 8192

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


def make_long_text(target_bytes: int) -> str:
    """A long-text document: one object, one member, one very long CJK string.

    This is the shape a model produces when it writes a file, a markdown answer
    or a translation, and it is measured separately because it spends memory
    differently from the object array above: the value tree is two nodes, and
    everything else is string buffer. `--check` therefore separates the string
    buffers from the rendered copy without any help from the tree.
    """
    unit = "中文内容"
    unit_bytes = len(unit.encode())
    body = []
    n = 0
    while n < target_bytes:
        body.append(unit)
        n += unit_bytes
    return '{"text":"' + "".join(body) + '"}'


def make_events(doc: str, path: str) -> int:
    """Write the document as an Anthropic `text_delta` stream; return its size.

    This is the input `jsonmend llm --text` is designed for: the model streams
    the document one delta at a time and the adapter feeds `TextStream`, which
    feeds a `PartialParser`. The file is larger than the document because every
    delta carries JSON envelope, which the note in the output accounts for.
    """
    lines = []
    for i in range(0, len(doc), EVENT_CHUNK):
        lines.append(
            json.dumps(
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": doc[i:i + EVENT_CHUNK]},
                },
                separators=(",", ":"),
            )
        )
    body = "\n".join(lines) + "\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    return len(body.encode())


def peak_rss(command, stdin=None):
    """Run `command` under `/usr/bin/time` and return (peak MiB, stdout, rc, stderr)."""
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
    actual = len(doc.encode())
    mb = actual / 1048576.0
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as fh:
        fh.write(doc)
        path = fh.name
    events_path = path + ".events.jsonl"
    events_bytes = make_events(doc, events_path)
    try:
        # ------------------------------------------------------------------
        # The modes of this release.
        # ------------------------------------------------------------------
        modes = [
            {
                "mode": "repair()",
                "what": "值树 + 渲染输出",
                "metric": "峰值 RSS",
                "argv": [args.cli, path],
                "input": actual,
            },
            {
                "mode": "analyze()",
                "what": "计划（explain --json），不渲染值",
                "metric": "峰值 RSS",
                "argv": [args.cli, "explain", "--json", path],
                "input": actual,
            },
            {
                "mode": "streaming feed",
                "what": "默认 64 KiB 分块（主路径，渲染输出）",
                "metric": "峰值工作集（峰值 RSS）",
                "argv": [args.cli, path],
                "input": actual,
            },
            {
                "mode": "streaming readiness",
                "what": "字段就绪事件流（readiness）",
                "metric": "峰值工作集（峰值 RSS）",
                "argv": [args.cli, "readiness", path],
                "input": actual,
            },
            {
                "mode": "text-only (llm --text)",
                "what": "文本增量 → TextStream → PartialParser",
                "metric": "峰值工作集（峰值 RSS）",
                "argv": [args.cli, "llm", "--text", events_path],
                "input": events_bytes,
                "extra": "事件文件 %d B（文档的 %.2f ×）"
                % (events_bytes, events_bytes / actual),
            },
        ]

        for m in modes:
            peak, out, rc, err = peak_rss(m["argv"])
            if peak is None or rc not in (0, 1):
                m["peak"] = None
                m["note"] = "failed (rc=%d) %s" % (rc, err.strip().splitlines()[-1:])
            else:
                m["peak"] = peak
                m["note"] = m.pop("extra", "")

        # A diagnostic, not a mode: `--check` sets `want_text: false`, so it
        # builds the same tree without rendering the value. The difference
        # against `repair()` is the cost of the output; what is left is the
        # value tree plus the string parts, and core's own share is not
        # separable from that (see section 4).
        check_peak, _out, _rc, _err = peak_rss([args.cli, "--check", path])

        # The no-tree mode does not exist yet: it is reported as a declared
        # target, not as a measurement.
        no_tree = {
            "mode": "no-tree",
            "what": "完全不建值树",
            "metric": "—",
            "peak": None,
            "note": "0.6.0 无此模式：`Options::for_text()` 仍走建树解析，未测得",
            "input": actual,
        }

        # ------------------------------------------------------------------
        # The cross-implementation comparison (kept from 0.3.0).
        # ------------------------------------------------------------------
        cross = []
        peak, _, rc = python_peak([sys.executable, "-c", PY_SCRIPT, path])
        py_peak = None
        try:
            body = subprocess.run(
                [sys.executable, "-c", PY_SCRIPT, path],
                capture_output=True, text=True, timeout=1800,
            )
            py_peak = int(body.stdout.strip().splitlines()[-1]) / 1048576.0
        except Exception:
            pass
        cross.append({
            "name": "python3 json.loads + json.dumps",
            "peak": peak,
            "note": (
                "tracemalloc 峰值 %.1f MB，即 RSS 的 %.0f%% 是解释器与 GC 空闲"
                % (py_peak, 100.0 * (peak - py_peak) / peak)
            ) if py_peak else "",
        })
        peak, out, rc, _ = peak_rss(["node", "-e", NODE_SCRIPT, path])
        cross.append({"name": "node JSON.parse + JSON.stringify", "peak": peak, "note": ""})
        cross.append({
            "name": "jsonmend repair（本表第一行）",
            "peak": modes[0]["peak"],
            "note": "同一份文档，同一次运行",
        })
        baseline = next((a["peak"] for a in cross if a["name"].startswith("node")), None)

        # ------------------------------------------------------------------
        # The long-text shape (TC-B-11).
        #
        # Same byte size as the object array, so the ratio columns are
        # comparable; a completely different allocation profile, which is the
        # point. Two arms only: `--check` (builds the tree, renders nothing) and
        # `repair` (renders the whole output).
        # ------------------------------------------------------------------
        long_doc = make_long_text(size)
        long_bytes = len(long_doc.encode())
        with tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        ) as lf:
            lf.write(long_doc)
            long_path = lf.name
        long_arms = []
        for arm, argv in (
            ("--check（建树、不渲染）", [args.cli, "--check", long_path]),
            ("repair（渲染输出）", [args.cli, long_path]),
        ):
            peak, _o, rc, err = peak_rss(argv)
            long_arms.append({
                "arm": arm,
                "peak": peak if rc in (0, 1) else None,
                "note": "" if rc in (0, 1) else "failed (rc=%d) %s" % (rc, err.strip()),
            })

        # ------------------------------------------------------------------
        # The document.
        # ------------------------------------------------------------------
        now = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
        node_version = subprocess.run(
            ["node", "--version"], capture_output=True, text=True
        ).stdout.strip()

        lines = []
        lines.append("# 内存基线：按模式与跨实现对照（NFR-PERF-04）")
        lines.append("")
        lines.append("由 `code/tests/memory_baseline.py` 在 %s 生成。" % now)
        lines.append("")
        lines.append("| 环境 | 值 |")
        lines.append("| --- | --- |")
        lines.append("| 输入 | 同一份对象数组文档，%d B（%.2f MB） |" % (actual, mb))
        lines.append("| 计时工具 | `/usr/bin/time %s`（峰值 RSS） |" % ("-l" if sys.platform == "darwin" else "-v"))
        lines.append("| JSONMend | `%s` |" % os.path.relpath(args.cli, ROOT))
        lines.append("| Node | %s |" % node_version)
        lines.append("| Python | %s |" % sys.version.split()[0])
        lines.append("")

        lines.append("## 一、按模式的峰值内存")
        lines.append("")
        lines.append("| 模式 | 工作负载 | 指标 | 峰值 | 相对输入 | 备注 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for m in modes + [no_tree]:
            if m["peak"] is None:
                lines.append(
                    "| %s | %s | %s | 未测得 | — | %s |"
                    % (m["mode"], m["what"], m["metric"], m["note"])
                )
                continue
            rel = m["peak"] / (m["input"] / 1048576.0)
            lines.append(
                "| %s | %s | %s | %.1f MB | %.1f × | %s |"
                % (m["mode"], m["what"], m["metric"], m["peak"], rel, m["note"])
            )
        lines.append("")

        if modes[0]["peak"] and modes[1]["peak"]:
            lines.append(
                "`analyze()` 与 `repair()` 的比值是 %.2f ×（%.1f MB vs %.1f MB）。计划同样建值树，"
                "两者的差别只在于它是否再渲染一整份输出：比值接近 1 说明这个通道没有多留一份全文。"
                "1.3.0 起 `explain --json` 默认不带 `text`（`--with-text` 才带上），"
                "所以这一比值从「比 repair 高」变成了与 repair 同量级。"
                % (modes[1]["peak"] / modes[0]["peak"], modes[1]["peak"], modes[0]["peak"])
            )
            lines.append("")
        lines.append("每个模式的「相对输入」都是**峰值 RSS ÷ 该模式实际读入的字节数**。")
        lines.append("`text-only (llm --text)` 这一行的分母是事件文件（%d B），" % events_bytes)
        lines.append("不是文档本身，因为该模式读的就是事件流。")
        lines.append("")

        lines.append("## 二、与 Node / Python 的横向对照")
        lines.append("")
        lines.append("| 实现 | 峰值 RSS | 相对输入 | 相对 Node | 备注 |")
        lines.append("| --- | --- | --- | --- | --- |")
        for a in cross:
            if a["peak"] is None:
                lines.append("| %s | 未测得 | — | — | %s |" % (a["name"], a["note"]))
                continue
            rel_in = a["peak"] / mb
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

        lines.append("## 三、两条声明目标：声明了，本次未达成 / 未测得")
        lines.append("")
        lines.append("| 目标 | 状态 | 依据 |")
        lines.append("| --- | --- | --- |")
        text_peak = next((m["peak"] for m in modes if m["mode"].startswith("text-only")), None)
        if text_peak is None:
            text_status = "未测得"
            text_why = "`llm --text` 臂未运行成功"
        else:
            text_ratio = text_peak / (events_bytes / 1048576.0)
            text_status = "%.1f × 事件文件（目标 ≤ 4 × 输入，未据此判定达成）" % text_ratio
            text_why = (
                "该数值里含事件文件本身的 %d B（文档的 %.2f ×）与 `read_all` 的整段缓冲，"
                "只能作为上界，不能用来宣称纯文本路径达标"
                % (events_bytes, events_bytes / actual)
            )
        lines.append("| text-only ≤ 4 × 输入 | %s | %s |" % (text_status, text_why))
        lines.append(
            "| no-tree ≤ 2 × 输入 | 未达成（模式不存在） | `Options::for_text()` 仍然建值树，"
            "0.6.0 没有关闭建树的入口，因此这条目标只能声明、不能测 |"
        )
        lines.append("")
        lines.append(
            "这两条目标来自 0.6.0 冻结的内存策略。本文件只报告状态："
            "不把「流式路径的峰值恰好低于 4 ×」当成达标，因为该峰值包含整段输入缓冲"
            "（见下一节），也不把尚未实现的 no-tree 写成达标。"
        )
        lines.append("")

        lines.append("## 四、这张表能回答什么，不能回答什么")
        lines.append("")
        lines.append(
            "能回答：**同一份文档、同一个「读入 + 建树 + 保留」工作负载**下，各模式的峰值差多少，"
            "以及 JSONMend 与调用方本来就会用的两个运行时相比是高还是低。"
        )
        lines.append("")
        if check_peak is not None:
            lines.append(
                "不能回答：MoonBit **core** 的 `@json.parse` 单独占多少。core 没有文件读取入口，"
                "本库也刻意不暴露一个。能测到的最接近的两臂是 `--check`（建树、不渲染，本次 %.1f MB）"
                "与 `repair()`（建树并渲染，本次 %.1f MB）：`--check` 现在设置 `want_text=false`，"
                "所以两者之差是**渲染输出**的边际成本；剩下的 %.1f MB 是值树与字符串 parts，"
                "core 自身在这部分里占多少，从这两个数里拆不出来。"
                "要一个精确的 core 基线，需要给基准程序加一个 FFI 读文件入口"
                "（core 自身没有文件读取 API）。"
                % (check_peak, modes[0]["peak"], check_peak)
            )
        else:
            lines.append(
                "不能回答：MoonBit **core** 的 `@json.parse` 单独占多少。core 没有文件读取入口，"
                "本库也刻意不暴露一个，`--check`（建树、不渲染）本次也未测得，"
                "所以没有任何一臂能把「输入缓冲 + 值树」再拆一层。"
            )
        lines.append("")
        lines.append(
            "默认的 `repair` / `--check` 主路径按 64 KiB `fread` 分块，每块直接 `feed_bytes` 给解析器，"
            "不把整份输入读成第二个 `String`；`explain`、`readiness`、`batch` 与 `llm` 仍然 `read_all`，"
            "所以这些臂的峰值还包含整份输入文本。主路径保留 1 MiB 前缀用于错误摘录，"
            "分块本身不保留。`streaming feed`、`readiness`、`llm --text` 三行之间以及它们与 `repair` "
            "之间的差额，是计划、事件表与渲染输出的**边际**成本，而不是「流式模式省掉了值树」的证据。"
        )
        lines.append("")
        lines.append(
            "另外，Python 一行的备注给出 `tracemalloc` 峰值：它是 Python **自身分配**的精确值，"
            "与 RSS 的差额是解释器与 GC 的空闲内存。把这个差值当成「实现效率」是不对的，"
            "这也是为什么同一张表里既给 RSS 也给 tracemalloc。"
        )
        lines.append("")

        lines.append("## 五、长文本形状：单条字符串吃掉整篇文档（TC-B-11）")
        lines.append("")
        lines.append(
            "上面四节用的是对象数组：成本主要是**值树**。LLM 场景里另一种形状同样常见——"
            "模型写文件、写 markdown 回答、写译文时，参数里几乎只有一个超长字符串，"
            "此时值树只有两个节点，成本几乎全是**字符串缓冲**。这一节用同样的字节量测这种形状："
            "`{\"text\":\"中文内容…\"}`，%d B（%.2f MB，%d 个码元）。"
            % (long_bytes, long_bytes / 1048576.0, len(long_doc))
        )
        lines.append("")
        lines.append("| 模式 | 峰值 RSS | 相对输入 |")
        lines.append("| --- | --- | --- |")
        for arm in long_arms:
            if arm["peak"] is None:
                lines.append("| %s | 未测得 | — |" % arm["arm"])
                continue
            lines.append(
                "| %s | %.1f MB | %.1f × |"
                % (arm["arm"], arm["peak"], arm["peak"] / (long_bytes / 1048576.0))
            )
        lines.append("")
        lines.append(
            "1.3.0 改动的是这一形状的成本结构，不是结果：字节入口 `feed_bytes` 过去只批量纯 ASCII 段，"
            "非 ASCII 字节一个码元一次 `parts.push(c.to_string())`，于是长文本文档的峰值随**字符数**"
            "而不是字节数增长。现在完整的 UTF-8 序列并成一次 run，一条 25 171 907 字节、"
            "8 388 619 码元的 CJK 文档实测由 239 075 328 B（228.0 MB，9.5 ×）降到 46–54 MB"
            "（1.9–2.2 ×，`--check`；峰值 RSS 随调用上下文抖动约 8 MB），`repair` 由 "
            "289 521 664 B（276.1 MB）降到 89.8–94.3 MB。那两个「修复前」数字**不是本次运行测的**"
            "——当前二进制已经修好——"
            "是同一批文件用改动前的二进制测出来的，记录在 `docs/BENCHMARK.md`「长文本输入」。"
        )
        lines.append("")
        long_check = long_arms[0]["peak"]
        long_repair = long_arms[1]["peak"]
        if long_check and check_peak:
            lines.append(
                "同一尺寸下两种形状可以直接比：%d B 的对象数组 `--check` 是 %.1f MB（%.1f ×，"
                "见第一节），同字节量的长文本 `--check` 是 %.1f MB（%.1f ×）——长文本省下的是值树，"
                "留下的是两份 UTF-16 文本（`parts` 与 `Json::string`）。"
                "但这个比值也不要与 25 MB 文件的 1.9–2.2 × 直接对比：峰值里有一部分与输入大小无关"
                "（运行时本身、主路径保留的 1 MiB 错误摘录前缀），它在较小的文档里占比更大。"
                % (
                    actual,
                    check_peak,
                    check_peak / (actual / 1048576.0),
                    long_check,
                    long_check / (long_bytes / 1048576.0),
                )
            )
            lines.append("")
        lines.append("")
        lines.append(
            "`repair` 与 `--check` 之差是渲染输出的边际成本：长文本下它是整整第二份文本，"
            "所以这一形状的 `repair` 峰值明显高于 `--check`，与对象数组形状的结论一致。"
        )
        lines.append("")

        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
        print("\n".join(lines))
    finally:
        for p in (path, events_path, locals().get("long_path", path)):
            try:
                os.unlink(p)
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
