#!/usr/bin/env python3
"""Ground-truth evaluation harness for JSONMend (I-4).

Runs the pre-registered corpus (`corpus.py`, registration in
`code/docs/EVAL_REGISTRATION.md`) through `jsonmend --batch` and writes
`code/docs/EVAL.md`.

    python3 code/tests/eval/run_eval.py --cli <path to jsonmend>

Exit status is 0 when every pre-registered acceptance criterion holds.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
REGISTRATION = os.path.join(ROOT, "docs", "EVAL_REGISTRATION.md")
OUT = os.path.join(ROOT, "docs", "EVAL.md")

sys.path.insert(0, HERE)
import corpus as corpus_mod  # noqa: E402

NOTATION = corpus_mod.NOTATION
LOSSY = corpus_mod.LOSSY


# ------------------------------------------------------------------ values --


def same(a, b) -> bool:
    """Structural equality with the registered number tolerance."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a is b
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return math.isclose(float(a), float(b), rel_tol=1e-12, abs_tol=0.0)
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(same(a[k], b[k]) for k in a)
    return False


# ---------------------------------------------------------------- driver ----


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
        timeout=900,
    )
    if proc.returncode != 0:
        raise SystemExit(
            "batch run failed (rc=%d): %s" % (proc.returncode, proc.stderr[:400])
        )
    out = {}
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        out[row["id"]] = row
    return out


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def binary_stamp(path):
    return "sha256:%s, %d bytes" % (sha256_file(path)[:16], os.path.getsize(path))


def moon_version():
    try:
        proc = subprocess.run(["moon", "version"], capture_output=True, text=True)
        return proc.stdout.strip().splitlines()[0]
    except Exception:
        return "unknown"


# ----------------------------------------------------------------- report ----


def pct(n, d):
    return "n/a" if d == 0 else "%.2f%%" % (100.0 * n / d)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True)
    ap.add_argument("--target", type=int, default=corpus_mod.TARGET)
    ap.add_argument("--seed", type=int, default=corpus_mod.SEED)
    ap.add_argument("--dump", default=os.path.join(HERE, "corpus.jsonl"))
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    cases, skipped = corpus_mod.build(args.target, args.seed)
    with open(args.dump, "w", encoding="utf-8") as fh:
        for c in cases:
            fh.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
    data_hash = corpus_mod.fingerprint(cases)

    # `prose` is the only family that needs a non-default flag; the registered
    # protocol says so, and it is applied to that family only.
    prose = [c for c in cases if c["family"] == "prose"]
    rest = [c for c in cases if c["family"] != "prose"]
    rows = run_batch(args.cli, rest)
    rows.update(run_batch(args.cli, prose, extra=["--skip-prose"]))

    results = []
    for c in cases:
        row = rows.get(c["id"])
        if row is None:
            raise SystemExit("no result for " + c["id"])
        value = row.get("value")
        ok = row["rc"] == 0
        hit = ok and same(value, c["truth"])
        results.append(
            {
                "case": c,
                "rc": row["rc"],
                "value": value,
                "exactness": row["exactness"],
                "codes": row["codes"],
                "text": row.get("text", ""),
                "hit": hit,
                "failed": not ok,
                "diff": not hit,
            }
        )

    n = len(results)
    hits = sum(1 for r in results if r["hit"])
    failed = sum(1 for r in results if r["failed"])
    diffs = [r for r in results if r["diff"]]
    mislabel = [
        r for r in diffs if r["exactness"] in ("exact", "cosmetic")
    ]
    honest = [r for r in diffs if r["exactness"] == "lossy"]

    labels = ["exact", "cosmetic", "lossy"]
    by_label = {}
    for lab in labels:
        group = [r for r in results if r["exactness"] == lab]
        by_label[lab] = (
            len(group),
            sum(1 for r in group if r["hit"]),
        )

    fams = []
    for fam in ["clean"] + list(corpus_mod.FAMILIES):
        group = [r for r in results if r["case"]["family"] == fam]
        if not group:
            continue
        gh = sum(1 for r in group if r["hit"])
        gd = [r for r in group if r["diff"]]
        gm = [r for r in gd if r["exactness"] in ("exact", "cosmetic")]
        counts = {lab: sum(1 for r in group if r["exactness"] == lab) for lab in labels}
        fams.append(
            {
                "family": fam,
                "n": len(group),
                "hits": gh,
                "diffs": len(gd),
                "mislabel": len(gm),
                "labels": counts,
            }
        )

    # Pre-registered acceptance criteria.
    checks = []
    checks.append(
        (
            "漏标率为 0（结果 ≠ 真值不得标为 exact/cosmetic）",
            len(mislabel) == 0,
            "%d 条差异中有 %d 条被标为 exact/cosmetic" % (len(diffs), len(mislabel)),
        )
    )
    clean = [r for r in results if r["case"]["family"] == "clean"]
    checks.append(
        (
            "clean 族全部 exact 且恢复率 1",
            all(r["exactness"] == "exact" and r["hit"] for r in clean),
            "%d 条中 %d 条 exact，%d 条恢复"
            % (
                len(clean),
                sum(1 for r in clean if r["exactness"] == "exact"),
                sum(1 for r in clean if r["hit"]),
            ),
        )
    )
    notation = [r for r in results if r["case"]["family"] in NOTATION]
    notation_ok = all(
        r["hit"] and r["exactness"] in ("exact", "cosmetic") for r in notation
    )
    checks.append(
        (
            "记法族恢复率 1 且标签不为 lossy",
            notation_ok,
            "%d 条中 %d 条恢复，%d 条标签为 exact/cosmetic"
            % (
                len(notation),
                sum(1 for r in notation if r["hit"]),
                sum(1 for r in notation if r["exactness"] in ("exact", "cosmetic")),
            ),
        )
    )
    lossy = [r for r in results if r["case"]["family"] in LOSSY]
    lossy_ok = all(r["hit"] and r["exactness"] == "lossy" for r in lossy)
    checks.append(
        (
            "丢信息族恢复率 1 且标签为 lossy",
            lossy_ok,
            "%d 条中 %d 条恢复，%d 条标签为 lossy"
            % (
                len(lossy),
                sum(1 for r in lossy if r["hit"]),
                sum(1 for r in lossy if r["exactness"] == "lossy"),
            ),
        )
    )

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = []
    w = lines.append
    w("# JSONMend 真值评测报告（I-4）")
    w("")
    w("本文件由 `code/tests/eval/run_eval.py` 生成，请勿手工编辑。")
    w("")
    w("| 项 | 值 |")
    w("|----|----|")
    w("| 登记 | [EVAL_REGISTRATION.md](EVAL_REGISTRATION.md) sha256 `%s` |" % sha256_file(REGISTRATION)[:16])
    w("| 生成器 | `code/tests/eval/corpus.py` %s，种子 %d |" % (corpus_mod.VERSION, args.seed))
    w("| 语料 | `code/tests/eval/corpus.jsonl`，%d 条，sha256 `%s` |" % (n, data_hash[:16]))
    w("| 生成跳过 | %d 次尝试因算子不适用而丢弃（登记 §5） |" % skipped)
    w("| 被测二进制 | `%s`（%s） |" % (args.cli, binary_stamp(args.cli)))
    w("| 工具链 | `%s` |" % moon_version())
    w("| 运行时刻 | %s |" % now)
    w("| 退出码 | %d（0 = 全部验收判据通过） |" % (0 if all(c[1] for c in checks) else 1))
    w("")
    w("## 1. 总体")
    w("")
    w("| 指标 | 值 |")
    w("|------|----|")
    w("| 用例数 N | %d |" % n)
    w("| 恢复率（value == truth） | %s（%d/%d） |" % (pct(hits, n), hits, n))
    w("| 失败率（rc != 0） | %s（%d） |" % (pct(failed, n), failed))
    w("| 差异数（value != truth） | %d |" % len(diffs))
    w("| **漏标率**（差异中标签为 exact/cosmetic） | %s（%d/%d） |" % (pct(len(mislabel), len(diffs)), len(mislabel), len(diffs)))
    w("| 诚实标红率（差异中标签为 lossy） | %s（%d/%d） |" % (pct(len(honest), len(diffs)), len(honest), len(diffs)))
    w("")
    w("## 2. 分标签")
    w("")
    w("| 标签 | 用例数 | 其中恢复 | 该标签下的恢复率 |")
    w("|------|--------|----------|------------------|")
    for lab in labels:
        cnt, hit = by_label[lab]
        w("| `%s` | %d | %d | %s |" % (lab, cnt, hit, pct(hit, cnt)))
    w("")
    w("标签是「可执行性」的承诺：`exact`/`cosmetic` 表示结果可以直接执行，")
    w("`lossy` 表示修复过程发明或丢弃了信息。上表说明该承诺是否成立。")
    w("")
    w("## 3. 分族")
    w("")
    w("| 族 | N | 恢复 | 恢复率 | 差异 | 漏标 | exact | cosmetic | lossy |")
    w("|----|---|------|--------|------|------|-------|----------|-------|")
    for f in fams:
        w(
            "| `%s` | %d | %d | %s | %d | %d | %d | %d | %d |"
            % (
                f["family"],
                f["n"],
                f["hits"],
                pct(f["hits"], f["n"]),
                f["diffs"],
                f["mislabel"],
                f["labels"]["exact"],
                f["labels"]["cosmetic"],
                f["labels"]["lossy"],
            )
        )
    w("")
    w("## 4. 预登记验收判据")
    w("")
    w("| 判据 | 结果 | 证据 |")
    w("|------|------|------|")
    for name, ok, detail in checks:
        w("| %s | %s | %s |" % (name, "PASS" if ok else "**FAIL**", detail))
    w("")
    if diffs:
        w("## 5. 差异明细（最多 20 条）")
        w("")
        w("| id | 族 | 标签 | 码 | 输入（截断） | 真值 | 结果 |")
        w("|----|----|------|----|--------------|------|------|")
        for r in diffs[:20]:
            c = r["case"]
            w(
                "| `%s` | `%s` | `%s` | %s | `%s` | `%s` | `%s` |"
                % (
                    c["id"],
                    c["family"],
                    r["exactness"],
                    ",".join(r["codes"]) or "-",
                    short(c["input"]),
                    short(json.dumps(c["truth"], ensure_ascii=False)),
                    short(json.dumps(r["value"], ensure_ascii=False)),
                )
            )
        w("")
    w("## 6. 修订历史")
    w("")
    w("| 版本 | 时间 | 语料 sha256 | N | 恢复率 | 差异 | 漏标 | 关键修订 |")
    w("|------|------|-------------|----|--------|------|------|----------|")
    w("| `eval-1` | 2026-10-15 | `5a435447f28eee72` | 1200 | 91.58% | 101 | 16 | — |")
    w(
                "| `eval-2` | %s | `%s` | %d | %s | %d | %d | 语料：撇号歧义、裸 token 合并、标量根 prose、截断的祖先语义；实现：R015/R017/R021 降为 Info、新增 R022、R018 判等（[EVAL_REGISTRATION.md](EVAL_REGISTRATION.md) §10） |"
                % (
                    now[:10],
                    data_hash[:16],
                    n,
                    pct(hits, n),
                    len(diffs),
                    len(mislabel),
                )
            )
    w("")
    w("`eval-1` 的 16 条漏标与 84 条语料缺陷的完整归因见")
    w("[EVAL_REGISTRATION.md](EVAL_REGISTRATION.md) §10。")
    w("")
    w("## 7. 结论与限制")
    w("")
    w("见 [EVAL_REGISTRATION.md](EVAL_REGISTRATION.md) §9：本轮只覆盖合成语料的")
    w("单点变异，不覆盖真实模型分布、多处变异组合与 >1 MiB 文档；性能与内存见")
    w("[BENCHMARK.md](BENCHMARK.md)。")
    w("")

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    ok = all(c[1] for c in checks)
    print(
        "N=%d recovery=%s diffs=%d mislabel=%d -> %s"
        % (n, pct(hits, n), len(diffs), len(mislabel), "PASS" if ok else "FAIL")
    )
    for name, good, detail in checks:
        print("  [%s] %s (%s)" % ("PASS" if good else "FAIL", name, detail))
    print("report written to", args.out)
    return 0 if ok else 1


def short(s, limit=90):
    s = s.replace("\n", "\\n").replace("|", "\\|")
    return s if len(s) <= limit else s[: limit - 1] + "\u2026"


if __name__ == "__main__":
    raise SystemExit(main())
