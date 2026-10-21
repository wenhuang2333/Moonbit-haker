"""The versions this build must report, read from the release declarations.

The engine version and the mooncakes registry version are hardcoded in the
MoonBit sources, so a test that pins a literal goes red on every release --
which turns a release day into a guessing game about which literal is
current. Reading the declarations instead keeps the test honest (it still
fails when the binary disagrees with `moon.mod`) without making it a chore.

    code/moon.mod            -> the engine version
    README.md channel table  -> the registry version for that engine version
"""

from __future__ import annotations

from pathlib import Path

CODE = Path(__file__).resolve().parents[2]
REPO = CODE.parent


def engine_version() -> str:
    """The version in `code/moon.mod`."""
    mod = CODE / "moon.mod"
    for line in mod.read_text(encoding="utf-8").splitlines():
        if line.startswith("version"):
            return line.split("=", 1)[1].strip().strip('"')
    raise AssertionError(f"no version in {mod}")


def registry_version() -> str:
    """The mooncakes version the README's channel table maps the engine to."""
    engine = engine_version()
    readme = REPO / "README.md"
    for line in readme.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] == f"`v{engine}`":
            return cells[1].strip("`")
    raise AssertionError(f"README.md has no channel-table row for v{engine}")
