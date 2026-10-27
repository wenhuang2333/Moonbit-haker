"""HTTP facade tests: start a server on an ephemeral port and call it."""

from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request

from interjson.http import create_server
from version import engine_version, registry_version



class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = create_server("127.0.0.1", 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def post(self, path: str, body: dict) -> tuple[int, dict]:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read())

    def get(self, path: str) -> tuple[int, dict]:
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as response:
            return response.status, json.loads(response.read())

    def test_healthz(self) -> None:
        status, body = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["engine"], engine_version())

    def test_analyze(self) -> None:
        status, body = self.post(
            "/analyze",
            {
                "text": '{"words":["a" "b"]}',
                "profile": "execution",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["decision"], "ambiguous")

    def test_repair(self) -> None:
        status, body = self.post("/repair", {"text": "{'a':1,}"})
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["text"], '{"a":1}')

    def test_structured_error(self) -> None:
        status, body = self.post("/analyze", {"text": "{}", "profile": "nope"})
        self.assertEqual(status, 400)
        self.assertEqual(body["error"]["code"], "E050")

    def test_unknown_path(self) -> None:
        status, body = self.post("/nope", {})
        self.assertEqual(status, 404)
        self.assertFalse(body["ok"])

    def test_cors_preflight(self) -> None:
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/analyze", method="OPTIONS"
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 204)
            self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")


if __name__ == "__main__":
    unittest.main()
