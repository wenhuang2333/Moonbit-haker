# JSONMend 一页说明

**LLM JSON 的执行门：流式修复、部分解析与「能不能执行」的决策，纯 MoonBit 实现。**

## 问题

大模型输出的 JSON 经常不是合法 JSON：带 ``` 围栏、前后有说明文字、单引号、
行内注释、多余的尾逗号、`NaN`/`undefined`、被 `max_tokens` 截断在半个字符串
或半个对象中间。直接 `parse` 会失败，而丢掉整段输出代价很高。

## 方案

单趟、从左到右的宽容扫描器：能修就修并留下记录，不能修就补全，永远不因为
「还没结束」而报错。三条不变量贯穿实现：

1. **输出合法** —— 修复后的文本一定可以被标准 JSON 解析器接受；
2. **幂等** —— 再修一次不再产生任何改动；
3. **分块不变** —— 一次性喂入与任意切分逐块喂入，结果完全相同。

## 用法

### 给 agent 用：一次调用拿到「能不能执行」

```moonbit
let plan = @jsonmend.analyze(text, options=@jsonmend.Options::for_agent(),
  schema=@jsonmend.Schema::parse("{!query:string,!limit:integer}"))
plan.decision          // Safe | CosmeticRepair | LossyRepair | Ambiguous | Invalid
plan.is_executable()   // 唯一该看的问题
plan.prompt()          // 不能执行时，直接把这段回灌给模型
plan.repairs           // 每条：规则、动作、位置、置信类别、是否丢信息
plan.to_json()         // 机器通道：decision/exactness/value/retry/repairs
```

`analyze` **永不抛错**：拒绝是返回值的一部分，不是一个需要 `try` 的异常。

### 给宿主用：四种接入面

| 接入面 | 命令 / 包 | 谁调用 |
| --- | --- | --- |
| MCP | `jsonmend mcp` | Claude Code / Cursor / Codex CLI / Gemini CLI / Cline / Windsurf |
| 长驻协议 | `jsonmend serve` | 任意语言；`watch`/`llm` 流式 |
| 语言包 | `npm install ./code/npm` / `pip install ./code/python` | Node / Python 宿主 |
| HTTP | `jsonmend-http --port 8080`（Python） | n8n / Dify / Coze / 网关 |

工具声明不用翻译：`schema_json=tool.inputSchema` 直接吃 JSON Schema 子集
（`type`/`properties`/`required`/`items`/`enum`/`const`/数值与长度约束/锚定
字符类 `pattern`）；不支持的键报 `E070`。协议规范见 `PROTOCOL.md`，逐工具
配方见 `INTEGRATIONS.md`。

```moonbit
// 一次性
let r = @jsonmend.repair("{'a':1,}")        // r.text == {"a":1}
// r.repairs: R003 1:2 quote normalized…, R005 1:7 extra comma removed

// 流式（LLM 边生成边解析）
let p = @jsonmend.PartialParser::new()
p.feed("{\"name\":\"Mo")
p.snapshot()   // {"name":"Mo"} | Partial | name
p.feed("onBit\"}")
p.finish()     // Complete, {"name":"MoonBit"}
```

命令行（native）：

```bash
jsonmend < broken.json > fixed.json
jsonmend --report --indent 2 broken.json
jsonmend --check broken.json ; echo $?     # 1 = 需要修复
```

## 实现规模

| 部分 | 文件 | 说明 |
| --- | --- | --- |
| 引擎 | `code/engine.mbt`、`code/engine_flow.mbt` | 显式栈 + 状态机，单趟扫描，无递归 |
| 公共 API | `code/api.mbt` | `repair` / `parse` / `PartialParser` / `is_valid_json` |
| 规则与错误 | `code/error.mbt` | 22 条修复规则（R001–R022）、12 个致命错误码（E001–E070，含 `E011` 歧义拒绝与 `E070` 骨架声明错误）、三级精确度标签 `Exactness` 与五态 `Ambiguity` |
| 安全档位 | `code/policy.mbt` | `SafetyPolicy` 五档（permissive / interactive / execution / agent / strict）；`with_policy` 只换安全字段，`of_options` 可反查档位 |
| 计划与决策 | `code/plan.mbt`、`code/decision.mbt` | `analyze` 一次调用返回 `RepairPlan`（修复操作、置信类别、决策、重试提示、JSON 通道）；`ExecutionDecision` 五态 |
| 骨架与就绪 | `code/schema.mbt`、`code/stream_readiness.mbt` | `Schema` 文本 DSL（0.7.0 起带值约束）、骨架判定（缺失/类型不符）、`semantic_readiness` 的语法/定稿/骨架三层分数、增量事件观察器 `SemanticWatcher` |
| 歧义与反馈 | `code/hint.mbt` | `RetryHint`：拒绝原因、位置、第二种读法、上下文窗口与插入符，可直接回灌模型（FR-28） |
| 就绪曲线 | `code/readiness.mbt` | 顶层成员的就绪比例、十分位曲线与增量驱动的 `FieldTracker`（FR-29） |
| 增量流 | `code/delta.mbt` | `Options::collect_deltas` 打开后记录 `Delta`（Set/AppendText/Close），路径为 RFC 6901 JSON Pointer，每个 delta 带已消费码元数 `at`（0.7.0） |
| 大模型适配 | `code/llm/` | Anthropic 与 OpenAI 兼容工具流、SSE 行解析、文本流（`delta.text` / `delta.content`）、结束原因（`Complete`/`MaxTokens`/`Interrupted`/`ProviderError`）、9 个生成夹具 + 文档转录事件形状 |
| 选项 | `code/options.mbt` | 严格模式、重复键、未完成数字、非有限值、多根值、规则开关、资源上限 |
| CLI | `code/cmd/jsonmend/` | stdin/文件（64 KB 分块流式读入）、`--report`、`--check`、`--strict`、`--indent`、`--multi-root`、`--max-repairs`、`--max-loss`、`--for-execution`、`--reject-ambiguous`、`--retry-hint`、`--policy`、`--schema`、`--json`、`--explain`、`--batch`、`--chunk`、`explain` / `readiness` / `llm` 子命令 |
| 自愈闭环 | `code/examples/agent_loop/` | 拒绝 → 回灌 `prompt()` → 重试 → 执行或放弃的四个 episode |
| 基准 | `code/bench/` | 吞吐、线性、流式、安全层单价（`gate`）、产物体积 |

## 证据

| 项 | 结果 |
| --- | --- |
| 黄金用例 | 126 条（附录 A 77 + 附录 B 49）全部通过 |
| 流式用例 | 21 条（S-001…S-021）+ 分块不变性（逐码元 / 二分 / 1 KB 分块） |
| 属性与模糊 | 8 组 × 400 例（可用 `JSONMEND_LONGRUN` 提高，夜间跑 1 000 000 例）；未发现反例 |
| 增量流 | 400 份生成文档 + 400 份变异输入上「增量重放 == 快照」；7 组选项剖面 |
| 真值评测 | 1200 条带真值用例（19 族 + 1 对照组，每族 60 条）；恢复率 100.00%，漏标率 0，五条预登记判据 PASS（`eval-3` 新增判据 3b） |
| 参照对照 | 同一 1200 条上 `jsonrepair` 静默错值 122、`json_repair` 189，JSONMend 0；执行闸拒绝 254/1200 且放行错值 0 |
| 多路径真值 | 分块 1/3/7/随机 + 双 provider 工具流/文本流共 8 条路径，全部 1200/1200，零分歧 |
| 对抗歧义 | 24 条手写用例：10/10 标记并拒绝，14/14 对照放行；判据机制另有守卫证明其可失败 |
| 大模型适配 | 9 个夹具 × 双 provider，截断/转义切分/代理对切分/多路并发全部覆盖；另有 `ping`/未知事件/`error`/三种结束原因/文本流的文档转录用例 |
| 公共面与选项 | 22 个 R 码 + 11 个 E 码逐一检查；策略枚举、规则开关、字节输入共 17 例 |
| 安全档位与计划 | 34 条新测试：档位 7、计划 22、骨架 5；`analyze` 相对 `repair` 1.00–1.03×，加 `for_agent` 1.33×，加骨架 1.45× |
| 骨架感知就绪 | 10 个场景：6 个存在落差（713‰–908‰），4 个两层同时到达末尾；`docs/READINESS.md` |
| 独立语料 | `nst/JSONTestSuite` 318 文件：`y_` 误修 2/95（重复键），`n_` 有效值 165/188 vs `json_repair` 166/188、`jsonrepair` 144/188 |
| 自愈闭环 | 4 个 episode：2 次重试后执行、1 次骨架不符回灌、1 次判定无改进后放弃 |
| 覆盖率 | 根包 3551/3777 = 94.0%（含新增 `json_schema.mbt` 206/224 = 92.0%；`plan.mbt` 489/526、`schema.mbt` 794/840、`stream_readiness.mbt` 310/327），`llm` 包 337/391 = 86.2%；库门禁 3818/4098 = 93.2% |
| 差分测试 | 402 条用例对照 `json-repair` 与 `jsonrepair`；202 处差异全部由修复记录解释，未解释 0 |
| 命令行 | 85 项断言全部通过（退出码 0/1/2/3/4/5/70 覆盖，含 `explain` 的 14 条、6 项版本一致性：4 份文档 + `--version` + README 通道映射对齐 `moon.mod`） |
| 演示页 | `static/demo/index.html` + `static/demo/live.html`，MoonBit JS 产物驱动，无头浏览器验证无报错 |
| 在线演示 | <https://wenhuang2333.github.io/Moonbit-haker/live.html>（GitHub Pages，`pages.yml` 发布） |
| 录屏 | `static/demo/demo.mp4`（69 秒，Chromium 真实录制）+ `static/demo/live-demo.gif` |
| 跨后端 | wasm-gc / native / JS / wasm 四个 target 各 210/210 同一套测试（共 840 次） |
| 吞吐 | native 35–39 MB/s（合法 JSON，1 KB–10 MB）；首个可见值出现在文档长度的 0.7%（中位数）；agent 场景（4 KB / 3 码元）0.08 µs/feed |
| 内存 | 12.95 MB 输入 177.9 MB（13.7 ×）；同机 Node 10.6 ×、Python 14.3 ×，4 × 目标对建树实现不现实 |
| 体积 | wasm-gc release 103.5 KiB（上限 150 KB）；native CLI 730.9 KiB；浏览器包 590.7 KiB |

## 与参照实现的关系

差分测试中约一半的用例结论不同，差异**全部**落在四类可解释的行为上：
截断处的补全策略（补 `null` 并闭合容器，而不是猜一个空串）、多根值策略
（默认只保留第一个，可用 `--multi-root array` 切换）、字面量与非有限值处理、
以及明确划到范围外的输入（无 JSON 值、`#` 注释、孤立代理码元）。
逐条说明见 `docs/DIVERGENCES.md`。

## 已知限制

- `semantic_readiness` 的代价是 `repair` 的 1.1–1.7×（约 116–170 µs/4.9 KiB）：时间轴取
  `Delta.at`，不再重放采样；放进每次 `feed` 的循环仍应用增量观察器（`SemanticWatcher`）；
- 覆盖率最低项是 `llm/text.mbt` 66/91 = 72.5%；根包最低为 `api.mbt` 86/95 = 90.5%，
  `plan.mbt` 489/526 = 93.0%、`delta.mbt` 本轮补到 93/101 = 92.1%；
- live 演示页的浏览器验证在本机做过（Playwright 无头），CI 只跑帧级断言；
- FR-37 的 live 帧只重放四个固定场景，不是任意流的通用可视化；
- FR-16 事件/回调接口已实现为 `feed_with` / `feed_bytes_with`（`drain_deltas` 的薄封装，0.4.0）；
- 快照的 `incomplete_number` / `pending_key` 策略只影响快照，最终结果仍补全；
- 峰值内存约为输入的 18 倍（12.95 MB 对象数组 → 230.6 MB；单个 10 MB 字符串 38 倍），未达到「≤ 4 倍输入」的预算：保留完整 `Json` 树就无法达标，见基准报告；
- 增量流的吞吐是基线耗时的 1.42–1.51 倍，未达到登记的「不低于基线 90%」；
- 前言重放**只在「干净」时被接受**：在取到值之前需要任何修复的文档仍被拒绝 —— 标量根前言（`说明\n42`）
  **有意拒绝**（前言在哪里结束不可判定），围栏**标量**根在 `skip_prose` 打开时（`explain` 的默认）被拒，
  而 `repair` 默认关闭它、接受并输出 `true`；围栏对象/数组两种模式都通过（见 `产品文档-精简版.md` §11）；
- 前言超过 `max_prose_buffer`（64 KiB）时引擎放弃重放并回退 `E002`（`prose_overflow`），CLI 的全文回退仍能救回；
- 骨架约束只覆盖 `minimum`/`maximum`/`enum`/`minLength`/`maxLength`/`pattern`（字符类子集），没有正则；
- 恢复策略是启发式的，不是某个标准的合规实现。

规范契约（逐条可引用的 `SR-n`）见 [`SPEC.md`](./SPEC.md)。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| `README.md` / `README.zh.md` | 安装、API、选项、CLI |
| [`SPEC.md`](./SPEC.md) | **规范契约**：三档就绪、delta 契约、精确度格、四个执行字段、骨架文法（`SR-1`…`SR-33`） |
| `docs/RULES.md` | 22 条修复规则的触发条件、级别、消息与示例 |
| `docs/ERRORS.md` | 12 个致命错误码、严格模式升级、退出码、失效模式 |
| `docs/DIVERGENCES.md` | 与两个参照实现的逐类差异与原因 |
| `docs/BENCHMARK.md` | 吞吐、线性、流式、内存、体积 |
| `docs/REPRODUCE.md` | 从零复现全部结论 |
| `docs/TRACEABILITY.md` | 需求 → 用例 → 证据 的追踪矩阵 |
| `CHANGELOG.md` | 版本变更与限制 |

CI 与本地执行同一组命令：`.github/workflows/ci.yml`（`moon check --deny-warn`、三后端
`moon test`、CLI/示例/演示冒烟、差分报告、覆盖率、产物体积）。
