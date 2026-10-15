# Changelog

本文件记录 JSONMend 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.4.0] - 2026-10-15

第五轮优化版本（`JSONMend 第五轮：优化、完善与扩展方向.md`），主题是**让证据经得起质疑**：
补上歧义这一层被排除的难例、把评测跑到流式与适配器两条真实路径上、与参照库做并列对照，
并把性能对齐到产品真实场景（4 KB、3 码元分块）。

### 新增

- **歧义标记与执行闸（FR-27）**。`Ambiguity` 五态（`unambiguous` / `bare_word` /
  `adjacent_strings` / `concat_operator` / `trailing_content`）进入每条修复记录；
  新的 `Options::reject_ambiguous` 在精确度闸**之前**抛 `E011 AmbiguousRepair`（退出码 5），
  因为「值没变」和「只有一种读法」是两件事。新增错误码编号 `E011`（错误码 10 → 11）。
- **拒绝即反馈（FR-28）**。`RetryHint`（`MendError::retry_hint`）：错误码、修复码、位置、
  歧义类、原因、有界上下文窗口与插入符，`to_prompt()` 可直接回灌模型；CLI `--retry-hint`。
- **字段就绪曲线（FR-29）**。`field_readiness` / `readiness_median` / `readiness_deciles` /
  `early_stop_saving` 与增量驱动的 `FieldTracker`；CLI `readiness` 子命令。
  取代「95% 覆盖」：后者在对象上结构性不敏感。
- **适配器事件完备性与结束原因（FR-30）**。`ping` 与未知事件类型计数后忽略；
  `error` 事件置 `ProviderError` 并暴露消息；`message_delta.stop_reason` 与 `finish_reason`
  映射到 `CallEnd`（`Open` / `Complete` / `MaxTokens` / `Interrupted` / `ProviderError`），
  并保留提供方的原始 `stop_reason`；新增 `TextStream` 读取 `delta.text` / `delta.content`，
  CLI `llm --text`、`llm --batch`。
- **事件接口（FR-16，原「削减」项）**。`PartialParser::feed_with` / `feed_bytes_with`：
  在 `drain_deltas` 上的薄封装（回调顺序与 drain 逐条一致），不做第二套引擎。
- **参照对照与多路径评测（FR-31）**。`tests/eval/refcompare.py`（同一 1200 条语料上跑
  `jsonrepair` 3.15.0 与 `json_repair` 0.64.0，报告「静默错值」）、
  `tests/eval/run_eval_paths.py`（8 条路径）、`tests/eval/run_ambiguity.py`（对抗语料 `amb-1`）、
  `tests/eval/check_amb_guard.py`（断言机制本身可失败的守卫）、
  `tests/memory_baseline.py`（与 Node / Python 的横向内存基线）。

### 变更

- `DeltaOp::Retract` 移除：它从未被发出，公开枚举只保留 `Set` / `AppendText` / `Close`。
- `Close` 的契约写清：`duplicate_keys KeepLast` 下同一路径在 `Close` 之后仍可被 `Set` 覆盖，
  并有测试固定该行为。
- `--chunk N` 的上限从 64 放宽到 1 048 576 码元（此前大于 64 的分块会被拒绝）。
- `llm --batch` 的事件既接受内嵌 JSON 对象，也接受 JSON 字符串。
- `R022 NormalizeLiteral` 的判据从「长度相同」改为「仅 ASCII 大小写不同」：
  `None` 补成 `null` 是发明取值（`R012`），`True` 补成 `true` 才是记法（`R022`）。
  该问题由对抗语料 `amb-1` 首次运行时发现。取值不变，因此 `DIVERGENCES.md` 逐字节不变。
- 模块名 `wenhuang2333/jsonmend` → `zhanshishan/jsonmend`（与 mooncakes 账号一致，发布前提）。

### 证据

- 真值语料 1200 条：`--batch` 基线、`--chunk 1/3/7/随机`、双 provider 工具流、
  双 provider 文本流，**8 条路径全部 1200/1200，零分歧**（`docs/EVAL_PATHS.md`）。
- `eval-3`：`R022` 的判据修正后新增判据 3b（`null`→`None` 必须恢复原值且标 `lossy`），
  **不排除任何用例**，1200 条上五条判据全 PASS。
- 对抗歧义语料 `amb-1` 24 例：10 例歧义全部标记且全部拒绝，14 例对照全部放行，失败 0；
  同一批用例上 `jsonrepair` 静默给出 8 个值、`json_repair` 10 个（`docs/EVAL_AMBIGUITY.md`）。
- 参照库对照：JSONMend 静默错值 0，`jsonrepair` 122，`json_repair` 189；
  `--for-execution` 拒绝 **254/1200** 且放行的错值 0（`docs/EVAL_REFERENCE.md`；
  `eval-3` 的标签修订使这 11 条 `null`→`None` 用例也进入拒绝集，见 `docs/EVAL_REGISTRATION.md` §11）。
- 场景基准：4 KB 工具调用文档按 3 码元分块，0.08 µs/feed（摊还），290 000 次 feed 中
  只有 17 次跨过 1 ms 时钟格、**没有任何一次单 feed 达到 1 ms 量级**（p99 只能给上界）；
  就绪曲线十分位 `0 10 21 30 41 51 61 71 80 90 100`（`docs/BENCHMARK.md`）。
- 内存横向基线：12.95 MB 输入下 JSONMend 13.7 ×、Node 10.6 ×、Python 14.3 ×；
  「≤ 4 ×」对任何建树实现都不现实（`docs/MEMORY.md`）。
- `moon test` 95/95（wasm-gc / native / js 一致）；`tests/cli_smoke.sh` 48/48。

### 如实记录的限制

- 适配器事件形状是**按官方文档与官方 SDK 类型定义转录**，不是真实流录制：
  本环境没有凭据与到 provider 的网络。`tests/record_stream.py` 可在有条件时录制，
  差别写在 `docs/LLM_EVENTS.md`。
- p99 单次 feed 延迟只能给上界：运行时 `@env.now()` 为毫秒分辨率，且没有分配计数。
- 就绪曲线只覆盖**顶层成员**，成本约 1.8 ms/KiB（采样 1000 次快照）；
  全字段早停节省在扁平记录上构造性地≈0。
- 文本模式默认不跳前言；`--skip-prose` 只从 `{` / `[` 开始取值，标量根需要关闭它。

## [0.3.0] - 2026-10-15

第四轮优化版本（`JSONMend 优化完善与创新方向建议.md` 的 I-1…I-6 / O-1…O-15），主题是**让「修好了」这件事可以被执行方信任**：
修复结果现在携带一个三级的精确度标签，调用方可以在执行之前拒绝它。

### 新增

- **精确度标签（FR-19 / I-1）**。`Exactness` 三级：`Exact`（完全没修）、
  `Cosmetic`（只改了记法，取值没变）、`Lossy`（发明或丢弃了信息）。
  `RepairResult`、`ParseResult`、`Snapshot`、`FinalResult` 都带 `exactness` 字段。
- **执行安全闸**。`Options::max_loss`（默认 `Lossy`，即不改变既有行为）在
  记录到超出上限的修复时立刻抛 `E010 StrictViolation`，错误里带着触发的那条修复码；
  CLI 对应 `--max-loss exact|cosmetic|lossy`，复用退出码 5。
  这样「先修再执行」可以变成「修的同时判断能不能执行」。
- **`Options` 预设**：`lenient()`（等于默认）、`strict()`、`for_llm()`（开增量流）、
  `for_execution()`（`max_loss: Cosmetic`）。
- **增量补丁流（FR-18 / I-2）**。`Options::collect_deltas` 打开后，
  `PartialParser::drain_deltas()` 返回 `Array[Delta]`（`Set` / `AppendText` / `Close` /
  `Retract`），路径用 JSON Pointer（RFC 6901）。契约由属性测试保证：
  把增量依次应用到上一次的快照上，结果与 `snapshot().value` 逐值相同。
  与 `KeepFirst` 重复键策略、`TrimToValid` 未完成数字不兼容，`validate()` 会拒绝。
- **`jsonmend/llm` 子包（FR-22 / I-3）**：Anthropic 细粒度工具流
  （`content_block_delta` → `input_json_delta` → `partial_json`）与
  OpenAI 兼容流（`choices[].delta.tool_calls[].function.arguments`）的适配器，
  支持多路并发工具调用、SSE 行解析（`SseBuffer`）、截断（`max_tokens`）时
  自动收尾并标 `Lossy`。9 个夹具（`llm/fixtures/*.jsonl`）由生成脚本与
  MoonBit 内嵌副本同源产出。
- **CLI `jsonmend llm`**：把录制的事件流喂给适配器，每个工具调用输出一行 JSON，
  `--follow` 每次增量都输出一行（演示「边收边展示」）。
- **CLI `--batch`**：逐行读 `{"id","input"}`、逐行输出
  `{"id","rc","exactness","codes","value","text"}`，让评测脚本不必为每个用例
  起一个进程。
- **CLI `--explain`**：逐条修复打印级别、位置与带插入符的代码片段，末尾给出
  精确度小结。
- **R022 `NormalizeLiteral`**：`True`/`FALSE` 这类只改大小写的字面量单独成码
  （Info）。此前它与「补全字面量」（`tru` → `true`，确实造值）共用 R012（Warning），
  导致纯记法修复被误报为信息损失。**R001–R021 的含义没有任何变化，码只追加。**
- **`E060 InvalidEvent`**：`jsonmend/llm` 遇到无法解释的事件负载时抛出。
- **真值评测（I-4）**：`tests/eval/corpus.py` 生成 1200 条带真值的用例
  （20 族单点变异，60 条/族），`tests/eval/run_eval.py` 驱动 `--batch` 并生成
  `docs/EVAL.md`。协议先冻结在 `docs/EVAL_REGISTRATION.md`（含数据集 sha256）。
  当前结果：恢复率 **100.00%**，漏标率 **0**，四条预登记判据全部 PASS。
- **长跑属性测试（O-6）**：`JSONMEND_LONGRUN=N` 把每个属性的用例数从 400 提到 N，
  夜间工作流用 1,000,000（本机约 50 s）。
- **夜间与发布工作流**：`.github/workflows/nightly.yml`（长跑 + 差分 + 评测）、
  `.github/workflows/release.yml`（tag 触发，产出 native CLI、wasm 探针、演示
  bundle 与 `SHA256SUMS`）。

### 变更

- **`E040` 偏移量改为绝对**：`feed_bytes` 此前把非法 UTF-8 的偏移量报成块内相对值，
  同一个输入换个分块大小就报不同的位置。现在所有错误偏移量都是相对输入起点的
  绝对偏移（坏续字节报自身位置，过长/超范围/结尾截断报序列起点）。
  `E021`/`E022` 复核确认本来就是绝对的，新增回归测试。
- **标签精度**：`R015`/`R017`/`R021` 由 Warning 降为 Info（只改记法）；
  `R018` 在两次取值结构相等时记为 Info。记法类修复的 `lossy` 误报
  从 300/900 降到 0/900。
- `RepairCode` 21 → 22 条；`MendError` 9 → 10 个变体（新增 `E060`）。
- 模块版本 0.2.0 → 0.3.0。

### 性能

本机（Apple Silicon，native release）观测值：

| 项目 | 数值 |
|------|------|
| 合法 JSON 1 KB / 100 KB / 1 MB / 10 MB | 35.7 / 35.7 / 33.0 / 29.3 MB/s |
| 有缺陷 JSON 1 MB | 70.0 MB/s |
| 超长字符串 1 MB | 520 MB/s |
| 流式 chunk 1 / 16 / 1024 / 65536 | 16.1 / 25.4 / 30.5 / 32.5 MB/s |
| 增量流（chunk 1024 / 65536） | 基线耗时的 141.7% / 151.0% |
| 首个可见值的偏移量（工具调用文档中位数） | 文档长度的 **0.7%** |

增量流目前是基线的 1.42–1.51 倍耗时（吞吐约为基线的 66–71%），
**未达到 I-2 登记的 90% 目标**：每个变更都要新分配一个 `Delta` 与一份路径数组。
下一轮的方向是紧凑增量缓冲（见 `产品文档.md` 第 14 节）。

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
