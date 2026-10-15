# JSONMend 一页说明

**流式 JSON 修复与部分解析库，纯 MoonBit 实现。**

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
| 规则与错误 | `code/error.mbt` | 22 条修复规则（R001–R022）、11 个致命错误码（E001–E060，含 `E011` 歧义拒绝）、三级精确度标签 `Exactness` 与五态 `Ambiguity` |
| 歧义与反馈 | `code/hint.mbt` | `RetryHint`：拒绝原因、位置、第二种读法、上下文窗口与插入符，可直接回灌模型（FR-28） |
| 就绪曲线 | `code/readiness.mbt` | 顶层成员的就绪比例、十分位曲线与增量驱动的 `FieldTracker`（FR-29） |
| 增量流 | `code/delta.mbt` | `Options::collect_deltas` 打开后记录 `Delta`（Set/AppendText/Close），路径为 RFC 6901 JSON Pointer |
| 大模型适配 | `code/llm/` | Anthropic 与 OpenAI 兼容工具流、SSE 行解析、文本流（`delta.text` / `delta.content`）、结束原因（`Complete`/`MaxTokens`/`Interrupted`/`ProviderError`）、9 个生成夹具 + 文档转录事件形状 |
| 选项 | `code/options.mbt` | 严格模式、重复键、未完成数字、非有限值、多根值、规则开关、资源上限 |
| CLI | `code/cmd/jsonmend/` | stdin/文件（64 KB 分块流式读入）、`--report`、`--check`、`--strict`、`--indent`、`--multi-root`、`--max-repairs`、`--max-loss`、`--for-execution`、`--reject-ambiguous`、`--retry-hint`、`--explain`、`--batch`、`--chunk`、`readiness` 与 `llm` 子命令 |
| 基准 | `code/bench/` | 吞吐、线性、流式、产物体积 |

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
| 覆盖率 | 根包 1378/1487 = 92.7%，`llm` 包 223/243 = 91.8% |
| 差分测试 | 402 条用例对照 `json-repair` 与 `jsonrepair`；202 处差异全部由修复记录解释，未解释 0 |
| 命令行 | 48 项断言全部通过（退出码 0/1/2/3/4/5/70 覆盖） |
| 演示页 | `static/demo/index.html`，MoonBit JS 产物驱动，无头浏览器验证无报错 |
| 跨后端 | wasm-gc / native / JS 三个后端 95 个测试全部通过 |
| 吞吐 | native 35–39 MB/s（合法 JSON，1 KB–10 MB）；首个可见值出现在文档长度的 0.7%（中位数）；agent 场景（4 KB / 3 码元）0.08 µs/feed |
| 内存 | 12.95 MB 输入 177.9 MB（13.7 ×）；同机 Node 10.6 ×、Python 14.3 ×，4 × 目标对建树实现不现实 |
| 体积 | wasm-gc release 101.4 KiB（上限 150 KB）；native CLI 623.8 KiB；浏览器包 284.1 KiB |

## 与参照实现的关系

差分测试中约一半的用例结论不同，差异**全部**落在四类可解释的行为上：
截断处的补全策略（补 `null` 并闭合容器，而不是猜一个空串）、多根值策略
（默认只保留第一个，可用 `--multi-root array` 切换）、字面量与非有限值处理、
以及明确划到范围外的输入（无 JSON 值、`#` 注释、孤立代理码元）。
逐条说明见 `docs/DIVERGENCES.md`。

## 已知限制

- FR-16 事件/回调接口未实现（需要回调的调用方只能用 `snapshot()` 轮询）；
- 快照的 `incomplete_number` / `pending_key` 策略只影响快照，最终结果仍补全；
- 峰值内存约为输入的 18 倍（12.95 MB 对象数组 → 230.6 MB；单个 10 MB 字符串 38 倍），未达到「≤ 4 倍输入」的预算：保留完整 `Json` 树就无法达标，见基准报告；
- 增量流的吞吐是基线耗时的 1.42–1.51 倍，未达到登记的「不低于基线 90%」；
- `--skip-prose` 只能跳过容器根之前的说明文字，标量根（`说明\n42`）无法定位，抛 `E002`；
- 恢复策略是启发式的，不是某个标准的合规实现。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| `README.md` / `README.zh.md` | 安装、API、选项、CLI |
| `docs/RULES.md` | 21 条修复规则的触发条件、级别、消息与示例 |
| `docs/ERRORS.md` | 9 个致命错误码、严格模式升级、退出码、失效模式 |
| `docs/DIVERGENCES.md` | 与两个参照实现的逐类差异与原因 |
| `docs/BENCHMARK.md` | 吞吐、线性、流式、内存、体积 |
| `docs/REPRODUCE.md` | 从零复现全部结论 |
| `docs/TRACEABILITY.md` | 需求 → 用例 → 证据 的追踪矩阵 |
| `CHANGELOG.md` | 版本变更与限制 |

CI 与本地执行同一组命令：`.github/workflows/ci.yml`（`moon check --deny-warn`、三后端
`moon test`、CLI/示例/演示冒烟、差分报告、覆盖率、产物体积）。
