# 基准报告（TC-B）

本文记录 JSONMend 0.4.0 的实测性能。所有数字都是**同一台机器上的一次观测**，
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
0.3.0 另加两档：**增量流**（`collect_deltas`，见下）与 **TTFV**（首个可见值出现的位置）。
0.4.0 再补三档，都是第五轮评审要求的场景基准：
**agent 场景**（4 KB 工具调用文档按 3 码元分块）、
**就绪曲线成本**（FR-29 的采样开销）与
**增量条数**（同一 4 KB 文档在 3 码元分块下的记录条数）。

## 结果：native（release）

```
throughput	valid	1079	0.0 ms	41.0 MB/s
throughput	valid	104056	2.3 ms	42.2 MB/s
throughput	valid	1064856	24.8 ms	40.9 MB/s
throughput	valid	10643280	248.0 ms	40.9 MB/s
throughput	flawed	1091	0.0 ms	76.5 MB/s
throughput	flawed	102445	1.2 ms	80.1 MB/s
throughput	flawed	1048622	11.6 ms	86.5 MB/s
throughput	flawed	10485824	121.0 ms	82.6 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	1.7 ms	594.1 MB/s
parse-only	1 MB	25.0 ms	40.6 MB/s
linearity	n	24.4 ms
linearity	2n	49.0 ms	ratio 2.0
linearity	4n	99.0 ms	ratio 2.0
stream	chunk 1	43.0 ms	23.6 MB/s
stream	chunk 16	27.8 ms	36.6 MB/s
stream	chunk 1024	25.5 ms	39.8 MB/s
stream	chunk 65536	25.0 ms	40.6 MB/s
stream	snapshot every 1024	46.0 ms	22.1 MB/s
stream	snapshot every 65536	25.5 ms	39.8 MB/s
snapshot	repeat 1000x without feeding	11.1 ms
deltas	chunk 1024	35.0 ms	29.0 MB/s	138.6% of baseline	194992 deltas
deltas	chunk 65536	36.3 ms	28.0 MB/s	143.9% of baseline	194706 deltas
ttfv	call 312	first 5.1%	ttfv95 97.4%	label at first exact
ttfv	call 1131	first 1.4%	ttfv95 96.2%	label at first exact
ttfv	call 4349	first 0.4%	ttfv95 95.3%	label at first exact
ttfv	median over 20 documents	first 0.7%	ttfv95 95.3%
```

## 结果：JavaScript 后端（release，node）

```
throughput	valid	1079	0.0 ms	39.0 MB/s
throughput	valid	104056	3.2 ms	31.1 MB/s
throughput	valid	1064856	32.8 ms	31.0 MB/s
throughput	valid	10643280	469.0 ms	21.6 MB/s
throughput	flawed	1091	0.0 ms	42.6 MB/s
throughput	flawed	102445	1.8 ms	55.7 MB/s
throughput	flawed	1048622	20.0 ms	50.0 MB/s
throughput	flawed	10485824	244.0 ms	41.0 MB/s
deep	depth 64	0.0 ms
deep	depth 512	0.1 ms
long-string	1 MB	3.5 ms	287.1 MB/s
parse-only	1 MB	37.7 ms	27.0 MB/s
linearity	n	37.0 ms
linearity	2n	81.0 ms	ratio 2.2
linearity	4n	193.0 ms	ratio 2.4
stream	chunk 1	57.0 ms	17.8 MB/s
stream	chunk 16	39.7 ms	25.6 MB/s
stream	chunk 1024	38.7 ms	26.3 MB/s
stream	chunk 65536	38.7 ms	26.3 MB/s
stream	snapshot every 1024	52.0 ms	19.5 MB/s
stream	snapshot every 65536	38.7 ms	26.3 MB/s
snapshot	repeat 1000x without feeding	14.1 ms
deltas	chunk 1024	47.7 ms	21.3 MB/s	114.4% of baseline	194992 deltas
deltas	chunk 65536	51.5 ms	19.7 MB/s	135.5% of baseline	194706 deltas
ttfv	median over 20 documents	first 0.7%	ttfv95 95.3%
```

## 结果：agent 场景（4 KB、3 码元分块）

第五轮评审指出 I-2 的 1.39 倍开销是在 1 MB 文档上测的，而工具调用参数只有几百到
几千码元、按 token 分块到达，两者不是同一个场景。下面把 4 KB 工具调用文档按 1 / 3 /
16 / 1024 / 65536 码元分块喂入，每档跑 200 遍整条流：

| 分块 | 200 条流总耗时 | 每次 feed | 吞吐 | feed 超过时钟分辨率 |
| --- | --- | --- | --- | --- |
| 1 | 39.0 ms | 0.04 µs | 21.3 MB/s | 29 / 869 800 |
| 3 | 23.0 ms | 0.08 µs | 36.1 MB/s | 17 / 290 000 |
| 16 | 15.0 ms | 0.28 µs | 55.3 MB/s | 0 / 54 400 |
| 1024 | 13.0 ms | 13.00 µs | 63.8 MB/s | 0 / 1 000 |
| 65536 | 12.0 ms | 60.00 µs | 69.1 MB/s | 0 / 200 |

读法与限制，必须一起看：

- **每次 feed 的成本是摊还值**，不是单次测量：`@env.now()` 在本运行时只有毫秒
  分辨率，所以表中「每次 feed」= 总耗时 ÷ feed 次数。要拿到真实的 p99 单次延迟，
  需要纳秒时钟或运行时的分配计数，当前工具链两者都没有。
- 因此 p99 只能给出**上界**：3 码元分块下 290 000 次 feed 里有 17 次跨过 1 ms 时钟
  的分辨率（这些"跨格"里包含该 feed 自身以及同批其他 feed 的成本），也就是说
  **没有观察到任何一次 feed 达到 1 ms 量级**。1 码元分块的 869 800 次里有 29 次，
  比例同样是万分之三左右，随分块变小而下降的比例与「每次 feed 固定成本」一致。
- 1 MB 文档的 1.39–1.46 倍增量开销在这个场景里不构成问题：3 码元分块下 4 KB 文档
  36 MB/s，整条流 23 ms / 200 = 0.115 ms。评审要求「先做场景基准，再决定要不要花
  1–1.5 天做紧凑缓冲」——本轮的结论是**不做**，理由是这个场景里开销已经不在关键路
  径上，而紧凑缓冲会改动 `Delta` 的公开形状。
- 同一 4 KB 文档在 3 码元分块下产生 **989 条增量**（`deltas 4KB call in 3 byte
  chunks`），即约 0.25 条/码元；这是一个 UI 每帧需要处理的量级。

## 结果：就绪曲线的成本（FR-29）

`field_readiness` 用「约一千次采样」换取曲线，每次采样都要 `snapshot()` 一次
（成本为当前值大小）。在 20 份扁平记录（共 50 807 B、每份约 200 个顶层成员）上：

| 指标 | 值 |
| --- | --- |
| 20 份文档总耗时 | 89.0 ms |
| 每份文档 | 4 450 µs |
| 每 KiB | 1 794 µs |
| 十分位曲线 | `0 10 21 30 41 51 61 71 80 90 100` |
| 全字段早停节省 | 1 / 1000 |

结论与边界，写清以免被误读：

- 这份成本是**测量工具**的成本，不是库路径上的成本：`readiness` 子命令用于评估与
  配图，热路径上用 `FieldTracker`（基于增量、无采样）。
- 十分位曲线在这份语料上接近对角线，说明「第 k 个成员在第 k/10 处定稿」——
  这正是这个指标想表达的、而「95% 覆盖」表达不了的东西。
- **全字段早停节省约等于 0 是构造性的**：扁平记录里最后一个成员的最后几个字节决定
  整条流的终点，一个「等所有字段就绪」的消费者仍然要读完整个文档。真正能省的地方是
  只需要**部分字段**的消费者，对应 API 是 `FieldTracker`（见下文）。报告这个数字是
  为了不把「早停」说成比实际更大的收益。
- 指标只覆盖**顶层成员**：`{"arguments":{...}}` 这种把参数嵌在一层里的工具调用文档
  里，`arguments` 只能等到容器闭合（permille 1000）才就绪，曲线因此是平的。嵌套成员
  的就绪度不在本轮范围内，已如实记录为限制。

## 判定

| 需求 | 阈值 | 实测 | 结论 |
| --- | --- | --- | --- |
| NFR-PERF-01 线性时间 | 输入翻倍耗时不超过 2.3 倍 | native 2.0 / 2.0（多次观测 2.0–2.3）；JS 2.2 / **2.4**（多次观测 4n 档 2.3–2.8） | native 达标；**JS 未稳定达标**（见下） |
| NFR-PERF-02 吞吐 | native ≥ 20 MB/s，JS ≥ 5 MB/s（合法 JSON） | native 40.9–42.2，JS 21.6–39.0 | 达标 |
| NFR-PERF-03 流式开销 | `feed` 摊还 O(块长)；`snapshot` 为 O(树大小) | 1 码元分块 21.8 MB/s（native，为 64 KB 分块的 56%）；`snapshot every 1024` 21.2 MB/s、`every 65536` 37.6 MB/s；agent 场景 4 KB/3 码元 0.08 µs/feed，无一次 feed 达到 1 ms | 达标（快照成本随调用频率线性增长） |
| NFR-PERF-05 增量流开销 | 记录增量时吞吐不低于不开增量基线的 90% | 1 MB：native 139.6% / 145.9% 耗时；JS 121.4% / 131.7%。**agent 场景（4 KB / 3 码元）0.08 µs/feed，整条流 0.115 ms**，开销不在关键路径上，本轮不做紧凑缓冲 | **未达标**（1 MB 口径，见下）；场景口径已量化并据此决定不做优化 |
| NFR-PERF-07 场景延迟（新增，无阈值） | 报告 4 KB / 3 码元分块下的每次 feed 成本与上界 | 0.08 µs/feed（摊还），290 000 次 feed 中 0 次达到 1 ms 量级；p99 ≤ 1 ms（受时钟分辨率限制，只能给上界） | 已实测 |
| NFR-PERF-06 首个可见值 | 报告实测位置即可（无阈值，用于产品评估） | 工具调用文档中位数：首个值出现在文档长度的 **0.7%**，95% 内容出现在 95.3%；FR-29 就绪曲线十分位 `0 10 21 30 41 51 61 71 80 90 100` | 已实测，见下（就绪曲线取代「95% 覆盖」作为主指标） |
| NFR-PERF-04 内存 | 峰值 ≤ 4 × 输入 + O(深度) | 见下节，实测约 18–38 × 输入 | **未达标**，已在限制一节说明 |
| NFR-SIZE-01 产物体积 | wasm-gc release ≤ 150 KB（未压缩） | 103 784 B（101.4 KiB）（`bench/probe`） | 达标 |

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

深层嵌套（512 层）耗时 0.1 ms，说明显式栈没有引入额外开销。

### 增量流的开销（未达标项）

打开 `Options::collect_deltas` 后，每次 `drain_deltas()` 返回自上次 drain 以来的变更。
实测（1 MB 合法 JSON，同一分块下与不开增量对比）：

| 分块 | native 耗时 | 相对基线 | JS 耗时 | 相对基线 | 记录条数 |
| --- | --- | --- | --- | --- | --- |
| 1024 | 35.0 ms（29.0 MB/s） | 138.6% | 47.7 ms（21.3 MB/s） | 114.4% | 194 992 |
| 65536 | 36.3 ms（28.0 MB/s） | 143.9% | 51.5 ms（19.7 MB/s） | 135.5% | 194 706 |

也就是说吞吐降到基线的 70%（native）/ 74–87%（JS），**低于 90% 的登记目标**。
194 992 条记录对应约 15 000 个元素，即每个元素平均 13 条——原因是每一条记录都要
新分配一个 `Delta` 记录与一份路径数组（`frame_path().copy()` + `push`），
而路径长度随深度增长。两条可选的优化路线写在根 `README.md` 的路线图里：
紧凑增量缓冲（把 `op|path|text` 编码进一块可复用的 `Bytes`，只在 drain 时物化
`Array[Delta]`）与路径前缀共享。本轮没有做，如实记录。

### 首个可见值（TTFV）与字段就绪曲线（FR-29）

登记在 `docs/EVAL_REGISTRATION.md` 的指标是「快照覆盖最终取值 95% 时已消耗的输入比例」，
基线（先收完再修）为 1.0。实测：

| 文档 | 首个可见值 | 95% 覆盖 | 首值处的标签 |
| --- | --- | --- | --- |
| 工具调用 312 码元 | 5.1% | 97.4% | exact |
| 工具调用 1 131 码元 | 1.4% | 96.2% | exact |
| 工具调用 4 349 码元 | 0.4% | 95.3% | exact |
| 20 份混合文档（中位数） | **0.7%** | 95.3% | — |

两个数字要分开读：

- **95% 覆盖这一档几乎没有收益**（95.3%，基线 1.0）。这是结构决定的：工具调用的参数是
  一个对象，对象只有接近闭合时才「几乎完整」。这条判据在 JSON 对象上不敏感，
  如实记录而不是换个更好看的指标。
- **首个可见值只有 0.7%** 才是产品上的收益：界面可以在收到第一个字符后就渲染出结构，
  并在同一时刻拿到精确度标签（本例中 `exact`），而不必等到流结束。`jsonmend llm --follow`
  就是这个行为的可运行示例。

两次快照调用的去重：`snapshot` 在引擎状态未变化时直接返回上一次的结果
（`Engine.snap_stamp` 记忆化），因此 `snapshot repeat 1000x`（1 MB 输入，取 1000 次
快照但不再喂入数据）native 只要 10.8 ms，JS 14.6 ms；未记忆化时约 200 倍于此。

## 内存（TC-B-04）

用 `/usr/bin/time -l` 测 CLI 的峰值 RSS（输入为合法 JSON 文件）：

| 输入 | 峰值 RSS | 相对输入 | 说明 |
| --- | --- | --- | --- |
| 0.62 MB（对象数组） | 15.3 MB | 24.3 × | 固定开销（运行时约 2.2 MB + 解析树 + 输出缓冲）在小输入上占比更高 |
| 3.17 MB（对象数组） | 59.1 MB | 18.4 × | — |
| 6.37 MB（对象数组） | 116.4 MB | 18.0 × | — |
| 12.95 MB（对象数组） | 231.4 MB | 17.6 × | `--check` 与正常输出的峰值相同，说明峰值来自解析树，而不是输出拼接 |
| 8.46 MB（纯数组） | 169.2 MB | 20.0 × | 元素多、字符串短时每个值的固定开销占比更高 |
| 10.00 MB（单个字符串） | 380.2 MB | 38.0 × | 一个 token 被复制三次：`parts` → `parts_text()` → `Json::string` |
| `{}`（进程基线） | 2.2 MB | — | — |

（0.3.0 复测。峰值与 0.2.0 同机对照为 +1% 以内：新增的精确度水位与
关闭状态的增量钩子都不分配内存。）

**这张表只是自比，不能回答「4 倍预算是否现实」。** 0.4.0 补了同机横向基线
（`code/tests/memory_baseline.py` → `docs/MEMORY.md`，同一份 12.95 MB 文档）：

| 实现 | 峰值 RSS | 相对输入 |
| --- | --- | --- |
| Node `JSON.parse` + `JSON.stringify` | 137.5 MB | 10.6 × |
| JSONMend `--check`（建树、不输出） | 177.9 MB | 13.7 × |
| JSONMend（默认修复） | 177.9 MB | 13.7 × |
| Python `json.loads` + `json.dumps` | 185.5 MB | 14.3 ×（tracemalloc 峰值 66.7 MB） |

也就是说：**4 × 输入对任何建树实现都不现实，Node 自己就是 10.6 ×**。
JSONMend 比 Node 高约 29%，差额来自同时存活的记录数组与输出缓冲；`--check` 与
默认路径峰值相同，说明峰值来自值树而不是输出。结论是 N2（无树模式）仍是唯一
能达标的路线，但「4 倍」这个阈值本身应先按横向基线重新定义，而不是继续当作
未达标项记在 JSONMend 头上。

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
| 对象数组 | 0.62 MB | 0.040 s | 15.7 MB/s | 15.3 MB |
| 对象数组 | 3.17 MB | 0.110 s | 29.3 MB/s | 59.1 MB |
| 对象数组 | 6.37 MB | 0.230 s | 28.1 MB/s | 116.4 MB |
| 对象数组 | 12.95 MB | 0.470 s | 28.0 MB/s | 231.4 MB |
| 纯数组 | 8.46 MB | 0.320 s | 26.4 MB/s | 169.2 MB |
| 单串 | 10.00 MB | 0.280 s | 35.7 MB/s | 380.2 MB |

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

### JS 后端的性能决策记录（O-11）

| 项 | 内容 |
| --- | --- |
| 现象 | JS 后端 4n/2n 比值中位数 2.4–2.5，超过 2.3 的线性阈值；10 MB 档吞吐从 31.0 降到 21.6 MB/s |
| 归因 | `moonc` 生成的 JS 里 `Position` 是对象，`advance()` 每推进一个输入码元就 `new Position(...)`：10 MB 输入约一千万个短生命周期对象，活堆越大 GC 扫描越贵 |
| 已尝试 | 把 `Position` 字段改成 `mut` 并原地更新。**回滚**：引擎把 `tok_start` / `fence_start` 等历史位置与当前位置共用同一个对象，原地更新会连带改掉历史位置，5 个黄金/流式用例失败（`R001@19 != R001@0`、`E022(5,@7) != E022(5,@2)`） |
| 决策 | 0.3.0 不修。理由：这是产物层面的分配模式问题，正确改法是把「当前位置」（三个 `Int32` 字段）与「历史位置」（不可变 `Position`）分离，只在 token 边界物化位置结构，属于引擎内部重构；而 JS 后端的绝对吞吐（21.6–39.0 MB/s）远高于 5 MB/s 的验收下限，线性度只影响 10 MB 以上的浏览器场景 |
| 下一步 | 若 10 MB 以上的浏览器输入成为真实场景：先做「当前位置内联为三个 `Int32`」的改动，再用本节的 10 MB 档复测 |

## 产物体积（TC-B-05）

| 产物 | 大小 | 说明 |
| --- | --- | --- |
| `bench/probe`（wasm-gc release） | 103 784 B（101.4 KiB） | 最小消费者：调用 `repair`、`PartialParser`、`is_valid_json`，代表库的真实增量体积 |
| `examples/web`（JS release） | 290 885 B（284.1 KiB） | 浏览器演示页的完整 bundle（含运行时）；同一文件即 `static/demo/jsonmend.js` |
| `cmd/jsonmend`（native release） | 638 816 B（623.8 KiB） | 命令行可执行文件（macOS arm64） |

## 备注

- 瑕疵 JSON 比合法 JSON 更快（native 48–56 MB/s）：合法 JSON 会完整构建
  `Json` 值，而大量瑕疵语料在更早的分支上就被丢弃或短路。
- 字符串批处理快路径（`Engine::push_run`）把连续普通字符一次并入，超长字符串
  1 MB 达到 native 594 MB/s、JS 287 MB/s；`parse-only` 档（只建树不产文本）
  仍受 `Json` 分配限制，native 40.6 MB/s。
- 0.3.0 新增的精确度标签与增量流没有改变默认路径的开销：`Exactness` 只是一个
  `Int32` 枚举水位，`max_loss` 是一条比较，`collect_deltas` 关闭时每个钩子只多一次分支。
  同机对照：0.2.0 与本轮在同一台机器上合法 JSON 均为 41–43 MB/s。
- JS 后端在 10 MB 档降到 20.3 MB/s，主要来自字符串拼接与 `Json` 对象的分配；
  仍高于 5 MB/s 的下限。
- 数字与机器强相关（散热、后台负载、Node 版本）。复现时请以 `bench.sh` 的
  当次输出为准，不要引用本文件的绝对值作为验收依据。**上表是单机单次观测**，
  同一台机器上不同轮次的差异可达 ±15%，不同机型（尤其是 CI 容器）差异更大。
