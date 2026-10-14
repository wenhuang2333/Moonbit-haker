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
| 规则与错误 | `code/error.mbt` | 21 条修复规则（R001–R021）、9 个致命错误码（E001–E050） |
| 选项 | `code/options.mbt` | 严格模式、重复键、未完成数字、非有限值、多根值、规则开关、资源上限 |
| CLI | `code/cmd/jsonmend/` | stdin/文件、`--report`、`--check`、`--strict`、`--indent`、`--multi-root` |
| 基准 | `code/bench/` | 吞吐、线性、流式、产物体积 |

## 证据

| 项 | 结果 |
| --- | --- |
| 黄金用例 | 115 条（规范附录 A、B）全部通过 |
| 流式用例 | 20 条（S-001…S-020）+ 分块不变性（逐码元 / 二分 / 1 KB 分块） |
| 属性与模糊 | 8 组 × 400 例，含 200 000 例压测；未发现反例 |
| 公共面与选项 | 21 个 R 码 + 9 个 E 码逐一检查；策略枚举、规则开关、字节输入共 17 例 |
| 覆盖率 | 库代码 1054/1125 行 = 93.7%（`moon test --enable-coverage`） |
| 差分测试 | 389 条用例对照 `json-repair` 与 `jsonrepair`；193 处差异全部由修复记录解释，未解释 0 |
| 命令行 | 25 项断言全部通过（退出码 0/1/2/3/4/5/70 覆盖） |
| 演示页 | `static/demo/index.html`，MoonBit JS 产物驱动，无头浏览器验证无报错 |
| 跨后端 | wasm-gc / native / JS 三个后端 28 个测试块全部通过 |
| 吞吐 | native 30–32 MB/s，JS 18–30 MB/s（合法 JSON，Apple M5） |
| 体积 | wasm-gc release 93.6 KiB（上限 150 KB） |

## 与参照实现的关系

差分测试中约一半的用例结论不同，差异**全部**落在四类可解释的行为上：
截断处的补全策略（补 `null` 并闭合容器，而不是猜一个空串）、多根值策略
（默认只保留第一个，可用 `--multi-root array` 切换）、字面量与非有限值处理、
以及明确划到范围外的输入（无 JSON 值、`#` 注释、孤立代理码元）。
逐条说明见 `docs/DIVERGENCES.md`。

## 已知限制

- `R019` 相邻字符串拼接（`"a" + "b"`）未实现；
- FR-16 事件/回调接口未实现；
- 快照的 `incomplete_number` / `pending_key` 策略只影响快照，最终结果仍补全；
- 峰值内存约为输入的 18 倍，未达到「≤ 4 倍输入」的预算（见基准报告）；
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
