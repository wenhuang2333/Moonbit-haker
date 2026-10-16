# Changelog

本文件记录 JSONMend 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-10-16

**公开面稳定。此后遵守语义化版本：破坏性变更必须升 major。标签一旦推送不再移动。**

1.0.0 不是新特性版本，而是对 0.7.0 的**承诺**。冻结这句话的可检查证据是
`pkg.generated.mbti`：编译器眼中的公开 API 已经进版本库，并由 CI 断言与源码一致，
所以「API 变了」会出现在评审 diff 里，而不是藏在某个特性提交里。

### 承诺稳定

| 面 | 承诺 |
| --- | --- |
| `pub` API 的签名与语义 | 新增是 minor；删除或改签名是 major |
| `explain --json` 的四个字段 | `valid_json` / `normalized` / `ambiguity` / `execution` 的名字与取值域 |
| delta 契约 | `Set` / `Close` / `AppendText` 的顺序与 `pointer()` 的输出格式 |
| 骨架语法 | 0.7.0 的语法全集；新增约束是 minor，**改变已有声明的含义是 major** |
| CLI 退出码 | 0/1/2/3/4/5/70 的含义 |
| 就绪口径的定义 | `settled` / `syntax_at` / `schema_permille` 的含义；`Delta.at` 的单位是 UTF-16 码元 |

### 明确不承诺

- **性能与内存数字**——它们随机器与版本浮动，`BENCHMARK.md` 是记录不是契约；
- `AppendText` 的**粒度**与它的 `at`（drain 时刻的属性，天然依赖分块）；
- 内部文件布局、`code/` 之外的路径、CI 工作流细节。

### 为什么现在发

0.7.0 的稳定性证据：四个后端各 192/192；冻结语料（`eval-2`，种子 20261015，
1200 条，sha256 `c528375a0d996a78`）恢复率 **100.00%**；同一套门禁连跑两次，
报告逐字节一致（除时间戳）；CI 在 0.7.0 之后的每个提交上通过。
计划要求「0.7.0 落完 Q-32/Q-35 后发 1.0.0」，两项均已落地。

### 1.0.0 不改变的已知边界

它们是契约的一部分，不是待修缺陷：前言 + 标量根**有意拒绝**（散文边界不可判定）；
前言缓冲超过 64 KiB 回退 `E002`；`valid_json` 的含义是「除重复键归一化外没有任何修复」，
**不是**「严格解析器接受这份输入」（`R014` 的非配对代理项分支是具名反例）。
完整清单见 `SPEC.md` SR-0 与 0.7.0 一节。

## [0.7.0] - 2026-10-16

主题：**前言重放、可定位的增量与声明式约束**。第七轮遗留的半修正确性问题在本轮收尾，
`Delta` 补上位置字段（1.0.0 之前必须做的契约变更），骨架声明开始表达**值**而不只是形状。

### 修复

- **Q-32 引擎层前言重放**：`skip_prose` 只认 `{` 和 `[`，所以根为标量的合法文档
  （`true` / `null` / `42` / `"a"`）在读的过程中与「散文」无法区分，直到 `finish`
  都没有解析出值，被报 `E002`。0.6.0 只在 `repair` / `analyze` / CLI 三个能拿到全文的
  入口上打补丁，**流式调用方仍然拿不到值**。现在引擎自己保留被跳过的前言
  （`max_prose_buffer`，默认 64 KiB，属资源限制家族），在 `finish` 时以 `skip_prose`
  关闭的模式重放；`finish` 本身是分块不变的，因此该修复天然保持 TC-P-03，
  且失败时回抛**原来的** `NoJsonFound` 偏移，不硬编码 0。
  重放只在「干净」时被接受——没有任何修复记录、没有任何歧义——因此
  `hello world`、`The answer is 42`、`前缀 🎯 null` 仍然被拒绝，与一次性 `repair`
  路径的历史行为逐字一致；纯散文不会被「修」成一个值。
  重放是第二个引擎实例，其 delta 流会被并入调用方看到的流，否则「重放 delta 得到
  最终值」这条契约恰好在本修复要救回的文档上不成立。
- 新增属性测试 **TC-P-09**：15 份合法标量根文档 × `skip_prose` × 逐码元与
  1/2/3/5/8 码元分块 ⇒ 取到值且与一次性结果逐字节一致；另一组 9 份「包含 JSON
  但不是一份 JSON 文档」的输入 ⇒ 在任何分块下都以相同偏移被拒绝。

### 新增

- **Q-35 `Delta.at`**：每条 delta 记录自己被产生时**已消费的输入码元数**
  （UTF-16 码元，与 `Position.offset` 同单位——同一个库里不引入字节/码元两套位置口径）。
  该值与分块方式无关，因此批量就绪 API 不再需要按 `step` 采样约 1000 次来近似时间轴。
  `at` 在 `delta_wbtest.mbt` 里被逐分块验证恒等且 `0 <= at <= 输入长度`。
  delta 目前只有内存 API（`drain_deltas` / `on_delta(&Delta)`），库和 CLI 都没有
  delta 的 JSON 序列化通道，因此这次字段新增不需要同步改任何 `to_json`；
  `Delta::pointer()` 的输出格式也未变。
- 版本推进到 `0.7.0`（`code/moon.mod`、`--version`）。

### 新增：声明式值约束（Schema constraints v1）

骨架以前只描述**形状**，`{!limit:integer}` 接受 `{"limit":-1}`。现在声明可以约束值：

- `minimum` / `exclusiveMinimum` / `maximum` / `exclusiveMaximum`（`number` / `integer`）；
- `minLength` / `maxLength`（`string`）；
- `enum:[字面量,…]`（任意标量种类，字面量必须与种类匹配）；
- `pattern:[字符类]`——**只有一个字符类，没有正则引擎**，明确不支持
  `+ * ? | ^ $ ( )`、连接、选择、锚点与反向引用。

语法紧跟在种类之后：`{!limit:integer(minimum:0)}`、
`{!code:string(pattern:[A-Z0-9_])}`、`{!kind:string(enum:["low","high"])}`。
因此**所有 0.6.x 声明逐字解析出同一个 schema、行为不变**（`{a:integer b:string}`
仍是两个成员；`{a:integer (minimum:0)}` 是 E070）。`stringify()` 会规范化并往返约束，
Q-23 往返语料扩到 25 条受限声明。

让这只是「运行时特性」而不是「校验器」的部分：新事件
`ReadinessEvent::FieldRejected(path, expected, got)` 在**使该值定稿的那条 delta** 上
发出，流式调用方可以据此取消——`{"limit":-1,"note":"…"}` 在 216 个码元中的第 12 个
就能拒绝，而不必读完尾部。`FieldInvalid` 仍然表示**种类不对**并携带整条声明；
`FieldRejected` 表示种类正确而值违反了约束。

### 变更：清掉第二个实现（Q-36）

- 删除 `semantic_readiness_sampled` 与 `KeepFirst` 分支（−72 行）。`KeepFirst`
  不再是一条独立实现路径，而是一个**有文档的组合**：观察器按「delta 被 drain 时
  值树里是什么」判定（增量喂入时重复名取先到的值，整块喂入时取后到的值）；
  早发的 `RootReady` 在 `KeepFirst` 下为真、在 `KeepLast` 下是**不会被撤回的下界**，
  `conflict()` 说明落在哪种情况，`verdict()` 始终是 `KeepLast` 的裁决。
- 已发布的就绪表格逐字未变（995/121、1000/1000、996/996、996/213、996/200、1000/1000、
  977/264、995/128/1000、992/84/1000、995/1000/1000）。唯一移动的数字是重复键文档的
  `syntax_permille`（933‰）——它以前是采样近似的产物。
- `plan.mbt` 的骨架消息从 `wrong kind` 改为 `mismatch`：0.7.0 之后种类可能正确而约束被
  违反，`expected` 里带的已经是约束（`integer >= 0`、`one of ["low","high"]`），
  再说「种类错误」会把读者引向一个并不存在的类型错误。

### 测试与门禁

- **Q-35 的落点**：`syntax_at` / `settled_at` / `RootInvalid` 与
  `decided_at_permille` 全部改用 `Delta.at`，`step` 参数仍被汇报但不再决定分辨率。
  新增回归测试断言 `chunk=1/997/整块` 与 `step=1/auto/997` 下的 permille 完全一致。
  实测同一台机器上 `semantic_readiness` 从 2.42–3.47× `repair` 降到
  **1.52× / 1.68× / 1.74×**（三次）。**没有达到规划里希望的 1.0–1.5×**：
  剩余成本是 `collect_deltas` 本身（`deltas` 基准行报告为解析基线的 144–153%）。
  再往前一步需要在引擎里把 delta 过滤到被观察路径上，属于 0.8 的候选。
- **Q-33 硬化为门禁**：`run_independent.py` 把「能在语法合法文件上触发的规则 ⊆ {R018}」
  从报告行升级为**无条件判据**（违反即 exit 1 并逐条点名 `file: R0xx line:col`）；
  `RULES.md` 给 22 条规则加了「能在合法 JSON 上触发」一列。执行这条判据时发现
  **R018 并不是唯一**：`R014 FixEscape` 的非配对代理项分支会在两个参考实现都接受输入时
  触发（11 个 `i_*` 文件、13 条记录）。已作为**具名残留**记录，并写明后果——
  `valid_json` 的含义是「除重复键归一化外没有任何修复」，**不是**「严格解析器接受这份输入」。
- **Q-37 覆盖率棘轮**：`tests/coverage.sh` 现在读取 `coverage_exemptions.txt`
  （71 条，格式 `文件⇥行号⇥该行源码`）。未覆盖且未登记 → 失败并点名；
  已登记但现在覆盖了 → 失败（「只能收缩」）；`--update-exemptions` 拒绝集合增长。
  锚定在**源码文本**而非行号，因此在上方插入代码不会让整个清单失效。
  同时把 CI 的覆盖率步骤从「打印原始报告」改为 `bash tests/coverage.sh`——
  只打印数字而不据此失败的步骤，等于没有门禁。
- `moon test --target all`：**192/192**（0.6.1 基线 171），四个后端同源。

### 文档与发布

- `code/docs/SPEC.md`：规范性规格（SR-1…SR-33），把 §20.1 的就绪表格冻结为 SR-12，
  并写入 delta 契约、精确度格、四个字段与 `settled = 1000‰` 的含义。
- **浏览器演示已发布**：https://wenhuang2333.github.io/Moonbit-haker/
  （`index.html` / `live.html` / `jsonmend.js` 三者实测 200），
  并录制了 69 秒走查（`static/demo/demo.mp4`，1280×800）与 10 秒 GIF（README 首屏）。
- `产品文档-精简版.md`：**356 行**的交付评审版（归档 `产品文档.md` 2691 行保留为历史）。
- **版本一致性进 CI**：`cli_smoke.sh` 新增 5 项断言，要求根 `README.md`、
  `code/README.md`、`code/README.zh.md`、`产品文档-精简版.md` 与 `--version`
  全部等于 `code/moon.mod` 的版本号，不一致时点名文件与两个字符串。
  顺带删掉 `cli_smoke.sh` 里硬编码的 `jsonmend 0.6.1`——那是个陷阱：
  每次发版都要手改，忘了就让一个正确的发版变红。

### 已知边界（诚实记录，未修）

- 前言缓冲区超限（默认 64 KiB）后不再重放，行为退回 `E002`；但上方
  `repair` / `analyze` / CLI 的全文回退仍然兜住这种情况（70000 空格 + `true`
  实测仍能取到值），两层如何组合见 `产品文档.md`。
- **一条规则解释所有被拒的情形，没有特例**：重放只在「干净」时被接受。于是
  「散文 + 标量」（`The answer is 42`）与代码围栏里的标量根都被拒绝——**但仅在
  `skip_prose` 打开时**。实测：`repair`（默认，`skip_prose` 关闭）对
  ```` ```json\ntrue\n``` ```` 返回 `true`、rc=0；`explain` **始终**打开
  `skip_prose`（`explain.mbt` 用 `options_of(…, agent_protocol=true)`，
  `agent_protocol` 会置 `skip_prose: true`），所以 `explain` 下它被拒，
  显式 `--skip-prose` 亦然。围栏里的对象/数组在两种设置下都正常，因为它们不需要重放：
  读到 `{` 就已经进入正文。
  **修正记录**：本轮先前把这条写成「围栏路径自身的缺陷，且关闭 `skip_prose` 时同样
  被拒」，那是错的——当时用来「关闭 `skip_prose`」的命令正是 `explain`，而
  `explain` 根本不关闭它。特此撤回，原先记的 Q-40 作为独立缺陷撤销。
- 「散文 + 标量」不被接受的原因不是偷懒而是不可判定：散文在哪里结束没有客观边界，
  因此仍然要求整段输入本身就是一份 JSON 文档。

## [0.6.1] - 2026-10-16

0.6.0 发布后由测试同学查出的两个缺陷，两处都在我（Lead）负责的文件里。
都是「不变量被违反」而不是新功能，因此按补丁版本发。

### 修复

- **`Schema::stringify()` 不引用成员名，破坏 Q-23 往返不变量**。
  合法标识符以外的成员名（含空格、含 `:`）被原样写回，得到
  `{!name with space:string}` —— 再解析直接 `E070`，即 `parse ∘ stringify` 在
  这一类声明上不是恒等。现在 `stringify()` 对无法裸写的名字加双引号
  （`{"name with space":string}` → `{!"name with space":string}`，可再解析），
  并在测试里把这个「已知缺口」翻成真正的不变量断言（含 `a:b` 一类）。
- **数组根骨架会过早给出 `RootReady`**。`required_paths()` 只枚举对象成员，
  所以 `[{!a:integer}]` 的必需路径为空、观察路径为空，观察器在刚读入 `[`
  时 `all_settled()` 即为真（空真），对半个数组 `evaluate` 后**报告骨架已满足**，
  `schema_permille = 0` —— 一个假性早定稿，正好是本轮要消灭的那类缺陷。
  现在结论只有在「所有必需路径都已定稿」**或**「根值已闭合」之后才允许发出；
  没有可观察路径的骨架（数组根、全部由子节点决定的骨架）一律等根闭合。

两个缺陷都由 `moon test --target all` 的四后端套件覆盖，现为 **171/171**。

## [0.6.0] - 2026-10-16

第七轮优化版本（`优化.md`），主题是**流式语义安全**：把「就绪」从采样工具变成运行时，
并把一件事写进产品表面 —— **语法合法不等于可以执行**。
本轮新增 `FR-39`（增量流式就绪）与 `FR-40`（回环 SSE 传输取证），
把 `NFR-PERF-09`（内存指标按模式报告）与 `NFR-TEST-02`（覆盖率下限）变成可执行的门禁。

### 修复

- **合法标量根文档被拒（正确性缺陷，本轮最重要的修复）**。`true`、`null`、`42`、`"ok"`、`""`
  都是合法 JSON（RFC 8259 允许任何值作为根），但任何开启 `skip_prose` 的路径都会拒绝它们：
  跳过前言只看第一个 `{` 或 `[`（`code/engine_flow.mbt` 前言阶段），标量根没有这个字符，
  整份输入被当成前言丢光，最后抛 `E002 NoJsonFound`。受影响的是
  `jsonmend explain`（默认 agent 协议）、`jsonmend --skip-prose`、
  `analyze(input, options=Options::for_agent())`。
  独立语料 `jsonmend-haker` 的 95 个 `y_*`（合法 JSON）文件里有 **8 个** 被直接拒绝。
  现在 `repair` / `analyze` / 流式 CLI 三条可拿到全文的入口都会在
  `NoJsonFound` 且 `is_valid_json(输入)` 为真时撤销跳过重解析；判断条件是"严格解析器接受全文"，
  因此前言不会被误读成值（`true story: {"a":1}` 仍然走 `R021` 并取到对象）。
  `code/tests/eval/run_independent.py` 新增 `--skip-prose` 假拒绝列作为回归门禁：
  对 0.5.0 二进制报 **8**，对 0.6.0 报 **0**。
  **已知限制**：只流式喂入、且调用方自己不保存全文的场景无法事后重解析，
  引擎层的前言重放留到 0.7；`产品文档.md` §21 记录了复现步骤。
- **`NoJsonFound` 偏移在一次性与分块路径间不一致**。`repair` 的回退分支把偏移硬编码成 `0`，
  破坏了 `prop_wbtest.mbt` 的分块不变性属性（TC-P-03）。现在原样回抛 `NoJsonFound(off)`，
  两条路径重新一致。

### 新增

- **增量流式就绪（FR-39，0.6.0 的 P0）**。`code/stream_readiness.mbt`：
  - `ReadinessEvent`：`FieldReady(path)` / `FieldInvalid(path, expected)` /
    `FieldIncomplete(path, expected)` / `RootReady` / `RootInvalid(offset)`，
    以及 `kind()` / `path()` / `is_verdict()` / `to_json()`；
  - `SemanticWatcher`：`new(schema, options?)`、`feed(chunk)`、`drain_events()`、
    `settled_at()`、`syntax_at()`、`concluded()`、`conflict()`、`verdict()`、`finish()`。
    它跟随 delta 流，而不是每一步重新快照整个文档；
  - `watch_readiness(input, schema, chunk?)` → 带 `permille` 的事件表（`-1` = 只有 `finish()` 能给出）、
    `decided_at_permille(...)`、`readiness_events_json(events)`。
  - `Schema::at_path(path)`：按路径取声明，供事件把路径映射回声明的类型。
- **`SemanticReadiness.settled_permille`**：每个声明成员"值已定"的输入比例，
  **不管类型对不对**；`schema_permille` 保持原义（已定 *且* 骨架满足），
  因此可判定的非法文档仍然报 `1000`。`jsonmend explain` 与 `explain --json` 现在同时打印三者。
  这修掉了 0.5.0 的观测盲点：`{"query":"MoonBit","limit":"ten",…}` 过去只能看到
  `syntax-ready 999/1000 schema-ready 1000/1000`，看起来像"永远没结论"，
  现在是 `settled 218/1000` —— 结论早就到了，结论是"不行"。
- **`jsonmend explain --json` 增加四个字段（Q-26）**：`valid_json`、`normalized`、
  `ambiguity`（`none` / `syntactic` / `semantic`）、`execution`（`allowed` / `blocked`）。
  `valid_json` 的口径是"输入本身是合法 JSON，JSONMend 只对重复键做了归一化"；
  该口径在独立语料的 95 个合法文件上验证过：只有 `R018` 会在合法 JSON 上触发。
  因此 `{"a":"b","a":"c"}` 现在报
  `valid_json:true, normalized:true, exactness:lossy, ambiguity:"semantic", execution:"blocked"`，
  `R018` 在产品叙述里改称**重复键归一化**（DuplicateKeyNormalization），
  而不是"修复合法 JSON"。

### 变更

- **就绪不再靠重采样**。`semantic_readiness` 与 `field_readiness`（FR-29）都改成
  delta 流的薄报表：前者 `O(n/step)` 次重新快照 → 一次跟随，后者用手表
  （最终成员表 + `any` 声明）复用同一条路径。同一台机器、三个 target、release 构建：
  - `semantic_readiness`：**32.7–34.3× repair → 2.42–3.47×**（同轮实测 0.5.0 实现 2233–3150 µs）；
  - `field_readiness`：**1794 µs/KiB → 154–191 µs/KiB**（约 9.4–10.8×）；
  - 实时路径 `watcher`（64 字节块逐块喂入 + 每次 drain）：**1.64–2.00× repair**，
    这才是运行时真正付的代价。
  文档里 0.5.0 的旧数字保留在对照列，便于审计。
- **内存指标改为按模式报告（NFR-PERF-09）**。撤销"峰值内存 ≤ 4× 输入"这条统一阈值：
  它把建树的解析器和流式解析器放在一起比，没有意义。改为按模式报告峰值 RSS，
  并声明（**不声称已达成**）尚未存在的两个模式的目标：纯文本 ≤ 4×、无树 ≤ 2×，留给 0.7。
- **覆盖率政策（NFR-TEST-02）**：整体 ≥ 85%，核心模块（`policy` / `decision` / `schema` /
  `plan` / `stream_readiness`）≥ 90%，由 `code/tests/coverage.sh` 执行；
  撤销 0.5.0"新增文件 ≥ 90%"的单条规则。
- 版本号 `0.5.0` → `0.6.0`。

### 测试

- 新增 `code/stream_readiness_wbtest.mbt`：事件序列、字符串成员只报一次就绪、
  容器成员在 `Close` 才就绪、重复键 `conflict()`、非法值早判定（`RootInvalid` 偏移小于输入一半）、
  缺失成员、截断输入、`Schema::at_path`、增量与批量口径一致、`decided_at_permille`、
  `readiness_events_json` 转义。
- `code/schema_wbtest.mbt` 增加 Q-23 往返不变量：`parse → stringify → parse` 语义不变、
  `stringify` 幂等，且 `{a:string}` 与 `{?a:string}` 的规范化文本必须不同 ——
  "无标记即必填"的文本 DSL 保留，但 `stringify()` 永远不能丢掉 `?`。
- `code/tests/cli_smoke.sh` 增加 12 条：标量根（含 `--skip-prose`）、
  重复键的四个语义字段、相邻字符串的 `syntactic` 歧义、`readiness` 的 `settled` 列。
- `code/tests/eval/run_independent.py` 增加 agent 模式的假拒绝门禁（见上）；
  `moon test --target all`：**170/170**，四个后端同源全过（0.5.0 为 129）。

## [0.5.0] - 2026-10-15

第六轮优化版本（`优化.md`），主题是**从解析库转为 AI 输出安全运行时**：不再增加修复规则，
而是把「这个值能不能用」变成一次调用就能拿到、并且可以回灌模型的对象。
本轮新增 7 条需求（`FR-32` … `FR-38`），不改动任何既有规则与既有输出。

**已发布**：mooncakes 上的 `zhanshishan/jsonmend@0.5.0`（`moon publish` 退出码 0，
页面 https://mooncakes.io/docs/zhanshishan/jsonmend/0.5.0 返回 200）；`v0.5.0` 标签已推送，
`release.yml` 产出预编译产物。0.5.0 也修正了 0.4.0 记录的
「`moon publish --dry-run` 返回 255」现象：本轮未复现。

### 新增

- **安全档位（FR-32）**。`SafetyPolicy`：`permissive` / `interactive` / `execution` / `agent` / `strict`
  五个具名档位，覆盖 `Options` 里与安全相关的字段（`mode`、`max_loss`、
  `reject_ambiguous`、重复键、截断数字、深度与长度上限）。
  `Options::with_policy` 只替换安全字段、保留协议字段（增量流、跳过前言）；
  `SafetyPolicy::of_options` 能把一份 `Options` 读回成档位名，未知组合返回 `None` 而不是就近归类。
  `agent` 档比 `execution` 多了资源上限（深度 64、输入 1 MiB）：一次工具调用的参数不该有 64 MiB。
- **执行决策（FR-34）**。`ExecutionDecision`：`safe` / `cosmetic_repair` / `lossy_repair` /
  `ambiguous` / `invalid`，把「修复了几处」与「能不能执行」分成两个问题，并给出可排序的风险。
- **修复计划（FR-33）**。`RepairPlan` + `PlanOp`（规则、动作 `remove`/`insert`/`replace`/
  `normalize`/`merge`/`wrap`、位置、严重度、歧义类、置信 *类别* 而不是概率、
  是否丢信息）；`analyze(input, options?, readiness?, schema?)` **永不抛错**，把拒绝放在返回值里，
  并带 `prompt()`（可直接回灌模型的提示）、`suggestions()`（按规则/歧义生成的具体指令）、
  `summary()`、`explain_text()`、`to_json()`（机器通道，含 `value`、`retry`、`repairs_truncated`）。
- **自愈闭环示例（FR-35）**。`examples/agent_loop`：四个 episode（相邻字符串 `E011`、截断 `E010`、
  骨架不符 `E070`、无改进则放弃），把 `prompt()` 回灌给「模型」并重试，直到可执行或到达次数上限。
- **骨架感知就绪（FR-36）**。`Schema` 文本 DSL（`{!key:type,?key:type}`，类型
  `any|null|boolean|integer|number|string|[inner]|{...}`）与
  `semantic_readiness`：同一份输入上给出「语法就绪」与「骨架就绪」两个分数，
  以及必需成员的缺失/类型不符清单；CLI `explain --schema`、`readiness --schema`；
  新错误码 `E070`（骨架声明错误，退出码 2）。
- **流式 live 演示（FR-37）**。`static/demo/live.html`：四个真实场景（截断参数→重试、
  歧义→重试、唯一读法→直接通过、长尾→19% 即可停），逐帧播放「模型流 / 实时结构 /
  成员就绪 ✓◐ / 三个 readiness + verdict / 重试面板」。
  打包入口 `jsonmendRegister3("live", …)` 与 `code/tests/demo_smoke.mjs` 的 14 条断言。
- **独立第三方语料（FR-38，本次一并落地）**。内置 `nst/JSONTestSuite`（318 个文件，
  MIT，commit `1ef36fa0`）与 `tests/eval/run_independent.py`：`y_` 误修 2/95、
  `n_` 产出合法值 165/188（`json_repair` 166、`jsonrepair` 144）。

### 变更

- `Options::strict()` 与 `Options::for_agent()` 的构造改为引用 `SafetyPolicy`，档位只有一个定义。
- CLI `explain` 默认按 agent 协议读取（等价于 `--skip-prose`）：调用方看的是模型的回答。
- CLI `explain` 的两层就绪数字用「显示档」测量：数字是输入与声明的属性，
  不接受被 `--policy strict` 之类改变（否则未闭合文档会变成「无法测量」）。
- 版本 0.4.0 → 0.5.0。

### 证据

- `moon test --target all`：**129 × 4 = 516 通过，0 失败**（新增 34 条：policy 7、plan 22、schema 5）。
- `bash tests/cli_smoke.sh`：**62 passed, 0 failed**（新增 14 条覆盖 `explain`、`--policy`、`--schema`、`E070`）。
- `bash tests/examples.sh` 6/6；`node code/tests/demo_smoke.mjs` 通过（4 个入口 + live 帧）。
- `tests/eval/run_eval.py`：1200/1200，四条预登记判据 PASS；
  `run_ambiguity.py` + `check_amb_guard.py`：24 例对抗语料 + 守卫通过。
- `tests/eval/run_independent.py`：`y_` 误修 **2/95**（均为重复键，见下），
  `n_` 165/188 vs `json_repair` 166/188 vs `jsonrepair` 144/188。
- `tests/eval/run_readiness.py`：7 个场景，4 个存在两层分数落差（最大 973‰ vs 260‰），
  3 个两层同时到达末尾——蓄意收录「没有收益」的场景，见 `docs/READINESS.md`。
- `bench/main.mbt` 新增 `bench_gate`：4.9 KiB × 20 次调用，
  `analyze` = **1.00× repair**（66.5 µs/次），`analyze for_agent` = 1.36×，
  `analyze +schema` = 1.38×，`semantic_readiness` = 34.25×（诊断用途，非热路径）。
- 覆盖率：根包 2312/2651 = **87.2%**，`llm` 337/391 = 86.2%（新增文件把分母推大，
  `plan.mbt` 71.5% 是当前最低项，已记入产品文档遗留问题）。

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
