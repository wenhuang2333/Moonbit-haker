#!/usr/bin/env python3
"""Visual + functional smoke for the static demo pages.

Serves static/demo, opens mcp.html, checks the real analyze result (E010 then
safe after "模型重发"), and refreshes the screenshots used by the README.
"""

from __future__ import annotations

import functools
import http.server
import socketserver
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
DEMO = ROOT / "static" / "demo"


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args: object) -> None:  # quiet
        pass


def main() -> None:
    handler = functools.partial(Handler, directory=str(DEMO))
    with socketserver.TCPServer(("127.0.0.1", 0), handler) as httpd:
        port = httpd.server_address[1]
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{port}"
        errors: list[str] = []
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 1200, "height": 900}, device_scale_factor=1)
            page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
            page.on("pageerror", lambda exc: errors.append(str(exc)))

            page.goto(f"{base}/mcp.html", wait_until="networkidle")
            page.wait_for_function("document.querySelector('#decision').textContent === 'lossy_repair'")
            assert page.text_content("#executable") == "false", page.text_content("#executable")
            assert "E010" in (page.text_content("#error") or ""), page.text_content("#error")
            page.screenshot(path=str(DEMO / "mcp-screenshot.png"), full_page=True)

            page.click("#run-good")
            page.wait_for_function("document.querySelector('#executable').textContent === 'true'")
            assert page.text_content("#decision") == "safe", page.text_content("#decision")

            page.goto(f"{base}/index.html", wait_until="networkidle")
            page.screenshot(path=str(DEMO / "screenshot.png"), full_page=True)

            # The "surfaces" panel of live.html is the poster used by README.
            page.goto(f"{base}/live.html", wait_until="networkidle")
            page.wait_for_function("() => globalThis.interjson && globalThis.interjson.live")
            page.get_by_role("button", name="接入面").click()
            page.wait_for_selector("#surfaces:not([hidden])")
            page.locator("#surfaces").screenshot(path=str(DEMO / "surfaces-poster.png"))
            browser.close()

        httpd.shutdown()
        if errors:
            raise SystemExit("console errors: " + " | ".join(errors[:5]))
        print("demo pages ok; screenshots refreshed")


if __name__ == "__main__":
    main()
