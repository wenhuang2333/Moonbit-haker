# JSONMend

纯 MoonBit 实现的流式 JSON 修复与部分解析库。

| | |
| --- | --- |
| 模块 | `wenhuang2333/jsonmend` |
| 版本 | 0.3.0 |
| 许可证 | Apache-2.0 |
| 首选后端 | `wasm`（同时支持 `native` 与 `js`） |

## 特性

- **一次性修复**：`repair` 返回修复后的文本、修复记录列表以及输入的完整性。
- **一次性解析**：`parse` 返回修复后的 `Json` 树，以及同样的修复记录。
- **流式部分解析**：`PartialParser` 支持任意分块地 `feed`（或 `feed_bytes`），随时 `snapshot()`，最后 `finish()`。
- **修复记录**：每次修改都带有稳定编号（`R001`…`R022`）、位置（UTF-16 偏移加 1 基的行列号）、严重级别和固定英文消息。
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
moon add wenhuang2333/jsonmend
```

然后在你自己的 `moon.pkg` 中按本文使用的别名导入：

```
import {
  "wenhuang2333/jsonmend" @jsonmend,
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
| `--version` | 显示版本（`jsonmend 0.3.0`）。 |
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
bash tests/cli_smoke.sh        # 36 项命令行断言
bash tests/examples.sh         # 示例输入与 code/examples/cases/*.expected 对照
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/run_eval.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/gen_llm_fixtures.py --check
```

| 测试集 | 规模 | 0.3.0 结果 |
| --- | --- | --- |
| 黄金用例（规范附录 A、B） | 126 条 | 通过 |
| 流式用例（S-001…S-021）与分块不变性 | 21 条 + 不变性检查 | 通过 |
| 精确度标签（TC-X-01） | 18 行手写表 + 240 例属性 | 通过 |
| 增量流重放（TC-DELTA） | 400 + 400 份文档，7 组选项剖面 | 通过 |
| 大模型适配器（TC-LLM） | 9 个夹具 × 双 provider，19 例 | 通过 |
| 真值评测（TC-EVAL） | 1200 条，协议先冻结 | 恢复率 100.00%，漏标 0 |
| 属性与模糊测试（TC-P-01…TC-P-06） | 8 组 × 400 例 | 通过，无反例 |
| 公共面（逐个 R 码与 E 码） | 22 + 10 个码的 9 项断言 | 通过 |
| 选项策略与字节输入 | 10 例 | 通过 |
| 命令行冒烟（退出码 0/1/2/3/4/5/70） | 36 项断言 | 通过 |
| 差分语料（对照 `jsonrepair` / `json-repair`） | 402 条 | 202 处差异全部有文档解释，未解释 0 |
| 库代码行覆盖率 | 根包 1378/1487 行、`llm` 包 223/243 行 | 92.7% / 91.8% |

三个后端结果一致：wasm-gc、native 与 JavaScript 均为 69 个测试全通过。`.github/workflows/ci.yml` 在每次推送时执行同一组命令，因此上表是重新推导出来的结果，而不是一次性记录。
复现步骤、阈值与两项已知未达标项见 [docs/REPRODUCE.md](docs/REPRODUCE.md)
与 [docs/TRACEABILITY.md](docs/TRACEABILITY.md)。

## 与 jsonrepair 的差异

JSONMend 不是 `jsonrepair` 的移植，也不追求逐字节一致的输出。若干差异是有意为之、且已文档化的策略选择：根值之后的尾随内容默认保留第一个值而不是合并，Markdown 围栏默认去除，重复键默认保留最后一个值，未完成的数字在快照中默认不出现，严格模式与逐规则开关也没有直接对应物。差分工具在手工编写与自动变异的语料上同时运行 `jsonrepair`（TypeScript/Node）与 `json-repair`（Python），比较解析后的值，并对每一处差异分类。0.3.0 的改动没有让这份报告变动一个字节：精确度标签与规则编号调整不改变任何取值。在随 0.3.0 提交的那份报告中，202 处差异全部有文档化的成因，没有无法解释的差异。方法与分类结果、参照库版本见 [docs/DIVERGENCES.md](docs/DIVERGENCES.md)；规则与需求的映射见 [docs/TRACEABILITY.md](docs/TRACEABILITY.md)。

## 性能

`bench/main.mbt` 覆盖合法 JSON、重度瑕疵 JSON、深层嵌套与超长字符串的一次性修复吞吐，另有仅解析开销、n/2n/4n 扩展性，以及分块大小与快照频率对流式开销的影响：

```sh
moon run bench --target native --release
moon run bench --target js --release
```

在 2026 年的 Apple 芯片笔记本上，native 实测合法 JSON 41–42 MB/s、瑕疵 JSON
83–87 MB/s、单个超长字符串 594 MB/s，js 实测 22–39 MB/s（同机多次观测的中位数，
不同轮次可差 ±15%）。同一轮还测了两个对流式真正重要的数字：**首个可见值**出现在
文档长度的 0.7% 处（工具调用载荷的中位数），打开 `collect_deltas` 的代价是基线的
**1.39–1.51 倍**——后一个数字是**已知未达标项**，不是成绩。

这些数字是观测值而非承诺：吞吐取决于输入形态、分块大小、快照频率与工具链版本。
内存（17.6–38.0 倍输入，同样未达标）与产物大小另行测量。完整方法、表格与决策记录见
[docs/BENCHMARK.md](docs/BENCHMARK.md)，复现步骤见 [docs/REPRODUCE.md](docs/REPRODUCE.md)。

## 已知限制

- **`FR-16` 事件/回调接口未实现。** `snapshot()` 返回完整深拷贝，开销与树的大小成正比，高频调用时总体代价较大。
- **省略号的判定位于键位与值位之前。** `R020` 处理 `[1,...,3]`、`{"a":1,...}`，键位置的独立 `...` 也会被删除（`{...}` → `{}`，`{"a":...}` → `{}`）；`....`、`..` 与字符串内部的 `...` 不是省略号。
- **残缺字面量前缀会无视后一个字符直接补全。** 例如裸词 `tru` 后跟意外字符时，会先补成 `true`，意外字符另行处理。
- **`incomplete_number` 与 `pending_key` 只影响快照。** 它们不改变 `finish`：最终结果按各自的规则裁剪数字（`R011`）、把悬空键填为 `null`（`R008`）。
- **孤立代理项在不同后端表现不同。** wasm 后端上 `\uD800` 这类孤立代理项会保留在输出中；其他后端走 `InvalidUtf8`（`E040`）路径，替换为 U+FFFD。
- **命令行仅支持 native。** `cmd/jsonmend/moon.pkg` 声明了 `supported_targets = "native"`。
- **修复保证是启发式的，不构成一致性声明。** JSONMend 不是 JSON 标准，也不保证对每种畸形输入都给出唯一解释；差分报告才是其已记录行为的证据。
- **`Json` 数字遵循 core 的表示。** 超大整数在树中可能损失精度，但修复后的文本保留数字原文。
- **`quote_lookahead` 默认关闭。** 开启后，缺少逗号的连续字符串会偏向解释为字符串内容。
- **修复记录受 `max_repairs` 限制（默认 10000 条）。** 超出后仍会继续修复但不再记录，结果把 `repairs_truncated` 置为 `true`，CLI 另向标准错误打印提示。
- **增量补丁流正确但不便宜。** 每次变更都要分配一个 `Delta` 与一份路径数组，1 MB 文档产生约 19.5 万条记录，耗时是基线的 1.39–1.51 倍；紧凑增量缓冲是既定修法。
- **`--skip-prose` 只能跳过容器根之前的说明文字。** 标量根带前缀文字（`Sure!\n42`）仍会抛 `E002`。
- **`DeltaOp::Retract` 从不发出。** 它存在于枚举里以固定契约，默认 `KeepLast` 策略不需要撤回。
- **内存是输入的 17.6–38.0 倍。** 预算是 4 倍；要达到必须做「只直出文本、不建树」的模式。
- **JS 后端仍会为每个码元分配一个 `Position`。** n/2n/4n 比值因此会到 2.3–2.8（阈值 2.3）；绝对吞吐远高于 5 MB/s 下限，因此记录为决策而不是立即修。
- **解析器实例非线程安全。** 每个输入流应使用独立实例。

## 路线图

- 发布到 mooncakes.io（只差一次交互式 `moon login`，其余已就绪）。
- 让增量流变便宜：把操作编码进可复用缓冲、共享路径前缀，目标从 1.39–1.51 倍降到 ≤1.11 倍。
- 增加 `FR-16` 事件/回调接口，让流式消费方不必做全量快照拷贝。
- 增加只直出文本的模式（`want_value = false`），让流式路径达到 4 倍输入的内存预算；当前是 17.6–38.0 倍。
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
