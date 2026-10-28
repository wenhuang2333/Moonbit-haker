# InterJSON

纯 MoonBit 的流式 JSON 修复/部分解析引擎，外加一个本地 MCP 执行门（`interjson mcp`）。

| | |
| --- | --- |
| 模块 | `zhanshishan/interjson` |
| 版本 | 1.5.0 |
| 许可证 | Apache-2.0 |
| 后端 | wasm-gc / native / JS / wasm，同一套测试，各 243/243 通过 |
| 发行渠道 | GitHub `v1.5.0`（8 个产物：三系统四二进制 + wasm 探针 + 浏览器包 + 安装脚本 + `SHA256SUMS`）；[mooncakes](https://mooncakes.io/docs/zhanshishan/interjson) `0.12.0`（2026-10-28 发布）。**npm 与 PyPI 上还没有 `interjson-moonbit`**，两个语言包按仓库路径安装 |

**本页是中文 API 速查**：`Options`、`PartialParser`、`Schema`、修复规则、错误码、快照语义。
项目的 60 秒上手、接入面、证据表与版本映射在[仓库首页](../README.md)；英文完整参考见
[`README.md`](./README.md)（mooncakes 包页渲染的就是它）；MCP 部署见 [`docs/MCP.md`](docs/MCP.md)。

## 安装

```sh
moon add zhanshishan/interjson
```

```text
import {
  "zhanshishan/interjson" @interjson,
}
```

## 三行上手

`repair` 会抛出 `InterJSONError`，因此需要包在 `try`/`catch` 中：

```moonbit
try {
  let result = @interjson.repair("{'a': 1,}")   // RepairResult
  println(result.text)                         // {"a":1}
  println(result.repairs.length())             // 修复记录条数
} catch {
  e => println(e.to_string())
}
```

需要 `Json` 树而不是文本时改用 `@interjson.parse`，它同样返回 `repairs` 与
`completeness`，并额外给出 `value`。需要「能不能执行」的判定时用 `analyze`：

```moonbit
let plan = @interjson.analyze(text,
  options=@interjson.Options::for_agent(),
  schema=@interjson.Schema::parse("{!query:string,!limit:integer}"))
plan.is_executable()   // 唯一需要判断的问题
plan.prompt()          // 不能执行时，直接回灌给模型
plan.to_json()         // decision/exactness/value/retry/repairs
```

`analyze` **永不抛错**：拒绝是返回值的一部分。

## 流式示例

`PartialParser` 接受任意分块，一个分块可以切断任何 token，包括转义序列和代理对。

```moonbit
try {
  let p = @interjson.PartialParser::new()
  p.feed("{\"name\":\"Mo")
  let s1 = p.snapshot()                          // value={"name":"Mo"}, Partial
  p.feed("n\"}")
  let done = p.finish()                          // Complete, {"name":"Mon"}
} catch {
  e => println(e.to_string())
}
```

`feed_bytes` 接收原始 UTF-8 字节，可以和 `feed` 混用；非法或被截断的 UTF-8 会抛出 `E040`。
`snapshot()` 返回 `Snapshot`（`value`、`completeness`、`open_path`），从不抛错也不改动状态；
`finish()` 返回 `FinalResult`（`text`、`value`、`repairs`、`completeness`），只能调用一次。

## 选项

`Options` 的全部字段如下，`@interjson.Options::default()` 即文档化的默认值。

| 字段 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `mode` | `Mode` | `Lenient` | `Lenient` 记录修复；`Strict` 在第一条修复记录处抛出 `E010`。 |
| `max_depth` | `Int32` | `512` | 容器最大嵌套深度，超出抛 `E020`。上限也是默认值，所以只能收紧不能放宽：更大的值报 `E050`（上限与成因见 [`SECURITY.md`](SECURITY.md)）。 |
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
| `rules` | `RuleSet` | `RuleSet::all()` | 逐规则开关；表由 `RepairCode::count()` 定尺寸，越界 fail-closed。 |
| `indent` | `Int32` | `0` | 输出缩进空格数；`0` 表示紧凑输出。 |
| `max_repairs` | `Int32` | `10000` | 最多保留多少条修复记录；超出后仍继续修复，但结果把 `repairs_truncated` 置为 `true`。 |
| `reject_ambiguous` | `Bool` | `false` | 是否拒绝有第二种读法的修复（`E011`）而不是照修；`Options::for_execution()` 会打开它。 |
| `max_loss` | `Exactness` | `Lossy` | 可接受的最大信息损失；记录到更严重的修复时抛 `E010`。`for_execution()` 设为 `Cosmetic`。 |
| `collect_deltas` | `Bool` | `false` | 是否记录增量补丁；与 `KeepFirst`、`TrimToValid` 不兼容。 |

非法取值（`max_depth <= 0` 或超过上限、`max_input_len <= 0`、`max_token_len <= 0`、
`max_repairs <= 0`、`indent < 0`）由 `Options::validate` 抛出 `E050`；`repair`、`parse` 与
`PartialParser::new` 都会替你调用校验。声明（JSON Schema 或骨架语言）超过深度上限报 `E070`。

安全档位 `SafetyPolicy` 五档：`permissive` / `interactive` / `execution` / `agent` / `strict`。
`with_policy` 只换安全字段、保留协议字段；`with_profile` 连该档的协议一起给（`agent` 含
`skip_prose`）；`of_options` 可反查。

## 修复规则一览

每次修改都对应一条编号稳定的记录；含示例与需求映射的完整字典见 `docs/RULES.md`。

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
| `R011` | `FixNumber` | 规范化或裁剪数字。值不变的写法是 `Cosmetic`；残缺指数（`1e`、`1e+`）是 `Lossy`。 |
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
| `R022` | `NormalizeLiteral` | 字面量只是大小写变体（`True`、`FALSE`），词形不变，记为 `Info`。 |

## 修复记录与错误码

修复记录是信息性的，随结果返回；致命错误中止处理，以 `InterJSONError` 抛出。
一条 `Repair` 包含 `code`、`position`、`severity`、`message`；`Position.offset` 从 0 开始按
UTF-16 码元计数，`line` 与 `column` 从 1 开始；消息是固定模板，绝不嵌入用户输入。
精确度标签只由严重级别决定：无记录为 `Exact`，只有 `Info` 为 `Cosmetic`，出现 `Warning` 为
`Lossy`；`max_loss` 在第一条超出上限的记录处抛 `E010`。

| 编号 | 错误 | 触发条件 |
| --- | --- | --- |
| `E001` | `EmptyInput` | 输入为空或只有空白。 |
| `E002` | `NoJsonFound` | 找不到 JSON 值（载荷为偏移量）。 |
| `E010` | `StrictViolation` | 严格模式或已关闭的规则拒绝某次修复，或超出 `max_loss`。 |
| `E011` | `Ambiguous` | 修复有第二种读法，且 `reject_ambiguous` 打开。 |
| `E020` | `DepthLimit` | 嵌套深度超过 `max_depth`。 |
| `E021` | `SizeLimit` | 输入超过 `max_input_len`。 |
| `E022` | `TokenLimit` | 单个 token 超过 `max_token_len`。 |
| `E030` | `InvalidState` | 在 `finish` 之后继续 `feed`，或重复 `finish`。 |
| `E040` | `InvalidUtf8` | `feed_bytes` 遇到非法或截断的 UTF-8（载荷为字节偏移）。 |
| `E050` | `InvalidOption` | 选项取值越界，或选项组合不成立。 |
| `E060` | `InvalidEvent` | `interjson/llm` 收到无法解释的事件负载。 |
| `E070` | `SchemaError` | 骨架声明本身写错，或用了子集之外的键。 |

完整参考见 `docs/ERRORS.md`，规范契约见 [`docs/SPEC.md`](docs/SPEC.md)。

## 快照语义

- **稳定前缀**：已经闭合的值在之后的快照中不再变化，只有最后一个未完成的元素会变。
- **单调性**：快照序列单调增长；`TrimToValid` 会故意破坏未完成数字的单调性（文档化行为）。
- **未完成的数字 / 键**：默认 `Drop` 与 `OmitKey` 下不出现；`TrimToValid` 显示最长合法前缀，
  `NullKey` 把悬空键显示为 `"key": null`。
- **未完成的字符串 / 字面量**：已接收的前缀出现，残缺转义暂缓；`tr` 这类字面量前缀不出现，
  `finish` 时才补全。
- **未闭合的容器**：以已确认的内容呈现，`completeness` 为 `Partial`；`open_path` 用
  `Array[PathSegment]`（`Key(String)` / `Index(Int32)`）指出正在构建的位置。
- 快照与最终结果的差异是有意设计的：`finish` 会闭合容器（`R009`）、补全字符串（`R010`）、
  裁剪数字（`R011`）、补全字面量（`R012`）、把悬空键填为 `null`（`R008`）。

## 命令行

`interjson` 有六个子命令：`repair`（缺省动作）、`explain`（完整分析与拒绝提示，可执行 0 /
拒绝 5）、`readiness`（字段就绪曲线）、`llm`（provider 事件流）、`serve`（版本化 JSONL 协议）、
`mcp`（MCP stdio server）。全部选项、退出码与英文说明见
[`README.md` 的 Command line 一节](./README.md#command-line)；`interjson --help` 打印中文帮助。

```sh
echo "{'a': 1,}" | interjson > fixed.json      # 修复
interjson --check broken.json ; echo $?        # 1 = 需要修复
interjson explain --policy agent --json tool_call.json
```

## 已知限制

- **内存是输入的 13.7 倍**（`repair()`，12.95 MB → 177.9 MB）；4 倍预算对任何建树实现都不现实，
  `--check` 峰值 8.0 倍。要达到 4 倍需要「只出文本、不建树」的模式。
- **增量流是基线的 1.39–1.51 倍**（native），未达到「不低于基线 90%」：每条变更都要分配一个
  `Delta` 与一份路径数组。
- **`max_depth` 只能收紧**；上限与成因见 [`SECURITY.md`](SECURITY.md)。骨架约束是字符类子集，
  不是正则（没有 `$ref`/`oneOf`/`format`）。
- **`semantic_readiness` 与 `repair` 同量级**（1.1–1.7 倍），热路径用 `SemanticWatcher` /
  `FieldTracker`。
- **MCP 是建议性的**：`interjson_gate` 是模型可以调用的工具；强制闸门在宿主侧
  （`PreToolUse` hook、`gate(args)`、`serve` / npm / pip / HTTP）。
- **命令行仅支持 native**；解析器实例非线程安全；`interjson/llm` 与 delta 子包是实验性的。

完整清单（含 1.4.x → 1.5.0 的契约变化）见 [`README.md#known-limitations`](./README.md#known-limitations)。

## 贡献与许可

`CONTRIBUTING.md` 覆盖开发环境、测试与新增规则的流程；`SECURITY.md` 说明漏洞上报渠道。
Apache License 2.0；`jsonrepair`（ISC）与 `json-repair`（MIT）只作为进程外差分参照，
未内嵌任何代码。
