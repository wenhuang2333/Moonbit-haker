# Changelog

本文件记录 InterJSON 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.5.1] - 2026-10-29

1.5.0 的 tag 打出去之后，深度与内存上的工作才做完。两者不能混在一个版本里：
**tag 是发布物，分支是后来者**，而 1.5.0 的二进制与 1.5.0 的文档说的不是同一件事。
这一节把 tag 之后进默认分支的引擎工作单独记下来，并重新发布——
**"README 说的"和"你装到的"必须是同一个东西**，否则发布这件事就没有意义。

版本对应 **1.5.1**（GitHub）↔ **0.13.0**（mooncakes）。

### 深度：`max_depth` 不再只能收紧

值上的四个遍历——`copy_json`、`json_equal`、`Schema::evaluate`、渲染——原本都是递归的，
所以"能处理多深"是原生栈的属性而不是机器的属性：wasm 后端在 896–1024 帧之间爆栈。
1.5.0 把 `max_depth` 卡在 512，正是为了让"拒绝而不是崩溃"成立，代价是调用方只能收紧、
不能放宽。四者都改成显式工作列表（渲染器同时替掉 core 里递归的 `Json::stringify`，
包括 plan 的 `value` 字段），上限因此变成防笔误的理智上界 `MAX_VALUE_DEPTH = 1048576`：
**10 万层的文档四个后端都能解析、渲染、判等、拷贝**。

声明（JSON Schema 与骨架 DSL）仍由两个递归解析器读，`MAX_SCHEMA_DEPTH = 256` 保留——
这是目前唯一还受栈限制的地方，`SECURITY.md` 如实这么写。

### 内存：三处真实浪费

- **数值**：每个数字都把源文本存成 `repr`，于是整数文档为每个整数分配一个 `String`，
  而那个文本对 `Double` 是可往返的、白存。现在只在文本确实承载信息时才存
  （`1.0`、`1e2`、`-0`、`9007199254740993` 仍然存；`12345` 不存），
  与核心序列化器的一致性由 `TC-R-24` 钉住。
- **容器**：`Map([])` 一次开八个槽、`Array` 同理，单键对象为另外七个空槽付费，
  且每一帧无论种类都同时分配数组和映射。现在容器按实际内容定尺寸（关闭时一次），
  帧只为自己的种类分配。
- **渲染器**：原本把容器的全部子节点一次性压进工作列表，对百万元素数组来说那就是峰值
  分配；改成游标逐个走。

实测（20 万元素，边际峰值 ÷ 输入）：整数 9.7 → **5.2 倍**、嵌套数组 47 → **24 倍**、
对象 29 → **24 倍**。标量进入 4 倍预算；容器没有，且在值是 core 的 `Json` 时不可能进入。

### 门：内存从"被打印"变成"被守住"

新增 `code/tests/memory_gate.py` 并接入 CI：同一组形状、每个形状一条记录的天花板，
涨过就失败。此前 `docs/MEMORY.md` 的数字只是被打印，漂了没人发现。已验证它能抓住真实
回退——把 `shrink_array` 关掉后 `[[1]]` 从 26.8 倍涨到 46.5 倍，门 exit 1。

### 文档

- 发布面 **478 KB → 346 KB**：删除 `PITCH.md`、`ONEPAGE.md`，三份 README 去重，
  1.2.0 及更早的更新日志移出发布面（旧条目在本地 `marks/CHANGELOG-history.md`，
  也仍在 git 历史与 GitHub Release 里）。
- 新增 `code/docs/NOTREE.md`：无树模式的完整设计——要解决的问题、四个真正需要值的点、
  验收判据、实施顺序。**它是设计，不是已实现的功能。**
- 已发布文档不再引用未发布文档（此前有 33 处死链，其中 `code/README.md` 是 mooncakes 包页）。

### 语言包：npm 与 PyPI 都发布了（2026-10-30）

`interjson-moonbit@1.5.1` 于 2026-10-30 发布到 npm 与 PyPI。两个渠道的安装形态不同，
这不是疏漏：

- **npm**：包内带引擎的 JavaScript 编译产物（`vendor/interjson.js`），装完在 Node 里
  直接可调；`interjson-mcp` 启动器仍需要原生二进制。
- **PyPI**：wheel 内带**四个平台的 native 二进制**（`linux-x86_64`、`linux-arm64`、
  `macos-arm64`、`windows-x86_64`，共约 3.4 MB 未压缩），`find_binary()` 按
  `sys.platform` + `platform.machine()` 选当前平台那一份。`pip install interjson-moonbit`
  是完整安装，不需要 `INTERJSON_BIN`、不需要 PATH 上有 `interjson`、不需要 MoonBit
  工具链。

  在此之前 Python 包是个"壳"：`pip install` 之后第一次调用会
  `FileNotFoundError: the interjson engine was not found`。把二进制放进 wheel 是唯一
  能消掉这一步的做法——装的时候不编译，跑的时候不下载。`code/python/build_wheel.sh`
  从 Release 取四个二进制并逐个核对 Release 自带的 `SHA256SUMS`，构建后断言 wheel 里
  确实有它们；`code/tests/package_dist.sh` 在空 venv 里装这个 wheel 并断言
  `find_binary()` 落到 `site-packages` 内、`repair`/`analyze`/`interjson-mcp` 都能用。

  轮到不支持的平台（Intel macOS）时，报错会说明"本包带的是哪些平台"，而不是让人
  反复重装一个不可能有产物的包。

### 未做的事（如实记录）

- **PyPI 上只有 wheel，没有可用的 sdist 安装路径之外的额外渠道**：sdist 里也带二进制，
  所以从 sdist 装同样自包含；但 `pip install` 默认取 wheel，这是被测试覆盖的那条。
- 「不建树、只出文本」的模式仍未实现：标量已在 4 倍预算内，**容器不在**（24–27 倍），
  而容器倍数在值是 core 的 `Json` 时不可能降下来。设计与验收判据见 `docs/NOTREE.md`。
- `PreToolUse` hook 配方是手工验证的草图，不是本仓库测试套件覆盖的配置。
- **文档体量仍高于评审给的 ≤ 120 KB 目标。** 随仓库发布的 markdown 从 **478 KB 降到
  337 KB**（−30%）。本轮删掉 `PITCH.md` 与 `ONEPAGE.md`，把三份 README 去重
  （根 README 62→37 KB、`code/README.md` 52→34 KB、`code/README.zh.md` 54→13 KB），
  并把 1.2.0 及更早的全部更新日志移出发布面（`CHANGELOG.md` 83→24.5 KB；旧条目在本地
  `marks/CHANGELOG-history.md`，也仍在 git 历史与 GitHub Release 里）。
  剩下的 337 KB 里，**83 KB 是生成的证据**（`DIVERGENCES.md` 40 KB、`EVAL_*` 43 KB，
  由流水线写、不由人写），96 KB 是三份 README，其余 158 KB 是接入文档与规范。
  再往下压只能压证据或压 API 参考——那是删内容，不是删重复，所以没做。

## [1.5.0] - 2026-10-28

修**两处「错误放行」**、一处**拒绝契约**、一处**档位定义漂移**，以及 CLI / MCP 协议 /
编码边界上的一组缺陷。这些缺陷都不是靠跑测试发现的，是读代码读出来的——它们全都在
「测试绿」的状态下发布过，这本身就是这一节要记下来的事实。

版本对应 **1.5.0**（GitHub）↔ **0.12.0**（mooncakes）。发布状态：
**`0.12.0` 已于 2026-10-28 上传 mooncakes**（`moon search interjson` 可见，
重复上传返回 409）；GitHub 侧 tag `v1.5.0` 已推送，Release 随该 tag 构建。
语言包当时还没有发布；npm 与 PyPI 的 `interjson-moonbit@1.5.1` 于 2026-10-30 补齐。

第一次打 tag 时 Release 失败了：`macos-15-intel` 这个矩阵项装不上 MoonBit 工具链
（`cli.moonbitlang.com/install/unix.sh` 只认 `Darwin arm64`、`Linux x86_64`、
`Linux aarch64`）。**平台矩阵不是选择题，是工具链给什么就是什么**；该矩阵项已删除，
安装脚本在 Intel Mac 上直接说明原因。

**`v1.5.0` 的 tag 被重新指向过一次**，需要记下来，因为它与本项目的发布规则相悖。
规则是「标签一旦推送不再移动」，理由是 tag 是任何引用的锚点，移动它等于改写历史。
那次移动的条件是：**Release 工作流失败、一个产物都没有对外发布、Release 记录不存在**，
所以移动没有改写任何已存在的引用。移动之后的正确做法是**不再移动**——1.5.0 之后每一处
引擎或文档的变化都进新版本，1.5.1 就是这么来的。规则没有变，只是首次破例的理由被记下来
而不是被忘掉。

### 两处「错误放行」（P0）

- **`json_equal` 按 `Double` 比较数字**：`9007199254740993` 与 `9007199254740992` 是
  2^53 之后相邻的两个整数，作为 `Double` 是同一个数。重复键合并因此被判定为「无损」、
  记为 `Info`，门对**一个已经被悄悄改过的值**回答 `executable: true`。现在按数字的
  精确十进制值比较：这一例记为 `R018` + `Warning`（有损、拒绝）。另一个方向也钉住了：
  `1` 与 `1.0`、`100` 与 `1e2`、`0.5` 与 `5e-1`、`-0` 与 `0` 仍是同一个数，合并仍为
  `Info` / `Cosmetic`，不会因为收紧比较而误报。
- **`RuleSet` 写死 22 个槽位**：`RepairCode::number()` 从 1 开始，所以 22 个槽只覆盖
  `R001` … `R021`，把同一轮新增的 `R022 NormalizeLiteral` 落在表外；`is_enabled` 的
  越界分支返回 `true`，于是 `R022` 看起来是开的，`disable(R022)` 却是**静默 no-op**——
  调用方以为自己关掉了一条规则，其实没有。现在表由 `RepairCode::count()` 定尺寸，
  越界一律 **fail-closed**（返回 `false`），`disable` / `enable` 对表外的码直接 abort
  而不是假装成功。这一条修的是**一类**缺陷（表与枚举可能不同步），不是那一个实例。

### 拒绝契约

- **不可执行的结果必带 `retry.prompt`，且 `value` 为 `null`**。1.4.x 里
  `plan_of_final` 对「被接受的结果」设 `retry_hint: None`，于是**被接受但不可执行**的
  计划（`permissive` 下的有损修复；骨架不符的值）序列化成 `"retry": null`，而工具描述
  却让调用方去读 `retry.prompt`——拒绝没有句子，同时对象里还带着一个活的 `value`。
  这正是宿主最不该看到的一种组合。现在：`executable == false` ⇒ `value: null`、
  `text: ""`、`retry.prompt` 非空；`executable == true` ⇒ `value` 存在、`retry: null`。
  两种拒绝路径（`plan_of_error` 与 `plan_of_final`）都覆盖到了。

### 档位定义漂移

- **MCP `agent` 档现在等于 `Options::for_agent()`**。按名字选档（MCP 工具、`--policy`、
  `serve`）此前只应用了 `SafetyPolicy` 的**安全字段**，丢掉了该档的**协议字段**——
  对 `agent` 就是 `skip_prose`。结果是旗舰工具 `interjson_gate` 拒绝最常见的模型输出
  形状 `Here are the args:\n{"a":1}`（`E002`）。现在新增 `Options::with_profile(policy)`
  与 `Options::for_profile(name)`，「一个档是什么意思」只有一处定义，库预设与按名选档
  走同一条路径。`execution` / `strict` / `interactive` / `permissive` 行为不变，仍然
  不跳前言（TC-R-12 钉住这一点）。

### 递归深度加界

- **`Options::max_depth` 有了上限**：新增公开常量 `MAX_VALUE_DEPTH = 512`（值）与
  `MAX_SCHEMA_DEPTH = 256`（声明）。`max_depth` 超过 512 报 `E050`；声明超过 256 报
  `E070`；值超过 `max_depth` 报 `E020`。上限不是策略选择：`copy_json`、`json_equal`、
  `walk_schema` 三个递归遍历与引擎自身的栈帧都以它为界，wasm 后端在 896–1024 帧之间
  会爆栈——上限高于此就把 `E020` 变回它本要防的崩溃。因为 512 也是默认值，实际效果是
  「只能收紧，不能放宽」。
- 新增公开 API：`Options::with_profile(policy)`、`Options::for_profile(name)`、
  `RepairCode::count()`。

### CLI

- **`--max-repairs 10000` 不再报错**：解析复用了上限为 64 的 `parse_uint`，于是
  `--help` 推荐的 10000 是个错误值。现在用 `parse_uint_up_to`，上限 1000000。
- **`--max-prose-buffer=65536` 现在真的是 65536**：等号形式少切了一位，`=65536` 静默
  变成 `5536`——在「缓冲区多大」这个开关上小十二倍。
- **`--print-config claude`（空格形式）可用**，未知客户端名**报错**（退出码 2）而不是
  静默回落成 JSON 配置。此前空格形式下客户端名根本没被读，typo 会打印一份看起来
  正常的配置。
- 版本字符串统一到 `code/version.mbt` 的 `VERSION` / `REGISTRY_VERSION`，`--version`
  与 `serve` 的 `engine` / `registry` 字段都从那里读，不再各写一份字面量。

### 编码与健壮性

- **stdin 只解码一次**：`--batch` / `explain` / `readiness` / `llm` 此前按 64 KiB 分块
  各自 `decode_lossy`，跨块边界的一个多字节字符在**两块里都是非法序列**，于是被解码成
  两个 U+FFFD。中文与 emoji 会静默变成错误结果——命令报告成功，读到的文档却不是写下的
  文档。现在先读字节、最后解码一次，边界不复存在。
- 新增字节级模糊测试套件（`code/fuzz_wbtest.mbt`，TC-F-01…05），把「任何字节序列不得
  panic」从一句文档断言变成被测的断言。

### MCP 协议

- **新增接受 `2025-03-26`**（此前只接受 `2025-06-18` 与 `2024-11-05`）。未知的
  `protocolVersion` 一律回 `2025-06-18`，**绝不回显**客户端给的字符串——回显一个不存在
  的版本会让客户端以为自己谈成了。
- **握手前先报错**：`initialize` 之外的请求在握手前返回 `-32002`。此前 `tools/list`
  在握手前会成功，客户端跳过 `initialize` 后拿到工具列表，却在几步之后才发现
  `instructions` 与协商版本是空的——故障离原因很远。
- **未知工具与非法 `arguments` 返回 `-32602`**：此前未知工具返回工具级 `isError: true`，
  宿主无法区分「工具跑了并拒绝」与「工具名打错了」；非对象的 `arguments` 被当成
  「没有参数」，于是一个格式错误的调用变成「缺少 text」的费解错误。
- **`outputSchema` 改成真正的逐工具 schema**（封闭、列出必需字段），不再是
  `{type: object, additionalProperties: true}`。
- **`content[0].text` 改成摘要**：决策、`executable`、`exactness`、错误与 `retry` 提示；
  载荷只在 `structuredContent` 里出现一次。此前两条通道携带同一份完整对象，一次门调用
  在线路上是两个完整副本（每个副本里还各含一份修复后文本）。

### 打包与安装

- **`code/install.sh`**：一条命令的安装脚本，判断平台 → 下载 Release 产物 → 用 Release
  自带的 `SHA256SUMS` 核对 SHA-256 → 装到 `~/.local/bin` 并打印 `PATH` 提示。校验失败
  是硬失败：删除文件，什么都不装。覆盖三个操作系统上的四个二进制
  （linux-x86_64、linux-arm64、macos-arm64、windows-x86_64）。
  **没有 Intel macOS 产物**：MoonBit 工具链只发布 `darwin-aarch64`、
  `linux-x86_64`、`linux-aarch64`，那个平台连工具链都装不上（2026-10-28 的发布
  尝试就是因此失败的）。安装脚本在 Intel Mac 上直接报错说明原因，而不是下载一个
  不存在的产物。
- `code/npm/package.json` 与 `code/python/pyproject.toml` 补齐发布元数据
  （`repository` / `homepage` / `bugs` / `author` / `engines.node >= 20`、`[project.urls]`、
  `py.typed`），版本改为 `1.5.0`。两个包在 registry 上仍是**待发布**状态。

### 测试

- **243 个测试 × 4 个后端**（wasm-gc / native / JS / wasm；1.4.0 为 217）。新增
  `code/regression_1_5_wbtest.mbt`（TC-R-01…21，本节每一处缺陷都有一条断言）与
  `code/fuzz_wbtest.mbt`（TC-F-01…05，字节级模糊）。
- **122 条 CLI 断言**（1.4.0 为 106）：新增 `--chunk N` 走一次性路径（此前只影响 `--batch`，于是这个用来压流式路径的开关从没碰过它），以及冲突选项报错（`--strict --policy permissive` 此前静默丢弃 `--strict`；`--max-depth` 与 `--policy` 同理），退出码 2。
- **19 组一致性用例**（数量不变，用例变多：MCP 半侧新增 `2025-03-26` 回显、`-32002`、
  `-32602` 与摘要通道检查）。
- 库代码行覆盖率 **4113/4431 = 92.8%**（`tests/coverage.sh` 的 `library` 行口径；
  根包 3851/4115、`llm` 包 337/391）。

## [1.4.0] - 2026-10-27

更名 **InterJSON**，把「LLM 输出的执行门」作为产品定位，对外主入口改为**本地部署的
MCP server**。引擎、修复语义与全部不变量不变；版本对应 **1.4.0**（GitHub）↔
**0.11.0**（mooncakes）。这是模块路径与 MCP 工具名的破坏性重命名；1.3.0 的 registry
对应号 0.10.0 尚未上传 mooncakes，因此 registry 上的已发布历史（0.3.0 … 0.8.1）不构成
升级路径变更。registry 对应号 **0.11.0 已于 2026-10-27 上传 mooncakes**。

### 更名与 MCP

- **产品与模块统一更名**：产品、MoonBit 模块（`zhanshishan/interjson`）、CLI、
  npm/Python 包装层与浏览器 bundle（`interjson.js`）全部使用 InterJSON 命名。
  引擎与修复语义不变；公共 API 的**形状**不变，两处名字随之更改：
  `MendError` → `InterJSONError`，Python 侧 `JsonMendError` → `InterJSONError`。
  这是破坏性的导入变更，因此本轮直接按 minor 发布：版本 1.4.0 ↔ 0.11.0。
- **MCP 主工具改名**：`interjson_analyze` → `interjson_gate`，其余三个工具为
  `interjson_repair` / `interjson_validate` / `interjson_readiness`。`interjson_gate`
  不带 `profile` 时默认走 **`agent`** 档：lossy 或 ambiguous 的修复一律拒绝，
  不替模型猜；结果仍是 `decision` / `executable` / `exactness` / `value` /
  `retry.prompt`。
- **MCP 面补齐协议细节**：`initialize` 返回服务端 instructions；四个工具都声明
  `readOnlyHint` 与 `outputSchema`；协议协商首选 `2025-06-18`、接受 `2024-11-05`，不支持的版本回落到
  `2025-06-18`。stdout 只写 JSON-RPC；没有 `id` 的请求（通知）一律不回答。
  成功结果同时带 `content` 文本与 `structuredContent`，错误结果只带可读文本。
- **配置生成**：`interjson mcp --print-config[=claude|cursor|vscode|codex|windsurf|zed|json]`
  打印对应客户端配置；`--print-config=claude` 输出
  `claude mcp add interjson -- interjson mcp`。
- **同一入口的别名**：`interjson-mcp` 等价于 `interjson mcp`；npm 包
  `interjson-moonbit` 的 bin 为 `interjson-mcp`（需本机原生二进制），Python 包
  同时提供 `interjson-mcp` 控制台入口。
- **文档**：新增 `docs/MCP.md` 作为本地部署指南；`docs/PROTOCOL.md` 补充
  `serve` 与 MCP 的分工（宿主侧传输 vs 模型侧传输）；演示页、CHANGELOG 与
  其余接入文档同步新工具名。更早的版本记录、`static/demo/mcp-claude-session.txt`
  与 `产品文档.md` 是录制/历史证据，保留当时的旧名原文。
- **历史记录的处理**：更早的版本记录、`static/demo/mcp-claude-session.txt` 与
  `产品文档.md` 中出现的 `jsonmend` 与本次改名后的 `interjson` 指代同一对象；
  录制证据保持逐字节原文。已经发布的 Release（`v1.3.0` 及更早）资产文件名仍带
  旧前缀（`jsonmend-*`），下载链接以对应 Release 页面为准；下一次发布起资产改用
  `interjson-*`，命名规则见 `docs/MCP.md`。
- **不变量与数字均未变**：输出必合法 JSON、修复幂等、流式分块不变、快照是稳定
  前缀、任何字节序列不得 panic；README 与文档中的全部数字保持原值。版本统一为
  **1.4.0**（`code/moon.mod`、`--version`、npm/Python 清单与 `serve` 的
  `engine` 字段一致），mooncakes 对应号 **0.11.0**。
- **演示媒体随版本刷新**：`static/demo/` 下的截图、GIF 与录屏由
  `bash code/tests/media/refresh.sh` 在当前构建上重新生成（生成器移入
  `code/tests/media/`），不再保留更名前的旧画面；旧版派生素材
  （`mcp-claude-demo.gif`、`mcp-claude-poster.png`）已删除，
  `static/demo/mcp-claude-session.txt` 作为真实会话的逐字节文字证据保留原文。
- **发布后本地清理**：提交/发布后本地只保留当前版本——`_build/`、`test/`、
  缓存与旧演示媒体删除，历史版本由 GitHub 的提交历史与 Release 保存；旧文档
  不删除，但开头标注「历史档案」且不进入现行入口。规则见 `AGENTS.md`。

## [1.3.0] - 2026-10-26

结构性重构，目标是把三处「每条变更都付一次代价」的设计换成按 token / 按记录付费，
另修一处只影响成本、不影响结果的字节入口缺陷。默认行为不变：`repair`、`parse`、
`snapshot`、`drain_deltas` 的输出与 1.2.0 逐字节一致，只有新增 API 与一处 CLI 默认值
变化。版本对应 **1.3.0**（GitHub）↔ **0.10.0**（mooncakes）——新增公开 API 属 minor，
不能当 1.2.x 补丁。

### 引擎

- **当前位置与历史位置分离**：`Engine.pos : Position` 改为 `pos_offset/pos_line/
  pos_column` 三个整数，新增 `Engine::position()`（冻结成不可变 `Position`）与
  `Engine::advance(u)`。`step_*` 处理器不再携带 `p : Position`，只在真正要记录
  或报错时冻结一次：token 起点、错误点、逗号位置等历史位置仍是冻结的 `Position`，
  绝不与当前游标共享。改造前每个码元构造一个 `Position`，JS 后端因此每码元分配
  一个对象、代价随活跃堆增长；现在每 token / 每记录才物化一次。
- **增量日志改为紧凑数组 + 路径 arena**：`DeltaLog` 用并行数组（`ops`/`ats`/
  `path_ids`/`values`/`texts`）记录变更，路径是 arena 索引而不是一份
  `Array[PathSegment]` 拷贝。`Frame.path` 改为 `Frame.path_id`。arena 本身也是
  三组并行数组（不是「结构体数组」——带引用字段的结构体逐元素装箱，正是这里要
  避免的分配），并带一个内容寻址的单条缓存：同一个槽位的两三次查询（开标记、
  drain 时的文本刷新、落地）只做几次整数比较，不重复建节点。
- **新增 `DeltaView` 与零路径分配的消费入口**：`PartialParser::drain_views()`、
  `PartialParser::for_each_delta()`、`PartialParser::delta_path()`、
  `PartialParser::delta_pointer()`。视图只带 `op`/`at`/`value`/`text`，路径留在
  arena 里按需解码；不调用 `delta_path` 就没有路径分配。`drain_deltas()` 保留为
  兼容层并如实标注其成本（每条变更物化一个 `Delta` 与一份路径数组），
  `NFR-PERF-05` 的口径改登记到新入口上。
- **`Options::validate` 未变**：`collect_deltas` 仍拒绝 `KeepFirst` 与
  `TrimToValid`——这两条是流本身的语义约束，与记录方式无关。
- **不变量保持**：输出合法 JSON、修复幂等、任意分块与一次性结果一致、任何字节
  序列不 panic，全部由原有 212 条测试 × 4 后端继续强制；新增的两条测试断言
  「视图流与物化流逐字段、逐路径解码一致」。
- **字节入口对多字节 UTF-8 序列批量并入**：`feed_bytes` 的 ASCII 快路径（0.1.0 起）
  只认 `b < 0x80`，非 ASCII 字节一个码元一次 `parts.push(c.to_string())`，
  成本随字符数线性增长。现在第一段仍是原来的纯 ASCII 扫描（不带计数器，合进一个新
  循环会让纯 ASCII 慢 15%），第二段用新增的 `plain_utf8_run` 判断「完整 + 最短形式
  + `step_str` 会原样送入 `push_cu`」的序列并整段并入，码元数按 UTF-8 长度累计
  （四字节算两个码元）。`plain_utf8_run` 复制而不是复用 `feed_byte` 的校验：它只决定
  能不能批量，拒绝时一律退回逐字节路径，`E040` 仍由 `feed_byte` 以原来的绝对偏移报出。
  一行 `{"text": "…"}` 的长文本，native 由 38.5–39.6 → 209.7–220.8 Mu/s、JS 由 10.8–11.0 →
  76.3–79.1 Mu/s（4 Mi 码元，`bench -- longtext`，三次运行的区间），按字节算 CJK 与 ASCII 同价；CLI 读一份
  25.17 MB 的单条 CJK 字符串由 0.22–0.24 s 降到 0.04 s，`--check` 峰值 RSS 由
  228.0 MB（9.5 ×）降到 46–54 MB（1.9–2.2 ×，峰值 RSS 随调用上下文抖动）。
  纯 ASCII 与转义密集文本的读数不变。
  影响面限于喂字节的入口：CLI 的默认路径与 `batch` 子命令，以及直接调用
  `feed_bytes` 的库调用方。`serve` 的 `repair` / `watch`、npm 包与浏览器 bundle 走
  字符串入口 `feed`，本来就在快的那个路径上，本次未受影响。

### CLI

- **资源上限可在命令行设置**：新增 `--max-input-len`、`--max-depth`、
  `--max-token-len`（默认值与库一致：67108864 / 512 / 16777216）。此前只有库
  API 能改这三个上限，命令行用户既收不紧也放不宽。数值解析改为「乘之前先比较」，
  超长数字串不再回绕成负数被当成合法上限。
- **`explain --json` 默认不再带修复后全文**：机器可读的计划里已有 `value`，全文
  是第二份整篇拷贝；需要时用新增的 `--with-text` 取回。文本块的 `Repaired:` 行
  不受影响，`serve`/MCP 的 `analyze` 契约也不变。
- **命令行断言 94 → 102 条**：新增三个上限的「咬得住 / 放得开 / 越界拒绝 /
  回绕拒绝」四条与 `--with-text` 正反两条。

### 基准与门禁

- **`median5_single`**：`median5` 按「一轮里的调用次数」摊时间，一旦单次调用超过
  100 ms 就退化成**一个样本**——正是扩张性检查用的大输入，一次 GC 停顿就能独占
  结果。新增按「五次独立单次调用的中位数」测量，JS `4n/2n` 由在 2.2–2.8 之间跳动
  变为稳定值。
- **长文本 arm 与 arm 过滤器**：`bench/main.mbt` 新增 `longtext` 组（4 Mi 码元的纯
  ASCII、CJK、转义密集三种单字符串文档，同时报 `feed` 与 `feed_bytes` 两个入口，单位是
  UTF-16 码元/秒而不是 MB/s），并给 `main` 加了一个参数过滤器：4 MiB 的 CJK 文档会留下
  足够多的垃圾让紧随其后的 JS 读数偏离 30%，所以文档引用的是单独跑的读数
  （`moon run bench --target native --release -- longtext`）。
- **新增 `tests/scaling.sh`**：把 `NFR-PERF-01`（native `2n/n`、`4n/2n` ≤ 2.3）与
  `NFR-PERF-05`（native `for_each_delta` 开销 ≤ 160% 基线）做成 `best-of-N` 比值
  棘轮，进 CI。比值按「先取各尺寸的最小时间、再求比」归约，而不是取比值的最小值：
  两个被干扰放大的时间算出的比值可以落到 1 以下，取最小值会把这个假象留下来。
  JS 的扩张性只打印、不做硬门禁（共享 runner 的 GC 时序抖动大于要防的回归）。
## Earlier versions

`1.2.0` and everything before it — the JSONMend releases, the 1.0 public-API
freeze and the hackathon rounds — are in **`marks/CHANGELOG-history.md`**
(local only) and in the git history and GitHub releases, which is where a
changelog for a published project belongs. This file carried all of it until
1.5.0; at 82 KB it was the largest document in the repository and was being
downloaded by every reader to find the three versions that still matter.

The version-by-version channel mapping (GitHub `v1.x` ↔ mooncakes `0.x`) stays
in `README.md`, which is where an installer looks for it.

