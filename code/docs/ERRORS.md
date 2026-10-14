# 错误体系

JSONMend 有两条完全分开的信号通道（ADR-006，规格 D09 9.1）：

- **致命错误**：类型为 `MendError`（`code/error.mbt:211`），通过 `raise` 抛出。一旦抛出，本次调用失败，**不返回任何部分结果**，已经生成的文本全部丢弃；调用方只能捕获错误或让进程退出。
- **修复记录**：类型为 `Repair`（`code/error.mbt:201`），字段为 `code`、`position`、`severity`、`message`。它**永远不是致命错误**，随 `RepairResult` / `ParseResult` / `FinalResult` 一起返回，表示"改了什么、改在哪里、有多严重"。

`MendError` 共 9 个变体，每个变体都有稳定的 `code()` 字符串（`E001` … `E050`）与一行 `to_string()` 诊断。`RepairCode` 共 21 个变体，`code()` 为 `R001` … `R021`，`message()` 为固定英文模板（不含用户输入，避免日志注入，D09 9.7）。本文只记录 9 个致命错误码；修复码的含义见 D09 9.4。

`to_string()` 的格式为 `{code()} {变体名}: {说明}`，`E010` 额外携带位置与触发的修复码。

## 致命错误

### E001 EmptyInput

- `code()`：`E001`
- 载荷：无。
- `to_string()` 模板：`E001 EmptyInput: input is empty or whitespace only`
- 触发条件：`finish` 时从未产生根值，且回卷没有补出任何内容（`code/engine_flow.mbt:1159`）：

  ```moonbit
  if !self.saw_content && !unwound {
    raise EmptyInput
  }
  ```

  即输入为空或只有空白（规格 D09 9.3）。
- CLI 退出码：**3**（输入无效）。
- 示例：输入 `"   "`（三个空格），`to_string()` 输出

  ```text
  E001 EmptyInput: input is empty or whitespace only
  ```

### E002 NoJsonFound

- `code()`：`E002`
- 载荷：`Int32 offset`——第一个非空白码元的位置（`nojson_pos`）。
- `to_string()` 模板：`E002 NoJsonFound: no JSON value found at offset {offset}`
- 触发条件：有内容，但没有任何可识别的 JSON 值。实现中有 5 个抛出点：
  - `code/engine_flow.mbt:206`：根位置遇到无法归类的字符（`}`, `]`, `@`, 围栏、说明文字等）：

    ```moonbit
    raise NoJsonFound(self.nojson_pos.offset)
    ```

  - `code/engine_flow.mbt:928`：根位置的数字形状 token 没有可用前缀：`raise NoJsonFound(start.offset)`
  - `code/engine_flow.mbt:967`：根位置的裸词：`raise NoJsonFound(start.offset)`
  - `code/engine_flow.mbt:1033`：前置阶段的围栏不是三个反引号：`PPrelude => raise NoJsonFound(self.fence_start.offset)`
  - `code/engine_flow.mbt:1162`：`finish` 时没有根值：`raise NoJsonFound(self.nojson_pos.offset)`
- CLI 退出码：**3**（输入无效）。
- 示例：输入 `hello`，`to_string()` 输出

  ```text
  E002 NoJsonFound: no JSON value found at offset 0
  ```

### E010 StrictViolation

- `code()`：`E010`
- 载荷：`RepairCode code`（触发的修复码）、`Position pos`、`String msg`（固定消息模板）。
- `to_string()` 模板：`E010 StrictViolation at {line}:{column} (offset {offset}): {R 码} {R 名称}: {msg}`
- 触发条件：
  - 统一登记入口 `Engine::report`（`code/engine.mbt:276`）：

    ```moonbit
    if self.opts.mode is Strict || !self.opts.rules.is_enabled(code) {
      raise StrictViolation(code, p, code.message())
    }
    ```

  - 策略取 `Error` 时绕过 `report` 直接抛出：`multi_root = AsError`（`code/engine_flow.mbt:78`）、`duplicate_keys = AsError`（`code/engine_flow.mbt:470`）、`non_finite = AsError`（`code/engine_flow.mbt:912`）。
- CLI 退出码：**5**（严格模式违规）。
- 示例：输入 `{"a":1,}`，`mode = Strict`，第一条记录为 `R005@6`，`to_string()` 输出

  ```text
  E010 StrictViolation at 1:7 (offset 6): R005 RemoveExtraComma: extra comma removed
  ```

  多行输入 `{"a":1,\n"b":2,}` 在 Strict 下第一条记录为 `R005@13`，输出

  ```text
  E010 StrictViolation at 2:6 (offset 13): R005 RemoveExtraComma: extra comma removed
  ```

  格式示意（D09 9.7，位置取值与上例无关）：

  ```text
  E010 StrictViolation at 3:14 (offset 27): R005 RemoveExtraComma: extra comma removed
  ```

### E020 DepthLimit

- `code()`：`E020`
- 载荷：`Int32 limit`（上限 `max_depth`）、`Int32 offset`（超限容器起始位置）。
- `to_string()` 模板：`E020 DepthLimit: nesting limit {limit} exceeded at offset {offset}`
- 触发条件：压栈前发现栈深已达上限（`code/engine_flow.mbt:164`）：

  ```moonbit
  if self.stack.length() >= self.opts.max_depth {
    raise DepthLimit(self.opts.max_depth, p.offset)
  }
  ```

- CLI 退出码：**4**（资源限制）。
- 示例：输入 `[[[[1]]]]`，`max_depth = 3`，`to_string()` 输出

  ```text
  E020 DepthLimit: nesting limit 3 exceeded at offset 3
  ```

### E021 SizeLimit

- `code()`：`E021`
- 载荷：`Int32 limit`（上限 `max_input_len`）、`Int32 offset`（第一个超限码元的偏移）。
- `to_string()` 模板：`E021 SizeLimit: input limit {limit} exceeded at offset {offset}`
- 触发条件：处理每个码元前检查累计长度（`code/engine.mbt:304`）：

  ```moonbit
  if self.pos.offset >= self.opts.max_input_len {
    raise SizeLimit(self.opts.max_input_len, self.pos.offset)
  }
  ```

  载荷与分块方式无关（附录 A.6 第 1 条）。
- CLI 退出码：**4**（资源限制）。
- 示例：输入 `[1,2,3,4,5,6]`，`max_input_len = 10`，`to_string()` 输出

  ```text
  E021 SizeLimit: input limit 10 exceeded at offset 10
  ```

### E022 TokenLimit

- `code()`：`E022`
- 载荷：`Int32 limit`（上限 `max_token_len`）、`Int32 offset`（token 起点）。
- `to_string()` 模板：`E022 TokenLimit: token limit {limit} exceeded at offset {offset}`
- 触发条件：字符串 token（`code/engine_flow.mbt:611`）或裸词 token（`code/engine_flow.mbt:805`）的缓冲长度超过上限：

  ```moonbit
  if self.parts_len > self.opts.max_token_len {
    raise TokenLimit(self.opts.max_token_len, self.tok_start.offset)
  }
  ```

- CLI 退出码：**4**（资源限制）。
- 示例：输入 `["abcdef"]`，`max_token_len = 5`，`to_string()` 输出

  ```text
  E022 TokenLimit: token limit 5 exceeded at offset 1
  ```

### E030 InvalidState

- `code()`：`E030`
- 载荷：`String msg`。
- `to_string()` 模板：`E030 InvalidState: {msg}`
- 触发条件：在 `PFinished` 或 `PFailed` 状态下继续调用（生命周期检查）：
  - `code/engine.mbt:293`：`PFinished | PFailed => raise InvalidState("cannot feed a finished parser")`
  - `code/engine_flow.mbt:22`：`PFinished | PFailed => raise InvalidState("no input may be processed after finish")`
  - `code/engine_flow.mbt:1132`：`PFinished | PFailed => raise InvalidState("finish called on a finished parser")`
- CLI 退出码：**70**（内部错误）。
- 示例：`finish` 之后再次 `feed`，`to_string()` 输出

  ```text
  E030 InvalidState: cannot feed a finished parser
  ```

  `finish` 之后再次 `finish`，`to_string()` 输出

  ```text
  E030 InvalidState: finish called on a finished parser
  ```

### E040 InvalidUtf8

- `code()`：`E040`
- 载荷：`Int32 offset`——非法字节的偏移。
- `to_string()` 模板：`E040 InvalidUtf8: invalid UTF-8 byte at offset {offset}`
- 触发条件：字节输入不是合法 UTF-8，或结束时有未完成序列：
  - `code/engine.mbt:360`：非法首字节（不在 `0x00`–`0x7F`、`0xC2`–`0xF4` 内）：`raise InvalidUtf8(idx)`
  - `code/engine.mbt:364`：后续字节不在 `0x80`–`0xBF` 内：`raise InvalidUtf8(idx)`
  - `code/engine.mbt:371`：码点过短或大于 `U+10FFFF`：`raise InvalidUtf8(idx)`
  - `code/engine_flow.mbt:1138`：`finish` 时仍有未完成序列：

    ```moonbit
    if self.utf8_need != 0 {
      self.utf8_need = 0
      raise InvalidUtf8(0)
    }
    ```

- CLI 退出码：**3**（输入无效）。
- 示例：输入字节 `0x41 0xFF`，`to_string()` 输出

  ```text
  E040 InvalidUtf8: invalid UTF-8 byte at offset 1
  ```

  只喂入 `0xC3` 再 `finish`，`to_string()` 输出

  ```text
  E040 InvalidUtf8: invalid UTF-8 byte at offset 0
  ```

### E050 InvalidOption

- `code()`：`E050`
- 载荷：`String msg`。
- `to_string()` 模板：`E050 InvalidOption: {msg}`
- 触发条件：`Options::validate`（`code/options.mbt:224`）中的四条检查：

  ```moonbit
  if self.max_depth <= 0 {
    raise InvalidOption("max_depth must be a positive integer")
  }
  if self.max_input_len <= 0 {
    raise InvalidOption("max_input_len must be a positive integer")
  }
  if self.max_token_len <= 0 {
    raise InvalidOption("max_token_len must be a positive integer")
  }
  if self.indent < 0 {
    raise InvalidOption("indent must not be negative")
  }
  ```

  `PartialParser::new`、`repair`、`parse` 在入口调用 `opts.validate()`（`code/api.mbt:100/157/171`）。
- CLI 退出码：**2**（命令行用法错误）。
- 示例：选项 `max_depth = 0`，`to_string()` 输出

  ```text
  E050 InvalidOption: max_depth must be a positive integer
  ```

## 严格模式升级

严格模式由 `Mode`（`code/options.mbt:5`）选择，`Strict` 与逐条关闭规则走同一条升级路径。

- `Mode::Strict`：把**第一条**修复记录升级为 `E010 StrictViolation`，载荷中的修复码与位置和原本要记录的那条完全相同，说明取 `code.message()`。
- `RuleSet` 关闭某条规则：`RuleSet::disable(code)` 把对应开关置为 `false`，`RuleSet::is_enabled` 返回 `false`。其效果等价于对该码单独启用 Strict（D09 9.5）。
- 两者的实现都在统一登记入口 `Engine::report`（`code/engine.mbt:270`）：

  ```moonbit
  fn Engine::report(
    self : Engine,
    code : RepairCode,
    p : Position,
  ) -> Unit raise MendError {
    if self.opts.mode is Strict || !self.opts.rules.is_enabled(code) {
      raise StrictViolation(code, p, code.message())
    }
    if self.opts.collect_repairs {
      if self.reps.length() < self.opts.max_repairs {
        self.reps.push({
          code,
          position: p,
          severity: code.severity(),
          message: code.message(),
        })
      } else {
        self.repairs_truncated = true
      }
    }
  }
  ```

- 抛出发生在写入 `self.reps` **之前**，所以严格模式下不会留下任何修复记录，也不会返回部分结果。
- `collect_repairs = false` **不会**抑制这条路径：`collect_repairs` 只影响第二次判断（是否追加记录），Strict / 规则开关的判断在它之前。用例 G-252 断言 `{'a':1}` 在 `collect_repairs=false` + `Strict` 下仍抛出 `E010(R003@1)`。
- `duplicate_keys = AsError`、`non_finite = AsError`、`multi_root = AsError` 不经 `report`，而是直接抛 `E010`，载荷里的修复码分别为 `R018`、`R012`、`R016`（`code/engine_flow.mbt:78/470/912`）；这三条不受 `RuleSet` 影响。
- 合法 JSON 输入在任何模式下都不会触发 `E010`。

## 修复记录上限

上限由 `Options.max_repairs` 给出，默认 10000，判断在 `Engine::report` 的第二条分支
（`code/engine.mbt`）：

```moonbit
if self.opts.collect_repairs {
  if self.reps.length() < self.opts.max_repairs {
    self.reps.push({ code, position: p, severity: code.severity(), message: code.message() })
  } else {
    self.repairs_truncated = true
  }
}
```

- 记录数达到上限之后，后续记录被**丢弃**，解析继续正常进行，`finish` 仍然返回文本、值与已收集的记录；此时结果的 `repairs_truncated` 为 `true`，CLI 在 `--report` 下额外打印一行 `jsonmend: repair records truncated at N (raise max_repairs to record more)`。
- `max_repairs <= 0` 由 `Options::validate` 拒绝（`E050`）；CLI 用 `--max-repairs N` 设置。
- 上限只作用于 `self.reps`，不改变解析状态，也不改变任何错误码。
- **Strict 升级不受影响**：`mode is Strict || !rules.is_enabled(code)` 的判断在长度判断之前，所以第 10001 条之后的记录在 Strict 或规则关闭时仍然抛出 `E010`，载荷中的修复码与位置照常。
- `collect_repairs = false` 时任何记录都不写入 `self.reps`（Lenient 下静默修复），也不会把 `repairs_truncated` 置位，这与记录上限是两条独立的分支条件。

## CLI 退出码

来自规格 D09 9.8，与 `code/cmd/jsonmend/main.mbt:60` 的 `error_exit_code` 一一对应：

| 退出码 | 含义 | 对应错误 |
| --- | --- | --- |
| 0 | 成功（可能有修复） | — |
| 1 | `--check` 模式下发现需要修复的内容 | — |
| 2 | 命令行用法错误 | E050 |
| 3 | 输入无效 | E001 E002 E040 |
| 4 | 资源限制 | E020 E021 E022 |
| 5 | 严格模式违规 | E010 |
| 70 | 内部错误 | E030（内部不可达） |

补充说明：

- 退出码 1 由 `--check` 触发：`finish` 成功后若 `fin.repairs.length() > 0` 则 `quit(1)`（`code/cmd/jsonmend/main.mbt:138`）；此时不输出修复文本。
- 参数解析失败（未知选项、`--indent` 越界、`--multi-root` 取值非法等）直接 `quit(2)`，不经过 `MendError`；读文件失败也 `quit(3)`（`code/cmd/jsonmend/main.mbt:116`）。
- 修复后的文本写 **stdout**；`--report` 时把修复记录逐行写 **stderr**，错误信息同样写 stderr。
- `--report` 行格式（`code/cmd/jsonmend/main.mbt:72`）：

  ```text
  {R 码} {行}:{列} {message}
  ```

  例如修复记录 `R005@6`（输入 `{"a":1,}`）打印

  ```text
  R005 1:7 extra comma removed
  ```

  规格 D09 9.8 的示例为 `R005 3:14 trailing comma removed`；实现中 R005 的固定消息是 `extra comma removed`（`code/error.mbt:158`），因此实际输出为 `extra comma removed`。
- 错误信息格式为 `jsonmend: {to_string()}`，随后对**携带偏移**的错误追加两行上下文片段：一行原文，下一行用插入符 `^` 标出列（`snippet`，`code/cmd/jsonmend/main.mbt:16`）。`error_offset`（`code/cmd/jsonmend/main.mbt:49`）只为 `NoJsonFound`、`InvalidUtf8`、`StrictViolation` 返回偏移。示例：

  ```text
  $ printf 'hello' | jsonmend
  jsonmend: E002 NoJsonFound: no JSON value found at offset 0
    hello
    ^
  ```

  流式解析器不保存输入，因此库本身不提供片段，只有 CLI 提供。

## 失效模式

来自规格 D09 9.9，检测点对应到实际代码：

| 失效模式 | 检测点 | 响应 | 用户可见结果 |
| --- | --- | --- | --- |
| 输入过大 | `Engine::step` 开头的累计长度检查 `self.pos.offset >= self.opts.max_input_len`（`code/engine.mbt:304`） | E021 | 无部分结果；CLI 退出码 4 |
| 嵌套过深 | `Engine::enter` 的压栈检查 `self.stack.length() >= self.opts.max_depth`（`code/engine_flow.mbt:164`） | E020 | 同上 |
| 单 token 过长 | `Engine::push_char`（`code/engine_flow.mbt:611`）与 `Engine::push_bare_cu`（`code/engine_flow.mbt:805`）的缓冲长度检查 | E022 | 同上 |
| 非法 UTF-8 | `Engine::feed_byte` 的解码器（`code/engine.mbt:360/364/371`）与 `Engine::finish_engine` 的未完成序列检查（`code/engine_flow.mbt:1136`） | E040 | 同上；CLI 退出码 3 |
| 调用顺序错误 | `Engine::feed_str`（`code/engine.mbt:293`）、`Engine::step_idle`（`code/engine_flow.mbt:22`）、`Engine::finish_engine`（`code/engine_flow.mbt:1132`）的生命周期状态检查 | E030 | 无部分结果；CLI 退出码 70 |
| 内部不变量被破坏（缺陷） | 不可达分支 | 规格要求 E030 且说明中标注 `internal`；当前实现只有上述三处生命周期检查，没有标注 `internal` 的抛出点 | 视为缺陷，由模糊测试捕获 |
| 修复记录过多 | `Engine::report` 的 `self.reps.length() < self.opts.max_repairs`（默认 10000） | 停止追加记录并置 `repairs_truncated`，解析继续，Strict 升级不受影响 | 结果照常返回，记录被截断至 `max_repairs` 条 |
