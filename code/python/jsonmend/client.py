"""A thin, dependency-free client for the `jsonmend serve` protocol.

The server is a child process speaking one JSON object per line on stdin and
stdout. A reader thread turns stdout into a queue so a request can time out
without depending on `select` and buffered pipes.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Any, Iterable

__all__ = ["Client", "JsonMendError", "find_binary", "repair", "analyze", "validate"]

_EOF = object()


class JsonMendError(RuntimeError):
    """A structured refusal from the engine (`E010`, `E011`, `E070`, ...)."""

    def __init__(self, error: dict[str, Any]) -> None:
        self.code = str(error.get("code", "E000"))
        self.message = str(error.get("message", ""))
        self.exit_code = int(error.get("exit", 1))
        self.retry_hint = error.get("retry_hint")
        self.offset = error.get("offset")
        super().__init__(f"{self.code} {self.message}")

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"code": self.code, "message": self.message, "exit": self.exit_code}
        if self.retry_hint is not None:
            out["retry_hint"] = self.retry_hint
        if self.offset is not None:
            out["offset"] = self.offset
        return out


def find_binary() -> str:
    """Locate the engine.

    Order: `JSONMEND_BIN`, `PATH`, a binary bundled next to this package, then
    the development build inside this repository.
    """

    env = os.environ.get("JSONMEND_BIN")
    if env:
        return env
    found = shutil.which("jsonmend")
    if found:
        return found
    here = Path(__file__).resolve().parent
    for name in ("jsonmend", "jsonmend.exe"):
        candidate = here / "bin" / name
        if candidate.is_file():
            return str(candidate)
    # Development checkout: code/python/jsonmend/client.py -> code/
    code_dir = here.parents[1]
    for target in ("native",):
        candidate = (
            code_dir
            / "_build"
            / target
            / "release"
            / "build"
            / "cmd"
            / "jsonmend"
            / "jsonmend.exe"
        )
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(
        "the jsonmend engine was not found; set JSONMEND_BIN, put `jsonmend` on "
        "PATH, or build it with `moon build cmd/jsonmend --target native --release`"
    )


class Client:
    """A long-lived `jsonmend serve` process.

    Use it as a context manager, or call `close()`. One client is not shared
    between threads; a lock serialises requests so a caller that does share one
    still gets correct `id` matching.
    """

    def __init__(
        self,
        binary: str | None = None,
        *,
        args: Iterable[str] = (),
        timeout: float = 30.0,
        stderr: int | None = subprocess.DEVNULL,
    ) -> None:
        self.binary = binary or find_binary()
        self.timeout = timeout
        self._lock = threading.Lock()
        self._next_id = 0
        self._responses: "queue.Queue[Any]" = queue.Queue()
        self._stderr_lines: list[str] = []
        self.proc = subprocess.Popen(
            [self.binary, "serve", *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if stderr is None else stderr,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader.start()
        if stderr is None:
            self._err_reader = threading.Thread(target=self._read_stderr, daemon=True)
            self._err_reader.start()

    # -- plumbing ---------------------------------------------------------

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._responses.put(json.loads(line))
            except json.JSONDecodeError:
                self._responses.put({"ok": False, "error": {"code": "E030", "message": line}})
        self._responses.put(_EOF)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._stderr_lines.append(line.rstrip())
            if len(self._stderr_lines) > 100:
                del self._stderr_lines[:50]

    def request(self, method: str, **params: Any) -> Any:
        """Send one request and return its `result`, or raise `JsonMendError`."""
        with self._lock:
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"jsonmend exited with {self.proc.returncode}; "
                    f"stderr: {' | '.join(self._stderr_lines[-3:])}"
                )
            self._next_id += 1
            request_id = self._next_id
            payload = {"id": request_id, "method": method}
            if params:
                payload["params"] = params
            assert self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
            try:
                response = self._responses.get(timeout=self.timeout)
            except queue.Empty as exc:
                raise TimeoutError(f"jsonmend did not answer `{method}` in {self.timeout}s") from exc
            if response is _EOF:
                raise RuntimeError(
                    f"jsonmend closed the stream; stderr: {' | '.join(self._stderr_lines[-3:])}"
                )
            if response.get("id") != request_id:
                # The protocol answers in order; a mismatch means the stream is
                # out of sync, which is worth reporting rather than guessing.
                raise RuntimeError(
                    f"jsonmend answered id {response.get('id')} for request {request_id}"
                )
            if response.get("ok"):
                return response["result"]
            raise JsonMendError(response.get("error") or {})

    # -- methods ----------------------------------------------------------

    def hello(self) -> dict[str, Any]:
        """Handshake: name, engine version, registry version, protocol, capabilities."""
        return self.request("hello")

    def repair(
        self,
        text: str,
        *,
        profile: str | None = None,
        schema: str | None = None,
        schema_json: Any = None,
        skip_prose: bool | None = None,
        max_loss: str | None = None,
    ) -> dict[str, Any]:
        return self.request("repair", **self._params(text, profile, schema, schema_json, skip_prose, max_loss))

    def analyze(
        self,
        text: str,
        *,
        profile: str | None = None,
        schema: str | None = None,
        schema_json: Any = None,
        skip_prose: bool | None = None,
        max_loss: str | None = None,
    ) -> dict[str, Any]:
        """The decision plan: `decision`, `executable`, `exactness`, `retry`, ..."""
        return self.request("analyze", **self._params(text, profile, schema, schema_json, skip_prose, max_loss))

    def validate(
        self,
        text: str,
        *,
        schema: str | None = None,
        schema_json: Any = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        return self.request("validate", **params)

    def readiness(
        self,
        text: str,
        *,
        schema: str | None = None,
        schema_json: Any = None,
        step: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if step is not None:
            params["step"] = step
        return self.request("readiness", **params)

    def watch_start(
        self,
        *,
        schema: str | None = None,
        schema_json: Any = None,
        profile: str | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {}
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if profile is not None:
            params["profile"] = profile
        return self.request("watch.start", **params)

    def watch_feed(self, chunk: str) -> dict[str, Any]:
        return self.request("watch.feed", chunk=chunk)

    def watch_finish(self) -> dict[str, Any]:
        return self.request("watch.finish")

    def llm_open(self, provider: str = "anthropic") -> dict[str, Any]:
        return self.request("llm.open", provider=provider)

    def llm_feed(self, event: str) -> dict[str, Any]:
        return self.request("llm.feed", event=event)

    def llm_close(self) -> dict[str, Any]:
        return self.request("llm.close")

    @staticmethod
    def _params(
        text: str,
        profile: str | None,
        schema: str | None,
        schema_json: Any,
        skip_prose: bool | None,
        max_loss: str | None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if profile is not None:
            params["profile"] = profile
        if schema is not None:
            params["schema"] = schema
        if schema_json is not None:
            params["schema_json"] = schema_json
        if skip_prose is not None:
            params["skip_prose"] = skip_prose
        if max_loss is not None:
            params["max_loss"] = max_loss
        return params

    # -- lifecycle --------------------------------------------------------

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                self.request("shutdown")
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

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def __del__(self) -> None:  # pragma: no cover - best effort
        try:
            self.close()
        except Exception:
            pass


def repair(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot repair. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.repair(text, **kwargs)


def analyze(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot analyze. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.analyze(text, **kwargs)


def validate(text: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot validate. Reuse a `Client` in a loop; this spawns a process."""
    with Client() as client:
        return client.validate(text, **kwargs)
