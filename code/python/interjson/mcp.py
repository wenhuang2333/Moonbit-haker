"""Console entry point for an MCP client: `interjson-mcp`.

The MCP server itself is implemented in the MoonBit binary (`interjson mcp`);
this module only resolves the binary and replaces the process with it, so
stdin/stdout remain a clean JSON-RPC channel with no Python in the middle.

    {"mcpServers": {"interjson": {"command": "interjson-mcp"}}}
"""

from __future__ import annotations

import os
import sys

from .client import find_binary

__all__ = ["main"]


def main() -> None:
    binary = find_binary()
    os.execv(binary, [binary, "mcp", *sys.argv[1:]])


if __name__ == "__main__":
    main()
