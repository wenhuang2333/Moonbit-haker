#!/usr/bin/env python3
"""Functional smoke for the interactive console (static/demo/index.html).

The console is the demo's front door: it must show the MCP entry point, the
repair workbench, the execution gate, the stream replay, the 22 rules, the
readiness curve and the CLI builder -- and every verdict it prints has to come
from the MoonBit bundle, not from a literal in the page.

Usage (from the repository root):

    python3 code/tests/media/index_console_smoke.py

Requires Python Playwright + Chromium.  Exits non-zero on the first failure.
"""

from __future__ import annotations

import functools
import http.server
import json
import socketserver
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
DEMO = ROOT / "static" / "demo"

SECTIONS = ["mcp", "workbench", "gate", "stream", "rules", "readiness", "cli", "surfaces"]
EVIDENCE = ["217", "868", "1200", "402", "109.1"]
NEW_FLAGS = {
    "repair": ["--max-loss", "--max-input-len", "--max-depth", "--max-token-len", "--max-repairs"],
    "explain": ["--with-text", "--max-loss"],
    "llm": ["--text"],
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:  # quiet
        pass


def main() -> None:
    handler = functools.partial(Handler, directory=str(DEMO))
    with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
        port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{port}"
        errors: list[str] = []
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 1440, "height": 1000})
            page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
            page.on("pageerror", lambda exc: errors.append(str(exc)))
            page.goto(f"{base}/index.html", wait_until="networkidle")
            page.wait_for_timeout(400)

            # 1. The engine bundle must be there, and every section must render.
            assert "已加载" in page.text_content("#engine-status"), page.text_content("#engine-status")
            for section in SECTIONS:
                assert page.locator(f"#{section}").count() == 1, f"missing section #{section}"

            # 2. The evidence strip must carry the current figures.
            evidence = page.text_content("#evidence-strip")
            for value in EVIDENCE:
                assert value in evidence, f"evidence {value} missing: {evidence}"

            # 3. The MCP section: four tools, seven client configs, real transcripts.
            assert page.locator("#mcp table tbody tr").count() == 4, "expected four MCP tools"
            clients = page.eval_on_selector_all("#mcp-client option", "els => els.map(e => e.value)")
            assert clients == ["claude", "cursor", "vscode", "codex", "windsurf", "zed", "json"], clients
            page.select_option("#mcp-client", "vscode")
            assert '"servers"' in page.text_content("#mcp-config"), page.text_content("#mcp-config")
            page.click('button[data-mcp-tab="refused"]')
            assert "E010" in page.text_content("#mcp-meta"), page.text_content("#mcp-meta")
            page.click('button[data-mcp-tab="allowed"]')
            assert "executable true" in page.text_content("#mcp-meta"), page.text_content("#mcp-meta")
            page.click('button[data-mcp-tab="init"]')
            assert "2025-06-18" in page.text_content("#mcp-msg"), page.text_content("#mcp-msg")

            # 4. The workbench repairs through the bundle and refuses under strict.
            page.click('button[data-sample="mixed"]')
            page.wait_for_timeout(400)
            json.loads(page.text_content("#wb-output"))  # the repaired text is valid JSON
            page.select_option("#wb-policy", "strict")
            page.wait_for_timeout(400)
            assert "E010" in page.text_content("#wb-verdict"), page.text_content("#wb-verdict")

            # 5. The execution gate refuses a truncated argument and offers a retry.
            page.click('button[data-gate-preset="decl-truncated"]')
            page.wait_for_timeout(300)
            assert "BLOCKED" in page.text_content("#gate-verdict"), page.text_content("#gate-verdict")
            assert page.locator("#gate-retry").is_visible(), "the retry prompt is missing"
            page.click('button[data-gate-mode="json"]')
            page.wait_for_timeout(300)
            assert page.text_content("#gate-verdict").strip() != "", "the JSON Schema mode did not run"

            # 6. The stream replay produces deltas and a verdict.
            page.click("#st-step")
            page.wait_for_timeout(250)
            assert any(k in page.text_content("#st-deltas") for k in ("set", "append_text"))
            page.eval_on_selector(
                "#st-range",
                "r => { r.value = r.max; r.dispatchEvent(new Event('input')); }",
            )
            page.wait_for_timeout(300)
            assert page.text_content("#st-verdict").strip() != ""

            # 7. All 22 rules are listed and each one fires on its own sample.
            assert page.locator("#rules-body tr[data-rule]").count() == 22
            page.click("#rules-verify")
            page.wait_for_timeout(1500)
            assert "22/22" in page.text_content("#rules-verify-out"), page.text_content("#rules-verify-out")

            # 8. The readiness curve answers with the three fractions.
            page.click('button[data-rd-sample="early"]')
            page.wait_for_timeout(300)
            assert "%" in page.text_content("#rd-settled"), page.text_content("#rd-settled")
            assert page.locator("#rd-events tr").count() >= 1

            # 9. The CLI builder offers the flags this version documents.
            for command, flags in NEW_FLAGS.items():
                page.select_option("#cli-cmd", command)
                page.wait_for_timeout(150)
                offered = page.eval_on_selector_all("input[data-cli-flag]", "els => els.map(e => e.dataset.cliFlag)")
                for flag in flags:
                    assert flag in offered, f"{command} is missing {flag}: {offered}"

            # 10. Theme, accessibility and the narrow viewport.
            before = page.get_attribute("html", "data-theme")
            page.click("#theme-toggle")
            assert before != page.get_attribute("html", "data-theme"), "the theme did not change"
            unnamed = page.eval_on_selector_all(
                "button", "els => els.filter(e => !(e.getAttribute('aria-label') || e.textContent.trim())).length"
            )
            assert unnamed == 0, f"{unnamed} buttons without an accessible name"
            page.set_viewport_size({"width": 390, "height": 844})
            page.wait_for_timeout(200)
            overflow = page.evaluate("document.scrollingElement.scrollWidth - window.innerWidth")
            assert overflow <= 2, f"horizontal overflow at 390px: {overflow}px"
            browser.close()

        httpd.shutdown()
        if errors:
            raise SystemExit("console errors: " + " | ".join(errors[:5]))
        print("index console ok; MCP, workbench, gate, stream, rules, readiness and CLI all answered")


if __name__ == "__main__":
    main()
