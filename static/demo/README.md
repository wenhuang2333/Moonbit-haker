# JSONMend 浏览器演示

纯静态页面，**没有构建步骤、没有依赖**。页面里的每一次修复与每一帧快照都由
`./jsonmend.js` 驱动 —— 那是 `code/examples/web/main.mbt` 用 MoonBit 的 JavaScript
后端编译出来的产物，页面里没有第二份实现。

| 文件 | 内容 |
| --- | --- |
| `live.html` | 实时演示：四条真实场景逐帧重放，同一帧里显示模型流、实时结构、成员就绪、`syntax ready` / `schema ready` 两个比例与拒绝时的重试提示；第五个标签页是**接入面**——五种接入方式的配置行，外加「粘贴工具 `inputSchema` → 当场看这道门怎么判」的面板 |
| `mcp.html` | 接入演示：`claude mcp add jsonmend -- jsonmend mcp` 配置、真实 `jsonmend_analyze` 的 E010 拒绝与重试、工具 `inputSchema` 直连 |
| `mcp-claude-session.txt` | **真实 Claude Code 会话**的逐字节事件流（`claude --output-format stream-json`）：会话 id、时间戳、模型名、工具入参、工具返回、`retry.prompt` 与原始 JSON 行 |
| `mcp-claude-demo.gif` / `mcp-claude-poster.png` | 上面那段真实会话的动画与封面帧（由 `test/record_claude_mcp.py` 渲染） |
| `index.html` | 交互控制台：修复工作台（五种安全档位、skip-prose、计划/记录/回灌提示）、执行门（骨架声明与 JSON Schema）、流式重放（delta 流与四个就绪数字）、22 条规则一键试用、字段就绪曲线、CLI 命令构造器与六种接入面；全部由 `jsonmend.js` 现场计算 |
| `jsonmend.js` | MoonBit → JavaScript 产物（由 `bash static/demo/build.sh` 生成，CI 校验它与源码同步） |
| `mcp-demo.gif` / `mcp-demo.png` | MCP server 响应实录（真实 `jsonmend mcp` 的响应；由 `test/render_mcp_gif.py` 渲染） |
| `screenshot.png` / `mcp-screenshot.png` | `index.html` / `mcp.html` 的静态截图（README 用） |

## 本地打开（一条命令）

```bash
bash static/demo/build.sh          # 仅在改过 code/ 后需要：重新生成 jsonmend.js
python3 -m http.server 8000 -d static/demo
# 打开 http://127.0.0.1:8000/index.html（交互控制台）或 /live.html（逐帧演示）
```

`python3 -m http.server` 只是为了让相对路径（`./jsonmend.js`）按 HTTP 规则解析。
直接双击 `live.html` 用浏览器打开也可以，`file://` 下相对路径同样成立。

## 线上地址

由 `.github/workflows/pages.yml` 发布整个目录（Pages 的 `build_type` 为 `workflow`）：

- <https://wenhuang2333.github.io/Moonbit-haker/> —— `index.html`
- <https://wenhuang2333.github.io/Moonbit-haker/live.html> —— 实时演示
- <https://wenhuang2333.github.io/Moonbit-haker/mcp.html> —— MCP 接入演示

Pages 不可用时的等价方案就是上面那条本地命令。
