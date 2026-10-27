"""interjson — the MoonBit JSON engine as a Python client.

The engine ships as a single native binary; this package speaks the versioned
stdio protocol (`interjson serve`) rather than reimplementing JSON
repair. That keeps one implementation of the semantics and gives Python the
same decision fields the CLI and the MoonBit library produce.

    from interjson import Client

    with Client() as jm:
        plan = jm.analyze(model_output, profile="agent", schema_json=tool["inputSchema"])
        if plan["executable"]:
            args = json.loads(plan["text"])

`find_binary()` resolves the engine: `INTERJSON_BIN`, then `PATH`, then a
bundled `interjson/bin/`, then the development build in this repository.
"""

from pathlib import Path

from .client import Client, InterJSONError, find_binary, repair, analyze, validate

__all__ = [
    "Client",
    "InterJSONError",
    "find_binary",
    "repair",
    "analyze",
    "validate",
    "__version__",
]

def _declared_version() -> str:
    """The version this package declares.

    `pyproject.toml` is the declaration, so it is read directly. When the
    package is installed rather than used from a source checkout, the
    installed metadata is the authority instead. A literal here went stale
    once already -- it said 1.1.0 while the package was 1.1.1 -- and nothing
    noticed, because the tests pinned the same stale literal.
    """
    import re

    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    try:
        text = pyproject.read_text(encoding="utf-8")
    except OSError:
        text = ""
    match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match:
        return match.group(1)
    from importlib.metadata import PackageNotFoundError
    from importlib.metadata import version as _metadata_version

    try:
        return _metadata_version("interjson-moonbit")
    except PackageNotFoundError:
        raise RuntimeError(
            "cannot determine the interjson version: no pyproject.toml next to "
            "the package and no installed metadata"
        )


__version__ = _declared_version()
