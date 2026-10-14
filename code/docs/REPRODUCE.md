# 复现指南（TC-R / NFR-MNT-01）

从零复现本仓库的全部结论：构建、测试、差分、基准、CLI 与演示页。
所有命令都假设工作目录是仓库根目录（`Moonbit 黑客松/`），路径含空格时请加引号。

## 0. 环境

| 依赖 | 版本（实测） | 安装 |
| --- | --- | --- |
| MoonBit 工具链 | `moon 0.1.20261012`、`moonc v0.10.15+943464bfa` | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash`，然后 `export PATH="$HOME/.moon/bin:$PATH"` |
| Python | 3.9+ | 差分测试脚本 |
| `json-repair`（Python） | 0.64.0 | `python3 -m pip install "json-repair==0.64.0"` |
| Node.js | 24.x | JS 后端、演示 bundle 冒烟测试与第二个差分参照 |
| `jsonrepair`（npm） | 3.15.0 | `npm install "jsonrepair@3.15.0"`；脚本会自动搜索 `NODE_PATH`、仓库内 `node_modules`、`/tmp/node_modules` 与 `npm root -g`，也可以用 `--node-module-dir` 指定 |

CI（`.github/workflows/ci.yml`）用同样的依赖版本执行下面第 1–6 节的命令。

```bash
export PATH="$HOME/.moon/bin:$PATH"
cd code
moon version --all
```

## 1. 构建与静态检查

```bash
cd code
moon check --deny-warn        # 0 errors, 0 warnings（警告即失败）
moon fmt --check              # 格式一致
moon build --target native --release
moon build --target wasm-gc --release
moon build --target js --release
```

## 2. 单元测试（黄金用例 + 流式用例 + 属性/模糊）

```bash
cd code
moon test                      # 默认后端（wasm-gc）
moon test --target native      # 本机后端
moon test --target js          # JS 后端
```

期望：32 个测试块全部通过（黄金用例 126 条、流式用例 6 块含 21 组断言、属性测试 8 组，
每组 400 例）。任一后端失败都视为发布阻塞。

覆盖率（`-p` 限定到库包，否则 `bench/main.mbt` 会以 0% 计入分母）：

```bash
cd code
moon coverage clean                     # 清掉上一轮的 .trace 文件，避免计数错位
moon test --enable-coverage
moon coverage report -f summary -p wenhuang2333/jsonmend   # 库代码 1137/1223 = 93.0%
moon coverage report -f summary                             # 含 bench：1137/1393 = 81.6%
```

## 3. 命令行冒烟测试（TC-C-01）

```bash
cd code
moon build cmd/jsonmend --target native --release
bash tests/cli_smoke.sh                       # 25 项断言，全部 ok 才算通过
bash tests/examples.sh                        # 示例输入与期望输出逐字节对照
bash tests/cli_smoke.sh ./path/to/jsonmend.exe  # 指定其它可执行文件
```

`code/examples/cases/` 下有 6 组 `*.json` 输入与同名 `*.expected` 期望输出
（引号与尾逗号、截断补全、围栏与注释、字面量与非有限值、多根值、前导说明），
`tests/examples.sh` 逐组比较，全部一致才算通过。

## 4. 差分测试（TC-D）

```bash
cd code
moon build cmd/jsonmend --target native --release

# 只用 Python 参照（node 参照不可用时自动跳过并说明，而不是记 0%）
python3 tests/diff/run_diff.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe --no-node

# 两个参照都跑：模块目录自动探测，也可显式指定
python3 tests/diff/run_diff.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe \
  --node-module-dir "$(npm root -g)" \
  --out /tmp/diff-report.md

# 提交版报告：--no-stamp 去掉日期与二进制哈希，输出逐字节可复现
python3 tests/diff/run_diff.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe \
  --no-stamp --out docs/DIVERGENCES.md
```

脚本产出 389 条用例的对照结果，报告头部记录生成时间、被测二进制的 sha256、两个
参照实现的版本与模块目录、语料构成（固定列表 + 固定变异，无随机种子）。当且仅当
「有文档解释的差异比例 ≥ 90% 且未解释差异为 0」时退出码为 0。
`tests/diff/report.md` 是本地默认输出（已 gitignore），提交版是 `docs/DIVERGENCES.md`。

## 5. 基准（TC-B）

```bash
bash code/tests/bench.sh          # native + js + 体积
bash code/tests/bench.sh native
```

结果与 `docs/BENCHMARK.md` 对照；绝对值随机器变化，判定阈值见该文档。

## 6. 浏览器演示页（TC-W-01）

演示页不依赖构建（bundle 已提交）：

```bash
cd code && moon build examples/web --target js --release
cp _build/js/release/build/examples/web/web.js ../static/demo/jsonmend.js

# 打开静态页（file:// 即可，无需服务器）
open ../static/demo/index.html
# 或：bash ../static/demo/build.sh   # 重新生成 bundle 并复制
```

页面上的「一次性修复」「修复记录」「流式快照」三个区域都由 MoonBit 的 JS 产物
直接驱动（`code/examples/web/main.mbt` 通过 `globalThis.jsonmendRegister*` 暴露
`repair` / `report` / `snapshot`），页面内没有第二份实现。

bundle 冒烟测试（Node 直接执行，CI 中也会先重建再比对，防止提交的 bundle 过期）：

```bash
node code/tests/demo_smoke.mjs        # 10 项断言：三个入口 + 典型修复/记录/快照
bash static/demo/build.sh && git diff --exit-code -- static/demo/jsonmend.js
```

无头验证（可选，需要 Python Playwright）：

```python
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    page = p.chromium.launch(headless=True).new_page()
    page.goto("file:///.../static/demo/index.html")
    page.wait_for_load_state("networkidle")
    print(page.locator("#out").inner_text())
```

## 7. 发布检查清单（TC-R）

```bash
cd code
moon check --deny-warn && moon fmt --check     # 无警告、格式一致
moon test && moon test --target native && moon test --target js
bash tests/cli_smoke.sh && bash tests/examples.sh
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
bash tests/bench.sh size                       # wasm-gc ≤ 150 KB（当前 98 247 B）
node ../code/tests/demo_smoke.mjs              # 演示 bundle 仍可用
```

逐项状态（含未达标项）见 `docs/TRACEABILITY.md`。

## 8. 已知的环境差异

- `moon test` 的默认后端由 `moon.mod` 的 `preferred_target = "wasm"` 决定；
  在 Apple Silicon 上默认落到 wasm-gc，因此 `moon build` 需要显式
  `--target native` 才能产生 CLI 可执行文件。
- CLI 包声明了 `supported_targets = "native"`，不能构建到 JS/wasm 后端。
- 演示 bundle 需要 `examples/web` 包声明 `supported_targets = "js"`。
- `/usr/bin/time -l` 是 macOS 的写法；Linux 上改用 `/usr/bin/time -v` 看
  `Maximum resident set size`。
