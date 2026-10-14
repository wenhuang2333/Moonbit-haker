# 基准报告（TC-B）

本文记录 JSONMend 0.1.0 的实测性能。所有数字都是**同一台机器上的一次观测**，
不是性能承诺；阈值判定见 `docs/TRACEABILITY.md` 的 NFR 一栏。

## 环境

| 项 | 值 |
| --- | --- |
| 机器 | Apple M5，24 GB 统一内存 |
| 系统 | macOS 26.5.1 |
| 工具链 | `moon 0.1.20261012`、`moonc v0.10.15+943464bfa` |
| 运行时 | Node.js v24.15.0（JS 后端） |
| 构建 | `--release`，native 后端用本机 clang |

## 复现

```bash
bash code/tests/bench.sh          # native + js + 产物体积
bash code/tests/bench.sh native   # 只跑 native
bash code/tests/bench.sh js       # 只跑 JS 后端
bash code/tests/bench.sh size     # 只量产物体积
```

基准程序（`code/bench/main.mbt`）用 `@env.now()` 计时，每档至少 100 ms，取 5 轮中位数，
自动放大重复次数；语料在计时前生成。输入分 1 KB、100 KB、1 MB、10 MB 四档，
覆盖合法 JSON、重度瑕疵 JSON、深层嵌套（64 / 512 层）与超长字符串（1 MB 单串）。

## 结果：native（release）

```
throughput	valid	1079	0.0 ms	31.8 MB/s
throughput	valid	104056	3.2 ms	31.1 MB/s
throughput	valid	1064856	33.7 ms	30.2 MB/s
throughput	valid	10643280	333.0 ms	30.5 MB/s
throughput	flawed	1091	0.0 ms	48.3 MB/s
throughput	flawed	102445	2.4 ms	41.0 MB/s
throughput	flawed	1048622	21.2 ms	47.2 MB/s
throughput	flawed	10485824	236.0 ms	42.4 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.0 ms
long-string	1 MB	25.0 ms	40.0 MB/s
parse-only	1 MB	33.3 ms	30.5 MB/s
linearity	n	33.3 ms
linearity	2n	65.5 ms	ratio 2.0
linearity	4n	134.0 ms	ratio 2.0
stream	chunk 1	48.3 ms	21.0 MB/s
stream	chunk 16	35.0 ms	29.0 MB/s
stream	chunk 1024	33.3 ms	30.5 MB/s
stream	chunk 65536	34.0 ms	29.9 MB/s
stream	snapshot every 1024	56.0 ms	18.1 MB/s
stream	snapshot every 65536	37.0 ms	27.4 MB/s
```

## 结果：JavaScript 后端（release，node）

```
throughput	valid	1079	0.0 ms	30.2 MB/s
throughput	valid	104056	4.2 ms	23.8 MB/s
throughput	valid	1064856	43.3 ms	23.4 MB/s
throughput	valid	10643280	574.0 ms	17.7 MB/s
throughput	flawed	1091	0.0 ms	40.2 MB/s
throughput	flawed	102445	2.6 ms	37.1 MB/s
throughput	flawed	1048622	28.0 ms	35.7 MB/s
throughput	flawed	10485824	319.0 ms	31.3 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	31.0 ms	32.3 MB/s
parse-only	1 MB	62.5 ms	16.2 MB/s
linearity	n	50.5 ms
linearity	2n	105.0 ms	ratio 2.1
linearity	4n	235.0 ms	ratio 2.2
stream	chunk 1	53.5 ms	19.0 MB/s
stream	chunk 16	53.0 ms	19.2 MB/s
stream	chunk 1024	49.3 ms	20.6 MB/s
stream	chunk 65536	50.5 ms	20.1 MB/s
stream	snapshot every 1024	59.0 ms	17.2 MB/s
stream	snapshot every 65536	51.0 ms	19.9 MB/s
```

## 判定

| 需求 | 阈值 | 实测 | 结论 |
| --- | --- | --- | --- |
| NFR-PERF-01 线性时间 | 输入翻倍耗时不超过 2.3 倍 | native 2.0 / 2.0，JS 2.1 / 2.2 | 达标 |
| NFR-PERF-02 吞吐 | native ≥ 20 MB/s，JS ≥ 5 MB/s（合法 JSON） | native 30.2–31.8，JS 17.7–30.2 | 达标 |
| NFR-PERF-03 流式开销 | `feed` 摊还 O(块长)；`snapshot` 为 O(树大小) | 1 码元分块仍有 21.0 MB/s（native，为 64 KB 分块的 70%）；`snapshot every 1024` 为 18.1 MB/s，`every 65536` 为 27.4 MB/s | 达标（快照成本随调用频率线性增长，符合 O(树大小) 语义） |
| NFR-PERF-04 内存 | 峰值 ≤ 4 × 输入 + O(深度) | 见下节，实测约 18–21 × 输入 | **未达标**，已在限制一节说明 |
| NFR-SIZE-01 产物体积 | wasm-gc release ≤ 150 KB（未压缩） | 95 837 B（93.6 KiB，`bench/probe`） | 达标 |

深层嵌套（512 层）耗时低于计时分辨率（< 0.1 ms），说明显式栈没有引入额外开销。

## 内存（TC-B-04）

用 `/usr/bin/time -l` 测 CLI 的峰值 RSS（输入为合法 JSON 文件）：

| 输入 | 峰值 RSS | 相对输入 | 说明 |
| --- | --- | --- | --- |
| 1.3 MB | 28 MB | 21 × | 固定开销（运行时 + 解析树 + 输出缓冲）在小输入上占比更高 |
| 13.2 MB | 234 MB | 17.7 × | `--check` 与正常输出的峰值相同，说明峰值来自解析树与输入副本，而不是输出拼接 |
| 全量基准（含 10 MB 语料多轮） | 229 MB | — | `bench.sh native` 的 `maximum resident set size` |

峰值由三份同时存活的数据构成：输入字符串（UTF-16）、完整 `Json` 解析树、
以及输出的 `StringBuilder`。`repair` 按 API 契约必须同时返回文本与值，
因此解析树无法提前释放。

NFR-PERF-04 的 4 倍预算是按「流式文本修复」设想写的；只要实现保留完整解析树，
就无法达到。0.1.0 选择如实记录而不隐藏：若后续需要满足该预算，需要在引擎里增加
「只产出文本、不建树」的模式（`want_value=false`），并把 `feed` 的输出直接写进
流式 sink。当前版本没有实现该模式。

## 产物体积（TC-B-05）

| 产物 | 大小 | 说明 |
| --- | --- | --- |
| `bench/probe`（wasm-gc release） | 95 837 B（93.6 KiB） | 最小消费者：调用 `repair`、`PartialParser`、`is_valid_json`，代表库的真实增量体积 |
| `examples/web`（JS release） | 258 516 B（252 KiB） | 浏览器演示页的完整 bundle（含运行时） |

## 备注

- 瑕疵 JSON 比合法 JSON 更快（native 42–48 MB/s）：合法 JSON 会完整构建
  `Json` 值，而大量瑕疵语料在更早的分支上就被丢弃或短路。
- JS 后端在 10 MB 档降到 17.7 MB/s，主要来自字符串拼接与 `Json` 对象的分配；
  仍高于 5 MB/s 的下限。
- 数字与机器强相关（散热、后台负载、Node 版本）。复现时请以 `bench.sh` 的
  当次输出为准，不要引用本文件的绝对值作为验收依据。
