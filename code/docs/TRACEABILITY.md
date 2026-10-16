# 追踪矩阵（D06 6.2 / 6.3）

状态取值：**通过**（有可复现证据）、**削减**（有意未实现或有已知未达标项，原因见备注）。
所有证据都在本仓库内可复现，命令见 `docs/REPRODUCE.md`。

`FR-21` … `FR-26` 是 0.3.0 新增的需求，来自第四轮建议（`I-1` … `I-5`）。
`FR-27` … `FR-31` 是 0.4.0 新增的需求，来自第五轮评审（`JSONMend 第五轮：优化、完善与扩展方向.md`），
编号沿用在 `FR-26` 之后，**不与 `FR-21`…`FR-26` 重号**；`FR-16` 由「未实现」转为「通过」。
`FR-32` … `FR-38` 是 0.5.0 新增的需求，来自第六轮优化文档（`优化.md`），
主题从「修得更准」转为「修出来的值能不能执行、什么时候可以执行、不能执行时怎么回灌模型」。
`FR-39`（与它的非功能侧 `NFR-PERF-09`）是 0.6.0「Streaming Semantic Safety」新增的：
把就绪从「离线重放测量」改成「增量事件流」，使 `semantic_readiness` / `field_readiness`
进入热路径，并让「可判定但无效」与「还没定」在数字上可区分。

## 功能需求

| 需求 | 名称 | 优先级 | 业务规则 | 测试用例 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| FR-01 | 一次性修复 | P0 | BR-01 BR-04 | TC-G 全部、TC-P-01 | `golden_wbtest.mbt` 126 条（附录 A 77 + 附录 B 49）；`prop_wbtest.mbt` TC-P-01 400 例 × 4 组选项 | 通过 |
| FR-02 | 修复报告 | P0 | BR-19 BR-20 | TC-G（记录字段）、TC-E-API | 记录含 code/position/severity/message；`error_api_wbtest.mbt` 校验 22 条规则的表完整性；CLI `--report` | 通过 |
| FR-03 | 值输出 | P0 | BR-01 | TC-G-VAL、TC-P-01 | `parse` 返回 `Json`；TC-P-02b 校验 `parse` 与文本一致 | 通过 |
| FR-04 | 合法输入恒等 | P0 | BR-02 BR-03 | TC-P-02b | 合法文档零记录、文本逐字不变 | 通过 |
| FR-05 | 截断补全 | P0 | BR-13 | TC-G-BR13、TC-P-04 | `{"a":{"b":[1,2` → `{"a":{"b":[1,2]}}`；400 例随机截断后 `finish` 全部合法 | 通过 |
| FR-06 | 词法宽容 | P0 | BR-06…BR-12 | TC-G-BR06…BR12、TC-D | 黄金用例 + 402 条差分用例 | 通过 |
| FR-07 | 结构修复 | P0 | BR-09 BR-13 BR-14 | TC-G-BR09/13/14 | 黄金用例 G-060…G-100 段 | 通过 |
| FR-08 | 围栏与前后缀 | P0 P1 | BR-05 | TC-G-BR05、TC-O-06 | `strip_fence` 开关双向覆盖；`skip_prose` 见 R021 | 通过 |
| FR-09 | 流式解析器 | P0 | BR-16 | TC-S-01、TC-P-03 | `stream_wbtest.mbt` S-001…S-020；逐码元/二分/1 KB 分块不变 | 通过 |
| FR-10 | 快照语义 | P0 | BR-16 | TC-S 全部、TC-P-05 | 稳定前缀、`open_path` 可遍历性、`Completeness` 三态 | 通过 |
| FR-11 | 分块鲁棒 | P0 | BR-12 BR-16 | TC-P-03 | 任意切分下文本、记录、错误三者一致 | 通过 |
| FR-12 | 字节输入 | P1 | BR-20 | TC-S-UTF8 | `feed_bytes` 在 UTF-8 序列中间切分仍与 `feed` 一致；非法字节抛 E040 | 通过 |
| FR-13 | 选项与模式 | P0 P1 | BR-17 BR-18 | TC-O-01…TC-O-07 | `options_wbtest.mbt` 覆盖全部策略枚举与规则开关 | 通过 |
| FR-14 | 引号歧义前瞻 | P1 | BR-06 | TC-G-BR06L | `quote_lookahead` 黄金用例 + 属性测试选项组 | 通过 |
| FR-15 | 多根值 | P1 | BR-15 | TC-O-03、TC-D | 三种策略（KeepFirst/AsArray/AsError）行为固定；差分探针证明与参照一致 | 通过 |
| FR-16 | 事件接口 | P2 | BR-16 | TC-DELTA | `PartialParser::feed_with` / `feed_bytes_with`：`drain_deltas` 的薄封装，回调顺序与 drain 逐条一致（`delta_wbtest.mbt` 两条，含字节路径、在 UTF-8 序列中间切分） | 通过（薄封装，非独立推送接口，理由见 `docs/ONEPAGE.md`） |
| FR-17 | 命令行 | P1 | BR-17 | TC-C-01 | `tests/cli_smoke.sh` **62** 项断言全绿；退出码 0/1/2/3/4/5/70 全覆盖；0.4.0 新增 `--for-execution`、`--reject-ambiguous`、`--retry-hint`、`readiness`、`--chunk N`、`llm --text`、`llm --batch`；0.5.0 新增 `explain`、`--policy`、`--schema`、`--json`、`E070` 的断言 | 通过 |
| FR-18 | 浏览器演示 | P1 | — | TC-W-01 | `static/demo/index.html` 由 MoonBit JS 产物驱动，Playwright 无头验证通过（无 console 错误） | 通过 |
| （FR-37 备注） | live 页的浏览器验证 | — | — | TC-W-02 | 本机用 Playwright 跑过两个场景（无 console 错误，截断场景重试后 `EXECUTION: READY`），CI 只跑 `demo_smoke.mjs` 的帧级断言：GitHub runner 上不安装 Playwright | 已记录 |
| FR-19 | 拼接与省略号 | P2 | BR-21 | TC-G-BR21 | `...` 删除（R020，G-301…G-303）；`"a" + "b"` 合并（R019，G-300、G-300b…G-300e，覆盖根值/数组/对象与流式 S-021） | 通过 |
| FR-20 | 缩进输出 | P2 | — | TC-G-INDENT | CLI `--indent 2` 与 `Options.indent` | 通过 |
| FR-21 | 精确度标签与执行安全闸 | P0 | BR-13 BR-19 | TC-EVAL、TC-X-01 | `Exactness` 进入四个结果类型；`max_loss` 在超限的第一条记录处抛 `E010`；`exactness_wbtest.mbt` 的 240 例属性 + 18 行手写表；真值评测漏标率 0（`docs/EVAL.md`） | 通过 |
| FR-22 | 增量补丁流 | P1 | BR-16 | TC-DELTA | `delta_wbtest.mbt`：400 份生成文档 + 400 份变异输入上「增量重放 == 快照」，另有 7 组选项剖面、RFC 6901 指针、空 drain、选项冲突、Close 之后可再 Set、FR-16 回调等价 | 通过（吞吐未达标，见 NFR） |
| FR-23 | 大模型工具流适配器 | P1 | BR-16 | TC-LLM | `code/llm/`：9 个夹具 × 双 provider；CLI `jsonmend llm`（`--provider`、`--sse`、`--follow`、`--text`、`--batch`）；真值语料 1200 条经双 provider 工具流与文本流全部 100%（`docs/EVAL_PATHS.md`） | 通过 |
| FR-24 | 真值评测 | P1 | — | TC-EVAL | `tests/eval/corpus.py` 1200 条（协议先冻结于 `docs/EVAL_REGISTRATION.md`）；`run_eval.py` 四条预登记判据全 PASS | 通过 |
| FR-25 | 长跑属性测试 | P1 | — | TC-P-LONG | `JSONMEND_LONGRUN=N` 提高每个属性的用例数；本机按 nightly 参数跑过 1 000 000 例（41.2 s，69/69 通过），`.github/workflows/nightly.yml` 以同一参数夜间运行 | 通过 |
| FR-26 | 修复解释输出 | P2 | BR-20 | TC-C-01 | CLI `--explain`：级别 + 位置 + 插入符片段 + 精确度小结；有歧义时追加 `[ambiguous: <类名>]` | 通过 |
| FR-27 | 歧义标记与执行闸 | P0 | BR-13 BR-19 | TC-EVAL、TC-X-01、TC-AMB | `Ambiguity` 五态进入每条记录；`Options::reject_ambiguous` 在 `max_loss` 判定**之前**抛 `E011`（退出码 5）；`--for-execution` 同时打开两道闸。对抗语料 `amb-1` 24 例：10 例歧义全部标记且全部拒绝，14 例对照全部放行，0 失败（`docs/EVAL_AMBIGUITY.md`，指纹 `c75989b1…`） | 通过 |
| FR-28 | 拒绝即反馈 | P1 | BR-19 | TC-HINT | `RetryHint`：错误码、修复码、位置、歧义类、原因、上下文窗口与插入符；`to_prompt()` 可直接回灌模型；非修复类错误返回 `None`；CLI `--retry-hint` 写标准错误且不改退出码 | 通过 |
| FR-29 | 字段就绪曲线与早停 | P1 | BR-16 | TC-READY | `field_readiness`/`readiness_median`/`readiness_deciles`/`early_stop_saving`；0.6.0 起由增量流驱动，热路径 API 是 `SemanticWatcher` / `FieldTracker`；CLI `readiness` 子命令；20 份扁平记录十分位 `0 10 21 30 41 51 61 71 80 90 100`；成本 **155 – 191 µs/KiB**（0.6.0 实测，0.5.0 基线 1 794 µs/KiB，`docs/BENCHMARK.md`）。**只覆盖顶层成员**，嵌套成员与「全字段早停≈0」的构造性结果已如实记录 | 通过（指标已量化，边界已记录） |
| FR-30 | 适配器事件完备性与结束原因 | P1 | BR-16 | TC-LLM | `ping` 与未知事件类型计数后忽略（文档要求）；`error` 事件置 `ProviderError` 并暴露消息；`message_delta.stop_reason` 与 `finish_reason` 映射到 `CallEnd`；三种结束（正常 / `max_tokens` / 连接中断）暴露在 `ToolCallView`；`TextStream` 读取 `delta.text` / `delta.content`。事件形状来源与「文档转录 ≠ 实况录制」的差别见 `docs/LLM_EVENTS.md` | 通过（形状为文档转录，未录制真实流，已披露） |
| FR-31 | 参照库对照与多路径真值 | P1 | — | TC-EVAL | 同一 1200 条语料上跑 `jsonrepair` 3.15.0 与 `json_repair` 0.64.0：静默错值 122 / 189 例，JSONMend 0 例（`docs/EVAL_REFERENCE.md`）；8 条路径（1/3/7/随机分块、双 provider 工具流、双 provider 文本流）全部 1200/1200（`docs/EVAL_PATHS.md`） | 通过 |
| FR-32 | 安全档位 | P0 | BR-13 BR-19 | TC-POLICY | `SafetyPolicy` 五档（permissive / interactive / execution / agent / strict）；`with_policy` 只换安全字段、保留协议字段；`of_options` 可反查档位名，未知组合返回 `None`（`policy_wbtest.mbt` 7 例） | 通过 |
| FR-33 | 修复计划与单次调用 | P0 | BR-19 BR-20 | TC-PLAN | `RepairPlan` + `PlanOp`（动作、位置、严重度、歧义类、置信类别、是否丢信息）；`analyze` 永不抛错，拒绝放在返回值里；`prompt()` / `suggestions()` / `summary()` / `explain_text()` / `to_json()`（`plan_wbtest.mbt` 22 例） | 通过 |
| FR-34 | 执行决策 | P0 | BR-13 BR-19 | TC-DECISION | `ExecutionDecision` 五态与 `rank` / `worse_of`；`decide` 与 `decide_error` 的映射由测试固定（`plan_wbtest.mbt`） | 通过 |
| FR-35 | 自愈闭环 | P1 | BR-19 | TC-X-02 | `examples/agent_loop`：4 个 episode（相邻字符串 E011、截断 E010、骨架不符 E070、无改进则放弃）；`moon run examples/agent_loop --target native --release` 在 CI 中执行 | 通过 |
| FR-36 | 骨架感知就绪 | P1 | BR-16 | TC-READY2 | `Schema` 文本 DSL + `semantic_readiness`（语法/`settled`/骨架三层分数、缺失与类型不符清单）；`schema_wbtest.mbt` 5 例；`tests/eval/run_readiness.py` **10 场景（4 落差 + 3 并列 + 3 可判定但无效）**，`docs/READINESS.md`；CLI `explain --schema`、`readiness --schema`；新错误码 `E070` | 通过 |
| FR-37 | 流式 live 演示 | P1 | BR-16 | TC-W-02 | `static/demo/live.html` 四场景逐帧重放；bundle 入口 `live`；`code/tests/demo_smoke.mjs` 的 live 断言（帧形状、成员就绪、执行判定、重试提示） | 通过（无头浏览器验证在本机做过，CI 里只跑帧级断言，见备注） |
| FR-38 | 独立第三方语料 | P1 | — | TC-EVAL | `nst/JSONTestSuite`（318 文件，MIT，commit `1ef36fa0`）逐字节 vendor + `tests/eval/run_independent.py`：`y_` 误修 2/95（均为重复键）、`n_` 有效值 165/188（`json_repair` 166/188、`jsonrepair` 144/188），`docs/EVAL_INDEPENDENT.md` | 通过（2 条误修与 8 条 UTF-8 拒绝已如实记录） |
| FR-39 | 增量流式就绪 | P0 | BR-16 BR-19 | TC-READY3 | `ReadinessEvent`（`FieldReady`/`FieldInvalid`/`FieldRejected`/`FieldIncomplete`/`RootReady`/`RootInvalid(offset)`，含 `kind()`/`path()`/`is_verdict()`/`to_json()`；`FieldRejected` 是 0.7.0 的值级拒绝，`FieldInvalid` 携带整条声明）+ `SemanticWatcher`（`new`/`feed`/`drain_events`/`bytes`/`settled_at`/`syntax_at`/`all_settled`/`ready_count`/`total_required`/`watched_paths`/`verdict`/`finish`/`concluded`/`conflict`）+ `watch_readiness`/`decided_at_permille`；`semantic_readiness` 与 `field_readiness` 重接到这条流上，`SemanticReadiness` 新增 `settled_permille`（`schema_permille` 对「可判定但无效」的文档报 `1000`，`settled_permille` 给出真正的判定时刻），`Schema::at_path` 新增；closer 通过 `is_prefix()` 决定容器内部缺失的成员；Q-35 起 `syntax_at`/`settled_at`/`decided_at_permille`/每个事件的 permille 都取自 `Delta.at`（与分块无关），`semantic_readiness` 因此整篇喂一次而不是按 `step` 采样。证据：`stream_readiness_wbtest.mbt`（事件、偏移与重复键冲突语义）；`code/bench/main.mbt` 的 `semantic_readiness` / `watcher chunk 64` / `decided` 行（0.6.0 的 `semantic_readiness sampled (0.5.0)` 对照行已在 0.7.0 随采样实现一起删除，Q-36；0.5.0 数字见 `docs/BENCHMARK.md` 的 git 历史指针）；`docs/READINESS.md` 的三行三方契约 —— `declared member, wrong kind`（`schema ready = 1000‰` 而 `settled = 128‰`，由成员自己的值决定）、`declared member, absent in a container`（`schema ready = 1000‰` 而 `settled = 84‰`，由容器的 closer 决定，`is_prefix()`）与 `declared member, absent at the root`（`settled = 1000‰`，只有输入结束才决定）。`--check` 同时断言前两行 `schema ready = 1000` 且 `settled < 500`、第三行 `settled = 1000`。0.5.0 报告值是 30.82 – 44.10× `repair`，0.7.0 的实现是 1.52 – 1.74×（0.6.0 的实现为 2.42 – 3.47×；`docs/BENCHMARK.md`、`NFR-PERF-09`；0.7.0 起不再同轮对照） | 通过 |

## 非功能需求

| 需求 | 名称 | 测试用例 | 证据 | 状态 |
| --- | --- | --- | --- | --- |
| NFR-COR-01 | 输出合法 | TC-P-01 | 400 例模糊输入 × 4 组选项，输出全部通过 `is_valid_json` | 通过 |
| NFR-COR-02 | 幂等 | TC-P-02a | 二次修复文本不变且零记录（400 例） | 通过 |
| NFR-COR-03 | 分块不变 | TC-P-03 | 文本、记录、错误三者一致（400 例，逐码元或 1/7/13 随机切分） | 通过 |
| NFR-COR-04 | 快照单调 | TC-P-05 | `Complete` 之后所有快照逐字相同；`open_path` 始终可遍历 | 通过 |
| NFR-COR-05 | 参照一致 | TC-D | 402 条用例、202 处差异全部有文档解释、未解释 0（`docs/DIVERGENCES.md`，`--no-stamp` 下逐字节可复现） | 通过 |
| NFR-ROB-01 | 不崩溃 | TC-P-06 | 10 万条 token soup 无 panic、无 E030 | 通过 |
| NFR-ROB-02 | 资源限制 | TC-E-API-03、黄金 E020/E021/E022 | 深度/长度/token 上限抛 E020/E021/E022；`Options::validate` 拒绝非法上限 | 通过 |
| NFR-PERF-01 | 线性时间 | TC-B-01 | 翻倍比值 native 2.0/2.0（4 次观测 2.0–2.3）；JS 4n 档 2.3–2.8（8 次观测，中位数 2.5），**超过 2.3 阈值** | native 通过；**JS 未稳定达标**（根因与改法见 `docs/BENCHMARK.md`「JS 后端的线性度问题」） |
| NFR-PERF-02 | 吞吐 | TC-B-02 | native 41–43 MB/s、JS 19–37 MB/s（阈值 20 / 5） | 通过 |
| NFR-PERF-03 | 流式开销 | TC-B-03 | 1 码元分块 21.8 MB/s（64 KB 分块的 56%）；`snapshot` 状态未变时命中记忆化（1000 次重复 11.8 ms）；agent 场景 4 KB/3 码元 0.08 µs/feed | 通过 |
| NFR-PERF-05 | 增量流开销 | TC-B-07 | `collect_deltas` 打开后耗时是基线的 1.39–1.44 倍（native）、1.14–1.36 倍（JS），**未达到「不低于基线 90%」** | 削减（每条变更分配一个 `Delta` 与路径数组；见 `docs/BENCHMARK.md`） |
| NFR-PERF-06 | 首个可见值 | TC-B-08 | 工具调用文档中位数：首个值出现在文档长度 0.7% 处；「95% 覆盖」判据为 95.3%（对象结构决定，几乎无收益）。0.4.0 以 **FR-29 字段就绪曲线**为主指标（十分位 `0 10 21 30 41 51 61 71 80 90 100`），95% 覆盖仅作历史对照 | 通过（指标已替换，原因见 `docs/BENCHMARK.md`） |
| NFR-PERF-07 场景延迟（0.4.0 新增） | TC-B-09 | 4 KB 工具调用文档按 3 码元分块：0.08 µs/feed（摊还），290 000 次 feed 中 0 次达到毫秒时钟分辨率；p99 ≤ 1 ms（只能给上界，`@env.now()` 为毫秒分辨率，运行时无分配计数） | 已实测 |
| NFR-PERF-09 增量就绪（0.6.0 新增，无阈值） | TC-B-10 | 20 份 4.9 KiB 工具调用文档、20 次调用、`median5`，同一 `repair` 基准：`semantic_readiness`（0.7.0：整篇喂一次，时间轴取 `Delta.at`）**116.28 – 170.00 µs = 1.52 – 1.74×**（0.6.0 的实现是 191 – 248 µs = 2.42 – 3.47×，三次运行同轮 `repair` 76.52 – 101.00 µs）；0.5.0 报告值 2 150 – 3 150 µs = 30.82 – 44.10×（0.7.0 删除了同轮对照行，见 `docs/BENCHMARK.md`）；`field_readiness` 266 – 333 µs = 3.67 – 4.67×（54.7 – 68.6 µs/KiB）；`watcher chunk 64` 114 – 143 µs = **1.64 – 2.00×**；`decided` 179 – 243 µs = 2.54 – 3.40×。命令：`moon run bench --target native --release`（`docs/BENCHMARK.md` 有原始输出与六次运行的区间） | 已实测（比例抖动 ±15%，故报区间；`watcher` 是流式路径的真实单价） |
| NFR-PERF-04 | 内存 | TC-B-04 | **统一的「≤ 4 × 输入」阈值已撤销**，改为按模式报告（`docs/BENCHMARK.md`「内存指标的重新定义」）：`repair()` / `analyze()` 报峰值 RSS（建树，无阈值）、streaming 报峰值工作集、`text-only ≤ 4 ×` 与 `no-tree ≤ 2 ×` 声明给 0.7。横向证据：12.95 MB 对象数组 JSONMend 177.9 MB（13.7 × 输入）、Node `JSON.parse` 137.5 MB（10.6 ×）、Python `json.loads` 185.5 MB（14.3 ×，其中 tracemalloc 峰值 66.7 MB） | 削减（统一阈值撤销，因为建树实现与流式设想不可比；0.6.0 无 `text-only`/`no-tree` 模式，两条目标不声称达标；数值证据见 `docs/MEMORY.md`） |
| NFR-SIZE-01 | 产物体积 | TC-B-05 | wasm-gc release 103 784 B（101.4 KiB），上限 150 KB | 通过 |
| NFR-PORT-01 | 跨后端一致 | TC-X-01 | `moon test`（wasm-gc）、`--target native`、`--target js` 均 95/95 通过 | 通过 |
| NFR-DET-01 | 确定性 | TC-X-02 | 固定种子的 LCG；同一输入重复运行输出逐字节相同 | 通过 |
| NFR-API-01 | 接口稳定 | TC-R-02 | 公共面：`repair`/`parse`/`is_valid_json`、`PartialParser` 6 个方法、`Exactness`/`Delta` 等 8 个结果类型、6 个策略枚举、`RuleSet` 4 个方法、`RepairCode`/`MendError` 查询函数；`jsonmend/llm` 子包 6 个入口 | 通过 |
| NFR-API-02 | 易用 | TC-DOC-01 | `README.md` / `README.zh.md`：安装、三行快速开始、流式示例、选项表、CLI 帮助 | 通过 |
| NFR-DOC-01 | 文档完整 | TC-DOC-02 | `docs/` 十份文档（含评测协议与结果、AI 使用说明）+ `CHANGELOG.md` + `LICENSE` + `NOTICE` | 通过 |
| NFR-TEST-01 | 覆盖率 | TC-COV-01 | `moon test --enable-coverage` + `moon coverage report -f summary -p zhanshishan/jsonmend`：根包 **1378/1487 = 92.7%**，`-p zhanshishan/jsonmend/llm` 为 223/243 = 91.8%（不加 `-p` 时 `bench/main.mbt` 也计入，得 1601/2002 = 80.0%）；`cmd/jsonmend` 因 `quit()` 无法出报告 | 通过 |
| NFR-SEC-01 | 安全 | TC-P-06、TC-P-07 | 错误消息模板固定、不回显输入；资源上限防止病态输入耗尽内存；无外部依赖 | 通过 |
| NFR-COMP-01 | 合规 | TC-L-01 | `LICENSE`（Apache-2.0 全文）、`NOTICE`（依赖与参照实现许可证：`jsonrepair` ISC、`json-repair` MIT） | 通过 |
| NFR-MNT-01 | 可维护 | TC-R-03 | `moon check --deny-warn` 零警告、`moon fmt --check` 干净、`docs/REPRODUCE.md` 一键复现；`.github/workflows/ci.yml` 在两个 job 中执行同一组命令，并已在 GitHub Actions 上跑通（run #1 `eff1ad2`、#2 `169353e`、#5 `9bf0a08`、#6 `231af5b`、**#7 `8b721db` 均 success**，run #7 覆盖 0.3.0 全部代码与真值评测）；`release.yml` 在 `v0.3.0` 上 run #1 success 并产出 4 个资产 | 通过 |
| NFR-REL-01 | 可发布 | TC-R-01 | `moon.mod` v0.3.0 + Apache-2.0 + repository；`moon package` 通过；未发布到 mooncakes.io | 削减（未发布到注册表） |

## 反向覆盖

| 业务规则 | 覆盖它的需求 | 证据 |
| --- | --- | --- |
| BR-01 至 BR-04 | FR-01 FR-03 FR-04、NFR-COR-01 02 | 黄金用例 + TC-P-01/02 |
| BR-05 | FR-08 | R001/R021 用例，TC-O-06 |
| BR-06 至 BR-08、BR-10 至 BR-12 | FR-06（BR-06 前瞻见 FR-14） | 黄金用例 + TC-D |
| BR-09 BR-13 BR-14 | FR-05 FR-07 | 黄金用例 G-060…G-100 段 |
| BR-15 | FR-15 | TC-O-03 |
| BR-16 | FR-09 FR-10 FR-11、NFR-COR-03 04 | TC-S、TC-P-03/05 |
| BR-17 BR-18 | FR-13、NFR-ROB-02 | TC-O-01…07、TC-E-API-03 |
| BR-19 BR-20 | FR-02 | 记录字段测试、TC-E-API-01 |
| BR-21 | FR-19 | R019 与 R020 的黄金用例（G-300…G-303） |
| BR-02 幂等 | NFR-COR-02 | TC-P-02a |

每个 R 码（R001–R021）在 `error_api_wbtest.mbt` 的 TC-E-API-01 中被逐一检查，
每个 E 码（E001–E050）在 TC-E-API-02 中被逐一检查，因此「每个 R/E 码至少对应一个
用例」由代码强制保证，而不是靠人工核对。

## 削减项汇总

| 项 | 原因 | 影响 |
| --- | --- | --- |
| FR-16 事件接口 | P2，0.2.0 未实现 | 需要回调式接口的调用方只能用 `snapshot()` 轮询 |
| NFR-PERF-01（JS） | JS 产物每码元构造一个 `Position` 对象 | 4n/2n 达 2.3–2.8，超出 2.3；需把当前位置与历史位置分离 |
| NFR-PERF-04 内存预算 | 统一阈值不可比：完整解析树常驻内存，而阈值是按「流式文本修复」写的 | 自比 12.95 MB 输入峰值 230.6 MB（单个 10 MB 字符串为 38 倍）；横向 Node 自身即 10.6 ×。统一阈值撤销，改为按模式报告；`text-only ≤ 4 ×` / `no-tree ≤ 2 ×` 属 0.7，需要「只产出文本、不建树」的模式（`Options.want_value = false`）才能达标 |
| NFR-REL-01 发布 | 未发布到 mooncakes.io（`moon whoami` 未登录） | 只能通过仓库源码使用 |
| NFR-PERF-05 增量流开销 | 每条变更分配一个 `Delta` 记录与一份路径数组 | 1 MB 口径 1.40–1.46 × 基线耗时；agent 场景（4 KB/3 码元）整条流 0.115 ms，不在关键路径；紧凑增量缓冲优先级下调 |
| NFR-PERF-06「95% 覆盖」判据 | JSON 对象只有接近闭合才「几乎完整」 | 该判据结构性不敏感（95.3%）；「首个可见值」0.7% 才是有效指标 |
