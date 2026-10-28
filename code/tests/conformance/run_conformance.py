#!/usr/bin/env python3
"""Conformance runner for the `serve` protocol and the MCP server.

    python3 code/tests/conformance/run_conformance.py \
        --cli code/_build/native/release/build/cmd/interjson/interjson.exe

Every case in `cases.jsonl` is one connection; a multi-step case keeps the
connection open so `watch`/`llm` state is exercised the way a client uses it.
The expected value is a *subset*: a case pins the fields that matter, so adding
a field to a response does not require rewriting the corpus, while removing or
changing one does fail.

The MCP half checks the four tool names, the gate's safe default, structured
content, a schema refusal (`isError`), protocol negotiation, and the
notification rule (a notification must produce no line).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
DEFAULT_CLI = HERE.parents[1] / "_build/native/release/build/cmd/interjson/interjson.exe"


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


def declared_engine() -> str:
    """The engine version, from the one place that declares it: `code/moon.mod`."""
    mod_path = HERE.parents[1] / "moon.mod"
    for line in mod_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("version"):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit(f"cannot read the version from {mod_path}")


def declared_registry() -> str:
    """The mooncakes version the README channel table maps the engine to."""
    engine = declared_engine()
    readme = HERE.parents[2] / "README.md"
    for line in readme.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] == f"`v{engine}`":
            return cells[1].strip("`")
    raise SystemExit(f"README.md has no channel-table row for v{engine}")


def resolve_versions(value: Any) -> Any:
    """Replace the `$engine` / `$registry` placeholders in an expectation.

    A release bump used to require editing `cases.jsonl` as well as the sources,
    so the corpus carried last release's version string until someone noticed.
    The placeholders keep the first case about the *shape* of `hello`; the
    `reported versions` group is what pins the two strings to the declarations,
    and it reads them from the same two files this substitution does.
    """
    if isinstance(value, str):
        return {"$engine": declared_engine(), "$registry": declared_registry()}.get(
            value, value
        )
    if isinstance(value, dict):
        return {k: resolve_versions(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve_versions(v) for v in value]
    return value


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
            expect = resolve_versions(case["expect"])
            if not subset(response, expect):
                failures.append(
                    f"raw line: expected {json.dumps(expect, ensure_ascii=False)}, "
                    f"got {json.dumps(response, ensure_ascii=False)}"
                )
        for step in case.get("steps", []):
            request = step["request"]
            connection.send(request)
            response = connection.read()
            if "id" in request and response.get("id") != request["id"]:
                failures.append(f"id mismatch: sent {request['id']}, got {response.get('id')}")
            expect = resolve_versions(step["expect"])
            if not subset(response, expect):
                failures.append(
                    f"step {request.get('method')}: expected "
                    f"{json.dumps(expect, ensure_ascii=False)}, got "
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
        result = init.get("result", {})
        if result.get("protocolVersion") != "2024-11-05":
            failures.append("initialize did not echo a supported legacy protocol version")
        if result.get("serverInfo", {}).get("name") != "interjson":
            failures.append("initialize did not report serverInfo.name=interjson")
        if not result.get("serverInfo", {}).get("title"):
            failures.append("initialize did not report serverInfo.title")
        if "interjson_gate" not in result.get("instructions", ""):
            failures.append("initialize did not tell the model to use interjson_gate")

        # A notification must produce no response: the next line must be the
        # ping's answer, not an empty notification answer. A request without an
        # `id` is a notification too, so `tools/list` sent that way is silent.
        # (The handshake has been answered above, so the session is open.)
        connection.send({"jsonrpc": "2.0", "method": "tools/list"})
        connection.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        connection.send({"jsonrpc": "2.0", "id": 2, "method": "ping"})
        ping = connection.read()
        if ping.get("id") != 2:
            failures.append(f"notification produced a response (next id {ping.get('id')})")

        connection.send({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
        tools = connection.read()
        declared = tools.get("result", {}).get("tools", [])
        names = [tool.get("name") for tool in declared]
        expected = [
            "interjson_gate",
            "interjson_repair",
            "interjson_validate",
            "interjson_readiness",
        ]
        if names != expected:
            failures.append(f"tools/list: expected {expected}, got {names}")
        for tool in declared:
            annotations = tool.get("annotations", {})
            if annotations.get("readOnlyHint") is not True:
                failures.append(f"{tool.get('name')}: missing readOnlyHint annotation")
            if tool.get("outputSchema", {}).get("type") != "object":
                failures.append(f"{tool.get('name')}: missing object outputSchema")

        # The gate is safe by default: the execution profile refuses the
        # truncated argument even though no profile was passed.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {"text": '{"path":"/tmp/x"'},
                },
            }
        )
        call = connection.read()
        # The machine-readable payload is `structuredContent`. The text channel
        # is a summary for the model, not a second copy of the payload, so the
        # two are deliberately different objects now.
        plan = call.get("result", {}).get("structuredContent")
        content = call.get("result", {}).get("content", [{}])[0].get("text", "")
        if not isinstance(plan, dict):
            failures.append("gate result carries no structuredContent object")
            plan = {}
        if plan.get("executable") is not False:
            failures.append(f"gate default profile executed a truncated value: {plan}")
        if "E010" not in (plan.get("retry") or {}).get("prompt", ""):
            failures.append("gate refusal did not carry an E010 retry prompt")
        # A refusal is a refusal on every channel: no value, and a prompt the
        # caller can send straight back to the model.
        if plan.get("executable") is False:
            if plan.get("value") is not None:
                failures.append("a non-executable plan still carried a value")
            if not (plan.get("retry") or {}).get("prompt"):
                failures.append("a non-executable plan carried no retry prompt")
        # The text channel must still be actionable and must not be the payload.
        if "decision=" not in content or "executable=" not in content:
            failures.append(f"gate text channel is not a summary: {content[:120]!r}")
        if "retry (send this back to the model)" not in content:
            failures.append("gate text channel did not repeat the retry prompt")

        # A two-reading repair is reported, not executed.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {
                        "text": '{"words":["a" "b"]}',
                        "profile": "execution",
                    },
                },
            }
        )
        ambiguous = connection.read()
        ambiguous_plan = ambiguous.get("result", {}).get("structuredContent") or {}
        if ambiguous_plan.get("decision") != "ambiguous" or ambiguous.get(
            "result", {}
        ).get("isError"):
            failures.append(f"gate ambiguous: unexpected result {ambiguous_plan.get('decision')}")

        # A schema the engine cannot honour is a tool error, not a silent pass.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {"text": "{}", "schema_json": {"$ref": "#/x"}},
                },
            }
        )
        refused = connection.read()
        if not refused.get("result", {}).get("isError"):
            failures.append("tools/call with an unsupported schema keyword was not isError")
        if "E070" not in refused.get("result", {}).get("content", [{}])[0].get("text", ""):
            failures.append("tools/call refusal did not name E070")
        if "structuredContent" in refused.get("result", {}):
            failures.append("an error result must not carry structuredContent")

        # An unknown tool is a protocol error, not a success with isError.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": {"name": "no_such_tool", "arguments": {}},
            }
        )
        unknown_tool = connection.read()
        if unknown_tool.get("error", {}).get("code") != -32602:
            failures.append(
                f"unknown tool: expected -32602, got {unknown_tool.get('error')}"
            )

        # A non-object `arguments` is a bad request, not an empty argument set.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "tools/call",
                "params": {"name": "interjson_gate", "arguments": "not an object"},
            }
        )
        bad_args = connection.read()
        if bad_args.get("error", {}).get("code") != -32602:
            failures.append(
                f"non-object arguments: expected -32602, got {bad_args.get('error')}"
            )

        # The agent profile is the profile the library documents, protocol
        # included: a model in a chat channel writes a sentence before the
        # arguments, and the gate exists to accept that. This is the shape the
        # tool description promises and the one that used to be refused.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 12,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {"text": 'Here are the args:\n{"a":1}'},
                },
            }
        )
        prose = connection.read()
        prose_plan = prose.get("result", {}).get("structuredContent") or {}
        if prose_plan.get("executable") is not True:
            failures.append(
                f"gate default profile refused a prose-prefixed argument: {prose_plan.get('error')}"
            )
        if prose_plan.get("value") != {"a": 1}:
            failures.append(f"gate did not return the parsed value: {prose_plan.get('value')}")

        # ...while `execution` is not the agent profile and must still refuse it.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 13,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {"text": 'Here are the args:\n{"a":1}', "profile": "execution"},
                },
            }
        )
        strict_plan = connection.read().get("result", {}).get("structuredContent") or {}
        if strict_plan.get("executable") is not False:
            failures.append("the execution profile accepted prose-prefixed arguments")

        # A declaration the value does not satisfy is a refusal with a prompt,
        # not a refusal with a value and a null retry.
        connection.send(
            {
                "jsonrpc": "2.0",
                "id": 14,
                "method": "tools/call",
                "params": {
                    "name": "interjson_gate",
                    "arguments": {
                        "text": '{"a":1}',
                        "schema_json": {
                            "type": "object",
                            "properties": {"a": {"type": "string"}},
                            "required": ["a"],
                        },
                    },
                },
            }
        )
        schema_plan = connection.read().get("result", {}).get("structuredContent") or {}
        if schema_plan.get("executable") is not False:
            failures.append("a value that fails its declaration was executable")
        if schema_plan.get("value") is not None:
            failures.append("a value that fails its declaration was still returned")
        if not (schema_plan.get("retry") or {}).get("prompt"):
            failures.append("a declaration failure carried no retry prompt")

        # The outputSchema of every tool must describe what the tool returns.
        # A schema that does not validate its own payload is worse than none:
        # a host that trusts it rejects valid responses.
        for tool in declared:
            schema = tool.get("outputSchema") or {}
            if schema.get("type") != "object":
                failures.append(f"{tool.get('name')}: outputSchema is not an object")
                continue
            if not schema.get("properties"):
                failures.append(f"{tool.get('name')}: outputSchema declares no properties")
            if schema.get("additionalProperties") is not False:
                failures.append(f"{tool.get('name')}: outputSchema is not closed")
            required = set(schema.get("required") or [])
            declared_props = set((schema.get("properties") or {}).keys())
            if not required <= declared_props:
                failures.append(f"{tool.get('name')}: outputSchema requires undeclared members")
            if tool.get("name") == "interjson_gate":
                for field in ("decision", "executable", "exactness", "value", "retry"):
                    if field not in declared_props:
                        failures.append(f"gate outputSchema omits `{field}`")

        connection.send({"jsonrpc": "2.0", "id": 8, "method": "nope"})
        unknown = connection.read()
        if unknown.get("error", {}).get("code") != -32601:
            failures.append(f"unknown method: expected -32601, got {unknown.get('error')}")
    finally:
        connection.close()

    # The printed client configurations are part of the deployment surface: a
    # typo here is what a user copies into their client, so they are pinned.
    config = subprocess.run(
        [binary, "mcp", "--print-config=claude"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    if config.returncode != 0 or config.stdout.strip() != (
        "claude mcp add interjson -- interjson mcp"
    ):
        failures.append(f"--print-config=claude printed {config.stdout!r}")
    cursor = subprocess.run(
        [binary, "mcp", "--print-config=cursor"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    try:
        printed = json.loads(cursor.stdout)
    except json.JSONDecodeError:
        printed = {}
    if printed.get("mcpServers", {}).get("interjson", {}).get("args") != ["mcp"]:
        failures.append(f"--print-config=cursor is not a usable config: {cursor.stdout!r}")

    # The `interjson-mcp` alias: a copy or symlink under that name starts the
    # MCP server with no arguments. This is how package managers and client
    # configs invoke the server, so the dispatch is exercised, not assumed.
    alias_dir = tempfile.mkdtemp(prefix="interjson-mcp-")
    try:
        alias = os.path.join(
            alias_dir, "interjson-mcp.exe" if os.name == "nt" else "interjson-mcp"
        )
        if os.name == "nt":
            shutil.copy2(binary, alias)
        else:
            os.symlink(binary, alias)
        alias_proc = subprocess.Popen(
            [alias],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        try:
            assert alias_proc.stdin is not None and alias_proc.stdout is not None
            alias_proc.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"},
                    }
                )
                + "\n"
            )
            alias_proc.stdin.flush()
            alias_proc.stdout.readline()
            alias_proc.stdin.write(
                json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}) + "\n"
            )
            alias_proc.stdin.flush()
            alias_tools = json.loads(alias_proc.stdout.readline())
            names = [t.get("name") for t in alias_tools.get("result", {}).get("tools", [])]
            if names != expected:
                failures.append(f"interjson-mcp alias did not start the server: {names}")
        finally:
            alias_proc.kill()
            alias_proc.wait(timeout=10)
    finally:
        shutil.rmtree(alias_dir, ignore_errors=True)

    # An unsupported protocol revision must be answered with the newest
    # revision the server implements, never echoed back.
    probe = Connection(binary, "mcp")
    try:
        probe.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "1999-01-01",
                    "capabilities": {},
                    "clientInfo": {"name": "conformance", "version": "0"},
                },
            }
        )
        unsupported = probe.read().get("result", {}).get("protocolVersion")
        if unsupported != "2025-06-18":
            failures.append(f"unsupported protocol version: expected 2025-06-18, got {unsupported}")
    finally:
        probe.close()

    # `2025-03-26` is a revision this server implements and must echo.
    mid = Connection(binary, "mcp")
    try:
        mid.send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-03-26"},
            }
        )
        echoed = mid.read().get("result", {}).get("protocolVersion")
        if echoed != "2025-03-26":
            failures.append(f"2025-03-26: expected it echoed, got {echoed}")
    finally:
        mid.close()

    # MCP is a session protocol: a request before `initialize` is `-32002`,
    # and `initialize` is answered even though nothing came before it.
    fresh = Connection(binary, "mcp")
    try:
        fresh.send({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        early = fresh.read()
        if early.get("error", {}).get("code") != -32002:
            failures.append(
                f"tools/list before initialize: expected -32002, got {early.get('error')}"
            )
        fresh.send({"jsonrpc": "2.0", "id": 2, "method": "ping"})
        if fresh.read().get("id") != 2:
            failures.append("ping before initialize was not answered")
        fresh.send(
            {"jsonrpc": "2.0", "id": 3, "method": "initialize", "params": {}}
        )
        if "result" not in fresh.read():
            failures.append("initialize was not answered on a fresh session")
        fresh.send({"jsonrpc": "2.0", "id": 4, "method": "tools/list"})
        if "result" not in fresh.read():
            failures.append("tools/list after initialize was not answered")
    finally:
        fresh.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--cases", default=str(HERE / "cases.jsonl"))
    args = parser.parse_args()
    binary = os.path.abspath(args.cli)
    if not os.path.isfile(binary):
        print(f"interjson not found: {binary}", file=sys.stderr)
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
