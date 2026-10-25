# 内存基线：按模式与跨实现对照（NFR-PERF-04）

由 `code/tests/memory_baseline.py` 在 2026-10-25 19:54 CST 生成。

| 环境 | 值 |
| --- | --- |
| 输入 | 同一份对象数组文档，13579171 B（12.95 MB） |
| 计时工具 | `/usr/bin/time -l`（峰值 RSS） |
| JSONMend | `_build/native/release/build/cmd/jsonmend/jsonmend.exe` |
| Node | v24.15.0 |
| Python | 3.12.6 |

## 一、按模式的峰值内存

| 模式 | 工作负载 | 指标 | 峰值 | 相对输入 | 备注 |
| --- | --- | --- | --- | --- | --- |
| repair() | 值树 + 渲染输出 | 峰值 RSS | 177.8 MB | 13.7 × |  |
| analyze() | 计划（explain --json），不渲染值 | 峰值 RSS | 326.2 MB | 25.2 × |  |
| streaming feed | 默认 64 KiB 分块（主路径，渲染输出） | 峰值工作集（峰值 RSS） | 177.8 MB | 13.7 × |  |
| streaming readiness | 字段就绪事件流（readiness） | 峰值工作集（峰值 RSS） | 202.7 MB | 15.7 × |  |
| text-only (llm --text) | 文本增量 → TextStream → PartialParser | 峰值工作集（峰值 RSS） | 500.5 MB | 33.7 × | 事件文件 15552749 B（文档的 1.15 ×） |
| no-tree | 完全不建值树 | — | 未测得 | — | 0.6.0 无此模式：`Options::for_text()` 仍走建树解析，未测得 |

`analyze()` 比 `repair()` 高（326.2 MB vs 177.8 MB，1.83 ×）：计划模式并不更省，因为它同样建值树，还额外保留修复后的文本并渲染整份机器可读计划。

每个模式的「相对输入」都是**峰值 RSS ÷ 该模式实际读入的字节数**。
`text-only (llm --text)` 这一行的分母是事件文件（15552749 B），
不是文档本身，因为该模式读的就是事件流。

## 二、与 Node / Python 的横向对照

| 实现 | 峰值 RSS | 相对输入 | 相对 Node | 备注 |
| --- | --- | --- | --- | --- |
| python3 json.loads + json.dumps | 185.1 MB | 14.3 × | 1.35 × | tracemalloc 峰值 66.7 MB，即 RSS 的 64% 是解释器与 GC 空闲 |
| node JSON.parse + JSON.stringify | 137.5 MB | 10.6 × | 1.00 × |  |
| jsonmend repair（本表第一行） | 177.8 MB | 13.7 × | 1.29 × | 同一份文档，同一次运行 |

## 三、两条声明目标：声明了，本次未达成 / 未测得

| 目标 | 状态 | 依据 |
| --- | --- | --- |
| text-only ≤ 4 × 输入 | 33.7 × 事件文件（目标 ≤ 4 × 输入，未据此判定达成） | 该数值里含事件文件本身的 15552749 B（文档的 1.15 ×）与 `read_all` 的整段缓冲，只能作为上界，不能用来宣称纯文本路径达标 |
| no-tree ≤ 2 × 输入 | 未达成（模式不存在） | `Options::for_text()` 仍然建值树，0.6.0 没有关闭建树的入口，因此这条目标只能声明、不能测 |

这两条目标来自 0.6.0 冻结的内存策略。本文件只报告状态：不把「流式路径的峰值恰好低于 4 ×」当成达标，因为该峰值包含整段输入缓冲（见下一节），也不把尚未实现的 no-tree 写成达标。

## 四、这张表能回答什么，不能回答什么

能回答：**同一份文档、同一个「读入 + 建树 + 保留」工作负载**下，各模式的峰值差多少，以及 JSONMend 与调用方本来就会用的两个运行时相比是高还是低。

不能回答：MoonBit **core** 的 `@json.parse` 单独占多少。core 没有文件读取入口，本库也刻意不暴露一个。能测到的最接近的两臂是 `--check`（建树、不渲染，本次 103.6 MB）与 `repair()`（建树并渲染，本次 177.8 MB）：`--check` 现在设置 `want_text=false`，所以两者之差是**渲染输出**的边际成本；剩下的 103.6 MB 是值树与字符串 parts，core 自身在这部分里占多少，从这两个数里拆不出来。要一个精确的 core 基线，需要给基准程序加一个 FFI 读文件入口（core 自身没有文件读取 API）。

默认的 `repair` / `--check` 主路径按 64 KiB `fread` 分块，每块直接 `feed_bytes` 给解析器，不把整份输入读成第二个 `String`；`explain`、`readiness`、`batch` 与 `llm` 仍然 `read_all`，所以这些臂的峰值还包含整份输入文本。主路径保留 1 MiB 前缀用于错误摘录，分块本身不保留。`streaming feed`、`readiness`、`llm --text` 三行之间以及它们与 `repair` 之间的差额，是计划、事件表与渲染输出的**边际**成本，而不是「流式模式省掉了值树」的证据。

另外，Python 一行的备注给出 `tracemalloc` 峰值：它是 Python **自身分配**的精确值，与 RSS 的差额是解释器与 GC 的空闲内存。把这个差值当成「实现效率」是不对的，这也是为什么同一张表里既给 RSS 也给 tracemalloc。
