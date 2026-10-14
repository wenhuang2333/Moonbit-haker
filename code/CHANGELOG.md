# Changelog

本文件记录 JSONMend 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] - 2026-10-14

首个发布版本。

### 新增

- 一次性修复与解析：`repair` 与 `parse` 入口，返回修复后的文本、解析出的
  `Json` 值以及逐条修复记录（修复码、位置偏移、严重级别）。
- 流式部分解析：`PartialParser` 支持 `feed`、`feed_bytes`、`snapshot` 与
  `finish`，任意分块边界下快照结果一致，并提供完整性状态与路径信息。
- 21 条修复规则（R001 至 R021）：围栏剥离、注释剥离、引号规范化、裸词加引号、
  多余逗号删除、缺失逗号插入、缺失冒号插入、缺失值补 null、容器闭合、字符串
  闭合、数字修复、字面量转换、控制字符转义、转义修复、括号错配、意外内容丢弃、
  多余闭合符丢弃、重复键合并、字符串拼接、省略号丢弃、前导说明跳过。
- 严格模式（`Mode::Strict`）：需要修复时直接以 `E010` 报错，不产出修复结果。
- 资源限制：嵌套深度（`max_depth`）、输入长度（`max_input_len`）与单 token
  长度（`max_token_len`）上限，超限分别抛出 `E020`/`E021`/`E022`。
- 策略选项：重复键（`duplicate_keys`：保留最后一个/保留第一个/报错）、未结束
  数字（`incomplete_number`：快照中丢弃/裁剪为合法数字）、悬空键
  （`pending_key`：省略/补 null）、非有限值（`non_finite`：转 null/报错/转字符串）
  与多根值（`multi_root`：保留第一个/合成数组/报错）。
- Markdown 代码围栏剥离（`strip_fence`，默认开启）。
- 前导说明文字跳过选项（`skip_prose`）与引号歧义前瞻选项（`quote_lookahead`）。
- 按规则粒度的开关（`RuleSet::enable`/`disable`），关闭某条规则后对应情形按
  严格模式处理。
- 原生命令行工具 `cmd/jsonmend`：支持 `--strict`、`--check`、`--report`、
  `--indent N`、`--multi-root MODE`、`--skip-prose`、`--quote-lookahead`、
  `-h/--help`，从文件或标准输入读取并输出修复后的 JSON。
- 基准测试框架 `bench/`，用于测量一次性修复与流式解析的吞吐和耗时。
- 黄金用例测试套件（`golden_wbtest.mbt`，覆盖项目文档附录 A/B 的 TC-G 用例）
  与文档用例流式测试套件（`stream_wbtest.mbt`，覆盖 TC-S 及分块不变性、
  幂等性、严格模式派生断言）。
- 差分测试框架 `tests/diff/`：以 `jsonrepair`（TypeScript/Node）与
  `json-repair`（Python）作为行为对照的 oracle，输出带分歧归因的差分报告。
- 属性与模糊测试（`prop_wbtest.mbt`）：确定性 LCG 生成合法文档与变异文档，
  断言输出合法、幂等、分块不变、截断可补全、快照单调，共 8 组 × 400 例。
- 公共面与选项测试（`error_api_wbtest.mbt`、`options_wbtest.mbt`）：逐一检查
  21 条修复码与 9 个错误码，并覆盖全部策略枚举、规则开关与字节输入。
- 命令行冒烟脚本 `tests/cli_smoke.sh`（25 项断言，覆盖退出码 0/1/2/3/4/5/70）
  与基准脚本 `tests/bench.sh`（含 wasm-gc 产物体积）。
- 浏览器演示页 `static/demo/index.html`：由 MoonBit JS 产物直接驱动，无第二实现。
- 文档集 `docs/`：RULES、ERRORS、DIVERGENCES、BENCHMARK、REPRODUCE、ONEPAGE、
  TRACEABILITY，以及 `CONTRIBUTING.md`、`SECURITY.md`、`LICENSE`、`NOTICE`。

### 修复

- 首个发布版本，暂无已修复问题记录。

### 已知限制

- `snapshot()` 返回完整拷贝，代价与树大小成正比，高频调用时总体开销较大；
  FR-16 的事件接口可缓解。
- `Json` 数值遵循 core 的表示，大整数可能损失精度；修复后的文本保留数字原文。
- 引号前瞻默认关闭，开启后对缺逗号的字符串序列会偏向解释为内容。
- 修复记录有内部上限 10000 条。
- 解析器实例非线程安全，每个输入流应使用独立实例。
- 与 `jsonrepair` 存在有意差异，详见差分报告；差异点包括未结束数字在快照中
  默认不输出、悬空键在快照中省略而最终结果为 null、重复键默认保留最后一个并
  记录 R018、孤立代理码元统一替换为 U+FFFD，以及参照实现中更激进的猜测式修复
  属于范围外行为。
- 峰值内存约为输入的 18 倍，未达到「≤ 4 倍输入」的预算；需要「只产出文本、
  不建树」的模式才能达标（见 `docs/BENCHMARK.md`）。
- `R019` 相邻字符串拼接（`"a" + "b"`）未实现；FR-16 事件/回调接口未实现。
- 命令行工具仅支持 native 后端；库本身在 wasm-gc / native / JS 三个后端均通过测试。
