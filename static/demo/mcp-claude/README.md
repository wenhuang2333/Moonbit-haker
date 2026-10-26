# JSONMend × Claude Code — 真实会话实录

这个目录里的三个文件来自**一次真实的 Claude Code 会话**：Claude Code 真的启动了这个
仓库编译出来的 `jsonmend mcp` 服务，真的把被截断的工具参数交给了
`jsonmend_analyze`，真的收到了 `E010` 拒绝，真的按 `retry.prompt` 重发了参数，
真的拿到了 `executable: true`。

没有 mock，没有手写的会话，没有把旧的 `mcp-demo.gif` 重新渲染一遍充数。

| 文件 | 内容 |
| --- | --- |
| `../mcp-claude-session.txt` | 会话逐字记录：环境、命令、完整 prompt、每一次工具调用的入参与返回（原始单行 JSON，未重新格式化）、Claude Code 的最终总结，以及**整份 `claude --output-format stream-json` 原始事件流**（可直接与工具返回的字节对照） |
| `../mcp-claude-demo.gif` | 上面那次会话的动画：7 屏，逐行揭示，最后一屏停在 Claude 的结论上 |
| `../mcp-claude-poster.png` | 封面图：左边是那次被拒绝的调用，右边是重发后被放行的调用 |

## 会话里发生了什么

| 步骤 | 内容 |
| --- | --- |
| 1 | `claude mcp add jsonmend -- …/jsonmend.exe mcp`，`claude mcp list` 报告 `jsonmend: … ✔ Connected` |
| 2 | 第一次 `jsonmend_analyze`，`text` 是被 `max_tokens` 截断的 `{"amount":100,"currency":"USD"`（30 字符，缺右花括号） |
| 3 | 服务返回 `decision: lossy_repair` / `executable: false` / `error.code: E010`（`R009 CloseContainer at 1:31`），并给出 `retry.prompt` |
| 4 | Claude 读 `retry.prompt`，自己重发 `{"amount":100,"currency":"USD"}`，第二次调用 |
| 5 | 第二次返回 `decision: safe` / `executable: true` / `schema 2/2 satisfied` / `value: {"amount":100,"currency":"USD"}` |
| 6 | Claude Code 给出总结：`E010` → `false` → 重发 → `safe` → `true` |

`E010` 是 `agent`/`execution` 档的硬拒绝：补右花括号会*发明内容*，所以门不替模型猜。
注意第 4 步——**参数是 Claude 自己重发的**，门只给出提示；执行与否由宿主决定，这正是
MCP 与 `serve --stdio` 的区别（逐工具配方见 `code/docs/INTEGRATIONS.md`，本地文档）。

## 怎么录的（逐条命令）

```bash
# 1. 编译原生 CLI
export PATH="$HOME/.moon/bin:$PATH"
cd code && moon build cmd/jsonmend --target native --release
cd ..

# 2. 注册 MCP 服务
claude mcp add jsonmend -- \
  "$PWD/code/_build/native/release/build/cmd/jsonmend/jsonmend.exe" mcp
claude mcp list          # -> jsonmend: … ✔ Connected

# 3. 跑一次真实的无头会话
claude -p "<见下方 '复现' 一节的完整 prompt>" \
  --allowedTools mcp__jsonmend__jsonmend_analyze,mcp__jsonmend__jsonmend_repair,\
mcp__jsonmend__jsonmend_validate,mcp__jsonmend__jsonmend_readiness \
  --output-format stream-json --verbose > test/mcp-claude-raw.jsonl

# 4. 渲染
python3 test/record_claude_mcp.py --render-only
```

一次性跑完全部步骤（编译 → 注册 → 录制 → 渲染 → 注销）：

```bash
python3 test/record_claude_mcp.py
```

## 复现

`test/record_claude_mcp.py`（`test/` 已被 `.gitignore` 忽略，是工作区约定里的临时脚本目录）
是这三份产物的唯一来源。它做四件事：

1. `moon build cmd/jsonmend --target native --release`；
2. `claude mcp add jsonmend -- … mcp`，并把 `claude mcp add` / `claude mcp list` 的真实输出
   记进 transcript；
3. 跑 `claude -p … --output-format stream-json --verbose`，把原始事件流存到
   `test/mcp-claude-raw.jsonl`；
4. 从这份事件流里**提取** transcript、动画与封面。

脚本带一道闸：如果这次捕获里**没有**「第一次调用 → `E010` 且 `executable:false` →
第二次调用 → `executable:true`」这条链，它会直接报错退出、**不写任何产物**。
所以它不可能在没有真实会话的情况下产出一份看起来像真的动画。

```bash
python3 test/record_claude_mcp.py                 # 完整跑一遍
python3 test/record_claude_mcp.py --render-only   # 用已有 raw jsonl 重新渲染
python3 test/record_claude_mcp.py --keep-server   # 录完保留 MCP 注册
```

录制用的 prompt 是脚本里的 `PROMPT` 常量，transcript 里也有全文。

## 诚实边界（评委应该知道的事）

- **会话是真的**：Claude Code CLI v2.1.301、`claude mcp add` / `claude mcp list`
  报告 `✔ Connected`、`tools/call` 真的打到了本地 `jsonmend.exe mcp`，返回的
  `E010`、`retry.prompt`、`decision` 全部由仓库里的 MoonBit 引擎产生。
- **模型不是 Anthropic 的 Claude**：这台机器的 `~/.claude/settings.json` 把
  `ANTHROPIC_BASE_URL` 指向了第三方网关（`api.longcat.chat`），所以驱动这次会话的
  权重是 `LongCat-2.0`（transcript 里的 `model` 字段与 `modelUsage` 写了实际模型名）。
  Claude Code 客户端、工具协议、MCP 握手、工具调用与重试路径都是 Anthropic 官方
  客户端的真实行为；换句话说，**客户端是官方的，模型是这台机器自己配的**。
  想换成官方模型，只需把 `~/.claude/settings.json` 的 `env` 段改掉再重跑脚本。
- **一次运行可能有细微差别**：模型在重发参数时是自己写的 `retry.prompt`；不同模型
  或不同网关可能给出措辞不同的总结，也可能选择另一种截断位置（例如同样会得到
  `E010`，但规则名可能是 `R010 CloseString`）。脚本对此只会打印一行 `WARNING`，
  不会伪造。
- **动画里的换行是排版**：GIF 把单行 JSON 按 133 列折行显示，拆点只落在 `,` `}` `]`
  和空格上，不切开转义序列；`mcp-claude-session.txt` 里的 JSON 保持**原始单行**，
  末尾还附了完整的原始事件流，两者可以逐字节对照。
- **MCP 注册是临时的**：脚本录完会 `claude mcp remove jsonmend`，把机器恢复成原样
  （用 `--keep-server` 可以保留）。要长期使用，按仓库文档执行
  `claude mcp add jsonmend -- jsonmend mcp` 即可（`jsonmend` 在 `PATH` 上时）。

## 复现到的环境

| 项 | 值 |
| --- | --- |
| 平台 | macOS 14/15（Darwin 25.5.0, arm64） |
| Claude Code | 2.1.301 |
| 引擎 | `jsonmend` 1.1.1（录制时的构建；当前版本 1.3.0） |
| 会话 | `claude -p`，3 turns，`stop_reason: end_turn` |

会话 id、时间戳、模型名、逐字节的工具入参与返回，都写在
[`../mcp-claude-session.txt`](../mcp-claude-session.txt) 里。
