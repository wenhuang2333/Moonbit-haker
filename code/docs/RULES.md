# 修复规则

本文件描述 JSONMend 0.6.0 的 22 条修复规则（`R001`–`R022`）。

> **0.6.0 没有新增规则，也没有改变任何规则的触发条件、级别或消息。**
> 0.5.0 把 22 条规则记录翻译成可执行的决策与计划
> （`RuleSet` → `PlanOp` 的 `action` 映射是**全函数**，新增规则必须同时给出动作，
> 否则 `plan_action` 的总性测试会失败），详见 `docs/ONEPAGE.md` 与产品文档 §16。
> 0.6.0 的改动在「安全」这一层：计划新增 `valid_json` / `normalized` / `execution`
> 三个字段，R018 因此在本文件中改写为**重复键规范化**（Q-26）：语义与实现不变，
> 只是把它与「修复非法 JSON」区分开——见 [R018](#r018-重复键合并重复键规范化q-26)。
> 22 个码到动作的映射（`plan_action`，全函数）：
> `remove`（R001、R002、R005、R016、R017、R020、R021）、`wrap`（R004）、
> `insert`（R006、R007、R008、R009、R010）、`replace`（R012、R015）、
> `normalize`（R003、R011、R013、R014、R022）、`merge`（R018、R019）。

规则在**单次从左到右扫描**中即时生效：引擎按 UTF-16 码元推进，遇到可修复的情形立刻登记记录并继续，不回溯、不二次遍历。同一位置可能命中多条规则，此时按本文《规则总览》表的顺序（即规则编号从小到大）依次生效，每条规则各产生一条独立的修复记录。记录数组上限默认 **10000** 条（`Options.max_repairs`），超出后不再记录并把结果的 `repairs_truncated` 置为 `true`（`Strict` 判定与规则开关的检查不受该上限影响）。

位置遵循 BR-20：

- `offset` 以 UTF-16 码元计，从 0 起，相对整个输入（流式调用时为累计偏移）。
- `line`、`column` 从 1 起。`\n`（U+000A）换行并把列重置为 1；`\r`（U+000D）只推进列。
- 插入类修复（R006、R007、R008、R009、R010）指向**插入点**，输入结束时取输入总长度；删除/改写类修复指向**被处理文本的第一个字符**（例如尾逗号指向逗号本身）。

说明：规范 5.6 第 4 条要求同一位置的多条记录按编号从小到大排列，但实现按扫描顺序登记。例如 `{"a` 产生 `R010@3, R008@3, R009@3`（G-095），并非编号顺序，详见末节。

## 规则总览

| 规则 | 名称 | 级别 | 触发条件 | 能在合法 JSON 上触发 |
| --- | --- | --- | --- | --- |
| R001 | StripFence | Info | `strip_fence=true` 且文档前导或根值之后出现三个反引号围栏行 | 否 |
| R002 | StripComment | Info | 字符串外出现 `//` 行注释或 `/* */` 块注释 | 否 |
| R003 | NormalizeQuote | Info | 字符串用单引号或弯引号作界定符；或前瞻判定候选结束引号为内容 | 否 |
| R004 | QuoteBareWord | Info | 裸词既非字面量（前缀）也非数字形态，出现在键位置或容器内的值位置 | 否 |
| R005 | RemoveExtraComma | Info | 尾逗号、前导逗号或连续逗号 | 否 |
| R006 | InsertComma | Info | 容器内两个值/键之间缺少逗号 | 否 |
| R007 | InsertColon | Info | 对象中键之后缺少冒号 | 否 |
| R008 | FillNull | Warning | 对象中有键无值即遇到闭合符、逗号或输入结束；或无合法前缀的数字形态 token | 否 |
| R009 | CloseContainer | Warning | 输入结束时仍有未闭合的数组或对象 | 否 |
| R010 | CloseString | Warning | 输入结束时字符串仍未闭合 | 否 |
| R011 | FixNumber | Warning | 数字形态 token 的规范化结果与原文不同（去 `+`、去前导零、补零、去尾点、去残缺指数） | 否 |
| R012 | ConvertLiteral | Warning | 字面量前缀补全、Python/JS 写法，或 `NaN`/`Infinity` 按 `non_finite` 转换 | 否 |
| R013 | EscapeControl | Info | 字符串内出现未转义的控制字符（码元 < 0x20） | 否 |
| R014 | FixEscape | Warning | 非法转义、残缺 `\u` 序列，或未配对的代理码元 | **是**（†） |
| R015 | MismatchedCloser | Info | 数组遇到 `}`，或对象遇到 `]` | 否 |
| R016 | DropUnexpected | Warning | 当前状态无法识别的内容、非注释的 `/`、以及 `multi_root=KeepFirst` 时根值之后的内容 | 否 |
| R017 | DropExtraCloser | Info | 根值结束后、栈空时出现多余的 `}` 或 `]` | 否 |
| R018 | MergeDuplicateKey | 见下 | 对象中同一个键被赋值两次；两次取值结构相等时为 Info，否则 Warning。这是**重复键规范化**（合法 JSON 的语义歧义），不是修复非法 JSON | **是** |
| R019 | ConcatStrings | Info | 相邻字符串用 `+` 拼接（BR-21） | 否 |
| R020 | DropEllipsis | Warning | 独立的 `...` 裸词占位符 | 否 |
| R021 | SkipProse | Info | `skip_prose=true` 且第一个 `{` 或 `[` 之前存在非空白文字 | 否 |
| R022 | NormalizeLiteral | Info | 字面量**只是 ASCII 大小写变体**（`True`、`FALSE`、`nUll`）：判据是 `ascii_lower(text) == canon`。`None`、`NULL`→`null` 这类**换词**不走这条规则，走 R012 `ConvertLiteral`（Warning，因为补全的是另一个词） | 否 |

† **R014 的边界，就在这一行下面写清楚**：`{"a":"\ud800"}`（孤立高位代理转义）是
**合法 JSON**——`json.loads` 与 `JSON.parse` 都接受它——而 JSONMend 因为要把它替换成
U+FFFD，会登记 R014 并让 `RepairPlan::valid_json` 变成 `false`。也就是说
**`valid_json` 不是「严格解析器接受这个输入」**，而是「这次不需要规范化」；
两者在 R014 的代理分支上分叉。语料里的这类文件是 `i_string_1st_surrogate_but_2nd_missing.json`
与 `i_string_incomplete_surrogates_escape_valid.json`（共 11 个 `i_*` 文件、13 条 R014 记录，`y_*` 里一个都没有），
`code/tests/eval/run_independent.py` 的「Hard criterion」一节把这条**具名残留**打印出来，
而不是留在脚注里。详见下面「能在合法 JSON 上触发」一节的第二条。

“级别”一列取自 `RepairCode::severity()`（0.3.0 起 R015/R017/R021 已按此表降为 Info）。
三个调用点会传入**显式级别**覆盖默认值，除此之外 `severity()` 是唯一来源：
R003 的前瞻分支（Warning）、R004 的值位置（Warning）、R018 的相等判断（Info↔Warning）。
级别是**精确度标签**（`Exactness`）的唯一依据：任一 Warning 记录即 `Lossy`，
只有 Info 记录即 `Cosmetic`，无记录即 `Exact`。详见 [RULES 末节](#级别与精确度标签)。

### “能在合法 JSON 上触发”一列

“合法 JSON”指的是**与 `code/tests/eval/run_independent.py` 同一个严格判据**：`json.loads`
在字节流上成功（`NaN`/`Infinity` 经 `parse_constant` 拒绝），并以 Node `JSON.parse` 交叉
校验。这正是该评估里 `y_*` 文件族的含义，也就是 `run_independent.py` 那条硬性判据
（合法文件上只允许 `R018`）所指的对象。一列的值都以 `code/engine_flow.mbt` 的登记点为
依据，而**不是**以“语料里没见过”为依据：

- **R018**（`MergeDuplicateKey`，`engine_flow.mbt` 的 `assign`：`map.contains(k)` 分支）：
  RFC 8259 允许重复名，所以带重复键的对象是合法 JSON，而默认策略仍会合并并登记。严格判据
  之所以接受它，是因为丢弃是**语义规范化**而不是语法修复。
- **R014**（`FixEscape`）**也是“是”**，这一列在 0.7.0 之前的那份说明里说的是“只有 R018 是”，
  那是错的。R014 有两条分支：非法转义/残缺 `\u`（`\q`、`\x`、截断的 `\u12`）确实是非法
  JSON；但**未配对的代理码元**（`"\ud800"`、`"\udc00"`，或一个高位代理后面直接跟别的
  东西）在 RFC 8259 与两个判据里都是**合法**的——`json.loads` 和 `JSON.parse` 都接受它，
  返回一个含孤立代理的字符串。JSONMend 把孤立代理替换为 U+FFFD（`push_code_point(0xFFFD)`）
  并登记 R014（Warning）。`code/tests/eval/third_party/jsontestsuite` 里这样的文件都归在
  `i_*` 族（11 个文件、13 条记录，例如 `i_string_1st_surrogate_but_2nd_missing.json`），`y_*` 族里
  一个都没有，所以 `run_independent.py` 的硬性判据（只作用于 `y_*`）仍然是绿的。
  复现命令：`python3 test/probe_valid_json_rules.py`（第 1 遍列出 13 个语料文件，
  第 2 遍的 `lone high/low surrogate escape` 两个手写样例）。
- 其余 20 条**否**：每条的前置条件都是严格判据会拒绝的输入——未闭合的容器/字符串
  （R009、R010）、缺失分隔符（R006、R007）、多余逗号（R005）、非 JSON 引号（R003）、
  围栏/注释/说明文字（R001、R002、R021）、裸词与省略号（R004、R020）、字面量大小写变体
  （R022）或补全（R012）、数字写法（R011）、未转义控制字符（R013）、闭合符不匹配或多余
  （R015、R017）、语法上无法安置的内容（R016）、`+` 拼接（R019）——以及 R014 的
  *非法转义* 分支。

### `FieldInvalid` 与 `FieldRejected`：两个「这个字段不对」的区别

0.7.0 起流式裁定（`ReadinessEvent`）把两件事分开，读者最容易在这里混淆：

- `FieldInvalid(path, decl)`：值已定稿，但**类型不对**（wrong kind）——值与声明根本不是一类。
  payload 是**整条声明**（`integer(minimum:0)`），因为要报的是「这里本该是个整数」。
- `FieldRejected(path, expected, got)`：值已定稿，类型正确，但**约束不满足**（constraint violated）
  ——`expected` 是**被违反的那一条约束**（`integer >= 0`、`string with length <= 3`、
  `one of ["low","high"]`、`string of characters in [A-Z]`），`got` 是值的类型。

两者都是裁决（`is_verdict()` 为真），都在**值定稿的那个 delta** 上发出，并同时产生同一偏移的
`RootInvalid`；`settled_permille` / `decided_at_permille` 反映的就是这个偏移。

这一列有一个直接后果，值得写下来而不是藏起来：`RepairPlan::valid_json`
（`code/plan.mbt`，定义为“没有修复记录，或全部是 R018”）在含孤立代理的文档上会报 `false`，
而严格判据说该输入合法。也就是说 `valid_json` 的判据是“**这次需要规范化吗**”，
不是“输入合法吗”，两者在 R014 的代理分支上分叉。判据的适用范围（`y_*`）正是因此写在
`run_independent.py` 里：把硬性判据从 `y_*` 扩大到严格判据接受的**全部**文件，
就会把 R014 也判成误修，而那是一个被有意保留的语义选择，不是缺陷。

## 规则详情

### R001 围栏剥离

- 名称：`StripFence`
- 级别：Info
- 消息：`code fence removed`
- 触发条件：`strip_fence=true`，且在文档前导（prelude）或根值结束之后（epilogue）读到三个连续反引号。围栏行上紧随其后的语言标记（如 `json`）与整行其余内容一并跳过。
- 行为：前导围栏及其语言标记被跳过，换行后继续解析正文；结尾围栏被跳过。每个围栏在**第一个反引号**处产生一条记录。反引号不足三个时，前导位置按 `E002` 处理。
- 金样例：G-010、G-291（`skip_prose=true` 时前导围栏被 prose 吞掉，只记结尾围栏）。

````text
输入：
```json
{"a":1}
```
输出：{"a":1}
记录：R001@0, R001@16
````

### R002 注释删除

- 名称：`StripComment`
- 级别：Info
- 消息：`comment removed`
- 触发条件：字符串外部出现 `/`，且下一个码元是 `/`（行注释，删到行尾）或 `*`（块注释，删到 `*/`）。未闭合的块注释删除到输入末尾。
- 行为：注释内容不进入结果；`/` 后不是 `/` 或 `*` 时不算注释，该 `/` 按 R016 丢弃。记录位置为第一个 `/`。字符串内部的 `//`（如 `http://x`）不处理。
- 金样例：G-040、G-041、G-042、G-043。

```text
输入：[1,/* x */2]
输出：[1,2]
记录：R002@3
```

### R003 引号规范化

- 名称：`NormalizeQuote`
- 级别：Info
- 消息：`quote normalized to double quote`
- 触发条件：字符串以 `'`、`“`、`‘` 之一开始（输出统一为双引号）；或 `quote_lookahead=true` 时，候选结束引号之后的第一个非空白码元既不是 `,`、`}`、`]`、`:`，也不是 `/`，该引号被判为字符串内容。
- 行为：界定符规范化为 `"`，字符串内部的 `"` 在输出中转义；弯引号可作为界定符，其对应的弯引号或直引号均可结束字符串。界定符的记录位置为起始引号；前瞻分支的记录位置为被判为内容的那个引号，且登记级别为 Warning（调用点显式传入，比默认的 Info 更保守）。
- 金样例：G-020、G-021、G-022、G-140。

```text
输入：{'a':'x'}
输出：{"a":"x"}
记录：R003@1, R003@5
```

### R004 裸词加引号

- 名称：`QuoteBareWord`
- 级别：Info（键位置 Info；值位置 Warning）
- 消息：`bare word quoted`
- 触发条件：一个裸词 token 既不是字面量或其前缀，也不是数字形态，出现在对象键位置或容器内的值位置。裸词字符集包含 ASCII 字母、数字、`_`、`$`、`+`、`-`、`.` 以及非 ASCII 的非空白字符，因此 `2024-01-01`、`12abc` 属于裸词。
- 行为：用双引号包裹原文本。键位置记 Info，值位置记 Warning。在根位置（栈空）遇到裸词值不处理，抛 `E002`（BR-07a）。
- 金样例：G-030、G-031、G-240、G-241、G-244、G-245。

```text
输入：{a:1}
输出：{"a":1}
记录：R004@1
```

### R005 多余逗号删除

- 名称：`RemoveExtraComma`
- 级别：Info
- 消息：`extra comma removed`
- 触发条件：在本应出现值或键的位置遇到逗号（前导逗号、连续逗号）；或容器闭合时发现最后一个逗号之后没有任何元素（尾逗号）。
- 行为：逗号被删除。前导/连续逗号在遇到时立即记录；尾逗号在容器闭合（含输入结束时的补闭合）时记录，位置为该逗号的偏移。对象中位于 `...` 占位符之前的逗号不会重复记录。
- 金样例：G-050、G-051、G-055、G-056、G-096、G-160、G-161、G-162。

```text
输入：[1,,2]
输出：[1,2]
记录：R005@3
```

### R006 缺失逗号补全

- 名称：`InsertComma`
- 级别：Info
- 消息：`missing comma inserted`
- 触发条件：数组或对象中已有一个完整元素，随后直接开始下一个值或键，中间没有逗号。
- 行为：在新区段起始处插入逗号，记录位置即该插入点。`multi_root=AsArray` 使用的合成根数组不记录此规则。
- 金样例：G-052、G-053。

```text
输入：[1 2]
输出：[1,2]
记录：R006@3
```

### R007 缺失冒号补全

- 名称：`InsertColon`
- 级别：Info
- 消息：`missing colon inserted`
- 触发条件：对象中已读出键、正等待冒号时，读到一个可开始值的码元（不是 `:`，也不是 `}`、`]`、`,`）。
- 行为：在值起始处插入冒号，记录位置即该插入点。
- 金样例：G-054。

```text
输入：{"a" 1}
输出：{"a":1}
记录：R007@5
```

### R008 缺失值补 null

- 名称：`FillNull`
- 级别：Warning
- 消息：`null filled for missing value`
- 触发条件：对象中已有键但没有值，此时遇到 `}`、`]` 或 `,`，或输入结束；另一种情形是对象值位置出现数字形态但没有任何合法数字前缀的 token（如 `-`、`.`）。
- 行为：为该键补 `null`。容器情形记录位置为触发的闭合符/逗号或输入结束偏移（插入点）；无前缀数字情形记录位置为该 token 的起点。数组中无前缀的数字形态 token 不记 R008，而是记 R011 并丢弃。
- 金样例：G-077、G-093、G-094、G-095。

```text
输入：{"a":
输出：{"a":null}
记录：R008@5, R009@5
```

### R009 容器补全

- 名称：`CloseContainer`
- 级别：Warning
- 消息：`unclosed container closed`
- 触发条件：输入结束时栈中仍有未闭合的数组或对象。
- 行为：自内向外逐个补闭合符，每个未闭合容器一条记录，位置均为输入结束偏移（插入点）。若闭合前存在尾逗号，会先在该逗号处记一条 R005。
- 金样例：G-090、G-091、G-092、G-093、G-094、G-095、G-096、G-097、G-098、G-101、G-102、G-208。

```text
输入：{"a":[1,2
输出：{"a":[1,2]}
记录：R009@9, R009@9
```

### R010 字符串补全

- 名称：`CloseString`
- 级别：Warning
- 消息：`unclosed string closed`
- 触发条件：输入结束时字符串 token 仍处于打开状态（键或值均可）。
- 行为：补上结束引号，记录位置为输入结束偏移（插入点）。若字符串以残缺的 `\u` 或落单的反斜杠结束，先在该反斜杠处记一条 R014；若以未配对的代理码元结束，先记 R014。
- 金样例：G-091、G-095、G-099。

```text
输入："abc
输出："abc"
记录：R010@4
```

### R011 数字规范化

- 名称：`FixNumber`
- 级别：Warning
- 消息：`number normalized or trimmed`
- 触发条件：数字形态的裸词 token，其规范化写法与原文不同：去掉前导 `+`、去掉前导零、`.5` 补为 `0.5`、去掉裸露的尾点、丢弃残缺指数；或数组中出现无任何合法前缀的数字形态 token。
- 行为：输出规范化后的数字，记录位置为 token 起点。有效数字不被改动：`-0`、`1e5`、`1E+5`、`1.5e-3`、超出双精度的大整数均按原文保留且无记录。无前缀 token 在数组中记 R011 并被丢弃（`[-,1]` → `[1]`），在对象中记 R008 并补 `null`，在根位置抛 `E002`。
- 金样例：G-070、G-071、G-072、G-073、G-074、G-075、G-076、G-078。

```text
输入：[+1,.5,5.,007]
输出：[1,0.5,5,7]
记录：R011@1, R011@4, R011@7, R011@10
```

### R012 字面量转换

- 名称：`ConvertLiteral`
- 级别：Warning
- 消息：`literal converted or completed`
- 触发条件：裸词 token 经小写化后是 `true`、`false`、`null` 之一，或是它们的任意前缀，或是 `none`、`undefined`（含前缀，包括 `None` 这种换词）；或 token 为 `NaN`、`Infinity`、`-Infinity`。**只有「与规范写法只差 ASCII 大小写」的 token（`True`、`FALSE`、`nUll`）走 R022，不记 R012。**
- 行为：转换为标准字面量或 `null`；已是精确标准写法时不记录。字面量前缀一律补全为唯一匹配的字面量，与后继字符无关。非有限值按 `non_finite` 处理：`AsNull` 转 `null`，`AsString` 转为含原文的字符串，`AsError` 抛 `E010(R012@…)`。记录位置为 token 起点。
- 金样例：G-060、G-061、G-062、G-063、G-064、G-065、G-092、G-100、G-101。

```text
输入：[True,False,None]
输出：[true,false,null]
记录：R012@1, R012@6, R012@12
```

### R013 控制字符转义

- 名称：`EscapeControl`
- 级别：Info
- 消息：`control character escaped`
- 触发条件：字符串内部出现未转义的码元，其值小于 0x20（换行、制表符、NUL 等）。
- 行为：内容保留，输出端重新编码（`\n`、`\t`、`\u0000` 等），记录位置为该控制字符。（调用点把它记为 Warning：解码后控制字符保留在取值中，但输入里那个码元确实是非法 JSON，保守起见仍按信息损失处理。）
- 金样例：G-080、G-087。

```text
输入：{"a":"x<LF>y"}   （引号内是真实换行 U+000A）
输出：{"a":"x\ny"}
记录：R013@7
```

### R014 非法转义修正

- 名称：`FixEscape`
- 级别：Warning
- 消息：`invalid escape repaired`
- 触发条件：三种情形之一。其一，`\` 后跟非法转义字符（如 `\q`、`\'`）；其二，`\u` 之后不足四位十六进制就遇到非十六进制字符或输入结束；其三，出现未配对的代理码元，无论是原文中的孤立码元还是 `\uXXXX` 转义产生的孤立码元。
- 行为：非法转义去掉反斜杠、保留后续字符；残缺 `\u` 序列整体丢弃；孤立代理码元替换为 U+FFFD。记录位置为转义的反斜杠（孤立转义码元同样取反斜杠），原文中的孤立码元取该码元本身。合法的 `\u00e9`、`\/` 会被重新编码为规范写法但不记录。
- 金样例：G-081、G-082、G-083、G-084、G-085、G-220、G-221、G-222、G-224、G-225。
- **能在合法 JSON 上触发（是：R014 是第二条这样的规则，见「†」脚注）**：第三种情形
  （未配对的代理码元）在 RFC 8259 下是**合法**的，两个严格判据也都接受：
  `{"a":"\ud800"}` 会被 `json.loads` 与 `JSON.parse` 接受，返回一个含孤立代理的字符串；
  JSONMend 把它替换为 U+FFFD 并登记 R014（Warning），于是 `RepairPlan::valid_json` 为 `false`。
  即 `valid_json` 的判据是「这次需要规范化吗」，不是「严格解析器接受这个输入吗」。
  反例语料：11 个 `i_*` 文件（13 条 R014 记录；`i_string_1st_surrogate_but_2nd_missing.json`、
  `i_string_incomplete_surrogates_escape_valid.json` …），`y_*` 族里没有；
  复现：`python3 test/probe_valid_json_rules.py`。前两种情形（非法转义、残缺 `\u`）
  不是合法 JSON。

```text
输入：["\u12g"]
输出：["g"]
记录：R014@2
```

### R015 闭合符不匹配

- 名称：`MismatchedCloser`
- 级别：Info（0.3.0 起。替换闭合符只改记法，不复制也不丢弃任何取值）
- 消息：`mismatched closer replaced`
- 触发条件：栈顶为数组时读到 `}`，或栈顶为对象时读到 `]`。
- 行为：按栈顶容器类型当作正确的闭合符处理，记录位置为该闭合符本身。
- 金样例：G-110、G-111。

```text
输入：[1,2}
输出：[1,2]
记录：R015@4
```

### R016 意外内容丢弃

- 名称：`DropUnexpected`
- 级别：Warning
- 消息：`unexpected content dropped`
- 触发条件：当前容器状态下无法识别为值、键、逗号或闭合符的内容（如 `@`、`#`、数组中的裸代理码元）；`/` 后不是 `/` 或 `*`；`multi_root=KeepFirst` 时根值结束之后出现的非空白内容；闭合围栏之后的剩余内容。
- 行为：丢弃该内容。记录位置为被丢弃内容的第一个字符（`/` 情形取该斜杠）。根值之后的尾随内容只记第一条，其后内容静默丢弃。`multi_root=AsArray` 时后续根值被聚合而不记 R016；`multi_root=AsError` 时抛 `E010(R016@…)`。
- 金样例：G-120、G-226、G-230、G-232、G-280。

```text
输入：{"a":1} xyz
输出：{"a":1}
记录：R016@8
```

### R017 多余闭合符丢弃

- 名称：`DropExtraCloser`
- 级别：Info（0.3.0 起。被丢弃的闭合符后面没有任何取值）
- 消息：`extra closer dropped`
- 触发条件：根值已经结束、栈为空，此时出现 `}` 或 `]`，且 `multi_root` 不是 `AsError`。
- 行为：丢弃该闭合符，记录位置为该闭合符。`multi_root=AsError` 时改抛 `E010(R016@…)`。
- 金样例：G-112。

```text
输入：{"a":1}}}
输出：{"a":1}
记录：R017@7, R017@8
```

### R018 重复键合并（重复键规范化，Q-26）

- 名称：`MergeDuplicateKey`
- 级别：默认 `Warning`；仅当两次取值**结构相等**时降为 `Info`。`error.mbt` 的 `RepairCode::severity()` 对 R018 返回 `Warning`（它只把记号类规则列为 `Info`），引擎在记录时用 `json_equal(kept, v)` 覆盖：相等给 `Info`，否则给 `Warning`（`engine_flow.mbt` 的 R018 分支）。
- 消息：`duplicate key merged`
- 动作：`merge`（`plan.mbt` 的 `plan_action`：`MergeDuplicateKey => Merge`）。不是 `remove`、`replace` 或 `normalize`；计划 JSON 里的 `action` 就是 `merge`。
- 触发条件：对象中同一个键被第二次赋值。
- 行为：按 `duplicate_keys` 处理：`KeepLast`（默认）以后一个值覆盖并记录；`KeepFirst` 保留第一个值并记录；`AsError` 抛 `E010(R018@…)`。记录位置为后一次出现的键的起始位置。
- 金样例：G-032、G-033、G-034、G-270、G-271。

**这是「重复键规范化」，不是「修复非法 JSON」。** RFC 8259 允许对象里出现重复名，并把「哪一个胜出」留给消费者；`{"a":"b","a":"c"}` 是**语法合法**的 JSON，读它不需要修任何语法错误。R018 记录的是 JSONMend 替调用方做的一次**语义决定**：两个值只剩一个。这就是它的默认级别是 `Warning`（信息丢失）而不是 `Info`（记号规范化）的原因，也是同一份输入上 `valid_json=true` 与 `exactness=lossy` 同时为真的原因——`valid_json` 回答「输入本来是不是合法 JSON」，`exactness` 回答「输出丢了没有」，是两个问题。

于是 `{"a":"b","a":"c"}` 在 `--for-execution`（等于 `--max-loss cosmetic --reject-ambiguous`）下被拒绝，退出码 5，`E010`：

```text
jsonmend: E010 StrictViolation at 1:10 (offset 9): R018 MergeDuplicateKey: exactness lossy exceeds max_loss cosmetic
```

决策为 `lossy_repair`、`execution=blocked`：**语法合法不等于执行安全**。反过来，`{"a":1,"a":1}` 合并两个结构相等的值不丢信息，级别是 `Info`、`exactness=cosmetic`、`ambiguity=none`、`execution=allowed`，可以执行。

> JSONMend does not confuse syntactic validity with execution safety.

```text
输入：{"a":"b","a":"c"}      # 合法 JSON，但合并会丢一个值
输出：{"a":"c"}
记录：R018@9  severity=warning action=merge information_loss=true
     → decision=lossy_repair exactness=lossy valid_json=true normalized=true execution=blocked
```

```text
输入：{"a":1,"a":1}          # 合法 JSON，两个值相等，合并不丢信息
输出：{"a":1}
记录：R018@7  severity=info action=merge information_loss=false
     → decision=cosmetic_repair exactness=cosmetic valid_json=true normalized=true execution=allowed
```

### R019 字符串拼接

- 名称：`ConcatStrings`
- 级别：Info
- 消息：`string concatenation merged`
- 触发条件：相邻字符串之间用 `+` 连接（BR-21）。
- 行为：值位置已经得到一个字符串之后，紧跟的 `+` 被吞掉，随后的字符串**并入前一个字符串**而不是作为新元素；记录位置为 `+` 本身。合并发生在数组元素、对象属性值以及根值三种位置上：`["a" + "b"]` → `["ab"]`，`{"k":"a" + "b"}` → `{"k":"ab"}`，`"a" + "b"` → `"ab"`。连续拼接会逐次记录：`["a"+"b"+"c"]` → `["abc"]`，两条 R019。
- 只有前一个值是字符串、且下一个 token 是字符串时才合并。否则 `+` 按普通意外内容丢弃（R016），值照常单独成立：`["a" + 1]` → `["a",1]`（R016@5、R006@7），`[1 + "b"]` → `[1,"b"]`（R006、R011、R006）。行尾悬空的 `+` 同样只产生 R016：`["a" +]` → `["a"]`。
- 金样例：G-300、G-300b…G-300e。

```text
输入：["a" + "b"]
输出：["ab"]
记录：R019@5
```

### R020 省略号删除

- 名称：`DropEllipsis`
- 级别：Warning（占位符代表一个未知取值，丢弃它确实损失了信息）
- 消息：`ellipsis placeholder dropped`
- 触发条件：出现独立的 `...` 裸词 token，占位一个值（BR-21）。
- 行为：丢弃该占位符并视为该值槽已处理，因此不会连带产生缺失逗号等记录。记录位置为第一个 `.`。`....`、`..` 不是省略号，会走 R004 被加引号。实现中该判定位于键/值分支之前，故键位置的独立 `...`（如 `{...}`）也会命中 R020。
- 金样例：G-301、G-302、G-303。

```text
输入：[1,...,3]
输出：[1,3]
记录：R020@3
```

### R021 前置说明跳过

- 名称：`SkipProse`
- 级别：Info（0.3.0 起。被跳过的文字不是任何取值的一部分）
- 消息：`leading prose skipped`
- 触发条件：`skip_prose=true`，且第一个 `{` 或 `[` 之前存在非空白字符。
- 行为：丢弃第一个 `{` 或 `[` 之前的全部文字，记录位置为第一个非空白字符。开启后 `strip_fence` 的分支不再执行，前导围栏会被当作 prose 一起吞掉，因此只有结尾围栏产生 R001（G-291）。若整个输入都找不到 `{` 或 `[`，抛 `E002`（G-290）。首个非空白字符就是 `{`/`[` 时不记录。
- 金样例：G-011、G-290、G-291。

```text
输入：Here: {"a":1}
输出：{"a":1}
记录：R021@0
```

## 选项相关行为

所有选项由 `code/options.mbt` 的 `Options` 定义，默认值取自 `Options::default()`。`PartialParser::new`、`repair`、`parse` 都会先调用 `Options::validate()`：`max_depth`、`max_input_len`、`max_token_len` 必须为正，`indent` 不得为负，否则抛 `E050 InvalidOption`。

| 字段 | 类型 | 默认值 | 作用 |
| --- | --- | --- | --- |
| `mode` | `Mode` | `Lenient` | `Strict` 时任何本应登记记录的情形改为抛 `E010`，载荷携带触发的 R 码与位置；合法输入在任何模式下都不触发。 |
| `duplicate_keys` | `DuplicateKeys` | `KeepLast` | 重复键策略：`KeepLast` 覆盖、`KeepFirst` 保留首个、`AsError` 抛 `E010(R018)`；前两者各记一条 R018。 |
| `incomplete_number` | `IncompleteNumber` | `Drop` | 只影响快照：`Drop` 时未结束的数字不出现在 `snapshot()` 中，`TrimToValid` 时显示最长合法前缀（会破坏快照单调性）；`finish()` 一律裁剪到合法前缀。 |
| `pending_key` | `PendingKey` | `OmitKey` | 只影响快照：已有冒号但无值时，`OmitKey` 省略该键，`NullKey` 补 `null`；`finish()` 一律补 `null`（R008）。 |
| `non_finite` | `NonFinite` | `AsNull` | `NaN`、`Infinity`、`-Infinity` 的转换策略：`AsNull` 转 `null`、`AsString` 转为字符串原文、`AsError` 抛 `E010(R012)`；前两者各记一条 R012。 |
| `multi_root` | `MultiRoot` | `KeepFirst` | 根值之后内容的策略：`KeepFirst` 丢弃并记一条 R016、`AsArray` 聚合为数组（不记记录）、`AsError` 抛 `E010(R016)`。 |
| `strip_fence` | `Bool` | `true` | 是否剥离首尾代码围栏（R001）。关闭时前导围栏不识别，直接抛 `E002`。 |
| `skip_prose` | `Bool` | `false` | 是否丢弃第一个 `{`/`[` 之前的文字（R021）。开启后前导围栏也被当作 prose 吞掉。 |
| `quote_lookahead` | `Bool` | `false` | 是否对候选结束引号做前瞻：后继首个非空白字符不是 `,`、`}`、`]`、`:`、`/` 时把该引号判为内容并记 R003（Warning）。 |
| `collect_repairs` | `Bool` | `true` | 是否保存修复记录。关闭时记录列表为空，但 `Strict` 模式与规则关闭导致的 `E010` 仍然生效。 |
| `want_text` | `Bool` | `true` | 关闭时 `finish()`/`repair()` 返回的 `text` 为空串，`value` 仍完整。 |
| `indent` | `Int32` | `0` | 大于 0 时按该空格数缩进输出，`0` 时紧凑输出；负值抛 `E050`。 |
| `rules` | `RuleSet` | `RuleSet::all()` | 逐条规则开关。关闭某码后，该情形按该码单独启用 Strict 处理，即抛 `E010`。内部为长度 22 的布尔数组，用 `RepairCode::number()`（1–21）索引，索引 0 未使用。 |
| `max_depth` | `Int32` | `512` | 容器嵌套深度上限。进入第 `max_depth + 1` 层时抛 `E020(limit, offset)`；深度恰为上限时允许。 |
| `max_input_len` | `Int32` | `67108864` | 累计输入长度上限（UTF-16 码元）。处理到第 `max_input_len + 1` 个码元时抛 `E021(limit, offset)`，与分块方式无关。 |
| `max_token_len` | `Int32` | `16777216` | 单个字符串或裸词的长度上限（码元）。超出时抛 `E022(limit, token 起点)`。 |
| `max_repairs` | `Int32` | `10000` | 修复记录条数上限。达到上限后不再追加记录，并把结果里的 `repairs_truncated` 置为 `true`（CLI 会向 stderr 提示）；必须是正整数，否则抛 `E050`。 |

资源限制类错误（`E020`、`E021`、`E022`）为致命错误，不返回部分结果。

## 未实现或有意保留的规则

- **只有独立的 `...` 会被当作省略号丢弃。** `....`、`..` 以及字符串内部的 `...` 都不命中 R020，前者会走 R004 被加引号。需要说明的是：实现中该判定位于键/值分支之前，因此键位置的独立 `...`（如 `{...}` → `{}`，R020@1）同样会被删除，与“只在值位置”的表述不完全一致。
- **截断的字面量前缀一律补全。** 只要 token 是 `true`/`false`/`null`/`none`/`undefined` 的前缀，就在 token 结束时补全为唯一匹配的字面量，与紧随其后的字符无关：`[tru,1]` → `[true,1]`（R012@1），`{"a":nul}` → `{"a":null}`。只有既非字面量前缀也非数字形态的裸词才走 R004。
- **`incomplete_number` 与 `pending_key` 只影响快照。** 两者仅在 `snapshot()` 的取值路径中使用；`finish()`/`repair()` 的最终结果与它们无关：未结束的数字总是裁剪到最长合法前缀（R011），悬空键总是补 `null`（R008）。

### R022 字面量大小写规范化

- 名称：`NormalizeLiteral`
- 级别：Info
- 消息：`literal re-cased`
- 触发条件：裸词 token 经小写化后是 `true`、`false`、`null` 之一，且**原文与规范写法只差 ASCII 大小写**（`ascii_lower(text) == 规范写法`）。
- 行为：输出规范写法，记录位置为 token 起点。与 R012 的区别：R012 是「补全或换词」（`tru` → `true`、`nul` → `null`、`undefined` → `null`、`None` → `null`），必然引入原文没有的词形，因此是 Warning；R022 只是重新大小写，词形不变，因此是 Info。
- **判据曾是「长度相同」，0.4.0 改为「只差 ASCII 大小写」**：`None`（4 码元）与 `null`（4 码元）长度相同，旧判据把它当成大小写变体，标为 `cosmetic`——这是错的，因为 `None` 是另一个词。该问题由对抗语料 `amb-1` 首次运行时发现（见 `docs/EVAL_REGISTRATION.md` §11）。受影响的是 G-060 的 `None` 一项：现在报 `R012@12`，`Exactness` 为 `lossy`。
- 金样例：G-065（`[TRUE,Null]`）、G-060（`[True,False]` 部分；`None` 一项现在走 R012）。

```text
输入：[True,FALSE,nUll]
输出：[true,false,null]
记录：R022@1, R022@6, R022@12
```

## 新增一条规则时的检查清单（0.7.0 起）

新增、拆分或改变一条规则时，下面每一项都要**在同一个改动里**处理，任一项缺失都视为改动不完整：

1. **动作映射**：`plan_action` 是全函数，新规则必须同时给出 `RuleSet` → `PlanOp::action`
   的映射，否则 `plan_action` 的总性测试会失败（见文件开头与 `docs/ONEPAGE.md`）。
2. **级别**：在 `RepairCode::severity()` 里给出默认级别；若某个调用点要用显式级别覆盖，
   必须在《规则总览》的“级别”说明里点名。
3. **本文档**：《规则总览》表新增一行（含“能在合法 JSON 上触发”一列）＋
   《规则详情》一节（名称/级别/消息/触发条件/行为/金样例）＋ 一段可直接运行的金样例。
4. **“能在合法 JSON 上触发”一列必须给出代码依据**：指向 `code/engine_flow.mbt` 里的
   登记点，并说明该前置条件是否被严格判据接受；不能只写“语料里没见过”。
5. **跑一遍反例探针**：`python3 test/probe_valid_json_rules.py`。若新规则能在严格判据
   接受的输入上触发，则必须同时修改 `code/tests/eval/run_independent.py` 的
   `Y_ALLOWED_RULE_CODES`，并在本文档里说明这是**有意的语义规范化**还是**误修**；
   若 `Y_ALLOWED_RULE_CODES` 变了，第 3 步的那一列也要同步改。
6. **位置**：记录位置遵守 BR-20（插入类指向插入点，删除/改写类指向被处理文本的第一个字符）。
7. **四个后端**：`moon test --target all` 绿（wasm / wasm-gc / js / native），
   `moon check --deny-warn` 与 `moon fmt --check` 干净。

## 已知不一致

本节记录实现与规范文本之间仍然存在的差异，均已由测试固定，不做隐藏。

| 项 | 代码实际行为 | 规范 / 声明 | 说明 |
| --- | --- | --- | --- |
| 同位置记录顺序 | 按扫描（因果）顺序 | 规范 5.6 第 4 条要求按编号从小到大 | G-095 为 `R010@3, R008@3, R009@3`：必须先闭合字符串、再补 null、最后闭合容器，编号顺序会给出不可执行的动作序列。 |
| `...` 的判定位置 | 键位与值位都删除 | 规范表述为“数组或对象中的占位” | `{...}` → `{}`，R020@1；`{"a":...}` → `{}`，键位占位连同键一起丢弃。 |
| 记录上限 | 默认 10000，可用 `max_repairs` 调整；超出时置 `repairs_truncated` | 规范未规定上限 | BR-19 只要求“一次修改一条记录”；上限用于约束病态输入下的内存占用，Strict 升级不受影响。超出后调用方可从 `repairs_truncated` 得知记录被截断。 |
| `RuleSet::all()` | 分配 23 个标志位，下标 0 未使用 | — | 下标直接使用 `RepairCode::number()`（1–22），实现上最简单。 |

## 级别与精确度标签

级别不是日志装饰，而是 `Exactness` 的唯一来源：`Engine::report` 记下级别时同步
抬高引擎的精确度水位（`Info → Cosmetic`，`Warning → Lossy`），`finish()` 把它带给调用方。
`Options::max_loss` 在**第一条**超出上限的记录处就抛 `E010`，错误消息里带着那条修复码，
因此「先修完再判断能不能执行」可以变成「修的同时就拒绝」。

调用点显式传入级别的地方只有三处，都有明确理由：

| 位置 | 默认 | 实际 | 理由 |
|------|------|------|------|
| R003 引号前瞻 | Info | Warning | 被判为内容的前导引号可能是字符串的**结束**引号，此时多出的字符进入了取值 |
| R004 值位置 | Info（键位置） | Warning | 给一个裸词加引号会把它变成一个取值，属于发明 |
| R018 重复键 | Warning | Info / Warning | 两次取值结构相等时不丢信息，不等时才丢 |

0.1.0 之前各调用点各自传级别、与 `severity()` 表不一致；0.2.0 统一到
`severity_in(code, slot)`；0.3.0 在实测（`docs/EVAL.md`）发现 300/900 条记法类修复
被误标为 `lossy` 后，把 R015/R017/R021 降为 Info、新增 R022、
并允许上述三处显式覆盖。
