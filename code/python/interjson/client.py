"""A thin, dependency-free client for the `interjson serve` protocol.

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
import time
from pathlib import Path
from typing import Any, Iterable

__all__ = ["Client", "InterJSONError", "find_binary", "repair", "analyze", "validate"]

_EOF = object()


class InterJSONError(RuntimeError):
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


def _platform_key() -> str | None:
    """The release platform this interpreter can run, or None.

    The wheel carries one binary per release platform, so the choice is made
    here rather than by installing four different wheels: one wheel works on
    every platform the release supports, and the cost is a few unused
    megabytes.

    The keys are the release asset names with the `interjson-` prefix removed,
    so a wheel and a release can be compared by eye. There is deliberately no
    Intel-macOS key: the MoonBit toolchain publishes no `darwin-x86_64`
    target, so there is no binary to name.
    """

    import platform as _platform
    import sys

    machine = (_platform.machine() or "").lower()
    if sys.platform == "darwin":
        return "macos-arm64" if machine in ("arm64", "aarch64") else None
    if sys.platform.startswith("linux"):
        if machine in ("x86_64", "amd64"):
            return "linux-x86_64"
        if machine in ("aarch64", "arm64"):
            return "linux-arm64"
        return None
    if sys.platform in ("win32", "cygwin"):
        return "windows-x86_64"
    return None


def _make_executable(path: Path) -> None:
    """The executable bit survives a wheel install on most platforms, not all.

    A binary that is present but not executable turns every call into a
    `PermissionError` that names a file the user did not install by hand, so
    the bit is restored once, quietly, before the path is returned.
    """

    try:
        mode = path.stat().st_mode
        if not mode & 0o111:
            path.chmod(mode | 0o755)
    except OSError:
        pass


def find_binary() -> str:
    """Locate the engine.

    Order: `INTERJSON_BIN`, `PATH`, the binary this wheel carries for this
    platform, a binary placed directly in `bin/`, then the development build
    inside this repository.

    An explicit path or a `PATH` entry wins over the bundled binary on purpose:
    a caller who has installed a newer CLI should not silently get whichever
    engine happened to be current when the Python package was built.
    """

    env = os.environ.get("INTERJSON_BIN")
    if env:
        return env
    found = shutil.which("interjson")
    if found:
        return found
    here = Path(__file__).resolve().parent
    key = _platform_key()
    if key is not None:
        for name in ("interjson", "interjson.exe"):
            candidate = here / "bin" / key / name
            if candidate.is_file():
                _make_executable(candidate)
                return str(candidate)
    for name in ("interjson", "interjson.exe"):
        candidate = here / "bin" / name
        if candidate.is_file():
            _make_executable(candidate)
            return str(candidate)
    # Development checkout: code/python/interjson/client.py -> code/
    code_dir = here.parents[1]
    for target in ("native",):
        candidate = (
            code_dir
            / "_build"
            / target
            / "release"
            / "build"
            / "cmd"
            / "interjson"
            / "interjson.exe"
        )
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(_not_found_message(here, key))


def _not_found_message(here: Path, key: str | None) -> str:
    """Say what is missing in terms of what this installation actually has.

    Three different situations used to produce the same sentence, and only one
    of them was fixed by setting `INTERJSON_BIN`:

      * a source checkout with no build -- "build it";
      * a wheel installed for a platform the release does not cover, such as
        Intel macOS -- "there is no binary for this platform", which no amount
        of `pip install` will change;
      * a wheel whose bundled directory was stripped by a repackager.
    """

    import platform as _platform
    import sys

    bundled = sorted(
        p.name for p in (here / "bin").iterdir() if p.is_dir()
    ) if (here / "bin").is_dir() else []
    where = f"{_platform.system()} {_platform.machine() or 'unknown'} ({sys.platform})"
    if bundled and key is None:
        return (
            f"the interjson engine is not available for {where}: the package "
            f"carries {', '.join(bundled)}. Set INTERJSON_BIN to a binary built "
            "for this platform, or build one with "
            "`moon build cmd/interjson --target native --release`."
        )
    return (
        "the interjson engine was not found. Reinstall `interjson-moonbit` from "
        "PyPI to get the bundled binary, or set INTERJSON_BIN, put `interjson` on "
        "PATH, or build it with `moon build cmd/interjson --target native --release`"
    )


class Client:
    """A long-lived `interjson serve` process.

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
        stderr: int | None = None,
    ) -> None:
        self.binary = binary or find_binary()
        self.timeout = timeout
        self._lock = threading.Lock()
        self._next_id = 0
        self._responses: "queue.Queue[Any]" = queue.Queue()
        self._stderr_lines: list[str] = []
        # `stderr` defaults to a pipe rather than DEVNULL. The engine writes
        # its diagnostics there, and `stderr=DEVNULL` meant that every error
        # message the client raised about a dead or misbehaving process ended
        # with an empty `stderr:` field -- the one piece of evidence that says
        # *why* the engine exited was thrown away by default. Pass
        # `stderr=subprocess.DEVNULL` to opt out.
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

    def _resync(self) -> None:
        """Drop every buffered answer.

        The reader thread is left alone: starting a second one would let two
        threads feed the same queue, and the answers would interleave. What
        matters is that a *late* answer cannot be mistaken for the next
        request's answer, which `request` handles by matching ids.
        """
        while True:
            try:
                self._responses.get_nowait()
            except queue.Empty:
                break

    def request(self, method: str, **params: Any) -> Any:
        """Send one request and return its `result`, or raise `InterJSONError`."""
        with self._lock:
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"interjson exited with {self.proc.returncode}; "
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
            # Wait for *this* request's answer, discarding anything else.
            #
            # A timed-out request leaves its answer in flight: the reader
            # thread delivers it after the caller has given up, and it then
            # sits at the head of the queue. Reading it as the next request's
            # answer either raised a confusing id mismatch or, when the ids
            # happened to line up, returned the wrong result. Matching on the
            # id is what makes a late answer harmless.
            deadline = time.monotonic() + self.timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._resync()
                    raise TimeoutError(
                        f"interjson did not answer `{method}` in {self.timeout}s"
                    )
                try:
                    response = self._responses.get(timeout=remaining)
                except queue.Empty:
                    self._resync()
                    raise TimeoutError(
                        f"interjson did not answer `{method}` in {self.timeout}s"
                    )
                if response is _EOF:
                    raise RuntimeError(
                        f"interjson closed the stream; "
                        f"stderr: {' | '.join(self._stderr_lines[-3:])}"
                    )
                if response.get("id") != request_id:
                    # An answer to an abandoned request. Drop it and keep
                    # waiting for the one this call is owed.
                    continue
                if response.get("ok"):
                    return response["result"]
                raise InterJSONError(response.get("error") or {})

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
