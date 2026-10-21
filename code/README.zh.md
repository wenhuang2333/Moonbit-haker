# JSONMend

纯 MoonBit 实现的流式 JSON 修复与部分解析库。

| | |
| --- | --- |
| 模块 | `zhanshishan/jsonmend` |
| 版本 | 1.1.1 |
| 许可证 | Apache-2.0 |
| 首选后端 | `wasm`（同时支持 `native` 与 `js`） |
| 预编译产物 | [Release `v1.1.1`](https://github.com/wenhuang2333/Moonbit-haker/releases/tag/v1.1.1)——Linux / macOS arm64 / Windows 三个 CLI、wasm 探针、浏览器包、`SHA256SUMS` |
| 发行渠道 | [mooncakes.io `zhanshishan/jsonmend`](https://mooncakes.io/docs/zhanshishan/jsonmend) |

## 特性

### 0.5.0：把「能不能执行」变成一次调用

- **安全档位 `SafetyPolicy`**：`permissive` / `interactive` / `execution` / `agent` / `strict` 五个具名档位，
  覆盖 `Options` 里与安全相关的字段。`Options::with_policy` 只替换安全字段、保留协议字段
  （增量流、跳过前言）；`SafetyPolicy::of_options` 能把一份 `Options` 反查成档位名，未知组合返回 `None`。
- **一次调用拿到完整计划 `analyze`**：

  ```moonbit
  let plan = @jsonmend.analyze(text,
    options=@jsonmend.Options::for_agent(),
    schema=@jsonmend.Schema::parse("{!query:string,!limit:integer}"))
  plan.decision          // Safe | CosmeticRepair | LossyRepair | Ambiguous | Invalid
  plan.is_executable()   // 唯一需要判断的问题
  plan.repairs           // 每条：规则、动作（remove/insert/replace/…）、位置、置信类别、是否丢信息
  plan.prompt()          // 不能执行时，直接回灌给模型
  plan.to_json()         // 机器通道：decision/exactness/value/retry/repairs/…
  ```

  `analyze` **永不抛错**：拒绝是返回值的一部分。`repair` 相对的开销是 1.00–1.03×。
- **骨架感知就绪 `Schema` + `semantic_readiness`**：`{!query:string,!limit:integer}` 这样的声明，
  同时给出「语法就绪」与「骨架就绪」两个分数，以及缺失/类型不符的成员清单。
  CLI `jsonmend explain --schema '…'` 直接打印两层数字。
- **自愈闭环示例**：`code/examples/agent_loop` 把 `plan.prompt()` 回灌给「模型」并重试，
  四个 episode 覆盖 `E011` 歧义、`E010` 截断、`E070` 骨架不符与「无改进则放弃」。
- **实时演示页**：`static/demo/live.html` 逐帧重放四条真实场景（截断→重试→通过、
  歧义→重试→通过、唯一读法直接通过、长尾流在 19% 处即可停）。

### 其余能力

- **一次性修复**：`repair` 返回修复后的文本、修复记录列表以及输入的完整性。
- **一次性解析**：`parse` 返回修复后的 `Json` 树，以及同样的修复记录。
- **流式部分解析**：`PartialParser` 支持任意分块地 `feed`（或 `feed_bytes`），随时 `snapshot()`，最后 `finish()`。
- **修复记录**：每次修改都带有稳定编号（`R001`…`R022`）、位置（UTF-16 偏移加 1 基的行列号）、严重级别和固定英文消息。
- **精确度标签**：每个结果都带 `Exact` / `Cosmetic` / `Lossy`；`Options::max_loss` 在第一条超预算的修复处抛 `E010`，因此「先修再执行」不会静默发生。
- **歧义闸**：有第二种同样自洽读法的修复（`["a" "b"]`、`["a"+"b"]`、`[fast]`、`{"a":1} {"b":2}`）会带上 `Ambiguity` 分类，并在 `Options::reject_ambiguous` / `Options::for_execution()` 下以 `E011` 拒绝（先于精确度闸）。对抗语料 10/10 全部标记并拒绝，而两个参照库对同样 10 条全部静默给出取值（`docs/EVAL_AMBIGUITY.md`）。
- **拒绝即反馈**：`MendError::retry_hint`（CLI `--retry-hint`）把拒绝变成可直接回灌模型的提示片段：错误码、修复码、位置、第二种读法、有界上下文窗口与插入符。
- **字段就绪曲线**：`field_readiness` 给出每个顶层成员在输入消耗到多少时已定稿，`FieldTracker` 用增量流做同样的事，调用方可以在需要的字段定稿后立刻停掉生成。
- **增量补丁流**：`Options::collect_deltas` 打开后，`drain_deltas()` 返回带 RFC 6901 指针的 `Set` / `AppendText` / `Close`，`feed_with` 提供回调形式（`FR-16`）。
- **大模型适配器**（`jsonmend/llm` 子包，**实验性**）：Anthropic 细粒度工具流、OpenAI 兼容工具调用增量、SSE 分帧，以及从 `delta.text` / `delta.content` 中取 JSON 的文本流；调用结束分为 `Complete` / `MaxTokens` / `Interrupted` / `ProviderError`，并保留提供方的原始 `stop_reason`；`ping` 与未知事件计数后忽略。命令行见 `jsonmend llm`。
- **严格模式**：`Mode::Strict` 把第一条修复记录升级为致命错误 `E010`；逐规则开关关闭某条规则时同样如此。
- **资源限制**：嵌套深度、输入总长度、单个 token 长度（`E020`/`E021`/`E022`）。
- **多种策略**：重复键、非有限数、多根值、Markdown 围栏、前导说明文字、引号歧义、输出缩进。
- **多后端**：库为纯 MoonBit，不使用正则，也不使用递归；`bench` 可在 `native` 与 `js` 上运行。
- **命令行与浏览器演示**：命令行见 `cmd/jsonmend`，浏览器演示见 `examples/web`。

## 为什么需要它

大模型应用逐 token 地流式输出 JSON，而这段输出经常在值中间被截断，或者被 Markdown 围栏包住、用单引号书写、前后混入说明文字与注释。严格解析器会直接拒绝整个负载，于是应用在结束前什么都显示不出来，有时甚至永远拿不到结果。JSONMend 在每一个分块之后都保留最后一个已经确认的前缀，并在读取过程中顺手修复瑕疵，因此部分结果可以立刻使用，最终结果也是合法 JSON。一次性修复与流式解析共用同一个引擎，两条路径不会产生分歧。

## 安装

用 MoonBit 工具链添加依赖：

```sh
moon add zhanshishan/jsonmend
```

然后在你自己的 `moon.pkg` 中按本文使用的别名导入：

```
import {
  "zhanshishan/jsonmend" @jsonmend,
}
```

`moon add` 会把依赖写入模块清单（本仓库对应 `code/moon.mod`）。具体的注册表写法与当前工具链命令以 mooncakes.io 的说明为准，请在已发布的包页面上核对。

## 三行上手

`repair` 会抛出 `MendError`，因此需要包在 `try`/`catch` 中；下面三条语句就是完整示例：

```moonbit
try {
  let result = @jsonmend.repair("{'a': 1,}")   // RepairResult
  println(result.text)                         // {"a":1}
  println(result.repairs.length())             // 修复记录条数
} catch {
  e => println(e.to_string())
}
```

需要 `Json` 树而不是文本时改用 `@jsonmend.parse`，它同样返回 `repairs` 与 `completeness`，并额外给出 `value`。`repair` 返回 `RepairResult`，字段为 `text`、`repairs` 和 `completeness`。

## 接入面

库是引擎；五种交付面包装同一套语义：

| 接入面 | 用途 |
| --- | --- |
| `moon add zhanshishan/jsonmend` | MoonBit 项目（本包） |
| `jsonmend serve` | 任意语言；版本化 JSONL（[docs/PROTOCOL.md](docs/PROTOCOL.md)） |
| `jsonmend mcp` | Claude Code、Cursor、Codex CLI、Gemini CLI、Cline、Windsurf：四个工具 |
| `npm install ./code/npm` / `pip install ./code/python` | Node 与 Python 宿主 |
| `jsonmend-http`（Python 包） | n8n、Dify、Coze、网关 |

执行门在所有接入面上是同一个调用：`analyze(text, profile="agent",
schema_json=tool.inputSchema)` 返回 `executable`；为 false 时把 `retry.prompt`
原样回灌模型。逐工具配方见 [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md)。

## 流式示例

`PartialParser` 接受任意分块，一个分块可以切断任何 token，包括转义序列和代理对。

```moonbit
try {
  let p = @jsonmend.PartialParser::new()
  p.feed("{\"name\":\"Mo")
  let s1 = p.snapshot()
  match s1.value {
    Some(v) => println(v.stringify())          // {"name":"Mo"}
    None => println("<none>")
  }
  println(s1.completeness is @jsonmend.Partial) // true
  p.feed("n\"}")
  let done = p.finish()
  println(done.text)                            // {"name":"Mon"}
  println(done.completeness is @jsonmend.Complete) // true
} catch {
  e => println(e.to_string())
}
```

`feed_bytes` 接收原始 UTF-8 字节，可以和 `feed` 混用；非法或被截断的 UTF-8 会抛出 `E040`。选项通过关键字参数传入：

```moonbit
try {
  let p = @jsonmend.PartialParser::new(options={
    ..@jsonmend.Options::default(),
    incomplete_number: @jsonmend.TrimToValid,
    pending_key: @jsonmend.NullKey,
  })
  p.feed_bytes(b"[1, 1.")
  let s = p.snapshot()
  // s.value 为 [1,1]：未完成的数字被裁剪到最长合法前缀。
  p.feed_bytes(b"5]")
  let done = p.finish()
  println(done.text)  // [1,1.5]
} catch {
  e => println(e.to_string())
}
```

`snapshot()` 返回 `Snapshot`，字段为 `value`（`Json?`）、`completeness` 和 `open_path`；`finish()` 返回 `FinalResult`，含 `text`、`value`、`repairs` 和 `completeness`。`snapshot()` 从不抛错，也不改动解析器状态；`finish()` 只能调用一次，重复调用或在上一次致命错误之后再调用会抛出 `E030`。

## 端到端示例：拒绝、回灌、再执行

`examples/agent_gate/` 是一个可运行的程序（`moon run examples/agent_gate --target native --release`），
它把「模型给了一份有两种读法的参数」这件事走完整条链路：

```text
== first attempt
model   : {"city":["Paris" "London"]}
gate    : E011 adjacent_strings - the gate cannot pick a reading
refused : the gate refused to pick a reading
prompt  :
  JSONMend refused the arguments: E011 R006 InsertComma at line 1 column 18 (offset 17).
  Reason: two adjacent strings may be two elements or one concatenated string
  Ambiguity: adjacent_strings
  Re-emit the arguments as valid JSON with exactly one reading.

== re-emitted
model   : {"city":["Paris","London"]}
execute : {"city":["Paris","London"]}
```

`Options::for_execution()` 先查歧义、再查精确度：`["Paris" "London"]` 与 `"Par" + "is"`
这类修复「取值没变但有两种读法」，只有歧义闸能拦住；`"Par` 这类截断则是 `E010`。
两者的拒绝理由都会变成可直接回灌模型的提示（`RetryHint::to_prompt()`）。
不带闸门时同一份输入照旧修复，只是把 `ambiguous` 标成 `true`——闸门是选择加入的。

## 选项

`Options` 的全部字段如下，`@jsonmend.Options::default()` 即文档化的默认值。

| 字段 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `mode` | `Mode` | `Lenient` | `Lenient` 记录修复；`Strict` 在第一条修复记录处抛出 `E010`。 |
| `max_depth` | `Int32` | `512` | 容器最大嵌套深度，超出抛 `E020`。 |
| `max_input_len` | `Int32` | `67108864` | 输入最大长度（UTF-16 码元），超出抛 `E021`。 |
| `max_token_len` | `Int32` | `16777216` | 单个 token 最大长度（码元），超出抛 `E022`。 |
| `duplicate_keys` | `DuplicateKeys` | `KeepLast` | 重复对象键的策略：`KeepLast`、`KeepFirst` 或 `AsError`（`R018`）。 |
| `incomplete_number` | `IncompleteNumber` | `Drop` | 快照中未完成数字的处理：`Drop` 或 `TrimToValid`。 |
| `pending_key` | `PendingKey` | `OmitKey` | 快照中悬空键的处理：`OmitKey` 或 `NullKey`。 |
| `non_finite` | `NonFinite` | `AsNull` | `NaN`/`Infinity`/`-Infinity` 转为 `AsNull`、`AsString` 或 `AsError`（`R012`）。 |
| `strip_fence` | `Bool` | `true` | 去除 Markdown 代码围栏（`R001`）。 |
| `collect_repairs` | `Bool` | `true` | 是否把修复写入结果；为 `false` 时数组为空，但严格模式与关闭的规则仍会抛错。 |
| `want_text` | `Bool` | `true` | 是否在 `FinalResult.text` 中生成修复文本；为 `false` 时只构建 `Json` 值。 |
| `skip_prose` | `Bool` | `false` | 跳过第一个 `{` 或 `[` 之前的说明文字（`R021`）。 |
| `quote_lookahead` | `Bool` | `false` | 对缺逗号的字符串序列启用引号歧义前瞻（`R003`）。 |
| `multi_root` | `MultiRoot` | `KeepFirst` | 根值之后内容的策略：`KeepFirst`、`AsArray` 或 `AsError`（`R016`）。 |
| `rules` | `RuleSet` | `RuleSet::all()` | 逐规则开关；关闭某条规则会让对应编号抛 `E010`。 |
| `indent` | `Int32` | `0` | 输出缩进空格数；`0` 表示紧凑输出。 |
| `max_repairs` | `Int32` | `10000` | 最多保留多少条修复记录；超出后仍继续修复，但结果把 `repairs_truncated` 置为 `true`。 |
| `reject_ambiguous` | `Bool` | `false` | 是否拒绝有第二种读法的修复（`E011`）而不是照修；`Options::for_execution()` 会打开它。 |
| `max_loss` | `Exactness` | `Lossy` | 可接受的最大信息损失；记录到更严重的修复时抛 `E010`（默认值等于不设限）。 |
| `collect_deltas` | `Bool` | `false` | 是否记录增量补丁；打开后 `drain_deltas()` 可用，与 `KeepFirst`、`TrimToValid` 不兼容。 |

非法取值（`max_depth <= 0`、`max_input_len <= 0`、`max_token_len <= 0`、`max_repairs <= 0`、`indent < 0`）由 `Options::validate` 抛出 `E050`；`repair`、`parse` 和 `PartialParser::new` 都会替你调用校验。

## 修复规则一览

每次修改都对应一条编号稳定的记录。含示例与需求映射的完整字典见 [docs/RULES.md](docs/RULES.md)。

| 编号 | 名称 | 含义 |
| --- | --- | --- |
| `R001` | `StripFence` | 去除 Markdown 代码围栏。 |
| `R002` | `StripComment` | 去除行注释或块注释。 |
| `R003` | `NormalizeQuote` | 把引号规范化为双引号。 |
| `R004` | `QuoteBareWord` | 给裸词加引号（键位置为 Info，值位置为 Warning）。 |
| `R005` | `RemoveExtraComma` | 删除尾逗号、前导逗号或重复逗号。 |
| `R006` | `InsertComma` | 补上缺失的逗号。 |
| `R007` | `InsertColon` | 补上缺失的冒号。 |
| `R008` | `FillNull` | 为缺失的值补 `null`。 |
| `R009` | `CloseContainer` | 补全未闭合的数组或对象。 |
| `R010` | `CloseString` | 补全未闭合的字符串。 |
| `R011` | `FixNumber` | 规范化或裁剪数字。 |
| `R012` | `ConvertLiteral` | 转换或补全字面量（`True`、`None`、`undefined`、非有限数等）。 |
| `R013` | `EscapeControl` | 转义字符串中的控制字符。 |
| `R014` | `FixEscape` | 修正非法或残缺的转义、孤立代理项。 |
| `R015` | `MismatchedCloser` | 闭合符类型与打开的容器不匹配时替换。 |
| `R016` | `DropUnexpected` | 丢弃无法识别或多余的内容，包括根值之后的尾随内容。 |
| `R017` | `DropExtraCloser` | 丢弃多余的闭合符。 |
| `R018` | `MergeDuplicateKey` | 按 `duplicate_keys` 策略合并重复键。 |
| `R019` | `ConcatStrings` | 合并相邻的字符串拼接（`["a" + "b"]` 得到 `["ab"]`）。 |
| `R020` | `DropEllipsis` | 删除值位置的 `...` 占位。 |
| `R021` | `SkipProse` | 跳过 JSON 值之前的说明文字。 |
| `R022` | `NormalizeLiteral` | 字面量只是大小写变体（`True`、`FALSE`），字符数与规范写法相同。 |

## 修复记录与错误码

库严格区分两类信号：修复记录是信息性的，随结果返回；致命错误会中止处理，以 `MendError` 抛出。

一条 `Repair` 包含 `code : RepairCode`、`position : Position`、`severity : Severity` 和 `message : String`。`Position.offset` 从 0 开始按 UTF-16 码元计数，`line` 与 `column` 从 1 开始。`Severity::Info` 表示值未变、只是记法被规范化；`Severity::Warning` 表示内容可能被补出、丢弃或改动。消息是固定模板，绝不嵌入用户输入。

严重级别是**精确度标签**（`Exactness`）的唯一依据：无记录为 `Exact`，只有 `Info` 记录为 `Cosmetic`，
出现任一 `Warning` 记录为 `Lossy`。`Options.max_loss` 在第一条超出上限的记录处抛
`E010 StrictViolation`（消息里带着那条修复码），CLI 对应 `--max-loss exact|cosmetic|lossy`。

| 编号 | 错误 | 触发条件 |
| --- | --- | --- |
| `E001` | `EmptyInput` | 输入为空或只有空白。 |
| `E002` | `NoJsonFound` | 找不到 JSON 值（载荷为偏移量）。 |
| `E010` | `StrictViolation` | 严格模式或已关闭的规则拒绝某次修复（载荷为编号、位置与消息）。 |
| `E020` | `DepthLimit` | 嵌套深度超过 `max_depth`。 |
| `E021` | `SizeLimit` | 输入超过 `max_input_len`。 |
| `E022` | `TokenLimit` | 单个 token 超过 `max_token_len`。 |
| `E030` | `InvalidState` | 在 `finish` 之后继续 `feed`，或重复 `finish`、在致命错误后 `finish`。 |
| `E040` | `InvalidUtf8` | `feed_bytes` 遇到非法或截断的 UTF-8（载荷为字节偏移）。 |
| `E050` | `InvalidOption` | 选项取值越界，或选项组合不成立（如 `collect_deltas` 与 `KeepFirst`）。 |
| `E060` | `InvalidEvent` | `jsonmend/llm` 收到无法解释的事件负载。 |
| `E070` | `SchemaError` | 骨架声明本身写错（括号不闭合、未知类型、成员重复）；CLI 退出码 2。 |

`RepairCode::code`、`MendError::code` 和 `MendError::to_string` 分别给出稳定字符串（如 `R005`）、错误编号（如 `E020`）和单行诊断信息。完整参考见 [docs/ERRORS.md](docs/ERRORS.md)。

## 快照语义

`snapshot()` 返回当前已解析值的非破坏性视图，不抛错，也不改动解析器状态：

- **稳定前缀。** 已经闭合的值——完整的字符串、数字、字面量和容器——在之后的快照中不再变化，只有最后一个未完成的元素会变。
- **单调性。** 快照序列单调增长。选择 `TrimToValid` 会故意破坏未完成数字的单调性（先看到 `12`，之后可能变成 `123`），这是文档化的行为，不是缺陷。
- **未完成的数字。** 默认 `incomplete_number = Drop` 时完全不出现；`TrimToValid` 时显示最长合法前缀，没有合法前缀则不出现。
- **未完成的键。** 尚未读到收尾引号的键不会出现。悬空键（已有键和冒号、没有值）在默认的 `pending_key = OmitKey` 下省略，在 `NullKey` 下显示为 `"key": null`。
- **未完成的字符串。** 已接收的前缀会出现；未完整的转义序列会暂缓，直到补全。
- **字面量前缀。** 诸如 `tr` 这样的残缺字面量不会出现在快照中，`finish` 时才补全。
- **未闭合的容器。** 以当前已确认的内容呈现，`completeness` 为 `Partial`。
- **`open_path`** 用 `Array[PathSegment]` 指出当前正在构建的值的位置，每段是 `Key(String)` 或 `Index(Int32)`。合成帧（例如 `multi_root = AsArray` 添加的数组外壳）会被跳过。

快照与最终结果的差异是有意设计的：预览省略尚未确定的部分，而 `finish` 会闭合容器（`R009`）、补全字符串（`R010`）、裁剪数字（`R011`）、补全字面量（`R012`），并把悬空键填为 `null`（`R008`）。因此预览中被省略的值，可能出现在最终结果里。

## 命令行与演示

构建并运行命令行工具：

```sh
moon build cmd/jsonmend --target native --release
echo "{'a': 1,}" | ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

以下是 `cmd/jsonmend/args.mbt::help_text()` 帮助文本的逐字引用：

```text
jsonmend [选项] [文件]

读取文件或标准输入，把修复后的 JSON 写到标准输出。

  --strict            严格模式：需要修复就报错（退出码 5）
  --check             只检查，不输出；需要修复时退出码 1
  --report            把修复记录写到标准错误
  --indent N          输出缩进空格数，默认紧凑输出
  --multi-root MODE   first、array 或 error，默认 first
  --skip-prose        跳过 JSON 之前的说明文字
  --quote-lookahead   启用引号歧义前瞻
  --max-repairs N     最多记录多少条修复记录，默认 10000
  --max-loss LEVEL    精确度上限：exact、cosmetic 或 lossy，默认 lossy
  --for-execution     执行档：等价于 --max-loss cosmetic --reject-ambiguous
  --reject-ambiguous  拒绝有第二种读法的修复，报 E011（退出码 5）
  --retry-hint        拒绝时在标准错误上打印可直接回灌模型的提示
  --chunk N           分块喂入：每次喂 N 个码元（≤1048576），用来验证流式路径（默认一次喂完）
  --explain           在标准错误上逐条解释修复，并打印精确度小结
  --policy NAME       安全档位：permissive、interactive、execution、agent 或 strict
  --schema DECL       骨架声明，例如 `{!query:string,!limit:integer}`；检查必需字段与类型
                      与 explain 同用时打印语法就绪与骨架就绪两层数字
  --json              与 explain 同用时打印机器可读的 JSON 计划，而不是文本块
  --batch             逐行读取 {"id","input"} JSON，逐行输出结果 JSON
                      与 --chunk N 同用可把每条输入按 N 字节分块喂入

jsonmend explain [选项] [文件]
  打印完整分析：修复了什么、为什么、风险多大、能不能执行；拒绝时给可直接回灌模型的提示。
  退出码与 jsonmend 相同（可执行 0，拒绝 5）。

jsonmend readiness [选项] [文件]
  打印字段就绪曲线：每个顶级字段在输入消耗到多少时已定稿。
  --step N            每 N 个码元观察一次，默认按长度自适应

jsonmend llm [选项] [文件]
  把模型的事件流喂给 provider 适配器，每个工具调用输出一行结果 JSON。
  --provider NAME     anthropic（默认）或 openai
  --sse               输入是 SSE 文本（默认按每行一个事件 JSON 读取）
  --text              读取文本增量（delta.content / text_delta）而不是工具调用参数（配 --skip-prose 可跳过前言）
  --follow            每次增量都输出一行，而不是只在结束时输出
  -h, --help          显示帮助
  --version           显示版本

文件为 `-` 或缺省时读取标准输入。

退出码：0 成功（可能有修复）；1 --check 发现需要修复；2 用法错误；
        3 输入无效；4 资源限制；5 严格模式违规；70 内部错误。
```

各选项含义：

| 选项 | 含义 |
| --- | --- |
| `--strict` | 严格模式：需要修复即报错（退出码 5）。 |
| `--check` | 只检查、不输出；需要修复时退出码 1。 |
| `--report` | 把修复记录写到标准错误。 |
| `--indent N` | 输出缩进空格数（0 到 64），默认紧凑输出。 |
| `--multi-root MODE` | `first`、`array` 或 `error`，默认 `first`。 |
| `--skip-prose` | 跳过 JSON 之前的说明文字。 |
| `--quote-lookahead` | 启用引号歧义前瞻。 |
| `--max-repairs N` | 最多保留多少条修复记录（默认 10000）；被截断时另向标准错误打印一行提示。 |
| `--max-loss LEVEL` | `exact`、`cosmetic` 或 `lossy`（默认）：超出即退出码 5，并指出是哪条修复。 |
| `--explain` | 逐条打印级别、位置与带插入符的片段，末尾给出精确度小结。 |
| `--batch` | 逐行读 `{"id","input"}`，逐行输出 `{"id","rc","exactness","codes","value","text"}`。 |
| `llm` 子命令 | `jsonmend llm [--provider anthropic\|openai] [--sse] [--follow] [文件]`：把事件流喂给 provider 适配器。 |
| `-h`、`--help` | 显示帮助。 |
| `--version` | 显示版本（`jsonmend 1.0.0`）。 |
| `--policy NAME` | 安全档位：`permissive`、`interactive`、`execution`、`agent` 或 `strict`（见 `SafetyPolicy`）。 |
| `--schema DECL` | 骨架声明，如 `{!query:string,!limit:integer}`；`explain` 会额外打印语法就绪与骨架就绪两层数字。 |
| `--json` | 与 `explain` 同用：输出机器可读的 JSON 计划，而不是文本块。 |
| 文件或 `-` | 读取文件；`-` 或缺省时读取标准输入。 |

`--indent=N`、`--multi-root=MODE`、`--max-repairs=N`、`--max-loss=LEVEL`、`--provider=NAME`
和用空格分隔的写法等价。

退出码：

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功；输出中仍可能包含修复。 |
| `1` | `--check` 发现需要修复。 |
| `2` | 用法错误（未知选项、选项取值非法，或 `E050`）。 |
| `3` | 输入无效（`E001`/`E002`/`E040`/`E060`，或文件无法读取）。 |
| `4` | 触发资源限制（`E020`/`E021`/`E022`）。 |
| `5` | 严格模式违规（`E010`，含 `--max-loss` 超限）。 |
| `70` | 内部错误（`E030`）。 |

浏览器演示的源码位于 `examples/web`，构建好的页面是 `static/demo/index.html`，可以直接用浏览器打开。该包导出三个「字符串进、字符串出」的入口：`repair_text`、`report_text` 和 `snapshot_text`（返回某个前缀的值、完整性与打开路径），并通过 `globalThis.jsonmendRegister*` 注册到宿主页面，因此页面内没有第二份实现。重新生成 bundle 用 `bash static/demo/build.sh`；构建步骤与无头校验见 [docs/REPRODUCE.md](docs/REPRODUCE.md)。

## 测试

```bash
cd code
moon test                      # 默认后端（wasm-gc）
moon test --target native      # 本机后端
moon test --target js          # JavaScript 后端
bash tests/cli_smoke.sh        # 62 项命令行断言
bash tests/examples.sh         # 示例输入与 code/examples/cases/*.expected 对照
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/run_eval.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/run_eval_paths.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/check_amb_guard.py    # 对抗语料的判据机制本身可失败的守卫
python3 tests/eval/run_ambiguity.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/refcompare.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/gen_llm_fixtures.py --check
python3 tests/memory_baseline.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/run_independent.py    # 内置 nst/JSONTestSuite，独立于自造语料
python3 tests/eval/run_readiness.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe --check
moon run examples/agent_loop --target native --release   # 自愈闭环
```

| 测试集 | 规模 | 0.5.0 结果 |
| --- | --- | --- |
| 黄金用例（规范附录 A、B） | 126 条 | 通过 |
| 流式用例（S-001…S-021）与分块不变性 | 21 条 + 不变性检查 | 通过 |
| 精确度标签（TC-X-01） | 18 行手写表 + 240 例属性 | 通过 |
| 增量流重放（TC-DELTA） | 400 + 400 份文档，7 组选项剖面 | 通过 |
| 大模型适配器（TC-LLM） | 9 个生成夹具 + 文档转录事件形状，30 例 | 通过 |
| 适配器真值路径 | 1200 条 ×（双 provider × 工具流 / 文本流） | 四条路径均 **1200/1200**（[docs/EVAL_PATHS.md](docs/EVAL_PATHS.md)） |
| 对抗歧义语料 `amb-1` | 24 条手写，指纹冻结 | 10/10 标记并拒绝，14/14 对照放行，失败 0（[docs/EVAL_AMBIGUITY.md](docs/EVAL_AMBIGUITY.md)） |
| 参照库并列对照 | 1200 条 ×（`jsonrepair` 3.15.0、`json_repair` 0.64.0） | JSONMend 静默错值 0，`jsonrepair` 122，`json_repair` 189（[docs/EVAL_REFERENCE.md](docs/EVAL_REFERENCE.md)） |
| 分块路径真值 | 1200 条 × 分块 1/3/7/随机 | 每条路径 1200/1200，零分歧 |
| 真值评测（TC-EVAL） | 1200 条，协议先冻结 | 恢复率 100.00%，漏标 0，五条判据全 PASS（含 `eval-3` 新增的判据 3b） |
| 属性与模糊测试（TC-P-01…TC-P-06） | 8 组 × 400 例 | 通过，无反例 |
| 安全档位 / 修复计划 / 骨架（0.5.0 新增） | 34 条（7 + 22 + 5） | 通过 |
| 独立第三方语料（`nst/JSONTestSuite`） | 318 个文件（95 `y_` / 188 `n_` / 35 `i_`） | `y_` 误修 2/95（重复键），`n_` 有效值 165/188 vs `json_repair` 166/188、`jsonrepair` 144/188（[docs/EVAL_INDEPENDENT.md](docs/EVAL_INDEPENDENT.md)） |
| 骨架就绪表 | 10 个场景 | 6 个存在落差（713‰–908‰），4 个两层同时到达末尾（[docs/READINESS.md](docs/READINESS.md)） |
| 公共面（逐个 R 码与 E 码） | 22 + 12 个码的断言 | 通过 |
| 选项策略与字节输入 | 10 例 | 通过 |
| 命令行冒烟（退出码 0/1/2/3/4/5/70） | 62 项断言，含 `explain` 14 条 | 通过 |
| 差分语料（对照 `jsonrepair` / `json-repair`） | 402 条 | 202 处差异全部有文档解释，未解释 0 |
| 库代码行覆盖率 | 根包 3551/3777 行、`llm` 包 337/391 行 | 94.0% / 86.2% |

三个后端结果一致：wasm-gc、native 与 JavaScript 均为 129 个测试全通过。`.github/workflows/ci.yml`
在每次推送时执行同一组命令（含差分、真值评测与产物体积），因此上表是重新推导出来的结果，
而不是一次性记录。0.4.0 的 `ci.yml` 与 `release.yml` 运行记录见仓库 Actions 页，
`release.yml` 在 `v0.5.0` 标签上产出 [Release `JSONMend v0.5.0`](https://github.com/wenhuang2333/Moonbit-haker/releases/tag/v0.5.0)
（Linux CLI、wasm 探针、演示 bundle、`SHA256SUMS`）。
复现步骤、阈值与两项已知未达标项见 [docs/REPRODUCE.md](docs/REPRODUCE.md)
与 [docs/TRACEABILITY.md](docs/TRACEABILITY.md)。

## 与 jsonrepair 的差异

JSONMend 不是 `jsonrepair` 的移植，也不追求逐字节一致的输出。若干差异是有意为之、且已文档化的策略选择：根值之后的尾随内容默认保留第一个值而不是合并，Markdown 围栏默认去除，重复键默认保留最后一个值，未完成的数字在快照中默认不出现，严格模式与逐规则开关也没有直接对应物。差分工具在手工编写与自动变异的语料上同时运行 `jsonrepair`（TypeScript/Node）与 `json-repair`（Python），比较解析后的值，并对每一处差异分类。0.3.0 与 0.4.0 的改动都没有让这份报告变动一个字节：精确度标签、`R022` 判据与规则编号调整都不改变任何取值。0.4.0 另加了一份**同语料上的并列对照**：1200 条里 JSONMend 的静默错值为 0，`jsonrepair` 为 122、`json_repair` 为 189（`docs/EVAL_REFERENCE.md`）。在 0.4.0 提交的那份差分报告中，202 处差异全部有文档化的成因，没有无法解释的差异。方法与分类结果、参照库版本见 [docs/DIVERGENCES.md](docs/DIVERGENCES.md)；规则与需求的映射见 [docs/TRACEABILITY.md](docs/TRACEABILITY.md)。

## 性能

![字段就绪曲线](../static/readiness-curve.svg)

上图由 `code/tests/readiness_figure.py` 依据 `jsonmend readiness` 的真实输出生成：
左panel是工具调用文档（`name` 188、`arguments` 858、`id` 981，中位数 858/1000），
右panel是 200 个顶层成员的扁平记录的十分位曲线（`0 10 21 30 41 51 61 71 80 90 100`）。
虚线是理想基线（字段在它自己那一段输入读完时就定稿）。这张图替代了上一轮的
「95% 覆盖」指标：后者在对象结构上几乎恒为 95.3%，区分不出好坏。限制同样写在图上——
指标只覆盖**顶层**成员，所以 `arguments` 要等它的容器闭合才就绪，这正是左panel偏离
对角线的唯一原因。

`bench/main.mbt` 覆盖合法 JSON、重度瑕疵 JSON、深层嵌套与超长字符串的一次性修复吞吐，另有仅解析开销、n/2n/4n 扩展性，以及分块大小与快照频率对流式开销的影响：

```sh
moon run bench --target native --release
moon run bench --target js --release
```

在 2026 年的 Apple 芯片笔记本上，native 实测合法 JSON 35–39 MB/s、瑕疵 JSON
72–80 MB/s、单个超长字符串 594 MB/s，js 实测 19–49 MB/s（同机多次观测的中位数，
不同轮次可差 ±15%）。0.4.0 补了**产品场景**的基准：4 KB 工具调用文档按 3 码元分块，
摊还 0.08 µs/feed、36 MB/s，290 000 次 feed 里没有一次达到毫秒时钟分辨率；
按 1 MB 文档口径打开 `collect_deltas` 的代价仍是基线的 **1.40–1.46 倍**（**已知未达标项**，
不是成绩），但这个开销在真实场景（整条流 0.115 ms）里不在关键路径上。
就绪曲线取代了「95% 覆盖」：十分位 `0 10 21 30 41 51 61 71 80 90 100`，
成本约 1.8 ms/KiB（它是测量工具，不是热路径）。

0.5.0 另加了一组「安全层要多少钱」的基准（`bench` 的 `gate` 行）：同一份 4.9 KiB 工具调用、
20 次调用，`analyze` 是 `repair` 的 **1.00–1.03 倍**（66–72 µs/次），
`analyze` + `for_agent` 两道闸 **1.33–1.36 倍**，再加骨架检查 **1.38–1.45 倍**；
`semantic_readiness` 在 `Delta.at` 落地后是 **1.1–1.7 倍**（约 116–170 µs/4.9 KiB）：
时间轴直接取每个 delta 的消费偏移，不再按 1‰ 采样重放。

这些数字是观测值而非承诺：吞吐取决于输入形态、分块大小、快照频率与工具链版本。
内存（12.95 MB 输入实测 177.9 MB，13.7 倍；同机 Node 10.6 倍、Python 14.3 倍，
因此「4 倍」目标本身不现实）与产物大小另行测量。完整方法、表格与决策记录见
[docs/BENCHMARK.md](docs/BENCHMARK.md)，复现步骤见 [docs/REPRODUCE.md](docs/REPRODUCE.md)。

## 已知限制

- **`semantic_readiness` 与 `repair` 同量级但仍是整篇调用。** 约 116–170 µs / 4.9 KiB（`repair` 的 1.1–1.7 倍）：`Delta.at` 折算免掉了重放采样。要放进每次 `feed` 的循环，仍然用增量观察器（`SemanticWatcher` / `FieldTracker`），它不做快照。
- **骨架约束只覆盖值约束子集。** 0.7.0 起支持 `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` / `minLength` / `maxLength` / `enum` / `pattern`（字符类子集），但没有 `$ref` / `oneOf` / `format`（见 `docs/SPEC.md`）。
- **覆盖率最低项在 `llm` 包**：`llm/text.mbt` 66/91 = 72.5%（文本流的错误分支只覆盖一半）；根包最低为 `api.mbt` 86/95 = 90.5%，`plan.mbt` 已达 489/526 = 93.0%。
- **live 演示页只重放四个固定场景。** 它是「同一份数据在两种读法下的对比」演示，不是任意流的通用可视化；浏览器验证在本机用 Playwright 做过，CI 只跑帧级断言。
- **`Options::for_text()` 是预设，不是无树引擎。** 它关掉修复记录与缩进，但值仍然建树；真正的「只出文本」模式（`want_value = false`）仍未实现，见路线图。
- **`FR-16` 事件接口是薄封装。** `feed_with` / `feed_bytes_with` 只是 `drain_deltas` 的迭代器形式，回调在 `feed` 内部运行，因此回调里不能再次喂同一个解析器；它不是独立的推送接口（理由见 [docs/ONEPAGE.md](docs/ONEPAGE.md)）。
- **省略号的判定位于键位与值位之前。** `R020` 处理 `[1,...,3]`、`{"a":1,...}`，键位置的独立 `...` 也会被删除（`{...}` → `{}`，`{"a":...}` → `{}`）；`....`、`..` 与字符串内部的 `...` 不是省略号。
- **残缺字面量前缀会无视后一个字符直接补全。** 例如裸词 `tru` 后跟意外字符时，会先补成 `true`，意外字符另行处理。
- **`incomplete_number` 与 `pending_key` 只影响快照。** 它们不改变 `finish`：最终结果按各自的规则裁剪数字（`R011`）、把悬空键填为 `null`（`R008`）。
- **孤立代理项在不同后端表现不同。** wasm 后端上 `\uD800` 这类孤立代理项会保留在输出中；其他后端走 `InvalidUtf8`（`E040`）路径，替换为 U+FFFD。
- **命令行仅支持 native。** `cmd/jsonmend/moon.pkg` 声明了 `supported_targets = "native"`。
- **修复保证是启发式的，不构成一致性声明。** JSONMend 不是 JSON 标准，也不保证对每种畸形输入都给出唯一解释；差分报告才是其已记录行为的证据。
- **`Json` 数字遵循 core 的表示。** 超大整数在树中可能损失精度，但修复后的文本保留数字原文。
- **`quote_lookahead` 默认关闭。** 开启后，缺少逗号的连续字符串会偏向解释为字符串内容。
- **修复记录受 `max_repairs` 限制（默认 10000 条）。** 超出后仍会继续修复但不再记录，结果把 `repairs_truncated` 置为 `true`，CLI 另向标准错误打印提示。
- **增量补丁流正确但不便宜。** 每次变更都要分配一个 `Delta` 与一份路径数组，1 MB 文档产生约 19.5 万条记录，耗时是基线的 1.40–1.46 倍。在 agent 场景（4 KB、3 码元分块）整条流是 0.115 ms，开销不在关键路径上，因此紧凑缓冲不再是下一步要做的。
- **`--skip-prose` 只能跳过容器根之前的说明文字。** 标量根带前缀文字（`Sure!\n42`）仍会抛 `E002`。
- **内存是输入的 13.7 倍（12.95 MB 输入实测 177.9 MB）。** 同一份输入上 Node `JSON.parse` 是 10.6 倍、Python `json.loads` 是 14.3 倍：**「≤ 4 倍」对任何建树实现都不现实**，包括 Node 自己。要达到只能做「只直出文本、不建树」的模式（`docs/MEMORY.md`）。
- **单次 feed 的 p99 只能给上界。** 运行时 `@env.now()` 是毫秒分辨率、也没有分配计数，所以场景基准报告的是摊还 µs/feed 与「没有一次 feed 达到毫秒分辨率」的计数（`docs/BENCHMARK.md`）。
- **字段就绪曲线只覆盖顶层成员。** 嵌套成员（`{"arguments":{…}}`）要等容器闭合才就绪；曲线成本约 1.8 ms/KiB，且全字段早停的节省在扁平记录上构造性地≈0。
- **文本模式默认不跳前言。** `--skip-prose` 只从 `{` 或 `[` 开始取值，标量根（`0`、`42`、`false`）会被当成前言跳过，所以默认关闭；前言加标量根（`Sure!\n42`）仍会抛 `E002`。
- **JS 后端仍会为每个码元分配一个 `Position`。** n/2n/4n 比值因此会到 2.3–2.8（阈值 2.3）；绝对吞吐远高于 5 MB/s 下限，因此记录为决策而不是立即修。
- **解析器实例非线程安全。** 每个输入流应使用独立实例。

## 路线图

- ~~发布到 mooncakes.io~~：`zhanshishan/jsonmend` 0.3.0 … **0.7.0** 已发布。`1.0.0` **无法**发布——mooncakes 现阶段只接受 `0.x.y`；`0.8.0` 是 `1.1.0` 的 registry 版本，两者除版本字符串外逐字节相同。接入面（`serve`、`mcp`、npm、pip）已在 `1.1.0` / `0.8.0` 发布。
- ~~给浏览器演示页加一个播放「模型流」的标签页~~：`static/demo/live.html` 已落地（四个真实场景逐帧重放，含重试面板），线上地址 <https://wenhuang2333.github.io/Moonbit-haker/live.html>。
- ~~把就绪曲线扩展到「调用方真正需要的字段」~~：`Schema` + `semantic_readiness` 已落地（语法/骨架两层分数）。
- ~~给骨架加约束~~：`minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` / `minLength` / `maxLength` / `enum` / `pattern`（字符类子集，不是正则）已在 0.7.0 落地。
- ~~`--schema` 的约束语言~~：`minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum` / `minLength` / `maxLength` / `enum` / `pattern` 已在 0.7.0 落地（`SPEC.md`）。
- ~~把 `semantic_readiness` 做成增量~~：`Delta.at` 折算已落地（1.1–1.7× `repair`）；流式运行时用 `SemanticWatcher`（1.64–2.00×）。
- 让增量流变便宜：把操作编码进可复用缓冲、共享路径前缀，目标从 1.40–1.46 倍降到 ≤1.11 倍。
  （场景基准显示这不在关键路径上，优先级因此下调。）
- ~~`FR-16` 事件/回调接口~~：已以 `feed_with` 薄封装完成。
- 录制真实 provider 流替换文档转录的事件形状（需要凭据；`tests/record_stream.py` 已就绪）。
- 把就绪曲线扩展到嵌套成员，并给它一个基于增量的零采样实现。
- 增加只直出文本的模式（`want_value = false`）。横向基线表明「4 倍」目标对建树实现不现实（Node 自身 10.6 倍），因此这条路线的前提是先改指标。
- 给浏览器演示页加一个播放录制事件流的标签页，让标签与参数生长不用终端就能看见。
- 把引擎的「当前位置」与「已记录位置」分离，消除 JS 后端的每码元分配。
- 继续扩大差分语料，并为流式路径补内存预算测试。
- 保持 `docs/RULES.md`、`docs/ERRORS.md`、`docs/DIVERGENCES.md`、`docs/BENCHMARK.md` 与 `docs/TRACEABILITY.md` 与代码同步。

## 贡献

- `CONTRIBUTING.md`（随发布交付）覆盖开发环境、测试运行方式、提交规范，以及如何新增修复规则——规则变更必须同时更新 `docs/RULES.md`、`docs/TRACEABILITY.md` 与 golden 测试。
- Issue 模板覆盖缺陷（输入、选项、期望与实际输出、后端）和新规则建议。
- `SECURITY.md`（随发布交付）说明问题上报方式：本库处理的是不可信输入。

## 许可证与致谢

JSONMend 以 Apache License 2.0 发布（`code/moon.mod` 中 `license = "Apache-2.0"`）。`LICENSE`/`NOTICE` 文件属于发布清单。

- [jsonrepair](https://github.com/josdejong/jsonrepair)（TypeScript）与 [json-repair](https://github.com/mangiucugna/json_repair)（Python）在差分报告中作为行为参照。它们仅用于对照，未内嵌任何代码。
- MoonBit 核心库（`moonbitlang/core/json`、`moonbitlang/core/string`）提供 `Json` 类型与字符串处理。

项目一页说明见 [docs/ONEPAGE.md](docs/ONEPAGE.md)。
