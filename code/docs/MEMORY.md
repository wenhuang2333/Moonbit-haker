# 内存基线：与 Node / Python 的横向对照（NFR-PERF-04）

由 `code/tests/memory_baseline.py` 在 2026-10-15 18:01 CST 生成。

| 项 | 值 |
| --- | --- |
| 输入 | 同一份对象数组文档，13579171 B（12.95 MB） |
| 计时工具 | `/usr/bin/time -l` |
| JSONMend | `../../../../../tmp/jsonmend` |
| Node | v24.15.0 |
| Python | 3.12.6 |

## 峰值 RSS

| 实现 | 峰值 RSS | 相对输入 | 相对 Node | 备注 |
| --- | --- | --- | --- | --- |
| python3 json.loads + json.dumps | 185.5 MB | 14.3 × | 1.35 × | tracemalloc peak 66.7 MB, i.e. 64% of the RSS is interpreter + GC slack |
| node JSON.parse + JSON.stringify | 137.5 MB | 10.6 × | 1.00 × |  |
| jsonmend (default repair) | 177.9 MB | 13.7 × | 1.29 × |  |
| jsonmend --chunk 65536 (streaming) | 177.9 MB | 13.7 × | 1.29 × |  |
| jsonmend --check (no output written) | 177.9 MB | 13.7 × | 1.29 × |  |

## 这张表能回答什么，不能回答什么

能回答：**同样的文档、同样的「读入 + 建树 + 保留」工作负载**下，JSONMend 的峰值内存与调用方本来就会用的两个运行时相比是高还是低、差多少倍。NFR-PERF-04 的「≤ 4 × 输入」是否现实，取决于这个差距，而不是取决于 0.3.0 与 0.2.0 的自比。

不能回答：MoonBit **core** 的 `@json.parse` 单独占多少。core 没有文件读取入口，本库也刻意不暴露一个，所以能测到的最接近的两臂是 `jsonmend --check`（建树但不渲染输出）与 `jsonmend`（建树并渲染），两者峰值相同即说明峰值来自值树而不是输出。两者的差异是引擎的记录数组与位置对象，量级远小于此处比较的实现间差异，但如果需要一个精确的 core 基线，需要给基准程序加一个 FFI 读文件入口（core 自身没有文件读取 API）。

另外，Python 一行的注释给出 `tracemalloc` 峰值：它是 Python **自身分配**的精确值，与 RSS 的差额是解释器与 GC 的空闲内存。把这个差值当成「实现效率」是不对的，这也是为什么同一张表里既给 RSS 也给 tracemalloc。
