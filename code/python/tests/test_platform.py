"""The wheel carries one engine per release platform; these are the rules it
uses to pick one.

Run from `code/python`: `python -m unittest discover -s tests`.

Nothing here starts a process. The client tests already cover "a found binary
answers"; what is easy to get wrong is the choice itself -- a wheel that ships
the right bytes but picks the wrong directory looks exactly like a working
install until the first call.
"""

from __future__ import annotations

import io
import os
import platform
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from interjson.client import _not_found_message, _platform_key, find_binary

# The platform keys the wheel ships. Kept next to the assertions rather than
# imported from the client so a typo in one is caught by the other.
RELEASE_PLATFORMS = {"linux-x86_64", "linux-arm64", "macos-arm64", "windows-x86_64"}


def _key_for(system: str, machine: str) -> str | None:
    """`_platform_key()` with `sys.platform` and `platform.machine()` faked."""

    with mock.patch.object(sys, "platform", system), mock.patch.object(
        platform, "machine", lambda: machine
    ):
        return _platform_key()


class PlatformKeyTests(unittest.TestCase):
    def test_every_key_it_can_return_is_a_platform_the_release_has(self) -> None:
        seen = {
            _key_for("darwin", "arm64"),
            _key_for("linux", "x86_64"),
            _key_for("linux", "aarch64"),
            _key_for("win32", "AMD64"),
        }
        self.assertEqual(seen, RELEASE_PLATFORMS)

    def test_machine_spellings_are_equivalent(self) -> None:
        # `platform.machine()` is not uniform across interpreters and libc
        # versions; the two spellings of arm64 are the same machine.
        self.assertEqual(_key_for("linux", "aarch64"), _key_for("linux", "arm64"))
        self.assertEqual(_key_for("darwin", "aarch64"), "macos-arm64")
        self.assertEqual(_key_for("linux", "AMD64"), "linux-x86_64")

    def test_intel_macos_has_no_key(self) -> None:
        # The MoonBit toolchain publishes no darwin-x86_64 target, so there is
        # no binary to name. A key here would send find_binary() looking for a
        # directory the wheel never has, and the error would blame the install.
        self.assertIsNone(_key_for("darwin", "x86_64"))

    def test_unsupported_systems_have_no_key(self) -> None:
        for system in ("freebsd14", "sunos5", "emscripten"):
            self.assertIsNone(_key_for(system, "x86_64"), system)


class BundledBinaryTests(unittest.TestCase):
    """`find_binary()` must prefer the wheel's directory and say why if it can't."""

    def setUp(self) -> None:
        # CI exports INTERJSON_BIN for the client tests, and that variable is
        # by design the first thing `find_binary()` looks at -- so leaving it
        # set would make every assertion below pass or fail for a reason this
        # class is not testing. It is cleared here and restored afterwards.
        self._saved_bin = os.environ.pop("INTERJSON_BIN", None)
        # `PATH` can also answer the question before the bundled directory is
        # reached, for the same reason.
        self._saved_which = shutil.which
        shutil.which = lambda _name: None
        self.tmp = tempfile.TemporaryDirectory()
        self.pkg = Path(self.tmp.name) / "interjson"
        self.pkg.mkdir()
        # `find_binary()` derives the package directory from `__file__`, so the
        # fake module file has to sit one level inside it.
        self.module_file = self.pkg / "client.py"
        self.module_file.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        shutil.which = self._saved_which
        if self._saved_bin is not None:
            os.environ["INTERJSON_BIN"] = self._saved_bin
        self.tmp.cleanup()

    def _place(self, key: str, name: str = "interjson") -> Path:
        directory = self.pkg / "bin" / key
        directory.mkdir(parents=True)
        binary = directory / name
        binary.write_bytes(b"#!/bin/sh\n")
        binary.chmod(0o644)  # the mode a wheel can end up with after unpacking
        return binary

    def test_it_prefers_the_directory_for_this_platform(self) -> None:
        self._place("linux-x86_64")
        with mock.patch(
            "interjson.client._platform_key", lambda: "linux-x86_64"
        ), mock.patch("interjson.client.shutil.which", lambda _: None), mock.patch(
            "interjson.client.Path", lambda *_: self.module_file
        ):
            found = find_binary()

        self.assertTrue(found.endswith("bin/linux-x86_64/interjson"), found)

    def test_it_restores_a_missing_executable_bit(self) -> None:
        # A binary that is present but not executable fails with PermissionError
        # naming a file the user never installed by hand.
        binary = self._place("macos-arm64")
        with mock.patch(
            "interjson.client._platform_key", lambda: "macos-arm64"
        ), mock.patch("interjson.client.shutil.which", lambda _: None), mock.patch(
            "interjson.client.Path", lambda *_: self.module_file
        ):
            find_binary()

        self.assertTrue(binary.stat().st_mode & 0o111, "the executable bit was not restored")

    def test_an_explicit_binary_still_wins(self) -> None:
        # A caller pointing at a newer CLI must not silently get the bundled one.
        # setUp popped INTERJSON_BIN, so this sets the case explicitly instead
        # of inheriting whatever the shell had.
        with mock.patch.dict(os.environ, {"INTERJSON_BIN": "/opt/interjson"}), mock.patch(
            "interjson.client.shutil.which", lambda _: None
        ):
            self.assertEqual(find_binary(), "/opt/interjson")

    def test_the_error_names_the_platforms_the_wheel_carries(self) -> None:
        self._place("linux-x86_64")
        self._place("macos-arm64")
        message = _not_found_message(self.pkg, None)

        self.assertIn("linux-x86_64", message)
        self.assertIn("macos-arm64", message)
        # "Reinstall" is the wrong advice when the platform has no binary at all.
        self.assertNotIn("Reinstall", message)


class WheelShapeTests(unittest.TestCase):
    """The built wheel must carry every platform directory, not just one."""

    def test_the_published_wheel_lists_every_platform(self) -> None:
        # `dist/python` is where `build_wheel.sh` writes. The gate runs the
        # same assertion on the artefact; doing it here as well means a
        # developer who rebuilds and reruns `node --test`-style checks sees it
        # without running the shell gate.
        wheels = sorted((Path(__file__).resolve().parents[3] / "dist" / "python").glob("*.whl"))
        if not wheels:
            self.skipTest("no built wheel in dist/python; run bash code/python/build_wheel.sh")

        names = zipfile.ZipFile(io.BytesIO(wheels[-1].read_bytes())).namelist()
        for key in RELEASE_PLATFORMS:
            suffix = ".exe" if key.startswith("windows") else ""
            self.assertIn(
                f"interjson/bin/{key}/interjson{suffix}",
                names,
                f"the wheel does not carry the engine for {key}",
            )


if __name__ == "__main__":
    unittest.main()
