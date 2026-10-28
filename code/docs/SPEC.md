# InterJSON 规范（SPEC）

> **状态**：1.0.0 现行（公开面稳定）。本文件规定 InterJSON 的**公开契约**，不是实现说明。
> 规范性关键词：**必须**（MUST）、**必须不**（MUST NOT）、**应当**（SHOULD）、**可以**（MAY）。
> 每条要求有编号（`SR-n`），测试与评审可以逐条引用。
>
> **不重复的内容**：22 条修复规则的触发条件、级别与消息模板见
> [`RULES.md`](./RULES.md)；需求 → 用例 → 证据的追踪见
> [`TRACEABILITY.md`](./TRACEABILITY.md)；12 个错误码与退出码的完整表见
> [`ERRORS.md`](./ERRORS.md)。本文件只规定这些表之间**必须成立的契约**。

## SR-0　兼容性承诺（1.0.0 起生效）

`pkg.generated.mbti` 是公开 API 的权威清单，它**已经进版本库**，并由 CI 断言与源码一致。
因此「1.0.0 代表 API 冻结」这句话是可验证的，而不只是声明。

**承诺稳定**（1.0.0 之后改动需要 major 版本）：

| 面 | 承诺 |
| --- | --- |
| `pub` API 的签名与语义 | `pkg.generated.mbti` 里的一切；新增是 minor，删除或改签名是 major |
| `explain --json` 的四个字段 | `valid_json` / `normalized` / `ambiguity` / `execution` 的名字与取值域 |
| delta 契约 | `Set` / `Close` / `AppendText` 的顺序与 `pointer()` 的输出格式 |
| 骨架语法 | 0.7.0 的语法全集；**新增**约束是 minor，**改变已有声明的含义**是 major |
| CLI 退出码 | 0/1/2/3/4/5/70 的含义 |
| 就绪口径的**定义** | `settled` / `syntax_at` / `schema_permille` 的含义（`Delta.at` 的单位是 UTF-16 码元） |

**明确不承诺**（可以随 minor 变化，且已写进文档）：

- 任何**性能数字**与内存倍数——它们随机器和版本浮动，`BENCHMARK.md` 是记录不是契约；
- `AppendText` 的**增量粒度**与它的 `at`（它是 drain 时刻的属性，天然依赖分块）；
- 内部文件布局、`code/` 之外的路径、CI 工作流细节；
- `--chunk` 的分块大小对 `AppendText` 的影响。


---

## 1. 范围与总不变量

**SR-1**　规范对象是三个入口：一次性 `repair` / `parse` / `analyze`，流式
`PartialParser`（`feed` / `feed_bytes` / `snapshot` / `finish`），以及把两者包成文件与进程的
`interjson` CLI。任何实现只要满足本文全部要求即为合规实现；本文不规定内部数据结构。

**SR-2**　对任意输入，库**必须**满足三条不变量，且由属性测试强制（`prop_wbtest.mbt`）：

1. **输出合法** —— 修复后的文本一定能被标准 JSON 解析器接受；
2. **幂等** —— 再修一次不再产生任何改动、记录或标签变化（`TC-P-02`）；
3. **分块不变** —— 见 SR-3。

**SR-3**　**分块不变性是硬契约**：同一份输入，一次性喂入与按**任意**切分逐块喂入，
**必须**给出逐字节相同的修复文本、相同的修复记录序列（码、级别、位置、消息）、
相同的精确度标签与相同的错误（含错误码与偏移）。它不因为切分粒度而放宽。

```bash
# 复现：文本、记录、退出码在任意分块下相同
cd code && J=./_build/native/release/build/cmd/interjson/interjson.exe
for n in 1 2 3 7 1000; do
  printf '%s' '{"a":[1,2,{"b":"x y"}],"c":NaN,}' | $J --report          > /tmp/a 2>/tmp/ae
  printf '%s' '{"a":[1,2,{"b":"x y"}],"c":NaN,}' | $J --report --chunk $n > /tmp/b 2>/tmp/be
  diff /tmp/a /tmp/b && diff /tmp/ae /tmp/be      # 必须为空
done
```

**SR-4**　**快照是稳定前缀**：`snapshot()` 给出「目前为止已确定」的值、完整性状态与未闭合路径；
输入继续增长时，已确定的部分**必须不**回退或改变含义。流式调用方据此在文档结束前就开始渲染。

## 2. 增量流（delta）契约

**SR-5**　当 `Options.collect_deltas` 打开时，`drain_deltas()` 返回自上次 drain 以来对当前值的
增量变更，`op ∈ {Set, AppendText, Close}`，路径为 RFC 6901 JSON Pointer。

**SR-6**　**重放契约（必须成立）**：把 `drain_deltas()` 返回的 delta 依次应用到上一次 drain 得到的值上，
结果**必须**与 `snapshot().value` 逐值相同。`delta_wbtest.mbt` 以「重放 == 快照」的形式检查它。

**SR-7**　**时间戳契约**：每个 `Delta` 带 `at : Int32`，含义是**产生该 delta 时已消费的输入码元数**
（UTF-16 code unit）——与 `Position.offset` **同一单位**，库内不存在第二套位置单位。
`Set` 与 `Close` 的 `at` **必须**分块不变；一次喂入 `"{\"a\":1}"` 与逐码元喂入**必须**给出相同的 `at` 序列。

**SR-8**　`AppendText` 是 SR-7 的**显式例外**：文本在 `drain_deltas()` 时成块刷出（否则长字符串要为每个码元付一次路径计算），
因此它的 `at` 记录的是**调用方 drain 的时刻**，其条数与出现时机**依赖切分**。
凡需要时间线的调用方**必须**只读结构 delta（`Set` / `Close`），
**必须不**把 `AppendText` 的 `at` 当作文本位置。

## 3. 三个就绪数字

就绪不是布尔量，而是**输入的比例**，单位是千分比（permille，`0`–`1000`）。
`1000` 一律读作「**在输入结束之前没有发生**」，`-1` 读作「输入无法解析」。

**SR-9**　`syntax_ready`（`syntax_permille`）：文档已经**不再需要任何闭合**的最早输入比例。
它就是「这份文本什么时候已经就是它最终的样子」。`1000` = 直到结束才成立。

**SR-10**　`schema_ready`（`schema_permille`）：声明的**全部必填成员都已出现且已定稿、且类型正确**
（即骨架被满足）的最早输入比例；从未满足过则为 `1000`。
它回答的是「**我现在可以执行了吗**」。

**SR-11**　`settled`（`settled_permille`）：声明的**全部必填成员都已出现且已定稿**的最早输入比例，
**不论类型对不对**；从未发生则为 `1000`。它回答的是「**我现在知道答案了吗**」，
也就是运行时可以据此取消剩余流、甚至提前拒绝的那个时刻。

**SR-12**　三个数在同一个输入上**必须**可以不同，且差异是**信息而不是噪声**。下表**是契约而非示例** ——
它就是 [`产品文档.md`](../../产品文档.md) §20.1 登记的那张表，本规范把它冻结在这里；任何一行被改动都算破坏契约：

| 情形 | `syntax_ready` | `settled` | `schema_ready` | 谁定的 |
| --- | ---: | ---: | ---: | --- |
| 声明的成员类型不对 | 984‰ | **218‰** | 1000‰ | 该成员**自己的值**到达时 |
| 声明的成员在**容器内部**缺失 | 987‰ | **987‰** | 1000‰ | **那个容器的闭合括号** |
| 声明的成员在**根上**缺失 | 980‰ | **1000‰** | 1000‰ | 根闭合括号（对正常文档即输入结束） |

第一行是「错误可以被**提前**报出来」；第二行是「闭合括号决定其内部」；第三行是同一规则在根上的结果 ——
闭合之前，一条还开着的流不能排除模型接着写这个成员，因此根上缺失**必须**记在 `1000‰`。
`settled` 与 `schema_ready` 落在不同桶里，正是 0.5.0 报不出前两行的原因。

```bash
cd code && J=./_build/native/release/build/cmd/interjson/interjson.exe
printf '%s' '{"limit":"ten","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' \
  | $J readiness --schema '{!limit:integer}'          # settled 218/1000, schema-ready 1000/1000
printf '%s' '{"outer":{"pad":"xxxxxxxxxxxxxxxxxxxx"},"tail":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' \
  | $J readiness --schema '{!outer:{!limit:integer},!tail:string}'   # settled 987/1000
printf '%s' '{"outer":{"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}' \
  | $J readiness --schema '{!outer:{!pad:string},!limit:integer}'    # settled 1000/1000
```

**SR-13**　就绪数字**必须不**表达「允不允许执行」。执行与否由 SR-16 的 `execution` 单独回答；
调用方把 `schema_ready = 1000‰` 直接当成放行是**误用**，因为「从未满足过」与「最后一刻满足」都等于 1000‰。

**SR-14**　当 `syntax_ready` 为 `-1`（输入无法解析）时，另外两个数**必须不**被解释为时间点。

## 4. 精确度格（exactness lattice）

**SR-15**　每个结果类型都带 `exactness`，取值构成一个**全序格**：

| 取值 | 秩 | 允许的改动 |
| --- | ---: | --- |
| `Exact` | 0 | 没有做任何改动：输入已经是合法 JSON，记录为空 |
| `Cosmetic` | 1 | 只改**记法**，信息不增不减：引号、逗号、注释、围栏、字面量大小写、空白 |
| `Lossy` | 2 | 发明或丢弃了信息：补 `null`、闭合半个字符串、重复键归一化、多根值取舍 |

数字写法按**值是否改变**分类，而不是按文本是否改变：`+1`→`1`、`01`→`1`、
`1.`→`1`、`.5`→`0.5`、`-01`→`-1` 只改记法，属于 `Cosmetic`；
`1e`/`1e+`→`1` 丢弃了指数，属于 `Lossy`。这条区分由 `R011` 的调用点级别实现。

**SR-16**　`max_loss` 是**执行前的闸门**，不是建议：当结果的 `exactness` 秩**严格大于** `max_loss` 的秩时，
面向执行档的入口**必须**在第一条越界记录处拒绝（`E010`，退出码 5），而不是先执行再报告。
`Options::default()` 的 `max_loss` 是 `Lossy`（默认不拒绝）；`for_execution` / `for_agent` 为 `Cosmetic`。
`--max-loss <exact|cosmetic|lossy>` 是同一个闸门的命令行形式。

**SR-17**　在 `max_loss` 允许范围内，`Exact` 与 `Cosmetic` 的结果**可以**执行；
任何 `Lossy` 结果**必须不**被静默执行 —— 调用方要么显式放宽 `max_loss`，要么把拒绝原因回灌模型。

## 5. 四个字段：语法、归一化、歧义、执行

`analyze` / `explain --json` **必须**同时给出下面四个互相独立的答案：

**SR-18**　`valid_json : Bool` —— **输入本身**是不是合法 JSON（RFC 8259），与 InterJSON 做了什么无关。
口径是「记录为空，或全部记录都是 `R018` 重复键归一化」：在合法的 JSON 上只有 `R018` 会触发，
该口径在 `nst/JSONTestSuite` 的 95 个 `y_` 文件与 188 个 `n_` 文件上验证过。

**SR-19**　`normalized : Bool` —— InterJSON **有没有改写文本**（即记录是否非空）。

**SR-20**　`ambiguity ∈ {none, syntactic, semantic}` —— 前缀是否还有第二种读法：

- `none`：唯一读法；
- `syntactic`：记法有两种读法但**值相同**（如相邻字符串拼接 `["a" "b"]`）；
- `semantic`：**两个值被合成一个**，不同消费者可以不同意（如重复键 `{"a":"b","a":"c"}`）。

**SR-21**　`execution ∈ {allowed, blocked}` —— 当前前缀**能不能直接执行**。

**SR-22**　**本项目的核心原则**：语法合法**不等于**可以执行。
`{"a":"b","a":"c"}` 是合法 JSON，却没有唯一含义；InterJSON 把它归一化、标成 `Lossy`、
报 `ambiguity = "semantic"`，并在执行档下 `execution = "blocked"`（退出码 5）。
`valid_json: true` 与 `execution: "blocked"` 并列出现**必须**是可能的，这正是这条原则的全文。

```bash
cd code && J=./_build/native/release/build/cmd/interjson/interjson.exe
printf '%s' '{"a":"b","a":"c"}' | $J explain --json --policy execution ; echo "exit=$?"
# {"decision":"lossy_repair",...,"valid_json":true,"normalized":true,
#  "ambiguity":"semantic","execution":"blocked",...}   exit=5
```

**SR-23**　`execution = "blocked"` 的结果**应当**同时给出可回灌模型的拒绝原因（`retry.prompt`），
其中包含错误码、位置、一行上下文与一句「重新输出成只有一个读法的合法 JSON」的指令。

## 6. `settled = 1000‰` 的含义

**SR-24**　`settled = 1000‰` **必须**只表示一件事：**必填成员是否定稿，直到输入结束才成为已知**。
它**必须不**按情形改写含义。因此：

- 全部成员都在中途定稿 → 严格小于 1000；
- 必填成员在根上缺失 → 1000（见 SR-12 第三行，根闭合即输入结束）；
- 文档结尾才满足 → 1000。

一个数只有一种含义，优先于两种情形各自最优。若调用方需要知道根闭合发生在何处，
**应当**读事件表里的 `RootInvalid(offset)`，而**必须不**要求 `settled` 换一套语义。

## 7. 骨架声明文法（0.7.0）

**SR-25**　骨架声明是**类型检查 + 值约束**，文法如下（EBNF，空白可以出现在记号之间）：

```ebnf
schema     = kind constraints? | object | array ;
kind       = "any" | "null" | "boolean" | "number" | "integer" | "string" ;
constraints= "(" [ constraint { ("," | ";") constraint } [("," | ";")] ] ")" ;
constraint = name ":" value ;
name       = ASCII 字母，大小写不敏感（见 SR-27）；
object     = "{" [ member { [("," | ";")] member } [("," | ";")] ] "}" ;
member     = [("!" | "?")] key ":" schema ;
array      = "[" schema "]" ;
key        = 裸标识符 | 双引号字符串 ;
```

`!` 表示必填，`?` 表示可选（可选成员不参与 SR-10/SR-11 的就绪时刻）；省略标记等价于 `!`，
但 `stringify()` 总会把标记写回来，因此文本形式只有一个规范拼写。
**约束之间**的 `,` / `;` **必须**写出（末项之后可以有一个）；**成员之间**的 `,` / `;` 可以省略。
成员名重复、括号未闭合、`(` 未闭合都是 `E070`。

**SR-26**　`stringify()` **必须**是 `parse` 的逆：`parse(stringify(s))` 与 `s` 等价，
且含 `:`、空白、引号的成员名**必须**被写回引号形式，使规范拼写唯一。

**SR-27**　约束名（0.7.0 起）与**适用类型**是一张闭合表；把约束写在不接受它的类型上是 `E070`，
**必须不**退化成「永远不触发的规则」：

| 约束 | 适用类型 | 取值 |
| --- | --- | --- |
| `minimum` / `maximum` | `number`、`integer` | JSON 数字（`1`、`-1`、`1.5`、`1e3`） |
| `exclusiveMinimum` / `exclusiveMaximum` | `number`、`integer` | 同上 |
| `minLength` / `maxLength` | `string` | 非负整数（`-1`、`1.5` 是 `E070`） |
| `enum` | 任何类型 | JSON 字面量数组 |
| `pattern` | `string` | 字符类（见 SR-28） |

`enum` 的拼写、转义与数字形式**必须**是 JSON 自己的（`enum:["low","high"]`），不得另立方言。

**SR-28**　`pattern` **必须**是**字符类子集，不是正则表达式**：
`pattern:[a-zA-Z0-9_]` 表示「值的每个字符都属于该类」，前导 `^` 表示取反，
允许 `\ \] \- \^ \n \t \r \d \w \s` 与 `a-z` 形式的区间（区间不可倒置、不可起止于转义），
空类 `[]`、`[^]` 与任何正则语法（`*`、`+`、`?`、`|`、`.`、锚点、分组）都是 `E070`。
本库**必须不**内置正则引擎。

**SR-29**　0.6.x 能解析的声明，0.7.0 **必须**解析成同一个骨架、`stringify()` 写回同一文本、
`accepts` / `evaluate` 行为不变；约束只有在**写出来**时才可见。

**SR-30**　就绪与判定**必须**共用同一个声明：`semantic_readiness` 给的两个数、
`walk_schema` / `evaluate` 的判定、`at_path` 的按路径查询，**必须**来自同一份解析结果，
不得各自解释一遍文本。

**SR-31**　值级约束的违反**必须**在值定稿时即刻可见（进入 `FieldInvalid` / `RootInvalid` 一类的判定），
而不是等到文档结束；这是「值级早拒绝」与 SR-10/SR-11 咬合的地方。

```bash
# 复现：约束在 0.7.0 上逐条生效（退出码 5 = 拒绝执行，2 = E070 声明写错）
cd code && J=./_build/native/release/build/cmd/interjson/interjson.exe
printf '%s' '{"limit":0}'    | $J explain --json --schema '{!limit:integer(minimum:1)}'    ; # 5
printf '%s' '{"s":"abcdef"}' | $J explain --json --schema '{!s:string(maxLength:3)}'      ; # 5
printf '%s' '{"s":"abcD"}'   | $J explain --json --schema '{!s:string(pattern:[a-z])}'    ; # 5
printf '%s' '{"k":"mid"}'    | $J explain --json --schema '{!k:any(enum:["low","high"])}' ; # 5
printf '%s' '{"n":1.5}'      | $J explain --json --schema '{!n:number(exclusiveMaximum:1.5)}' ; # 5
printf '%s' '{"limit":1}'    | $J explain --json --schema '{!limit:integer(maxLength:3)}' ; # 2 E070
printf '%s' '{"s":"a"}'      | $J explain --json --schema '{!s:string(pattern:a+)}'       ; # 2 E070
# 向后兼容：带约束的声明与不带约束的声明都能解析，行为只在写出约束时才不同
printf '%s' '{"a":"x","b":1}' | $J explain --json --schema '{!a:string b:integer}'       ; # 0
```

## 8. 明确不在范围内

**SR-32**　InterJSON **不是** JSON Schema 实现，也不打算成为：
不支持 `$ref`、`oneOf`/`allOf`/`anyOf`、`format`、`if`/`then`、正则表达式。
判定**已完成**的文档是成熟领域；本库的贡献在**流式**这一半。

**SR-33**　恢复策略是启发式的，**不是**任何标准的合规实现；规则级的触发条件以 `RULES.md` 为准。

---

## 附：一条命令跑完全部规范检查

```bash
cd code
moon test                                  # wasm-gc 后端：SR-2/3/5/6/7/8 的属性测试
moon test --target native && moon test --target js
bash tests/cli_smoke.sh                    # SR-12/16/18–24 的命令行断言
python3 tests/eval/run_readiness.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe --check
python3 tests/eval/run_independent.py --cli ./_build/native/release/build/cmd/interjson/interjson.exe --node-dir <node_modules>
```

需求编号与用例的对应关系维护在 [`TRACEABILITY.md`](./TRACEABILITY.md)；
每条规则的详细语义维护在 [`RULES.md`](./RULES.md)。
