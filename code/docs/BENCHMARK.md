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
throughput	valid	1079	0.0 ms	35.7 MB/s
throughput	valid	104056	2.8 ms	35.4 MB/s
throughput	valid	1064856	29.0 ms	35.0 MB/s
throughput	valid	10643280	315.0 ms	32.2 MB/s
throughput	flawed	1091	0.0 ms	54.4 MB/s
throughput	flawed	102445	1.7 ms	56.1 MB/s
throughput	flawed	1048622	20.7 ms	48.4 MB/s
throughput	flawed	10485824	204.0 ms	49.0 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	1.9 ms	534.7 MB/s
parse-only	1 MB	26.5 ms	38.3 MB/s
linearity	n	26.8 ms
linearity	2n	53.5 ms	ratio 2.0
linearity	4n	111.0 ms	ratio 2.1
stream	chunk 1	46.3 ms	21.9 MB/s
stream	chunk 16	30.0 ms	33.9 MB/s
stream	chunk 1024	26.0 ms	39.1 MB/s
stream	chunk 65536	25.8 ms	39.4 MB/s
stream	snapshot every 1024	48.0 ms	21.2 MB/s
stream	snapshot every 65536	26.5 ms	38.3 MB/s
snapshot	repeat 1000x without feeding	13.0 ms
```

## 结果：JavaScript 后端（release，node）

```
throughput	valid	1079	0.0 ms	36.6 MB/s
throughput	valid	104056	3.6 ms	27.2 MB/s
throughput	valid	1064856	37.0 ms	27.4 MB/s
throughput	valid	10643280	499.0 ms	20.3 MB/s
throughput	flawed	1091	0.0 ms	46.9 MB/s
throughput	flawed	102445	2.0 ms	47.9 MB/s
throughput	flawed	1048622	23.8 ms	42.0 MB/s
throughput	flawed	10485824	264.0 ms	37.9 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	3.6 ms	277.2 MB/s
parse-only	1 MB	44.0 ms	23.1 MB/s
linearity	n	41.0 ms
linearity	2n	92.0 ms	ratio 2.2
linearity	4n	209.0 ms	ratio 2.3
stream	chunk 1	58.5 ms	17.4 MB/s
stream	chunk 16	54.0 ms	18.8 MB/s
stream	chunk 1024	62.0 ms	16.4 MB/s
stream	chunk 65536	53.0 ms	19.2 MB/s
stream	snapshot every 1024	68.0 ms	14.9 MB/s
stream	snapshot every 65536	51.5 ms	19.7 MB/s
snapshot	repeat 1000x without feeding	18.0 ms
```

## 判定

| 需求 | 阈值 | 实测 | 结论 |
| --- | --- | --- | --- |
| NFR-PERF-01 线性时间 | 输入翻倍耗时不超过 2.3 倍 | native 2.0 / 2.1，JS 2.2 / 2.3 | 达标（JS 在 4n 档贴近阈值，余量很小） |
| NFR-PERF-02 吞吐 | native ≥ 20 MB/s，JS ≥ 5 MB/s（合法 JSON） | native 32.2–35.7，JS 20.3–36.6 | 达标 |
| NFR-PERF-03 流式开销 | `feed` 摊还 O(块长)；`snapshot` 为 O(树大小) | 1 码元分块仍有 21.9 MB/s（native，为 64 KB 分块的 56%）；`snapshot every 1024` 21.2 MB/s、`every 65536` 38.3 MB/s | 达标（快照成本随调用频率线性增长） |
| NFR-PERF-04 内存 | 峰值 ≤ 4 × 输入 + O(深度) | 见下节，实测约 16–18 × 输入 | **未达标**，已在限制一节说明 |
| NFR-SIZE-01 产物体积 | wasm-gc release ≤ 150 KB（未压缩） | 98 247 B（95.9 KiB）（`bench/probe`） | 达标 |

深层嵌套（512 层）耗时低于计时分辨率（0.1 ms），说明显式栈没有引入额外开销。

两次快照调用的去重：`snapshot` 在引擎状态未变化时直接返回上一次的结果
（`Engine.snap_stamp` 记忆化），因此 `snapshot repeat 1000x`（1 MB 输入，取 1000 次
快照但不再喂入数据）native 只要 13.0 ms，JS 18.0 ms；未记忆化时约 200 倍于此。

## 内存（TC-B-04）

用 `/usr/bin/time -l` 测 CLI 的峰值 RSS（输入为合法 JSON 文件）：

| 输入 | 峰值 RSS | 相对输入 | 说明 |
| --- | --- | --- | --- |
| 5.2 MB | 92 MB | 17.7 × | 固定开销（运行时 + 解析树 + 输出缓冲）在小输入上占比更高 |
| 13.2 MB | 212 MB | 16.1 × | `--check` 与正常输出的峰值相同，说明峰值来自解析树，而不是输出拼接 |
| 全量基准（含 10 MB 语料多轮） | 见 `bench.sh` | — | `bench.sh native` 的 `maximum resident set size` |

CLI 现在按 64 KB 分块读入并直接喂给解析器（`code/cmd/jsonmend/io.mbt`），
不再把整个输入读成一份 `Bytes` 再复制；13.2 MB 输入因此从 234 MB 降到 212 MB。
剩余峰值由两份同时存活的数据构成：完整 `Json` 解析树与输出 `StringBuilder`。

NFR-PERF-04 的 4 倍预算是按「流式文本修复」设想写的；只要实现保留完整解析树，
就无法达到。0.1.0 选择如实记录而不隐藏：若后续需要满足该预算，需要在引擎里增加
「只产出文本、不建树」的模式（`want_value=false`），并把 `feed` 的输出直接写进
流式 sink。当前版本没有实现该模式。

## 产物体积（TC-B-05）

| 产物 | 大小 | 说明 |
| --- | --- | --- |
| `bench/probe`（wasm-gc release） | 98 247 B（95.9 KiB） | 最小消费者：调用 `repair`、`PartialParser`、`is_valid_json`，代表库的真实增量体积 |
| `examples/web`（JS release） | 269 715 B（263 KiB） | 浏览器演示页的完整 bundle（含运行时） |

## 备注

- 瑕疵 JSON 比合法 JSON 更快（native 48–56 MB/s）：合法 JSON 会完整构建
  `Json` 值，而大量瑕疵语料在更早的分支上就被丢弃或短路。
- 字符串批处理快路径（`Engine::push_run`）把连续普通字符一次并入，超长字符串
  1 MB 达到 native 535 MB/s、JS 277 MB/s；`parse-only` 档（只建树不产文本）
  仍受 `Json` 分配限制，native 38.3 MB/s。
- JS 后端在 10 MB 档降到 20.3 MB/s，主要来自字符串拼接与 `Json` 对象的分配；
  仍高于 5 MB/s 的下限。
- 数字与机器强相关（散热、后台负载、Node 版本）。复现时请以 `bench.sh` 的
  当次输出为准，不要引用本文件的绝对值作为验收依据。**上表是单机单次观测**，
  同一台机器上不同轮次的差异可达 ±15%，不同机型（尤其是 CI 容器）差异更大。
