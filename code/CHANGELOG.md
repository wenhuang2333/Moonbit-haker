# Changelog

本文件记录 JSONMend 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0] - 2026-10-15（待发布）

第二轮优化版本。`moon package` 已能产出
`wenhuang2333-jsonmend-0.2.0.zip`（128 KB）；发布到 mooncakes.io 仍阻塞在
`moon whoami` 未登录（`moon login` 只有交互式浏览器流程，无法在无人值守环境完成）。

### 新增

- **R019 字符串拼接落地**：值位置已得到字符串后再遇到 `+` 时，把后继字符串并入
  前一个字符串（数组元素、对象属性值、根值三种位置；链式拼接逐条记录；非字符串
  操作数回退到 R016/R006）。此前该码只在枚举中声明、引擎从不产生记录，现在
  **21 条规则全部生效**。黄金用例 G-300、G-300b…G-300e 与流式用例 S-021 覆盖。
- 修复记录上限可配置（`Options.max_repairs`，默认 10000）：超出后仍继续修复但不再
  记录，结果类型新增 `repairs_truncated` 字段；CLI 对应 `--max-repairs N`，被截断时
  向标准错误打印一行提示。
- 字符串批处理快路径（`Engine::push_run`）：连续普通字符一次并入，超长字符串
  1 MB 从 37.7 MB/s 提升到 580 MB/s（native）。
- 快照记忆化（`Engine.snap_stamp`）：引擎状态未变化时 `snapshot()` 直接返回上一次
  结果，1 MB 输入重复取 1000 次快照由约 200 倍代价降到 10.8 ms。
- CLI 读取改为**每块一次 `fread`**（`moonbit_fread_ffi`），替代逐字节 `fgetc`：
  端到端吞吐 +21%（12.95 MB 输入 0.587 s → 0.464 s）、缩进输入 +26%，逐字节读取
  不再是瓶颈（此前它把 CLI 压在约 25 MB/s，而引擎本身是 42 MB/s）。
- 持续集成 `.github/workflows/ci.yml`：两个 job 分别执行 `moon check --deny-warn`、
  三后端 `moon test`、CLI/示例/演示冒烟、覆盖率（带 `-p` 过滤的双口径）、
  bundle 同步检查，以及差分报告与基准。
- 演示 bundle 冒烟测试 `tests/demo_smoke.mjs`（Node 直接执行已提交的 bundle）。
- 差分脚本增强：自动探测 `jsonrepair` 模块目录（`--node-module-dir`、`--no-node`），
  报告头部记录生成时间、被测二进制 sha256、两个 oracle 的版本与语料构成；
  `--no-stamp` 输出逐字节可复现，`--out` 避免弄脏工作区。

### 变更

- 差分语料 389 → **402 条**：补 R019 的 9 个手写用例（`"a" + "b"`、链式拼接、
  非字符串操作数回退）与 3 个嵌套多根文档；重跑后 202 处差异**全部有文档化成因**，
  未解释 0，Node 参照一致率 59.7%（236/395）。
- 文档口径刷新：吞吐按多次观测中位数（native 41–43 MB/s、JS 19–37 MB/s）、
  内存按语料形状分列（对象数组 17.8×、纯数组 23.1×、单个 10 MB 字符串 38.0×）、
  `docs/BENCHMARK.md` 新增命令行端到端一节与读取方式 A/B 表。
- 根 `README.md` 新增「与 moon_json_repair 的定位差异」对照表与「为什么是 MoonBit」，
  并把「MoonBit 生态里没有」的表述改为与 `btlqql/moon_json_repair` 的分工对比。

### 修复

- 差分报告的成因表把 R014/R015 的规则名与 R020 的需求编号写错了（R020 记成 BR-16，
  R015 记成转义类），已改为 `invalid escape repaired (BR-08)`、
  `mismatched closer replaced (BR-14)`、`ellipsis placeholder dropped (BR-21)`；
  并加入 `CODE_REASON` 必须恰好覆盖 R001–R021 的断言，防止再次漂移。

### 已知限制

- **JS 后端线性度未达标**：4n/2n 在同机 8 次运行中为 2.3–2.8（中位数 2.5），
  超过 NFR-PERF-01 的 2.3；根因是 JS 产物每个码元构造一个 `Position` 对象。
  原地更新方案会破坏历史位置（`tok_start` 等与 `self.pos` 共用对象），实测导致
  5 个用例失败并已回滚，正确做法是分离「当前位置」与「历史位置」。
- 峰值内存约为输入的 18 倍（12.95 MB 对象数组输入 → 230.6 MB，单个 10 MB 字符串
  为 38 倍），未达到「≤ 4 倍输入」的预算；需要「只产出文本、不建树」的模式才能达标
  （见 `docs/BENCHMARK.md`）。
- FR-16 事件/回调接口未实现，需要回调的调用方只能用 `snapshot()` 轮询。
- 命令行工具仅支持 native 后端；库本身在 wasm-gc / native / JS 三个后端均通过测试。

## [0.1.0] - 2026-10-14（未发布）

首个版本。本版本尚未发布到 mooncakes.io（`moon whoami` 未登录），源码状态见
`docs/TRACEABILITY.md`。

### 新增

- 一次性修复与解析：`repair` 与 `parse` 入口，返回修复后的文本、解析出的
  `Json` 值以及逐条修复记录（修复码、位置偏移、严重级别）。
- 流式部分解析：`PartialParser` 支持 `feed`、`feed_bytes`、`snapshot` 与
  `finish`，任意分块边界下快照结果一致，并提供完整性状态与路径信息。
- 修复规则（R001 至 R018、R020、R021，共 20 条生效）：围栏剥离、注释剥离、
  引号规范化、裸词加引号、多余逗号删除、缺失逗号插入、缺失冒号插入、缺失值补
  null、容器闭合、字符串闭合、数字修复、字面量转换、控制字符转义、转义修复、
  括号错配、意外内容丢弃、多余闭合符丢弃、重复键合并、省略号丢弃、前导说明跳过。
  （R019 字符串拼接在 0.2.0 落地。）
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
  `-h/--help`，从文件或标准输入读取并输出修复后的 JSON；输入按 64 KB 分块流式读入，
  不再把整份输入复制成一份 `Bytes`。
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

### 已知限制

- `snapshot()` 返回完整拷贝，代价与树大小成正比，高频调用时总体开销较大；
  FR-16 的事件接口可缓解。
- `Json` 数值遵循 core 的表示，大整数可能损失精度；修复后的文本保留数字原文。
- 引号前瞻默认关闭，开启后对缺逗号的字符串序列会偏向解释为内容。
- 解析器实例非线程安全，每个输入流应使用独立实例。
- 与 `jsonrepair` 存在有意差异，详见差分报告；差异点包括未结束数字在快照中
  默认不输出、悬空键在快照中省略而最终结果为 null、重复键默认保留最后一个并
  记录 R018、孤立代理码元统一替换为 U+FFFD，以及参照实现中更激进的猜测式修复
  属于范围外行为。
