#!/usr/bin/env python3
"""Record the InterJSON demo with real Chromium screen capture (Playwright video).

Three segments, each a genuine browser recording of a real page:

  1. title      - a generated card naming what is about to play
  2. live       - static/demo/live.html, the four scenarios, driven by clicking
                  the real tabs and waiting for the page's own state to settle
  3. cli        - a terminal panel whose text is the byte-for-byte output of the
                  real commands (agent_loop and `explain --json`), read from
                  files produced by actually running them

Output: /tmp/demo/rec/{title,live,cli}.webm, to be concatenated by ffmpeg.

Usage:
  python3 code/tests/media/demo_record.py [--out DIR] [--root REPO]
"""

import argparse
import json
import os
import pathlib
import shutil
import sys

from playwright.sync_api import sync_playwright

VIEW = {"width": 1280, "height": 800}
FPS_FRIENDLY = 1280


def title_page(text, sub):
    # The sweeping bar is not decoration: Chromium's screencast only emits a
    # frame when the page repaints, so a fully static card records as one frame.
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
      html,body{{margin:0;height:100%;background:#0d1117;color:#e6edf3;
        font:600 44px/1.35 -apple-system,BlinkMacSystemFont,"Noto Sans SC",sans-serif;
        display:flex;align-items:center;justify-content:center;overflow:hidden}}
      div{{text-align:center;max-width:1000px}} p{{font:400 20px/1.6 -apple-system,sans-serif;
        color:#8b949e;margin:.8rem 0 0}}
      .bar{{position:fixed;left:0;bottom:0;height:6px;background:#1f6feb;
        animation:sweep 3s linear infinite}}
      @keyframes sweep{{from{{width:0}}to{{width:100%}}}}
    </style></head><body><div>{text}<p>{sub}</p></div><div class="bar"></div></body></html>"""


def cli_page(agent_loop_text, explain_json, explain_rc, commands):
    safe = json.dumps(explain_json, ensure_ascii=False)
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
      html,body{{margin:0;background:#0d1117;color:#c9d1d9;
        font:13.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}}
      #bar{{background:#161b22;border-bottom:1px solid #30363d;padding:.5rem .9rem;
        color:#8b949e;font-size:12.5px}}
      #wrap{{padding:.9rem 1rem 4rem}}
      .cmd{{color:#3fb950;white-space:pre-wrap;word-break:break-all}}
      .cmd::before{{content:"";}}
      pre{{margin:.25rem 0 0;white-space:pre-wrap;word-break:break-word}}
      .out{{color:#c9d1d9}}
      .note{{color:#d29922}}
      .hl{{background:#1f6feb33;border:1px solid #1f6feb;border-radius:5px;
        padding:.5rem .7rem;margin:.6rem 0;color:#e6edf3}}
      .k{{color:#79c0ff}} .yes{{color:#3fb950}} .no{{color:#f85149}}
      .seg{{margin-bottom:1.1rem}}
      h3{{font:600 12.5px/1.4 ui-monospace,monospace;color:#8b949e;margin:0 0 .3rem;
        text-transform:uppercase;letter-spacing:.08em}}
    </style></head><body>
    <div id="bar">interjson &mdash; live CLI output, captured verbatim at record time</div>
    <div id="wrap">
      <div class="seg"><h3>1 &middot; the self-healing agent loop</h3>
        <div class="cmd" id="cmd1"></div><pre class="out" id="out1"></pre></div>
      <div class="seg" id="seg2" style="visibility:hidden"><h3>2 &middot; valid JSON that must not be executed</h3>
        <div class="cmd" id="cmd2"></div><pre class="out" id="cmd2out"></pre>
        <div id="hl2" style="visibility:hidden"></div></div>
    </div>
    <script>
      const CMD1 = {json.dumps(commands[0])};
      const CMD2 = {json.dumps(commands[1])};
      const OUT1 = {json.dumps(agent_loop_text)};
      const JSON2 = {safe};
      const RC = {explain_rc};
      function typeCmd(el, text) {{
        return new Promise((res) => {{
          let i = 0;
          const t = setInterval(() => {{
            el.textContent = text.slice(0, i += 1);
            if (i >= text.length) {{ clearInterval(t); res(); }}
          }}, 22);
        }});
      }}
      function streamOut(el, text, msPerLine) {{
        return new Promise((res) => {{
          const lines = text.split("\\n");
          let i = 0, acc = "";
          const t = setInterval(() => {{
            acc += lines[i] + "\\n"; el.textContent = acc;
            window.scrollTo(0, document.body.scrollHeight);
            if (++i >= lines.length) {{ clearInterval(t); res(); }}
          }}, msPerLine);
        }});
      }}
      function hl(k, v, cls) {{
        return '<span class="k">' + k + '</span>:<span class="' + cls + '">' + v + '</span>';
      }}
      window.__run = async () => {{
        await typeCmd(document.getElementById("cmd1"), CMD1);
        await new Promise(r => setTimeout(r, 500));
        await streamOut(document.getElementById("out1"), OUT1, 118);
        await new Promise(r => setTimeout(r, 2200));
        document.getElementById("seg2").style.visibility = "visible";
        await typeCmd(document.getElementById("cmd2"), CMD2);
        await new Promise(r => setTimeout(r, 400));
        // The JSON is the real stdout, one line; wrap it by hand so it reads on a screen.
        const pretty = JSON.stringify(JSON.parse(JSON2), null, 1);
        await streamOut(document.getElementById("cmd2out"), pretty, 55);
        const d = JSON.parse(JSON2);
        document.getElementById("hl2").innerHTML =
          '<div class="hl">syntactic validity and execution safety are two answers: '
          + hl("valid_json", String(d.valid_json), d.valid_json ? "yes" : "no")
          + ' &nbsp;next to&nbsp; '
          + hl("execution", JSON.stringify(d.execution), d.execution === "allowed" ? "yes" : "no")
          + '<br><span class="note">ambiguity=' + d.ambiguity + ' &middot; exactness=' + d.exactness
          + ' &middot; exit code ' + RC + ' &middot; the tool call is not executed</span></div>';
        document.getElementById("hl2").style.visibility = "visible";
        window.scrollTo(0, document.body.scrollHeight);
        await new Promise(r => setTimeout(r, 3500));
        window.__done = true;
      }};
    </script></body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/demo/rec")
    ap.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[3]))
    args = ap.parse_args()

    root = pathlib.Path(args.root)
    out = pathlib.Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    live = root / "static" / "demo" / "live.html"
    if not live.exists():
        sys.exit(f"missing {live}")
    agent_loop = pathlib.Path("/tmp/demo/agent_loop.txt").read_text()
    explain_json = pathlib.Path("/tmp/demo/explain.json").read_text().strip()
    explain_rc = 5

    commands = [
        "moon run examples/agent_loop --target native --release",
        """printf '%s' '{"a":"b","a":"c"}' | interjson explain --json --policy execution""",
    ]

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        segments = []

        def new_ctx():
            return browser.new_context(viewport=VIEW, record_video_dir=str(out),
                                       record_video_size=VIEW)

        # ---- 1. title --------------------------------------------------------
        ctx = new_ctx()
        page = ctx.new_page()
        page.set_content(title_page(
            "InterJSON &mdash; don't wait for valid JSON",
            "live.html: four scenarios &middot; agent_loop: the round trip &middot; explain --json: valid_json next to execution"))
        page.wait_for_timeout(2800)
        video = page.video
        ctx.close()
        segments.append(video.path())

        # ---- 2. live.html ----------------------------------------------------
        ctx = new_ctx()
        page = ctx.new_page()
        page.goto(live.as_uri())
        page.wait_for_function("() => globalThis.interjson && globalThis.interjson.live")
        page.wait_for_timeout(800)
        tabs = page.locator("#tabs button")
        n = tabs.count()
        for i in range(n):
            tabs.nth(i).click()
            # wait for the page's own state machine to finish the scenario
            page.wait_for_function("() => state.paused === true", timeout=30000)
            page.wait_for_timeout(6000)
            shown = page.evaluate(
                """() => ({verdict: document.getElementById('verdict').textContent,
                           exactness: document.getElementById('exactness').textContent,
                           ambiguity: document.getElementById('ambiguity').textContent,
                           syntax: document.getElementById('syntax').textContent,
                           schema: document.getElementById('schema').textContent,
                           retry: document.getElementById('retry').hidden
                                  ? '(no retry panel)'
                                  : document.getElementById('prompt').textContent.split('\\n')[0],
                           meta: document.getElementById('meta').textContent})""")
            print(f"  scenario {i + 1}/{n}: {shown['verdict']} | exactness={shown['exactness']}"
                  f" ambiguity={shown['ambiguity']} syntax_ready={shown['syntax']}"
                  f" schema_ready={shown['schema']}")
            print(f"      retry panel: {shown['retry'][:96]}")
            print(f"      {shown['meta']}")
        page.wait_for_timeout(1200)
        video = page.video
        ctx.close()
        segments.append(video.path())

        # ---- 3. terminal panel ----------------------------------------------
        ctx = new_ctx()
        page = ctx.new_page()
        page.set_content(cli_page(agent_loop, explain_json, explain_rc, commands))
        page.evaluate("window.__run()")
        page.wait_for_function("() => window.__done === true", timeout=180000)
        video = page.video
        ctx.close()
        segments.append(video.path())

        # ---- 4. end card -----------------------------------------------------
        ctx = new_ctx()
        page = ctx.new_page()
        version = pathlib.Path(root / "code" / "moon.mod").read_text()
        version = [l for l in version.splitlines() if l.startswith("version")][0].split('"')[1]
        page.set_content(title_page(
            f"InterJSON {version}",
            'every frame is the real page or the real command output &middot; '
            'live: https://wenhuang2333.github.io/Moonbit-haker/live.html'))
        # the bar has a 3 s cycle; two cycles is what makes the card readable
        page.wait_for_timeout(6000)
        video = page.video
        ctx.close()
        segments.append(video.path())

        browser.close()

    for i, src in enumerate(segments, 1):
        dst = out / f"seg{i}.webm"
        shutil.move(src, dst)
        print(f"{dst}  {dst.stat().st_size} bytes")


if __name__ == "__main__":
    main()
