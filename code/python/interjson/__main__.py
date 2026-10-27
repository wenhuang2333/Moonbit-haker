"""`python -m interjson` — small dispatcher.

    python -m interjson mcp             # MCP stdio server (replaces the process)
    python -m interjson http --port 8080
    python -m interjson version
"""

from __future__ import annotations

import sys

from . import __version__


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    command, rest = args[0], args[1:]
    if command == "mcp":
        from .mcp import main as mcp_main

        # `mcp_main` reads sys.argv; pass the extra arguments through.
        sys.argv = ["interjson-mcp", *rest]
        mcp_main()
    elif command == "http":
        from .http import main as http_main

        http_main(rest)
    elif command in ("version", "--version", "-V"):
        print(f"interjson {__version__}")
    else:
        raise SystemExit(f"unknown command `{command}`; use mcp, http or version")


if __name__ == "__main__":
    main()
