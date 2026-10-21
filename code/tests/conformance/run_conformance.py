#!/usr/bin/env python3
"""Conformance runner for the `serve` protocol and the MCP server.

    python3 code/tests/conformance/run_conformance.py \
        --cli code/_build/native/release/build/cmd/jsonmend/jsonmend.exe

Every case in `cases.jsonl` is one connection; a multi-step case keeps the
connection open so `watch`/`llm` state is exercised the way a client uses it.
The expected value is a *subset*: a case pins the fields that matter, so adding
a field to a response does not require rewriting the corpus, while removing or
changing one does fail.

The MCP half checks the four tool names, a successful `tools/call`, a refusal
(`isError`), and the notification rule (a notification must produce no line).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
DEFAULT_CLI = HERE.parents[1] / "_build/native/release/build/cmd/jsonmend/jsonmend.exe"


def subset(actual: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual and subset(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(actual) == len(expected)
            and all(subset(a, e) for a, e in zip(actual, expected))
        )
    return actual == expected


class Connection:
    def __init__(self, binary: str, mode: str) -> None:
        self.proc = subprocess.Popen(
            [binary, mode],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )

    def send(self, message: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def send_raw(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def read(self) -> dict[str, Any]:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            stderr = ""
            if self.proc.stderr is not None:
                stderr = self.proc.stderr.read()
            raise RuntimeError(f"server closed the stream; stderr: {stderr.strip()[:400]}")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"non-JSON response: {line!r}") from exc

    def close(self) -> None:
        try:
            if self.proc.stdin is not None and not self.proc.stdin.closed:
                self.send({"id": 999999, "method": "shutdown"})
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                if stream is not None:
                    stream.close()
            except Exception:
                pass


def check_reported_versions(binary: str) -> list[str]:
    """The versions the protocol advertises must be the versions we publish.

    `hello` reports the engine version and the mooncakes registry version as
    two separate strings. Both are hardcoded in the source, so both can drift
    from what is actually released -- and a client that trusts them is misled.
    This check pins them to the two places that define the release: the
    version in `code/moon.mod` and the channel table in the repository
    README. It is the check that would have caught the drift itself.
    """
    failures: list[str] = []
    mod_path = HERE.parents[1] / "moon.mod"
    engine = ""
    for line in mod_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("version"):
            engine = line.split("=", 1)[1].strip().strip('"')
            break
    if not engine:
        return [f"cannot read the version from {mod_path}"]

    readme = HERE.parents[2] / "README.md"
    registry = ""
    for line in readme.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] == f"`v{engine}`":
            registry = cells[1].strip("`")
            break
    if not registry:
        return [f"README.md has no channel-table row for v{engine}"]

    connection = Connection(binary, "serve")
    try:
        connection.send({"id": 1, "method": "hello"})
        response = connection.read()
    finally:
        connection.close()
    result = response.get("result", {}) if isinstance(response, dict) else {}
    if result.get("engine") != engine:
        failures.append(
            f"hello reports engine {result.get('engine')!r} but code/moon.mod says {engine!r}"
        )
    if result.get("registry") != registry:
        failures.append(
            f"hello reports registry {result.get('registry')!r} but the README channel "
            f"table maps v{engine} to {registry!r}"
        )
    return failures


def run_serve_case(binary: str, case: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    connection = Connection(binary, "serve")
    try:
        if "raw" in case:
            connection.send_raw(case["raw"])
            response = connection.read()
            if not subset(response, case["expect"]):
                failures.append(
                    f"raw line: expected {json.dumps(case['expect'], ensure_ascii=False)}, "
                    f"got {json.dumps(response, ensure_ascii=False)}"
                )
        for step in case.get("steps", []):
            request = step["request"]
            connection.send(request)
            response = connection.read()
            if "id" in request and response.get("id") != request["id"]:
                failures.append(f"id mismatch: sent {request['id']}, got {response.get('id')}")
            if not subset(response, step["expect"]):
                failures.append(
                    f"step {request.get('method')}: expected "
                    f"{json.dumps(step['expect'], ensure_ascii=False)}, got "
                    f"{json.dumps(response, ensure_ascii=False)}"
                )
    finally:
        connection.close()
    return failures


def run_mcp(binary: str) -> list[str]:
    failures: list[str] = []
    connection = Connection(binary, "mcp")
    try:
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "conformance", "version": "0"},
                },
            }
        )
        init = connection.read()
        if init.get("result", {}).get("protocolVersion") != "2024-11-05":
            failures.append("initialize did not echo the client's protocol version")
        if init.get("result", {}).get("serverInfo", {}).get("name") != "jsonmend":
            failures.append("initialize did not report serverInfo.name=jsonmend")

        # A notification must produce no response: the next line must be the
        # ping's answer, not an empty notification answer.
        connection.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        connection.send({"jsonrpc": "2.0", "id": 2, "method": "ping"})
        ping = connection.read()
        if ping.get("id") != 2:
            failures.append(f"notification produced a response (next id {ping.get('id')})")

        connection.send({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        tools = connection.read()
        names = [tool.get("name") for tool in tools.get("result", {}).get("tools", [])]
        expected = [
            "jsonmend_repair",
            "jsonmend_analyze",
            "jsonmend_validate",
            "jsonmend_readiness",
        ]
        if names != expected:
            failures.append(f"tools/list: expected {expected}, got {names}")

        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "jsonmend_analyze",
                    "arguments": {"text": '{"words":["a" "b"]}', "profile": "execution"},
                },
            }
        )
        call = connection.read()
        content = call.get("result", {}).get("content", [{}])[0].get("text", "")
        try:
            plan = json.loads(content)
        except json.JSONDecodeError:
            failures.append(f"tools/call content is not JSON: {content[:120]!r}")
            plan = {}
        if plan.get("decision") != "ambiguous" or call.get("result", {}).get("isError"):
            failures.append(f"tools/call analyze: unexpected result {plan.get('decision')}")

        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {
                    "name": "jsonmend_analyze",
                    "arguments": {"text": "{}", "schema_json": {"$ref": "#/x"}},
                },
            }
        )
        refused = connection.read()
        if not refused.get("result", {}).get("isError"):
            failures.append("tools/call with an unsupported schema keyword was not isError")
        if "E070" not in refused.get("result", {}).get("content", [{}])[0].get("text", ""):
            failures.append("tools/call refusal did not name E070")

        connection.send({"jsonrpc": "2.0", "id": 6, "method": "nope"})
        unknown = connection.read()
        if unknown.get("error", {}).get("code") != -32601:
            failures.append(f"unknown method: expected -32601, got {unknown.get('error')}")
    finally:
        connection.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--cases", default=str(HERE / "cases.jsonl"))
    args = parser.parse_args()
    binary = os.path.abspath(args.cli)
    if not os.path.isfile(binary):
        print(f"jsonmend not found: {binary}", file=sys.stderr)
        return 2

    total = 0
    failed = 0
    for raw in Path(args.cases).read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        case = json.loads(raw)
        total += 1
        failures = run_serve_case(binary, case)
        if failures:
            failed += 1
            print(f"FAIL {case['name']}")
            for failure in failures:
                print(f"     {failure}")
        else:
            print(f"ok   {case['name']}")

    mcp_failures = run_mcp(binary)
    total += 1
    if mcp_failures:
        failed += 1
        print("FAIL mcp")
        for failure in mcp_failures:
            print(f"     {failure}")
    else:
        print("ok   mcp")

    version_failures = check_reported_versions(binary)
    total += 1
    if version_failures:
        failed += 1
        print("FAIL reported versions")
        for failure in version_failures:
            print(f"     {failure}")
    else:
        print("ok   reported versions")

    print(f"\n{total - failed}/{total} conformance groups passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
