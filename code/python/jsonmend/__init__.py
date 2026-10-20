"""jsonmend — the MoonBit JSON engine as a Python client.

The engine ships as a single native binary; this package speaks the versioned
stdio protocol (`jsonmend serve --stdio`) rather than reimplementing JSON
repair. That keeps one implementation of the semantics and gives Python the
same decision fields the CLI and the MoonBit library produce.

    from jsonmend import Client

    with Client() as jm:
        plan = jm.analyze(model_output, profile="agent", schema_json=tool["inputSchema"])
        if plan["executable"]:
            args = json.loads(plan["text"])

`find_binary()` resolves the engine: `JSONMEND_BIN`, then `PATH`, then a
bundled `jsonmend/bin/`, then the development build in this repository.
"""

from .client import Client, JsonMendError, find_binary, repair, analyze, validate

__all__ = [
    "Client",
    "JsonMendError",
    "find_binary",
    "repair",
    "analyze",
    "validate",
    "__version__",
]

__version__ = "1.1.0"
