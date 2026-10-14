# JSONMend — 流式 JSON 修复与部分解析库（纯 MoonBit）

[![CI](https://github.com/wenhuang2333/Moonbit-haker/actions/workflows/ci.yml/badge.svg)](https://github.com/wenhuang2333/Moonbit-haker/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](code/LICENSE)

**把大模型吐出的「几乎正确」的 JSON 变成可用的 JSON：能修就修、修不了就补全，全程留下可审计的修复记录。**

[English](#english) · [详细文档](#文档索引) · [演示页](static/demo/index.html) · [测试证据](#质量与证据)

```
{'name': 'MoonBit', 'tags': ['json', 'repair',], 'ok': true,}
                ↓  jsonmend
{"name":"MoonBit","tags":["json","repair"],"ok":true}
```

## 为什么需要它

LLM 的结构化输出经常不是合法 JSON：外面裹着 ``` 围栏、前面带一句「好的，这是你要的 JSON」、
用单引号、夹着 `//` 注释、尾逗号、`NaN`/`undefined`、被 `max_tokens` 截断在半个字符串中间。
严格解析器遇到这些直接抛错，而流式场景下应用只拿到前缀。TypeScript 与 Python 有成熟方案。

MoonBit 生态里已有 [`btlqql/moon_json_repair`](https://mooncakes.io/docs/btlqql/moon_json_repair@0.1.1)（保守修复，
明确声明 *"This implementation buffers input; it is not an unbounded streaming parser"*）。
JSONMend 与它的分工不同，一句话概括：

> **moon_json_repair 修的是已经写完的坏 JSON；JSONMend 修的是正在生成中的坏 JSON ——
> 模型每吐一个 token，应用就能多读到一点。**

差异清单见 [与 moon_json_repair 的定位差异](#与-moon_json_repair-的定位差异)。

三条不变量贯穿实现，并由属性测试强制：

1. **输出合法** —— 修复后的文本一定可以被标准 JSON 解析器接受；
2. **幂等** —— 再修一次不再产生任何改动；
3. **分块不变** —— 一次性喂入与任意切分逐块喂入，文本、修复记录、错误完全一致。

## 快速开始

```bash
# 1. 安装工具链（若尚未安装）
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"

# 2. 构建与测试（HTTPS 可直接匿名克隆；SSH 用 git@github.com:wenhuang2333/Moonbit-haker.git）
git clone https://github.com/wenhuang2333/Moonbit-haker.git
cd Moonbit-haker/code
moon check --deny-warn   # 0 warning
moon test                # 32 个测试块全部通过
```

```moonbit
// 3. 一次性修复
let r = @jsonmend.repair("{'a':1,}")
// r.text    == {"a":1}
// r.repairs == [R003 1:2 quote normalized to double quote,
//               R005 1:7 extra comma removed]

// 4. 流式部分解析：边生成边用
let p = @jsonmend.PartialParser::new()
p.feed("{\"name\":\"Mo")
p.snapshot()          // {"name":"Mo"} | Partial | name
p.feed("onBit\",\"tags\":[\"json\"]}")
p.finish()            // Complete, {"name":"MoonBit","tags":["json"]}
```

## 命令行

```bash
moon build cmd/jsonmend --target native --release
J=./_build/native/release/build/cmd/jsonmend/jsonmend.exe

$J broken.json > fixed.json          # 修复并输出
$J --report broken.json              # 修复记录写到 stderr
R003 1:2 quote normalized to double quote
R005 1:46 extra comma removed

$J --check broken.json ; echo $?     # 1：需要修复
$J --strict broken.json ; echo $?    # 5：严格模式，第一条记录即报错
jsonmend: E010 StrictViolation at 1:2 (offset 1): R003 NormalizeQuote: quote normalized to double quote
  {'name': 'MoonBit', 'tags': ['json', 'repair',], 'ok': true,}
   ^

$J --indent 2 broken.json            # 缩进输出
```

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功（可能有修复） |
| 1 | `--check` 发现需要修复 |
| 2 | 用法错误（未知选项、非法取值、E050） |
| 3 | 输入无效（E001/E002/E040，或文件不可读） |
| 4 | 资源限制（E020/E021/E022） |
| 5 | 严格模式违规（E010） |
| 70 | 内部错误（E030） |

## 功能一览

| 能力 | 说明 |
| --- | --- |
| 一次性修复 | `repair` 返回修复文本、`Json` 值与逐条修复记录（码、位置、级别、消息） |
| 流式部分解析 | `PartialParser::feed` / `feed_bytes` / `snapshot` / `finish`，快照给出值、完整性状态与未闭合路径 |
| 21 条修复规则 | R001–R021：围栏、注释、引号、裸词、逗号、冒号、缺值补 null、容器/字符串闭合、数字、字面量、转义、括号错配、意外内容、多余闭合符、重复键、相邻字符串拼接、省略号、前导说明 |
| 9 个错误码 | E001/E002/E010/E020/E021/E022/E030/E040/E050，含位置与上下文片段 |
| 严格模式 | 任何修复都升级为 `E010`，可用于校验流水线 |
| 策略选项 | 重复键、未完成数字、悬空键、非有限值、多根值、围栏、前导说明、引号前瞻、缩进、按规则开关 |
| 资源上限 | 嵌套深度、输入长度、单 token 长度，超限抛错而不是耗尽内存 |
| 多后端 | wasm-gc / native / JavaScript 三个后端测试结果一致；CLI 为 native |
| 无外部运行时依赖 | 只用 MoonBit 标准库 |

完整选项表见 [code/README.zh.md](code/README.zh.md#选项)，规则细节见 [code/docs/RULES.md](code/docs/RULES.md)。

## 质量与证据

| 项目 | 规模 | 结果 |
| --- | --- | --- |
| 黄金用例（项目文档附录 A、B） | 126 条 | 全部通过 |
| 流式用例（S-001…S-021）与分块不变性 | 21 条 + 逐码元/二分/1 KB 切分 | 通过 |
| 属性与模糊测试 | 8 组 × 400 例（另压测 20 万例） | 通过，无反例 |
| 公共面与选项测试 | 21 个 R 码 + 9 个 E 码逐一检查 | 通过 |
| 三个后端 | wasm-gc / native / JS | 各 32/32 通过 |
| 命令行冒烟 | 25 项断言（含全部退出码） | 通过 |
| 示例对照 | 6 组输入/期望输出 | 逐字节一致 |
| 差分测试（对照 `jsonrepair`、`json-repair`） | 402 条用例 | 202 处差异**全部有文档解释**，未解释 0 |
| 库代码行覆盖率 | 1137/1223 行 | 93.0% |
| 吞吐（Apple M5，release，单机多次观测中位数） | 合法 JSON native 41–43 MB/s、JS 19–37 MB/s | 达标（阈值 20 / 5） |
| 命令行吞吐（12.95 MB 输入，64 KB 分块） | 27.6 MB/s（峰值 RSS 230 MB） | 单次 `fread` 取代逐字节读后 +21% |
| wasm-gc 产物体积 | 95.9 KiB | 达标（上限 150 KB） |

```bash
cd code
moon test && moon test --target native && moon test --target js
bash tests/cli_smoke.sh && bash tests/examples.sh
node tests/demo_smoke.mjs
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

以上命令（含差分与产物体积）也在 `.github/workflows/ci.yml` 中按同样的版本执行。

## 演示页

![演示页](static/demo/screenshot.png)

`static/demo/index.html` 由 MoonBit 的 JavaScript 后端产物直接驱动（`code/examples/web/main.mbt`
把 `repair` / `report` / `snapshot` 注册到页面），**页面里没有第二份实现**。直接用浏览器打开即可，
无需服务器；重新生成 bundle 用 `bash static/demo/build.sh`。

## 与 jsonrepair 的关系

不是移植，也不追求逐字节一致。差分测试里约一半用例结论不同，全部落在四类**有意**的策略差异上：

1. **截断处的补全策略**：补 `null` 并闭合容器，而不是猜一个空字符串或把片段变成数组元素；
2. **多根值**：默认只保留第一个值，`--multi-root array` 可切换为合成数组（该探针下与参照一致）；
3. **字面量与非有限值**：`tru`→`true`、`NaN`/`Infinity`/`undefined`→`null`，裸词加引号；
4. **范围外输入**：没有任何 JSON 值时返回 `E001`/`E002`，而不是凭空造一个值。

逐条归因见 [code/docs/DIVERGENCES.md](code/docs/DIVERGENCES.md)。

## 与 moon_json_repair 的定位差异

同赛道已有 [`btlqql/moon_json_repair@0.1.1`](https://mooncakes.io/docs/btlqql/moon_json_repair@0.1.1)
（Apache-2.0，零第三方依赖，带可重放编辑与 JSONL 批处理）。下表按**对方 README 的原文声明**与
本仓库的实测行为逐项对照（对方信息取自 2026-10-15 的 mooncakes 页面，提交前会再复核一次）：

| 能力 | JSONMend | moon_json_repair@0.1.1 |
| --- | --- | --- |
| 定位 | 流式：边到达边解析 | 保守修复：已写完的文本 |
| 增量 `feed` / `snapshot` | 有（`PartialParser::feed`/`feed_bytes`/`snapshot`，任意切分结果一致） | 无（原文："not an unbounded streaming parser"） |
| 输入上限 | 64 Mi UTF-16 码元（可配） | 1 Mi（可配） |
| 嵌套深度上限 | 512（可配） | 128（可配 1–256） |
| 缺中间逗号 / 冒号 / 值 | 修复（R005/R006/R007/R008） | 原文："Missing middle commas/colons/values … fail" |
| 截断补全 | 闭合容器与字符串、补全字面量、缺值补 `null` | 原文：只在 relaxed 下闭合容器，"never completes strings, literals, empty containers, or values after commas" |
| 重复键 | 合并（R018，策略可选） | 原文："duplicate keys … fail" |
| 根值之后的多余内容 | 策略可选（保留首个 / 合成数组 / 报错） | 原文："extra root content fail" |
| 引号 / 注释 / 尾逗号 / 裸键 | 有（默认开启，可逐条关闭） | relaxed 模式提供 |
| 非有限值 `NaN`/`Infinity` | 转 `null`（策略可选） | 未声明 |
| 字符串 `+` 拼接（LLM 常见） | R019 合并 | 未声明 |
| 修复记录 | 21 类规则 + 级别 + 行列位置，可逐条开关、条数可配 | `Edit`（start/end/replacement/code） |
| 可重放编辑 | **无**（返回文本与记录） | **有**（`apply_edits`，拒绝重叠/越界/切断代理对） |
| JSONL 批处理 | **无**（在路线图上） | **有**（`repair_jsonl`） |
| 严格模式 | 有（`E010`，退出码 5） | `Options::strict` |
| 三条不变量（输出合法 / 幂等 / 分块不变） | 由属性测试强制，见 `prop_wbtest.mbt` | 未承诺 |
| 三后端一致性 | wasm-gc / native / JS 各 32/32 同一套测试 | 未声明 |
| 浏览器演示 | 有（`static/demo/index.html`，bundle 由 CI 校验同步） | 未提及 |
| 差分证据 | 402 例对照 `jsonrepair` 与 `json-repair`，202 处差异全归因 | 未提及 |
| wasm-gc 体积 | 95.9 KiB | 未声明 |

客观地说，对方的**可重放编辑**（带范围校验的 `Edit` 重放）与**JSONL 批处理**是 JSONMend
目前没有的能力；而 JSONMend 的差异化压在它的边界上：**流式增量**、**截断补全**、**更宽的修复面**
与**可审计的记录**。

## 为什么是 MoonBit

- **显式栈 + 模式匹配的状态机**替代递归下降：512 层嵌套不爆栈（`NFR-ROB-02`），
  而且每个状态转移都是 `match` 的一个分支，21 条规则各自独立可测；
- **`raise` 错误系统**直接承载 9 个 `E` 码，错误载荷（`limit`、`offset`、`RepairCode`、`Position`）
  随类型走，调用方不需要解析字符串；
- **三后端一条命令**：`moon test` / `--target native` / `--target js` 跑同一套 32 个测试块，
  同一份引擎源码产出 wasm-gc 95.9 KiB 的库、native CLI 和浏览器 bundle —— 这在别的语言里
  要三套构建与三套测试；
- **零第三方依赖**：无正则、无外部解析器，wasm-gc 产物只含引擎与 core 的必要部分；
- **工具链自带覆盖率与基准**：`moon coverage report` 与 `moon build --release` 就是
  质量证据链的一部分（见 [code/docs/REPRODUCE.md](code/docs/REPRODUCE.md)）。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `code/*.mbt` | 库本体（`engine.mbt`/`engine_flow.mbt` 状态机、`api.mbt`、`error.mbt`、`options.mbt`、`text.mbt`） |
| `code/*_wbtest.mbt` | 白盒测试：黄金用例、流式用例、属性/模糊、公共面、选项 |
| `code/cmd/jsonmend/` | 原生命令行前端 |
| `code/bench/`、`code/tests/bench.sh` | 基准与产物体积探针 |
| `code/examples/` | 浏览器演示入口（JS 后端）与示例输入/期望输出 |
| `code/tests/diff/` | 差分测试框架与报告生成器 |
| `code/docs/` | 规则、错误、差分、基准、复现、一页说明、追踪矩阵 |
| `static/demo/` | 构建好的演示页与 bundle |
| `marks/` | 项目文档集（需求、设计、测试计划） |

## 已知限制

- FR-16 事件/回调接口未实现（需要回调的调用方只能用 `snapshot()` 轮询）。
- 快照的 `incomplete_number` / `pending_key` 策略只影响快照，最终结果仍会补全。
- 峰值内存约为输入的 18 倍（12.95 MB 对象数组 → 230.6 MB；纯数组 23 倍；单个 10 MB 字符串 38 倍），未达到「≤ 4 倍输入」的预算：只要保留完整 `Json` 树就无法达标，需要「只产出文本、不建树」的模式。
- 命令行仅支持 native 后端；解析器实例非线程安全，每个流用一个实例。
- `Json` 数值遵循 core 的表示，大整数可能损失精度，但修复后的文本保留原数字。
- 恢复策略是启发式的，不是某个标准的合规实现。

完整清单见 [code/README.zh.md](code/README.zh.md#已知限制) 与 [code/docs/TRACEABILITY.md](code/docs/TRACEABILITY.md)。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [code/README.zh.md](code/README.zh.md) / [code/README.md](code/README.md) | 中文 / 英文完整说明：API、选项、CLI、测试 |
| [code/docs/RULES.md](code/docs/RULES.md) | 21 条修复规则：触发条件、级别、消息模板、示例 |
| [code/docs/ERRORS.md](code/docs/ERRORS.md) | 9 个错误码、严格模式升级、退出码、失效模式 |
| [code/docs/DIVERGENCES.md](code/docs/DIVERGENCES.md) | 与两个参照实现的逐类差异与归因 |
| [code/docs/BENCHMARK.md](code/docs/BENCHMARK.md) | 吞吐、线性、流式、内存、体积 |
| [code/docs/REPRODUCE.md](code/docs/REPRODUCE.md) | 从零复现全部结论 |
| [code/docs/ONEPAGE.md](code/docs/ONEPAGE.md) | 一页项目说明 |
| [code/docs/TRACEABILITY.md](code/docs/TRACEABILITY.md) | 需求 → 用例 → 证据 追踪矩阵 |
| [code/CHANGELOG.md](code/CHANGELOG.md) | 版本变更 |
| [code/CONTRIBUTING.md](code/CONTRIBUTING.md) | 开发环境、测试命令、新增规则的流程 |

## 路线图

- **发布 0.2.0 到 mooncakes.io**（`moon whoami` 未登录，阻塞中）；补 git tag 与独立版本小节。
- 实现 FR-16 事件/回调接口（`on_value_complete` / `on_repair`），让流式消费方不必轮询快照。
- 增加「只产出文本、不建树」的模式，把内存从 ≈18 倍降到 4 倍以内。
- **TTFV（Time-to-First-Value）指标**：量化「输入到达多少比例时能读到第一个完整值」，作为流式优势的客观证据。
- **JSONL 流式模式**：每行闭合即交付一个值（对方是整批缓冲，这里是增量）。
- 演示页新增「模拟 LLM 流」标签：逐 token 喂入，右侧实时显示快照生长。
- JS 后端位置分配重构：消除每码元一次的对象分配，把 4n/2n 从 2.3–2.8 拉回 ≤2.3。
- 快照增量子树缓存（`Frame.dirty` 已存在但未使用）：把「每 1024 码元一次快照」的 2 倍惩罚降下来。

## 许可与致谢

Apache-2.0，见 [code/LICENSE](code/LICENSE) 与 [code/NOTICE](code/NOTICE)。
测试使用 [`jsonrepair`](https://www.npmjs.com/package/jsonrepair)（ISC）与
[`json-repair`](https://pypi.org/project/json-repair/)（MIT）作为**进程外**差分参照，
其代码不进入本仓库或任何构建产物。

---

<a id="english"></a>

## English

**JSONMend** is a streaming JSON repair and partial-parsing library written in pure MoonBit.
It turns the almost-JSON that language models emit into usable JSON: repair what can be
repaired, complete what is truncated, and record every change with a code and a position.

- **One-shot**: `repair(input)` returns repaired text, the parsed `Json` value, and a list
  of repair records; `parse(input)` returns the value directly.
- **Streaming**: `PartialParser::feed` / `feed_bytes` / `snapshot` / `finish`, with snapshots
  that are a stable prefix (value, completeness, open path).
- **21 repair rules** (fences, comments, quotes, bare words, commas, colons, missing values,
  unclosed containers and strings, numbers, literals, escapes, mismatched closers, duplicate
  keys, ellipsis, prose) and **9 fatal error codes** with positions and snippets.
- **Guarantees enforced by property tests**: output is always valid JSON, repair is idempotent,
  and streaming is chunk invariant.
- **Verified**: 126 golden cases, 21 streaming cases, 8 property groups × 400 cases,
  32 test blocks on wasm-gc / native / JS, 25 CLI assertions, and a 402-case differential
  corpus against `jsonrepair` and `json-repair` in which every one of the 202 divergences has
  a documented cause. Library line coverage 93.0%; native throughput 41–43 MB/s
  (single-machine observation; CI reruns the same benchmark script).
- **CLI** (`jsonmend`) with `--report`, `--check`, `--strict`, `--indent`, `--multi-root`,
  `--max-repairs`, chunked streaming input, and a browser demo driven by the MoonBit JS build.

Docs: [code/README.md](code/README.md) (English) · [code/README.zh.md](code/README.zh.md) (中文) ·
[code/docs/](code/docs/). License: Apache-2.0.
