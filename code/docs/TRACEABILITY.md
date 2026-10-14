# 追踪矩阵（D06 6.2 / 6.3）

状态取值：**通过**（有可复现证据）、**削减**（有意未实现或有已知未达标项，原因见备注）。
所有证据都在本仓库内可复现，命令见 `docs/REPRODUCE.md`。

## 功能需求

| 需求 | 名称 | 优先级 | 业务规则 | 测试用例 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| FR-01 | 一次性修复 | P0 | BR-01 BR-04 | TC-G 全部、TC-P-01 | `golden_wbtest.mbt` 115 条；`prop_wbtest.mbt` TC-P-01 400 例 × 4 组选项 | 通过 |
| FR-02 | 修复报告 | P0 | BR-19 BR-20 | TC-G（记录字段）、TC-E-API | 记录含 code/position/severity/message；`error_api_wbtest.mbt` 校验 21 条规则的表完整性；CLI `--report` | 通过 |
| FR-03 | 值输出 | P0 | BR-01 | TC-G-VAL、TC-P-01 | `parse` 返回 `Json`；TC-P-02b 校验 `parse` 与文本一致 | 通过 |
| FR-04 | 合法输入恒等 | P0 | BR-02 BR-03 | TC-P-02b | 合法文档零记录、文本逐字不变 | 通过 |
| FR-05 | 截断补全 | P0 | BR-13 | TC-G-BR13、TC-P-04 | `{"a":{"b":[1,2` → `{"a":{"b":[1,2]}}`；400 例随机截断后 `finish` 全部合法 | 通过 |
| FR-06 | 词法宽容 | P0 | BR-06…BR-12 | TC-G-BR06…BR12、TC-D | 黄金用例 + 389 条差分用例 | 通过 |
| FR-07 | 结构修复 | P0 | BR-09 BR-13 BR-14 | TC-G-BR09/13/14 | 黄金用例 G-060…G-100 段 | 通过 |
| FR-08 | 围栏与前后缀 | P0 P1 | BR-05 | TC-G-BR05、TC-O-06 | `strip_fence` 开关双向覆盖；`skip_prose` 见 R021 | 通过 |
| FR-09 | 流式解析器 | P0 | BR-16 | TC-S-01、TC-P-03 | `stream_wbtest.mbt` S-001…S-020；逐码元/二分/1 KB 分块不变 | 通过 |
| FR-10 | 快照语义 | P0 | BR-16 | TC-S 全部、TC-P-05 | 稳定前缀、`open_path` 可遍历性、`Completeness` 三态 | 通过 |
| FR-11 | 分块鲁棒 | P0 | BR-12 BR-16 | TC-P-03 | 任意切分下文本、记录、错误三者一致 | 通过 |
| FR-12 | 字节输入 | P1 | BR-20 | TC-S-UTF8 | `feed_bytes` 在 UTF-8 序列中间切分仍与 `feed` 一致；非法字节抛 E040 | 通过 |
| FR-13 | 选项与模式 | P0 P1 | BR-17 BR-18 | TC-O-01…TC-O-07 | `options_wbtest.mbt` 覆盖全部策略枚举与规则开关 | 通过 |
| FR-14 | 引号歧义前瞻 | P1 | BR-06 | TC-G-BR06L | `quote_lookahead` 黄金用例 + 属性测试选项组 | 通过 |
| FR-15 | 多根值 | P1 | BR-15 | TC-O-03、TC-D | 三种策略（KeepFirst/AsArray/AsError）行为固定；差分探针证明与参照一致 | 通过 |
| FR-16 | 事件接口 | P2 | BR-16 | — | 未实现 | 削减（P2，0.1.0 未做） |
| FR-17 | 命令行 | P1 | BR-17 | TC-C-01 | `tests/cli_smoke.sh` 25 项断言全绿；退出码 0/1/2/3/4/5/70 全覆盖 | 通过 |
| FR-18 | 浏览器演示 | P1 | — | TC-W-01 | `static/demo/index.html` 由 MoonBit JS 产物驱动，Playwright 无头验证通过（无 console 错误） | 通过 |
| FR-19 | 拼接与省略号 | P2 | BR-21 | TC-G-BR21 | `...` 已实现（R020，G-301…G-303）；`"a" + "b"` 未实现 | 削减（R019 未实现，见 `docs/RULES.md`） |
| FR-20 | 缩进输出 | P2 | — | TC-G-INDENT | CLI `--indent 2` 与 `Options.indent` | 通过 |

## 非功能需求

| 需求 | 名称 | 测试用例 | 证据 | 状态 |
| --- | --- | --- | --- | --- |
| NFR-COR-01 | 输出合法 | TC-P-01 | 400 例模糊输入 × 4 组选项，输出全部通过 `is_valid_json` | 通过 |
| NFR-COR-02 | 幂等 | TC-P-02a | 二次修复文本不变且零记录（400 例） | 通过 |
| NFR-COR-03 | 分块不变 | TC-P-03 | 文本、记录、错误三者一致（400 例，逐码元或 1/7/13 随机切分） | 通过 |
| NFR-COR-04 | 快照单调 | TC-P-05 | `Complete` 之后所有快照逐字相同；`open_path` 始终可遍历 | 通过 |
| NFR-COR-05 | 参照一致 | TC-D | 389 条用例、193 处差异全部有文档解释、未解释 0（`docs/DIVERGENCES.md`） | 通过 |
| NFR-ROB-01 | 不崩溃 | TC-P-06 | 10 万条 token soup 无 panic、无 E030 | 通过 |
| NFR-ROB-02 | 资源限制 | TC-E-API-03、黄金 E020/E021/E022 | 深度/长度/token 上限抛 E020/E021/E022；`Options::validate` 拒绝非法上限 | 通过 |
| NFR-PERF-01 | 线性时间 | TC-B-01 | 翻倍比值 native 2.0/2.0、JS 2.1/2.2（阈值 2.3） | 通过 |
| NFR-PERF-02 | 吞吐 | TC-B-02 | native 30–32 MB/s、JS 18–30 MB/s（阈值 20 / 5） | 通过 |
| NFR-PERF-03 | 流式开销 | TC-B-03 | 1 码元分块仍有 21.0 MB/s；快照成本随调用频率线性增长 | 通过 |
| NFR-PERF-04 | 内存 | TC-B-04 | 实测峰值 ≈ 17.7–21 × 输入（13.2 MB 输入 → 234 MB），**超出 4 × 输入 + O(深度) 的预算** | 削减（原因见 `docs/BENCHMARK.md`；需要 `want_value=false` 的纯文本模式） |
| NFR-SIZE-01 | 产物体积 | TC-B-05 | wasm-gc release 95 837 B（93.6 KiB），上限 150 KB | 通过 |
| NFR-PORT-01 | 跨后端一致 | TC-X-01 | `moon test`（wasm-gc）、`--target native`、`--target js` 均 28/28 通过 | 通过 |
| NFR-DET-01 | 确定性 | TC-X-02 | 固定种子的 LCG；同一输入重复运行输出逐字节相同 | 通过 |
| NFR-API-01 | 接口稳定 | TC-R-02 | 公共面：`repair`/`parse`/`is_valid_json`、`PartialParser` 5 个方法、5 个结果类型、6 个策略枚举、`RuleSet` 4 个方法、`RepairCode`/`MendError` 查询函数 | 通过 |
| NFR-API-02 | 易用 | TC-DOC-01 | `README.md` / `README.zh.md`：安装、三行快速开始、流式示例、选项表、CLI 帮助 | 通过 |
| NFR-DOC-01 | 文档完整 | TC-DOC-02 | `docs/` 七份文档 + `CHANGELOG.md` + `LICENSE` + `NOTICE` | 通过 |
| NFR-TEST-01 | 覆盖率 | TC-COV-01 | `moon test --enable-coverage` + `moon coverage report -f summary`：库代码 1054/1125 行 = **93.7%**（`bench/` 不计） | 通过 |
| NFR-SEC-01 | 安全 | TC-P-06、TC-P-07 | 错误消息模板固定、不回显输入；资源上限防止病态输入耗尽内存；无外部依赖 | 通过 |
| NFR-COMP-01 | 合规 | TC-L-01 | `LICENSE`（Apache-2.0 全文）、`NOTICE`（依赖与参照实现许可证：`jsonrepair` ISC、`json-repair` MIT） | 通过 |
| NFR-MNT-01 | 可维护 | TC-R-03 | `moon check` 零警告、`moon fmt --check` 干净、`docs/REPRODUCE.md` 一键复现；未配置 CI | 削减（无 CI 运行器，全部检查本地执行） |
| NFR-REL-01 | 可发布 | TC-R-01 | `moon.mod` v0.1.0 + Apache-2.0 + repository；未发布到 mooncakes.io | 削减（未发布到注册表） |

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
| BR-21 | FR-19 | R020 黄金用例；R019 削减 |
| BR-02 幂等 | NFR-COR-02 | TC-P-02a |

每个 R 码（R001–R021）在 `error_api_wbtest.mbt` 的 TC-E-API-01 中被逐一检查，
每个 E 码（E001–E050）在 TC-E-API-02 中被逐一检查，因此「每个 R/E 码至少对应一个
用例」由代码强制保证，而不是靠人工核对。

## 削减项汇总

| 项 | 原因 | 影响 |
| --- | --- | --- |
| FR-16 事件接口 | P2，0.1.0 未实现 | 需要回调式接口的调用方只能用 `snapshot()` 轮询 |
| FR-19 的 R019 拼接 | P2，仅实现省略号删除 | `"a" + "b"` 目前按「缺逗号 + 数字修复」处理 |
| NFR-PERF-04 内存预算 | 完整解析树与输入副本同时存活 | 13 MB 输入峰值 234 MB；需要纯文本模式才能达标 |
| NFR-MNT-01 CI | 无 CI 运行器 | 全部检查在本地执行，命令见 `docs/REPRODUCE.md` |
| NFR-REL-01 发布 | 未发布到 mooncakes.io | 只能通过仓库源码使用 |
