#!/usr/bin/env node
"use strict";

// `interjson-mcp` — start the local MCP server from npm.
//
// The MCP implementation lives in the native binary (`interjson mcp`), not in
// this package: there is exactly one server, the same one the release assets
// and the pip package start. This launcher only finds that binary and hands it
// this process's stdin/stdout, so the JSON-RPC channel stays clean (no Node
// process in the middle, no banner on stdout).
//
// Resolution order, mirroring the Python client:
//   1. `INTERJSON_BIN`
//   2. `interjson` on PATH
//   3. the development build inside this repository
//
// A binary that is not found is a startup error on stderr with the install
// command, never a half-working server.

const { spawn } = require("node:child_process");
const { existsSync } = require("node:fs");
const { dirname, join } = require("node:path");
const { fileURLToPath } = require("node:url");

function findBinary() {
  const env = process.env.INTERJSON_BIN;
  if (env) return env;

  const pathParts = (process.env.PATH || "").split(require("node:path").delimiter);
  const names = process.platform === "win32" ? ["interjson.exe", "interjson"] : ["interjson"];
  for (const dir of pathParts) {
    if (!dir) continue;
    for (const name of names) {
      const candidate = join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }

  // Development checkout: code/npm/mcp.cjs -> code/
  const codeDir = join(__dirname, "..");
  for (const name of ["interjson.exe", "interjson"]) {
    const candidate = join(
      codeDir,
      "_build",
      "native",
      "release",
      "build",
      "cmd",
      "interjson",
      name,
    );
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function main() {
  const binary = findBinary();
  if (!binary) {
    process.stderr.write(
      [
        "interjson-mcp: the InterJSON engine was not found.",
        "",
        "Install it in one of these ways:",
        "  - download a release binary and put `interjson` on PATH",
        "  - set INTERJSON_BIN=/absolute/path/to/interjson",
        "  - build it: cd code && moon build cmd/interjson --target native --release",
        "",
      ].join("\n"),
    );
    process.exit(127);
  }

  const child = spawn(binary, ["mcp", ...process.argv.slice(2)], {
    stdio: "inherit",
    windowsHide: true,
  });
  child.on("error", (err) => {
    process.stderr.write(`interjson-mcp: failed to start ${binary}: ${err.message}\n`);
    process.exit(127);
  });
  child.on("exit", (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    process.exit(code === null ? 1 : code);
  });
}

main();
