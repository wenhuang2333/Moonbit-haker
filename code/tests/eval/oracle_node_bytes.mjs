// Independent-corpus oracle driver: repair each input with the `jsonrepair` npm
// package and also report whether strict `JSON.parse` accepts the input as-is.
//
//   node code/tests/eval/oracle_node_bytes.mjs < corpus.b64.jsonl > out.jsonl
//
// Input lines are `{"id", "b64"}`; the payload is base64 so that the original
// bytes survive the pipe. Output lines are
// `{"id", "decoding", "strict", "strict_error", "ok", "valid", "value", "error"}`.
//
// `decoding` is `utf-8` when the bytes are valid UTF-8 and `latin-1` otherwise:
// a JavaScript string cannot hold arbitrary bytes, so a non-UTF-8 input is
// mapped byte-per-code-point. Python's `json_repair` column in
// `run_independent.py` applies the same rule, so both oracles see the same
// characters.
//
// `strict` is `JSON.parse` on the untouched text, `valid` is `JSON.parse` on the
// text `jsonrepair` returned, which is what a caller would do next.

// `jsonrepair` is loaded through CommonJS resolution, not through a bare ESM
// `import`. The ESM resolver ignores `NODE_PATH` (that variable is CJS-only), so
// `import { jsonrepair } from "jsonrepair"` only works when the package happens
// to sit in a `node_modules` above this file — on a developer machine that is
// often true by accident, and in CI it never is, because the package is
// installed into `$RUNNER_TEMP`. The column then degraded to `n/a (library not
// installed)` with only a printed note, so every CI run silently published an
// independent-corpus report without the third oracle. Requiring the package by
// absolute path fixes that and keeps the column honest.
//
// The candidate list mirrors `code/tests/diff/run_diff.py::find_node_modules`;
// both conventions of the `--node-dir` argument are accepted, because the
// scripts in this directory disagree about whether it names `node_modules`
// itself or the directory that holds it.
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { existsSync } from "node:fs";
import path from "node:path";

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));

function searchDirs() {
  const dirs = [];
  const push = (d) => {
    if (d && !dirs.includes(d)) dirs.push(d);
  };
  for (const entry of (process.env.NODE_PATH || "").split(path.delimiter)) {
    if (!entry) continue;
    push(entry); // NODE_PATH names the node_modules directory
    push(path.join(entry, "node_modules")); // ...or the directory holding it
    push(path.dirname(entry)); // ...or the doubled form (`x/node_modules/node_modules`)
  }
  let d = HERE;
  for (let i = 0; i < 4; i += 1) {
    d = path.dirname(d);
    push(path.join(d, "node_modules"));
  }
  for (const base of ["/private/tmp", "/tmp", "/var/tmp"]) {
    push(path.join(base, "node_modules"));
  }
  return dirs;
}

function loadJsonrepair() {
  const tried = [];
  for (const dir of searchDirs()) {
    const pkg = path.join(dir, "jsonrepair");
    if (!existsSync(path.join(pkg, "package.json"))) {
      tried.push(dir);
      continue;
    }
    try {
      const mod = require(pkg);
      const fn = mod.jsonrepair || (mod.default && mod.default.jsonrepair);
      if (typeof fn === "function") return fn;
      tried.push(dir + " (no jsonrepair export)");
    } catch (e) {
      tried.push(dir + " (" + String(e).slice(0, 60) + ")");
    }
  }
  throw new Error(
    "jsonrepair not found; searched: " + (tried.length ? tried.join(", ") : "(none)")
  );
}

let jsonrepair;
try {
  jsonrepair = loadJsonrepair();
} catch (e) {
  process.stderr.write("jsonrepair unavailable: " + String(e.message) + "\n");
  process.exit(1);
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
const out = [];

function decode(buf) {
  try {
    return { text: new TextDecoder("utf-8", { fatal: true }).decode(buf), how: "utf-8" };
  } catch {
    return { text: buf.toString("latin1"), how: "latin-1" };
  }
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  const row = JSON.parse(line);
  const { text, how } = decode(Buffer.from(row.b64, "base64"));

  let strict = true;
  let strictError = "";
  try {
    JSON.parse(text);
  } catch (e) {
    strict = false;
    strictError = String(e).slice(0, 120);
  }

  let ok = true;
  let valid = false;
  let value = null;
  let error = "";
  try {
    const repaired = jsonrepair(text);
    try {
      value = JSON.parse(repaired);
      valid = true;
      // The value travels back as text: a value that cannot be serialised would
      // otherwise take down the whole batch.
      try {
        JSON.stringify(value);
      } catch (e) {
        value = null;
        error = "value is not serialisable: " + String(e).slice(0, 120);
      }
    } catch (e) {
      error = "repaired text is not JSON: " + String(e).slice(0, 120);
    }
  } catch (e) {
    ok = false;
    value = null;
    error = String(e).slice(0, 120);
  }
  out.push(JSON.stringify({ id: row.id, decoding: how, strict, strictError, ok, valid, value, error }));
});

rl.on("close", () => {
  process.stdout.write(out.join("\n") + "\n");
});
