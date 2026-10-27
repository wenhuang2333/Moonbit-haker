# InterJSON 浏览器演示

纯静态页面，**没有构建步骤、没有依赖**。页面里的每一次修复与每一帧快照都由
`./interjson.js` 驱动 —— 那是 `code/examples/web/main.mbt` 用 MoonBit 的 JavaScript
后端编译出来的产物，页面里没有第二份实现。

| 文件 | 内容 |
| --- | --- |
| `live.html` | 实时演示：四条真实场景逐帧重放，同一帧里显示模型流、实时结构、成员就绪、`syntax ready` / `schema ready` 两个比例与拒绝时的重试提示；第五个标签页是**接入面**——五种接入方式的配置行，外加「粘贴工具 `inputSchema` → 当场看这道门怎么判」的面板 |
| `mcp.html` | 接入演示：`claude mcp add interjson -- interjson mcp` 配置（也可用 `interjson mcp --print-config=claude|cursor|json` 生成）、真实 `interjson_gate` 的 E010 拒绝与重试、工具 `inputSchema` 直连 |
| `mcp-claude-session.txt` | **真实 Claude Code 会话**的逐字节事件流（`claude --output-format stream-json`），录制于产品更名之前，因此保留旧服务名与旧工具名：会话 id、时间戳、模型名、工具入参、工具返回、`retry.prompt` 与原始 JSON 行 |
| `index.html` | 交互控制台（线上首页）：本地 MCP 执行门（四个只读工具、`--print-config` 七种客户端、真实 JSON-RPC 往返）、修复工作台（五种安全档位、skip-prose、计划/记录/回灌提示）、执行门（骨架声明与 JSON Schema）、流式重放（delta 流与四个就绪数字）、22 条规则一键试用、字段就绪曲线、CLI 命令构造器与六种接入面；判定与修复全部由 `interjson.js` 现场计算，MCP 段落是 CLI 的真实输出 |
| `interjson.js` | MoonBit → JavaScript 产物（由 `bash static/demo/build.sh` 生成，CI 校验它与源码同步） |
| `mcp-demo.gif` / `mcp-demo.png` | MCP server 响应实录（由 `code/tests/media/render_mcp_gif.py` 按当前工具名与真实响应渲染） |
| `screenshot.png` / `mcp-screenshot.png` | `index.html` / `mcp.html` 的当前版本静态截图（由 `code/tests/media/demo_visual_smoke.py` 刷新） |
| `demo.mp4` / `live-demo.gif` | 当前版本的演示录屏与 `live.html` 片段（由 `code/tests/media/refresh.sh` 重新生成） |
| `surfaces-poster.png` | `live.html` 「接入面」标签页的截图（同一次刷新生成） |

`screenshot.png`、`mcp-screenshot.png`、`surfaces-poster.png`、`mcp-demo.gif`、
`demo.mp4` 与 `live-demo.gif` 都按当前 InterJSON 版本重新生成；更名前的截图、
GIF 与录屏不再保留。真实 Claude Code 会话只保留逐字节文本证据
（`mcp-claude-session.txt`），派生动画/封面已删除。

## 重新生成

```bash
bash code/tests/media/refresh.sh   # 需要 Python Playwright + Chromium + ffmpeg
```

每一步都可单独运行，生成器说明见 [`code/tests/media/README.md`](../../code/tests/media/README.md)。

## 本地打开（一条命令）

```bash
bash static/demo/build.sh          # 仅在改过 code/ 后需要：重新生成 interjson.js
python3 -m http.server 8000 -d static/demo
# 打开 http://127.0.0.1:8000/index.html（交互控制台）或 /live.html（逐帧演示）
```

`python3 -m http.server` 只是为了让相对路径（`./interjson.js`）按 HTTP 规则解析。
直接双击 `live.html` 用浏览器打开也可以，`file://` 下相对路径同样成立。

## 线上地址

由 `.github/workflows/pages.yml` 发布整个目录（Pages 的 `build_type` 为 `workflow`）：

- <https://wenhuang2333.github.io/Moonbit-haker/> —— `index.html`
- <https://wenhuang2333.github.io/Moonbit-haker/live.html> —— 实时演示
- <https://wenhuang2333.github.io/Moonbit-haker/mcp.html> —— MCP 接入演示

Pages 不可用时的等价方案就是上面那条本地命令。
