# Demo media generation

Every image and recording under `static/demo/` is generated from the current
tree; none of it is hand-drawn. This directory holds the generators, so a new
release can refresh the media instead of shipping a picture of an older build.

```bash
bash code/tests/media/refresh.sh
```

The script rebuilds `interjson.js`, refreshes `screenshot.png`,
`mcp-screenshot.png` and `surfaces-poster.png` from the real pages, repaints
`mcp-demo.gif` from the MCP transcript, records `demo.mp4` in headless Chromium,
and derives `live-demo.gif` from the live segment.

| Script | Produces |
| --- | --- |
| `refresh.sh` | all of the below, in order |
| `demo_visual_smoke.py` | `screenshot.png`, `mcp-screenshot.png`, `surfaces-poster.png`; also checks the MCP page's E010 → safe flow |
| `index_console_smoke.py` | nothing; it asserts that `index.html` still answers: the MCP section, the workbench, the execution gate, the stream replay, the 22 rules, the readiness curve and the CLI builder, with no console error and no overflow at 390px |
| `render_mcp_gif.py` | `mcp-demo.gif`, `mcp-demo.png` |
| `demo_record.py` | the four WebM segments for `demo.mp4` (needs `ffmpeg` for assembly) |
| `record_claude_mcp.py` | the raw Claude Code session transcript (optional; requires the `claude` CLI) |

Requirements: Python 3, Playwright with Chromium (`pip install playwright &&
playwright install chromium`), and `ffmpeg`. CI does not run the recording
steps; it runs the bundle smoke test and the page checks that do not need a
browser. The release checklist runs `refresh.sh` once before tagging, so
`static/demo/` never contains media from a previous version.

`mcp-claude-session.txt` is the exception: it is a byte-for-byte transcript of
a real session, recorded before the InterJSON rename, and is kept as textual
evidence rather than regenerated. Its derived GIF/poster were removed under the
same "no stale media" rule; the transcript itself is the evidence.
