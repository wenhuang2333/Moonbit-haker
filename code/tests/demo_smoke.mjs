// Smoke test for the built browser demo bundle (P1-1 CI guard).
//
//   node code/tests/demo_smoke.mjs [path/to/jsonmend.js]
//
// The bundle is a plain script that calls the host hooks on `globalThis`, so
// it can be evaluated in Node exactly as the demo page does. This catches a
// stale bundle (source changed, `static/demo/jsonmend.js` not rebuilt) and a
// broken JS backend build.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bundle =
  process.argv[2] || resolve(here, "..", "..", "static", "demo", "jsonmend.js");

const registered = {};
globalThis.jsonmendRegister1 = (name, fn) => {
  registered[name] = fn;
};
globalThis.jsonmendRegister2 = (name, fn) => {
  registered[name] = fn;
};
globalThis.jsonmendRegister3 = (name, fn) => {
  registered[name] = fn;
};
globalThis.print = () => {};

let failures = 0;
const check = (label, got, want) => {
  if (got === want) {
    console.log(`ok   ${label}`);
  } else {
    failures += 1;
    console.log(`FAIL ${label}\n     want: ${JSON.stringify(want)}\n     got:  ${JSON.stringify(got)}`);
  }
};

new Function(readFileSync(bundle, "utf8"))();

check("bundle registers four entry points", Object.keys(registered).sort().join(","), "live,repair,report,snapshot");

check("repair fixes quotes and a trailing comma", registered.repair("{'a':1,}"), '{"a":1}');
check("repair leaves valid JSON alone", registered.repair('{"a":[1,2]}'), '{"a":[1,2]}');
check("repair closes a truncated container", registered.repair('{"a":{"b":[1,2'), '{"a":{"b":[1,2]}}');
check("repair strips a fence and comments", registered.repair('```json\n{"a": 1, // c\n}\n```'), '{"a":1}');

const report = registered.report("{'a':1,}");
check("report lists one line per repair", report.split("\n").length, 2);
check("report names the first rule", report.startsWith("R003 1:2 "), true);
check("report is empty for valid JSON", registered.report('{"a":1}'), "-");

check("snapshot of a prefix is partial", registered.snapshot('{"name":"Mo', 11).split(" | ")[1], "Partial");
check("snapshot of a closed document is complete", registered.snapshot('{"name":"MoonBit"}', 18).split(" | ")[1], "Complete");
check("snapshot reports the open path", registered.snapshot('{"name":"Mo', 11).split(" | ")[2], "name");

// The live view drives the streaming page: one JSON object per frame.
const live = registered.live('{"query":"MoonBit","limit":10}', 12, "{!query:string,!limit:integer}");
const frame = JSON.parse(live);
check("live frame reports how much was consumed", frame.consumed, 12);
check("live frame reports the whole stream", frame.total, 30);
check("live frame is partial mid-stream", frame.completeness, "Partial");
check("live frame lists the members seen so far", frame.members.map((m) => m.key).join(","), "query");
// Mid-stream the value is not executable: closing it would have to invent the
// rest of the string, and the gate says so instead of hiding it.
check("live frame refuses an unfinished value", frame.schema.decision, "lossy_repair");
check("live frame explains the refusal", frame.schema.retry.code, "E010");
check("live frame names the open path", frame.open_path, "query");
const done = JSON.parse(registered.live('{"query":"MoonBit","limit":10}', 30, "{!query:string,!limit:integer}"));
check("live frame is complete at the end", done.completeness, "Complete");
check("live frame reports every member ready", done.ready + "/" + done.seen, "2/2");
check("live frame says the finished value is executable", done.schema.executable, true);
check("live frame reports the finished value as safe", done.schema.decision, "safe");
check("live frame checks the skeleton", done.schema.schema_satisfied + "/" + done.schema.schema_total, "2/2");
const refused = JSON.parse(registered.live('{"words":["a" "b"]}', 19, "{!words:[string]}"));
check("live frame carries the gate decision for a refusal", refused.schema.decision, "ambiguous");
check("live frame carries a retry prompt for a refusal", refused.schema.retry.code, "E011");

if (failures > 0) {
  console.log(`\n${failures} demo check(s) failed`);
  process.exit(1);
}
console.log("\ndemo bundle smoke test passed");
