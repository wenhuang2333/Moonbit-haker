# 基准报告（TC-B）

本文记录 JSONMend 0.2.0 的实测性能。所有数字都是**同一台机器上的一次观测**，
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
throughput	valid	1079	0.0 ms	42.0 MB/s
throughput	valid	104056	2.3 ms	42.7 MB/s
throughput	valid	1064856	24.4 ms	41.6 MB/s
throughput	valid	10643280	243.0 ms	41.8 MB/s
throughput	flawed	1091	0.0 ms	74.1 MB/s
throughput	flawed	102445	1.2 ms	78.4 MB/s
throughput	flawed	1048622	12.1 ms	82.6 MB/s
throughput	flawed	10485824	126.0 ms	79.4 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.0 ms
long-string	1 MB	1.7 ms	580.0 MB/s
parse-only	1 MB	24.0 ms	42.3 MB/s
linearity	n	23.8 ms
linearity	2n	48.3 ms	ratio 2.0
linearity	4n	96.5 ms	ratio 2.0
stream	chunk 1	43.7 ms	23.3 MB/s
stream	chunk 16	27.8 ms	36.6 MB/s
stream	chunk 1024	24.8 ms	40.9 MB/s
stream	chunk 65536	24.6 ms	41.3 MB/s
stream	snapshot every 1024	46.3 ms	21.9 MB/s
stream	snapshot every 65536	25.0 ms	40.6 MB/s
snapshot	repeat 1000x without feeding	10.8 ms
```

## 结果：JavaScript 后端（release，node）

```
throughput	valid	1079	0.0 ms	31.2 MB/s
throughput	valid	104056	3.4 ms	29.2 MB/s
throughput	valid	1064856	33.7 ms	30.2 MB/s
throughput	valid	10643280	504.0 ms	20.1 MB/s
throughput	flawed	1091	0.0 ms	50.2 MB/s
throughput	flawed	102445	1.9 ms	51.8 MB/s
throughput	flawed	1048622	21.2 ms	47.2 MB/s
throughput	flawed	10485824	264.0 ms	37.9 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	3.6 ms	280.0 MB/s
parse-only	1 MB	39.3 ms	25.8 MB/s
linearity	n	39.3 ms
linearity	2n	81.5 ms	ratio 2.1
linearity	4n	204.0 ms	ratio 2.5
stream	chunk 1	63.0 ms	16.1 MB/s
stream	chunk 16	43.0 ms	23.6 MB/s
stream	chunk 1024	40.0 ms	25.4 MB/s
stream	chunk 65536	39.7 ms	25.6 MB/s
stream	snapshot every 1024	50.0 ms	20.3 MB/s
stream	snapshot every 65536	39.7 ms	25.6 MB/s
snapshot	repeat 1000x without feeding	14.6 ms
```

## 判定

| 需求 | 阈值 | 实测 | 结论 |
| --- | --- | --- | --- |
| NFR-PERF-01 线性时间 | 输入翻倍耗时不超过 2.3 倍 | native 2.0 / 2.0（4 次观测 2.0–2.3）；JS 2.1 / **2.5**（8 次观测 4n 档 2.3–2.8） | native 达标；**JS 未稳定达标**（见下） |
| NFR-PERF-02 吞吐 | native ≥ 20 MB/s，JS ≥ 5 MB/s（合法 JSON） | native 41.6–42.7，JS 20.1–31.2 | 达标 |
| NFR-PERF-03 流式开销 | `feed` 摊还 O(块长)；`snapshot` 为 O(树大小) | 1 码元分块仍有 23.3 MB/s（native，为 64 KB 分块的 56%）；`snapshot every 1024` 21.9 MB/s、`every 65536` 40.6 MB/s | 达标（快照成本随调用频率线性增长） |
| NFR-PERF-04 内存 | 峰值 ≤ 4 × 输入 + O(深度) | 见下节，实测约 18–38 × 输入 | **未达标**，已在限制一节说明 |
| NFR-SIZE-01 产物体积 | wasm-gc release ≤ 150 KB（未压缩） | 98 247 B（95.9 KiB）（`bench/probe`） | 达标 |

### JS 后端的线性度问题（未达标项）

JS 后端 4n/2n 比值在同机 8 次运行中为 `2.3, 2.4, 2.4, 2.5, 2.5, 2.5, 2.8`（另有 1 次
`1.8` 属 2n 档抖动异常值），中位数 2.5，**超过 2.3 的阈值**；native 同期为
`2.0, 2.0, 2.0, 2.3`。根因是 JS 产物里 `Position` 是对象，而 `advance()` 每个输入码元
都会 `new Position(...)`（见 `_build/js/.../bench.js` 中 `advance` 的实现）：
10 MB 输入等于分配约一千万个短生命周期对象，活堆越大 GC 扫描成本越高，表现为超线性。

把 `Position` 字段改成 `mut` 并在原地更新可以消掉这个分配，但引擎把 `tok_start` /
`fence_start` 等**历史位置**与当前 `self.pos` 共用同一个对象，原地更新会连带改掉历史
位置——实测 5 个黄金/流式用例失败（`R001@19 != R001@0`、`E022(5,@7) != E022(5,@2)`），
因此该改法已回滚。正确做法是把「当前位置」（三个 `Int32` 字段）与「历史位置」
（不可变 `Position`）分离，只在 token 边界物化位置结构；详见根 `README.md` 路线图。

深层嵌套（512 层）耗时低于计时分辨率（0.1 ms），说明显式栈没有引入额外开销。

两次快照调用的去重：`snapshot` 在引擎状态未变化时直接返回上一次的结果
（`Engine.snap_stamp` 记忆化），因此 `snapshot repeat 1000x`（1 MB 输入，取 1000 次
快照但不再喂入数据）native 只要 10.8 ms，JS 14.6 ms；未记忆化时约 200 倍于此。

## 内存（TC-B-04）

用 `/usr/bin/time -l` 测 CLI 的峰值 RSS（输入为合法 JSON 文件）：

| 输入 | 峰值 RSS | 相对输入 | 说明 |
| --- | --- | --- | --- |
| 0.62 MB（对象数组） | 15.2 MB | 24.6 × | 固定开销（运行时约 1.9 MB + 解析树 + 输出缓冲）在小输入上占比更高 |
| 3.17 MB（对象数组） | 58.5 MB | 18.4 × | — |
| 6.37 MB（对象数组） | 115.2 MB | 18.1 × | — |
| 12.95 MB（对象数组） | 230.6 MB | 17.8 × | `--check` 与正常输出的峰值相同，说明峰值来自解析树，而不是输出拼接 |
| 8.46 MB（纯数组） | 195.2 MB | 23.1 × | 元素多、字符串短时每个值的固定开销占比更高 |
| 10.00 MB（单个字符串） | 380.2 MB | 38.0 × | 一个 token 被复制三次：`parts` → `parts_text()` → `Json::string` |
| `{}`（进程基线） | 1.9 MB | — | — |

CLI 按 64 KB 分块读入并直接喂给解析器（`code/cmd/jsonmend/io.mbt`），每个块用一次
`fread`（`moonbit_fread_ffi`）取回，不再把整个输入读成一份 `Bytes` 再复制。同机 A/B：
逐字节 `fgetc` 换成单次 `fread` 后，12.95 MB 输入 0.587 s → 0.464 s（+21%），
10.6 MB 缩进输入 0.379 s → 0.282 s（+26%）。剩余峰值由两份同时存活的数据构成：
完整 `Json` 解析树与输出 `StringBuilder`。

NFR-PERF-04 的 4 倍预算是按「流式文本修复」设想写的；只要实现保留完整解析树，
就无法达到。0.2.0 选择如实记录而不隐藏：若后续需要满足该预算，需要在引擎里增加
「只产出文本、不建树」的模式（计划新增的 `Options.want_value = false`），并把 `feed`
的输出直接写进流式 sink。当前版本没有这个选项，引擎一律建树。

## 命令行端到端（TC-B-06）

CLI 是「读文件 → 修复 → 写 stdout」，因此它的吞吐同时受引擎与 I/O 影响。
下表是 `jsonmend <file>` 的实测（`/usr/bin/time -l`，native release）：

| 语料 | 输入 | 耗时 | 吞吐 | 峰值 RSS |
| --- | --- | --- | --- | --- |
| 对象数组 | 0.62 MB | 0.030 s | 20.6 MB/s | 15.1 MB |
| 对象数组 | 3.17 MB | 0.120 s | 26.4 MB/s | 58.3 MB |
| 对象数组 | 6.37 MB | 0.230 s | 27.7 MB/s | 115.0 MB |
| 对象数组 | 12.95 MB | 0.470 s | 27.6 MB/s | 230.6 MB |
| 纯数组 | 8.46 MB | 0.350 s | 24.2 MB/s | 195.1 MB |
| 单串 | 8.00 MB | 0.220 s | 36.4 MB/s | 276.0 MB |
| 缩进 JSON | 10.10 MB | 0.270 s | 37.4 MB/s | 122.1 MB |

读取方式 A/B（同一二进制两次构建、同一语料、交替 7 次取中位数）：

| 语料 | 逐字节 `fgetc` | 单次 `fread` | 增益 |
| --- | --- | --- | --- |
| 0.62 MB | 0.031 s | 0.024 s | +21.3% |
| 3.17 MB | 0.146 s | 0.115 s | +20.9% |
| 6.37 MB | 0.291 s | 0.231 s | +20.7% |
| 12.95 MB | 0.587 s | 0.464 s | +21.0% |
| 8.00 MB 单串 | 0.314 s | 0.240 s | +23.5% |
| 10.10 MB 缩进 | 0.379 s | 0.282 s | +25.5% |

结论：逐字节 `fgetc` 会把 CLI 压在约 25 MB/s，成为端到端瓶颈（引擎本身 42 MB/s）；
改为每块一次 `fread` 后 CLI 与引擎的差距缩小到约 30%。

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
