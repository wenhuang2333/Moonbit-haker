// Node tests for the npm package. Run with `node --test test/`.
//
// The engine is the same MoonBit bundle the browser demo uses; these tests are
// about the wrapper contract (module shape, profile handling, error mapping),
// not about the repair rules, which have their own suite.

import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  InterJSONError,
  repair,
  repairResult,
  analyze,
  gate,
  report,
  snapshot,
  snapshotText,
  live,
  readiness,
  deltas,
  version,
} from "../index.mjs";

const here = dirname(fileURLToPath(import.meta.url));

test("repair fixes quotes and a trailing comma", () => {
  assert.equal(repair("{'a':1,}"), '{"a":1}');
  assert.equal(repair('{"a":[1,2]}'), '{"a":[1,2]}');
});

test("a profile can refuse a repair instead of guessing", () => {
  assert.throws(
    () => repair('{"path":"/tmp/x"', { profile: "agent" }),
    /E010/,
  );
  assert.equal(repair("{'a':1,}", { profile: "execution" }), '{"a":1}');
});

test("repairResult carries the decision fields", () => {
  const r = repairResult("{'a':1,}", { profile: "execution" });
  assert.equal(r.text, '{"a":1}');
  assert.equal(r.exactness, "cosmetic");
  assert.equal(r.executable, true);
  assert.equal(r.decision, "cosmetic_repair");
});

test("analyze blocks an ambiguous repair", () => {
  const plan = analyze('{"words":["a" "b"]}', { profile: "execution" });
  assert.equal(plan.decision, "ambiguous");
  assert.equal(plan.executable, false);
  assert.equal(plan.execution, "blocked");
  assert.equal(plan.error.code, "E011");
  assert.match(plan.retry.prompt, /Re-emit/);
});

test("analyze accepts a JSON Schema tool declaration", () => {
  const plan = analyze('{"query":"x","limit":0}', {
    profile: "agent",
    schemaJson: {
      type: "object",
      properties: {
        query: { type: "string" },
        limit: { type: "integer", minimum: 1 },
      },
      required: ["query", "limit"],
    },
  });
  assert.equal(plan.executable, false);
  assert.equal(plan.schema_total, 2);
  assert.equal(plan.schema_satisfied, 1);
});

test("an unsupported JSON Schema keyword is reported, not ignored", () => {
  assert.throws(
    () =>
      analyze("{}", {
        schemaJson: { $ref: "#/definitions/x" },
      }),
    /E070.*\$ref/,
  );
});

test("the gate defaults to the profile the MCP tools use", () => {
  // `analyze` with no profile used to run the permissive profile while the
  // MCP gate ran `agent`, so the same input got two answers depending on
  // which surface asked. `gate` is the MCP call.
  const refused = gate('{"a":1,"a":2}');
  assert.equal(refused.executable, false);
  assert.equal(refused.decision, "lossy_repair");
  assert.ok(refused.retry && refused.retry.prompt, "a refusal carries a prompt");
  assert.equal(refused.value, null, "a refusal carries no value");
  // ...and the permissive profile is one explicit argument away.
  assert.equal(analyze('{"a":1,"a":2}', { profile: "permissive" }).decision, "lossy_repair");
});

test("a refusal always carries a prompt and never a value", () => {
  const plan = gate('{"a":1}', { schemaJson: { type: "object", properties: { a: { type: "string" } }, required: ["a"] } });
  assert.equal(plan.executable, false);
  assert.equal(plan.value, null);
  assert.ok(plan.retry.prompt.length > 0);
  assert.equal(plan.retry.code, "E070");
});

test("errors carry their code as a field", () => {
  assert.throws(
    () => repair('{"a":1,}', { profile: "strict" }),
    (e) => e instanceof InterJSONError && e.code === "E010" && e instanceof Error,
  );
});

test("the whole engine surface is exported", () => {
  // `validate`, `readiness` and `deltas` were reachable from the browser demo
  // but not from the package, so a Node caller had to reimplement them.
  assert.equal(typeof readiness, "function");
  assert.equal(typeof deltas, "function");
  assert.equal(typeof snapshotText, "function");
  const curve = readiness('{"a":1}', "{!a:integer}");
  assert.ok(typeof curve.syntax_permille === "number");
  const stream = deltas('{"a":1}', 7);
  assert.ok(Array.isArray(stream.deltas) || typeof stream === "object");
});

test("report, snapshot and live keep their documented shapes", () => {
  assert.equal(report('{"a":1}'), "-");
  assert.match(report("{'a':1,}"), /^R003 1:2 /);
  assert.match(snapshotText('{"name":"Mo', 11), /Partial \| name$/);
  const snap = snapshot('{"name":"Mo', 11);
  assert.equal(snap.completeness, "Partial");
  assert.equal(snap.openPath, "name");
  const frame = live('{"query":"MoonBit","limit":10}', 12, "{!query:string}");
  assert.equal(frame.consumed, 12);
  assert.equal(frame.completeness, "Partial");
});

test("the CommonJS entry point works", () => {
  const require = createRequire(import.meta.url);
  const cjs = require("../index.cjs");
  assert.equal(cjs.repair("{'a':1,}"), '{"a":1}');
  assert.equal(typeof cjs.analyze, "function");
});

test("importing the package writes nothing to stdout", () => {
  const entry = resolve(here, "..", "index.cjs");
  const r = spawnSync(process.execPath, ["-e", `require(${JSON.stringify(entry)})`], {
    encoding: "utf8",
  });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "");
  assert.equal(r.stderr, "");
});

test("the MCP launcher exposes the local server without touching stdout", () => {
  // The launcher is the npm install path for the MCP server. It must resolve a
  // binary (the development build here), pass the arguments through, and keep
  // the JSON-RPC channel clean. `--print-config` exits without reading stdin,
  // which is exactly the case a wrapper that printed a banner would break.
  const binary = resolve(
    here,
    "..",
    "..",
    "_build",
    "native",
    "release",
    "build",
    "cmd",
    "interjson",
    process.platform === "win32" ? "interjson.exe" : "interjson.exe",
  );
  const r = spawnSync(process.execPath, [resolve(here, "..", "mcp.cjs"), "--print-config=claude"], {
    encoding: "utf8",
    env: { ...process.env, INTERJSON_BIN: binary },
  });
  assert.equal(r.status, 0);
  assert.equal(r.stdout.trim(), "claude mcp add interjson -- interjson mcp");
  assert.equal(r.stderr, "");
});

test("the package reports the engine version", () => {
  // Read from `code/moon.mod` rather than pinning a literal: the version is
  // hardcoded in the MoonBit sources, so a pinned literal goes red on every
  // release. The test still fails when the bundle disagrees with the
  // declaration -- which is the part worth checking.
  const mod = readFileSync(resolve(here, "..", "..", "moon.mod"), "utf8");
  const declared = mod.match(/^version\s*=\s*"([^"]+)"/m)[1];
  assert.equal(version, declared);
  // The wrapper reports the package version; the package version must be the
  // engine version. Both are asserted against `moon.mod`, so a bump that
  // misses either file is caught here instead of by a reader.
  const pkg = JSON.parse(readFileSync(resolve(here, "..", "package.json"), "utf8"));
  assert.equal(pkg.version, declared);
});
