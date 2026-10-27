"""A dependency-free HTTP facade over the stdio protocol.

This is the integration path for tools that speak HTTP rather than stdio —
n8n, Dify, Coze, a gateway, or a browser page. It is deliberately a thin
translation of one request to one `interjson serve` call: no state, no caching,
no retries. A new engine process is used per request and closed afterwards, so
a crash cannot poison the next request; a caller that needs throughput should
use `Client` directly.

    python -m interjson.http --port 8080

    POST /repair    {"text": "...", "profile": "agent", "schema_json": {...}}
    POST /analyze   {"text": "...", "profile": "agent", "schema_json": {...}}
    POST /validate  {"text": "...", "schema": "{!query:string}"}
    POST /readiness {"text": "...", "schema": "{!query:string}"}
    GET  /healthz
"""

from __future__ import annotations

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .client import Client, InterJSONError, find_binary

__all__ = ["InterJSONHTTPServer", "create_server", "main"]

_METHODS = {
    "/repair": "repair",
    "/analyze": "analyze",
    "/validate": "validate",
    "/readiness": "readiness",
}


class InterJSONHTTPServer(ThreadingHTTPServer):
    """A threaded server that keeps the binary path and nothing else."""

    daemon_threads = True

    def __init__(self, address: tuple[str, int], binary: str | None = None) -> None:
        super().__init__(address, _Handler)
        self.binary = binary or find_binary()


class _Handler(BaseHTTPRequestHandler):
    server_version = "interjson/1.0.0"
    protocol_version = "HTTP/1.1"

    # -- helpers ----------------------------------------------------------

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("the request body must be a JSON object")
        return value

    # -- routes -----------------------------------------------------------

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/healthz":
            self._send(404, {"ok": False, "error": {"code": "E404", "message": "not found"}})
            return
        try:
            with Client(binary=self.server.binary) as client:  # type: ignore[attr-defined]
                hello = client.hello()
            self._send(200, {"ok": True, "engine": hello.get("engine"), "protocol": hello.get("protocol")})
        except Exception as exc:  # pragma: no cover - health is best effort
            self._send(503, {"ok": False, "error": {"code": "E030", "message": str(exc)}})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        method = _METHODS.get(path)
        if method is None:
            self._send(404, {"ok": False, "error": {"code": "E404", "message": "not found"}})
            return
        try:
            params = self._body()
        except Exception as exc:
            self._send(400, {"ok": False, "error": {"code": "E050", "message": str(exc)}})
            return
        try:
            with Client(binary=self.server.binary) as client:  # type: ignore[attr-defined]
                result = client.request(method, **params)
            self._send(200, {"ok": True, "result": result})
        except InterJSONError as exc:
            self._send(400, {"ok": False, "error": exc.to_dict()})
        except Exception as exc:  # pragma: no cover - defensive
            self._send(500, {"ok": False, "error": {"code": "E030", "message": str(exc)}})

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("interjson http: " + (fmt % args) + "\n")


def create_server(
    host: str = "127.0.0.1",
    port: int = 8080,
    binary: str | None = None,
) -> InterJSONHTTPServer:
    """Bind a server; pass `port=0` to let the OS choose one."""
    return InterJSONHTTPServer((host, port), binary=binary)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="interjson-http", description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--binary", default=None, help="path to the interjson executable")
    args = parser.parse_args(argv)
    server = create_server(args.host, args.port, args.binary)
    host, port = server.server_address[:2]
    print(f"interjson http listening on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
