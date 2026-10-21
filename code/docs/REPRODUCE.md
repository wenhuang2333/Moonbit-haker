# 复现指南（TC-R / NFR-MNT-01）

从零复现本仓库的全部结论：构建、测试、差分、基准、CLI 与演示页。
所有命令都假设工作目录是仓库根目录（`Moonbit 黑客松/`），路径含空格时请加引号。

## 0. 环境

| 依赖 | 版本（实测） | 安装 |
| --- | --- | --- |
| MoonBit 工具链 | `moon 0.1.20261016`、`moonc v0.10.16+b1a0e846e` | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash`，然后 `export PATH="$HOME/.moon/bin:$PATH"` |
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

> **工具链与 bundle 的耦合**：`static/demo/jsonmend.js` 与 `code/npm/vendor/jsonmend.js`
> 是 MoonBit JavaScript 后端的产物，不同 `moonc` 版本的 codegen 会有字节差异。
> CI 安装 `latest`，并对两个 bundle 做 `git diff --exit-code`；升级工具链后先重跑
> `bash static/demo/build.sh && bash code/npm/build.sh`，把新产物一起提交。
> 当前提交产物由 `moon 0.1.20261016` 生成。


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

期望：170 个测试全部通过（0.6.0 发布提交 `cce9ba67` 的 `ci.yml` 第 22 次运行实测；
0.5.0 时是 129 条，增量来自流式语义安全 `stream_readiness` 与标量根守卫的用例）。
0.5.0 的构成为黄金用例 126 条、流式用例 6 块含 21 组断言、属性测试 8 组每组 400 例、
精确度 240 例、增量流、`llm` 适配器 19 例，以及 0.5.0 新增的安全档位 7 例、修复计划
22 例、骨架 5 例。任一后端失败都视为发布阻塞。

长跑（O-6）：把每个属性的用例数从 400 提到 N（上限 1 000 000），本机 1 000 000 例
约 41 s（本机实测：400 → 0.12 s、4 000 → 0.23 s、40 000 → 1.75 s、1 000 000 → 41.2 s）。夜间工作流 `.github/workflows/nightly.yml` 用同一变量跑 1 000 000 例。

```bash
cd code
JSONMEND_LONGRUN=1000000 moon test --target native
```

覆盖率（`-p` 限定到库包，否则 `bench/main.mbt` 会以 0% 计入分母）：

```bash
cd code
moon coverage clean                     # 清掉上一轮的 .trace 文件，避免计数错位
moon test --enable-coverage
moon coverage report -f summary -p zhanshishan/jsonmend      # 根包 2850/3063 = 93.0%
moon coverage report -f summary -p zhanshishan/jsonmend/llm  # llm 包 337/391 = 86.2%
moon coverage report -f summary                               # 含 bench：3187/3907 = 81.6%
```

上表三个数字取自 `ci.yml` 第 22 次运行（run `38781104341`，`cce9ba67`，即 0.6.0
发布提交，2026-10-15T17:53Z）下载的日志：`-p` 报告末尾的 `Total: 2850/3063`、完整
报告末尾的 `Total: 3187/3907`；`llm` 包由完整报告里 `llm/*` 六个文件相加得到
（57+32+74+55+53+66 = 337，分母 70+34+82+59+55+91 = 391），该值自 0.5.0 起未变。
`bench/main.mbt` 以 `0/453` 计入完整报告的分母。第 18 次运行（`f94f9121`）给出的
是 `2371/2661` 与 `2708/3469`，那是上一版提交的数字，已随 0.6.0 一并更新。

`cmd/jsonmend` 在覆盖率报告里会因 `quit()` 的 native 实现而抛内部错误，属已知的
工具链限制，因此只对根包与 `llm` 包设口径。

## 3. 命令行冒烟测试（TC-C-01）

```bash
cd code
moon build cmd/jsonmend --target native --release
bash tests/cli_smoke.sh                       # 85 项断言，全部 ok 才算通过
bash tests/examples.sh                        # 示例输入与期望输出逐字节对照
bash tests/cli_smoke.sh ./path/to/jsonmend.exe  # 指定其它可执行文件
```

`code/examples/cases/` 下有 6 组 `*.json` 输入与同名 `*.expected` 期望输出
（引号与尾逗号、截断补全、围栏与注释、字面量与非有限值、多根值、前导说明），
`tests/examples.sh` 逐组比较，全部一致才算通过。

## 3b. 接入面一致性（serve / MCP / npm / Python）

```bash
cd code
moon build cmd/jsonmend --target native --release
J=./_build/native/release/build/cmd/jsonmend/jsonmend.exe

# 协议与 MCP：18 组用例（serve 17 + MCP 1），退出码 0 才算通过
python3 tests/conformance/run_conformance.py --cli "$J"

# Python 客户端与 HTTP facade：16 项
(cd python && JSONMEND_BIN="$PWD/../_build/native/release/build/cmd/jsonmend/jsonmend.exe" \
  python3 -m unittest discover -s tests)

# npm 包：10 项；先确保 vendor bundle 与 static/demo/jsonmend.js 一致
(cd npm && node --test)
```

手工试一次协议（每行一个请求、每行一个响应，stdout 只走协议）：

```bash
printf '%s\n' '{"id":1,"method":"hello"}' \
  '{"id":2,"method":"analyze","params":{"text":"{\"words\":[\"a\" \"b\"]}","profile":"execution"}}' \
  '{"id":3,"method":"shutdown"}' | "$J" serve
```

MCP 配置（Claude Code / Cursor / Codex CLI / Gemini CLI / Cline / Windsurf）：

```json
{"mcpServers":{"jsonmend":{"command":"jsonmend","args":["mcp"]}}}
```

协议规范见 `docs/PROTOCOL.md`，用例格式见 `docs/CONFORMANCE.md`，
逐工具配方见 `docs/INTEGRATIONS.md`。

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

脚本产出 402 条用例的对照结果，报告头部记录生成时间、被测二进制的 sha256、两个
参照实现的版本与模块目录、语料构成（固定列表 + 固定变异，无随机种子）。当且仅当
「有文档解释的差异比例 ≥ 90% 且未解释差异为 0」时退出码为 0。
`tests/diff/report.md` 是本地默认输出（已 gitignore），提交版是 `docs/DIVERGENCES.md`。

## 5. 基准（TC-B）

```bash
bash code/tests/bench.sh          # native + js + 体积
bash code/tests/bench.sh native
```

结果与 `docs/BENCHMARK.md` 对照；绝对值随机器变化，判定阈值见该文档。
`bench/main.mbt` 另输出 `deltas`（增量流开销，NFR-PERF-05）、`ttfv`（首个可见值，NFR-PERF-06）、
`agent`（4 KB 工具调用文档按 1/3/16/1024/65536 码元分块，NFR-PERF-07）、
`readiness`（字段就绪曲线成本与十分位，FR-29）与 `gate`（同一份 4.9 KiB 工具调用上
`repair` / `analyze` / `analyze for_agent` / `analyze +schema` / `semantic_readiness`
的单价与相对倍数，FR-32 … FR-36）。

## 5b. 真值评测（TC-EVAL）

协议先冻结（`docs/EVAL_REGISTRATION.md` 的版本号与数据集 sha256），再跑：

```bash
cd code
moon build cmd/jsonmend --target native --release
python3 tests/eval/run_eval.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

1200 条用例（19 个变异族 + 1 个对照组，每族 60 条，固定种子 `20261015`）经 `--batch` 一次性喂入，
产出 `docs/EVAL.md`。四条预登记判据全 PASS 时退出码为 0，`--allow-fail` 可只看报告。
语料本身可校验：`python3 tests/eval/corpus.py` 打印数据集指纹。

同一语料上的参照库对照（`jsonrepair` 3.15.0 / `json_repair` 0.64.0）与多路径评测：

```bash
cd code
python3 tests/eval/refcompare.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/run_eval_paths.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

对抗歧义语料与「判据机制本身可失败」的守卫：

```bash
cd code
python3 tests/eval/run_ambiguity.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
python3 tests/eval/check_amb_guard.py  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

`run_ambiguity.py` 的对照列需要 `jsonrepair`（Node，默认从 `/private/tmp/node_modules` 取，
用 `--node-dir` 改）与 `json_repair`（Python）。**两者缺失时脚本不失败**，
只在报告里把对应列写成 `n/a (library not installed)`，因为对照列是信息性的，
而 suite 自身只依赖 JSONMend 的判定——否则这套证据就只能在一台机器上跑得出来。

独立第三方语料（`nst/JSONTestSuite`，MIT，逐字节 vendor 在
`code/tests/eval/third_party/jsontestsuite/`），用来补上「1200 条语料是自造的、
缺少独立评测」这个证据缺口：

```bash
cd code
python3 tests/eval/run_independent.py
```

318 个文件（95 `y_` / 188 `n_` / 35 `i_`）逐个喂给 `jsonmend --report`，并用同一份
输入对照 `json_repair` 与 `jsonrepair`，产出 `docs/EVAL_INDEPENDENT.md`。判据不是我们
定的：`y_` 是**合法 JSON**，合法文档必须零修复，所以那里的每一条修复记录都是误报。
两个 oracle 缺失时同样不失败，对应列写成 `n/a (library not installed)`。上游 URL、
commit SHA、许可与「不得修改 vendor 文件」的约定见
`tests/eval/third_party/jsontestsuite/PROVENANCE.md`。

骨架就绪表（同一份输入上「语法就绪」与「骨架就绪」两个分数的七个场景）：

```bash
cd code
python3 tests/eval/run_readiness.py \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe --check
```

`--check` 要求表里既有落差（某场景骨架就绪远早于语法就绪）也有并列（声明字段就是最后写的东西），
否则脚本失败——一张永远给出同一个数的表证明不了任何事。产出 `docs/READINESS.md`。

横向内存基线（与 Node / Python 同文件对照）：

```bash
cd code
python3 tests/memory_baseline.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

`llm` 夹具由生成脚本与 MoonBit 内嵌副本同源产出，检查是否同步：

```bash
python3 tests/gen_llm_fixtures.py --check
```

`llm` 适配器的三类证据（合成夹具、文档转录、真实录制）与其来源的区别见
`docs/LLM_EVENTS.md`；本机凭据探测的结果与「有 Key 时的一条命令」见
`docs/PROVIDER_PROBE.md`。

真实传输的 loopback 录制（不需要任何第三方 Key）：`record_stream.py --loopback`
在 `127.0.0.1` 起一个本地 HTTP 服务，按 Anthropic `/v1/messages` 线格式发真实 SSE
字节流，再用普通 HTTP 客户端从真实 socket 读回，写出的夹具标记为
`transport: loopback-sse`（四个场景：正常工具调用、`\uXXXX` 转义中间切分、
无 `message_stop` 的截断、交错的并行工具调用）：

```bash
cd code
python3 tests/record_stream.py --loopback --out llm/fixtures \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

一条命令重录并逐字节比对全部 loopback 夹具，再把每个夹具同时经 `--sse`（原始字节）
与 `.jsonl`（逐行载荷）喂给真实 CLI 并对照金标准（CI 中也会执行）：

```bash
cd code
python3 tests/run_llm_loopback.py
```

真实供应商流的录制（需要凭据）：`docs/PROVIDER_PROBE.md` 记录了本机的探测结果——
没有第一方供应商 Key，只有一个 Anthropic 兼容中继（Claude Code 的
`~/.claude/settings.json` 里配置的 endpoint），`live_relay_*.{sse,jsonl}` 就是它的
实况录制，标记为 `transport: live-http-sse`。有 Key 时的命令用 `read -s`，密钥不进
shell 历史：

```bash
cd code
read -rsp 'ANTHROPIC_API_KEY: ' ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY && \
  python3 tests/record_stream.py --provider anthropic \
    --out llm/fixtures/anthropic_recorded.jsonl \
    --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
# 已有 Claude Code 配置时，连密钥都不用手输：
python3 tests/record_stream.py --provider anthropic --from-claude-settings \
  --out llm/fixtures/live_relay_tool_call.jsonl \
  --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

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
`repair` / `report` / `snapshot` / `live`），页面内没有第二份实现。

`static/demo/live.html` 是 0.5.0 的实时演示页，同样只调用 bundle 里的 `live` 入口：
四个场景逐帧重放（截断 → 重试 → 通过；歧义 → 重试 → 通过；唯一读法直接通过；
长尾流 19% 处即可停），一帧里同时给出 `consumed/total`、实时结构、成员就绪、
三个 readiness 数字（语法/骨架/执行）与拒绝时的重试提示。

```bash
open ../static/demo/live.html
python3 test/live_page_check.py     # 可选：无头重放两个场景并截图
```

bundle 冒烟测试（Node 直接执行，CI 中也会先重建再比对，防止提交的 bundle 过期）：

```bash
node code/tests/demo_smoke.mjs        # 四个入口 + 典型修复/记录/快照/实时帧
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
moon run examples/agent_gate --target native --release   # 拒绝 → 回灌 → 再执行
moon run examples/agent_loop --target native --release   # 自愈闭环：四次 episode，两次成功
python3 tests/diff/run_diff.py --cli ./_build/native/release/build/cmd/jsonmend/jsonmend.exe
bash tests/bench.sh size                       # wasm-gc ≤ 150 KB（当前 103 784 B）
node ../code/tests/demo_smoke.mjs              # 演示 bundle 仍可用
```

逐项状态（含未达标项）见 `docs/TRACEABILITY.md`。

### 7.1 发布到 mooncakes.io

**第一条规则：先探测，再打标签。** 标签一旦推送不再移动，而平台限制只能在
`moon publish` 时才暴露——1.0.0 就是这么被拦下的（mooncakes 现阶段只接受
`0.x.y`，`In this very early stage, the major version must be '0'`）。顺序反一次，
选择就要重做。

```bash
moon whoami                 # 必须是模块名里的用户名（当前 zhanshishan）
moon publish --dry-run      # 打包并检查；注意：dry-run 成功也可能以 255 退出，看输出里的 Server status
moon publish                # 上传；成功以 `Server status: 200 OK` 结束
```

`moon.mod` 的 `name` 必须等于 `moon whoami` 的用户名，否则 `moon publish` 报
「User mismatch」。版本与渠道映射见根 `README.md`「发布通道与版本映射」；
发布后把映射表第一行更新到新版本（`cli_smoke.sh` 有断言防止漂移）。

**已知故障与临时通道（1.0.x）**：0.7.0 起 `moon publish` 的上传阶段在本机会
以 `send failed because receiver is gone` 失败（退出码 255），而同一条 token、
同一个已校验产物用 `curl` multipart POST 同一端点 1.7 s 成功——指向 moon 的
HTTP 客户端实现而非账号或网络。因此每次发布**先试官方路径**；若仍失败：

1. 用 `moon package` 产出的已校验 zip 手工 POST：
   `curl -F token=<token> -F file=@<zip> https://mooncakes.io/api/v0/publish`；
2. 用「重复提交得 409 Version … is duplicated」做二次校验；
3. 把这次失败如实记录（这是临时通道，不改变发布的字节）。

工具链升级后按第一条规则复测官方路径；确认修好后删掉本节的手工步骤。

**关于二次校验**：**只有 409 可用**。mooncakes 没有版本查询 API
（`/api/v0/packages/...` 返回 404），而包页 URL 对**任何**版本都返回 200——
连 `9.9.9` 也一样，所以「页面能打开」什么都不能证明。唯一能证明「这个版本存在」
的办法是重新 POST 同一个版本，平台回答 409。

#### 本仓库的实测结果

| mooncakes 版本 | 第一次 POST | 第二次 POST（复核） | 结论 |
| --- | --- | --- | --- |
| `0.7.0` | 200 `{"status":"ok"}` | 409 duplicated | 存在 |
| `0.8.0` | （上一轮发布） | 409 `…is duplicated with an existing version (0.8.0)` | 存在 |
| `0.8.1` | 200 `{"status":"ok"}` | 409 `…is duplicated with an existing version (0.8.1)` | 存在 |

**产物可复现**：0.8.1 的包由 `v1.1.1` 标签重建得到，把 `moon.mod` 与 CLI 的
`--version` 字符串改写为 `0.8.1` 之外**不改一个字节**，两次独立重建得到**同一个
sha256**：

```
size   : 819750 bytes
sha256 : 874bba92a0ba69ec5f0069b45a7bb843cb532461356c9190a8a543bc33d6da43
```

重建脚本是 `test/verify_mooncakes.sh`（一次性脚本，按工作区约定不入库）。

### 7.2 只能在 GitHub 页面上完成的动作（agent 沙箱够不到）

> 1.0.0 起这三项都已完成或已可由仓库 token 走 API 完成；保留本节作为操作指引。

1. **建 Issue 与 PR**：官方要求保留 Issues、PR 与更新记录。`#1`（tracking）与
   `#2`（发布证据）均已关闭，闭环示例见 `docs/GITHUB.md`。
2. **手动触发一次 `nightly.yml`**：Actions 页 → 左侧选 `Nightly` → `Run workflow`；
   此后由 `schedule` 自动运行（首次定时运行已 success）。
3. **确认 Release 页**：`release.yml` 在 `v*` 标签上构建 **6 个资产**
   （Linux CLI、macOS arm64 CLI、Windows CLI、wasm 探针、浏览器包、`SHA256SUMS`）。
   发布后 job 会自动比对「已发布附件」与「已发布 `SHA256SUMS`」，不一致即失败；
   本地查同一个东西：

   ```bash
   GH_TOKEN=<token> bash tests/release_assets.sh v1.1.1
   ```

   > v1.1.0 的附件少了 Windows 二进制（`SHA256SUMS` 里却有它），
   > 这个脚本对 v1.1.0 会退出 1 并指出缺哪个文件——它是那类缺陷的检测器。

## 8. 已知的环境差异

- `moon test` 的默认后端由 `moon.mod` 的 `preferred_target = "wasm"` 决定；
  在 Apple Silicon 上默认落到 wasm-gc，因此 `moon build` 需要显式
  `--target native` 才能产生 CLI 可执行文件。
- CLI 包声明了 `supported_targets = "native"`，不能构建到 JS/wasm 后端。
- 演示 bundle 需要 `examples/web` 包声明 `supported_targets = "js"`。
- `/usr/bin/time -l` 是 macOS 的写法；Linux 上改用 `/usr/bin/time -v` 看
  `Maximum resident set size`。
