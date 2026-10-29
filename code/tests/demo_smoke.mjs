// Smoke test for the built browser demo bundle (P1-1 CI guard).
//
//   node code/tests/demo_smoke.mjs [path/to/interjson.js]
//
// The bundle is a plain script that calls the host hooks on `globalThis`, so
// it can be evaluated in Node exactly as the demo page does. This catches a
// stale bundle (source changed, `static/demo/interjson.js` not rebuilt) and a
// broken JS backend build.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bundle =
  process.argv[2] || resolve(here, "..", "..", "static", "demo", "interjson.js");

const registered = {};
globalThis.interjsonRegister1 = (name, fn) => {
  registered[name] = fn;
};
globalThis.interjsonRegister2 = (name, fn) => {
  registered[name] = fn;
};
globalThis.interjsonRegister3 = (name, fn) => {
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

check(
  "bundle registers the demo and library entry points",
  [
    "live",
    "repair",
    "report",
    "snapshot",
    "repair_opts",
    "analyze",
    "analyze_json_schema",
    "analyze_prose",
    "analyze_json_schema_prose",
    "readiness",
    "deltas",
  ].every((name) => typeof registered[name] === "function"),
  true,
);

check("repair fixes quotes and a trailing comma", registered.repair("{'a':1,}"), '{"a":1}');
check("repair leaves valid JSON alone", registered.repair('{"a":[1,2]}'), '{"a":[1,2]}');
check("repair closes a truncated container", registered.repair('{"a":{"b":[1,2'), '{"a":{"b":[1,2]}}');
check("repair strips a fence and comments", registered.repair('```json\n{"a": 1, // c\n}\n```'), '{"a":1}');
check("repair_opts applies a profile", registered.repair_opts("{'a':1,}", "execution"), '{"a":1}');
check(
  "analyze returns the decision plan",
  JSON.parse(registered.analyze('{"a":1,}', "execution", "")).decision,
  "cosmetic_repair",
);
check(
  "analyze_json_schema reads a tool declaration",
  JSON.parse(
    registered.analyze_json_schema(
      '{"query":"x","limit":2}',
      "agent",
      JSON.stringify({
        type: "object",
        properties: { query: { type: "string" }, limit: { type: "integer", minimum: 1 } },
        required: ["query", "limit"],
      }),
    ),
  ).schema_satisfied,
  2,
);
check(
  "analyze_json_schema refuses an unsupported keyword",
  JSON.parse(registered.analyze_json_schema("{}", "agent", JSON.stringify({ $ref: "#/x" }))).error.includes("E070"),
  true,
);
check(
  "analyze refuses a malformed declaration instead of ignoring it",
  JSON.parse(registered.analyze('{"a":1}', "agent", "{!query:string")).error.includes("E070"),
  true,
);
check(
  "analyze_prose refuses a malformed declaration",
  JSON.parse(registered.analyze_prose('{"a":1}', "agent", "{!query:string")).error.includes("E070"),
  true,
);
check(
  "live refuses a malformed declaration",
  JSON.parse(registered.live('{"a":1}', 7, "{!query:string")).error.includes("E070"),
  true,
);
check(
  "an empty declaration still means no skeleton",
  JSON.parse(registered.analyze('{"a":1}', "agent", "")).schema_total,
  0,
);

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

// The workbench's skip-prose switch: the same analysis with `skip_prose` on.
const prose = JSON.parse(
  registered.analyze_prose("Sure! Here is the JSON you asked for:\n{\"a\":1}", "permissive", ""),
);
check("analyze_prose accepts a prose prelude", prose.decision, "cosmetic_repair");
check("analyze_prose records the prelude", prose.repairs[0].rule, "R021");
check(
  "analyze_prose leaves the default profile alone",
  JSON.parse(registered.analyze("Sure! Here is the JSON you asked for:\n{\"a\":1}", "permissive", "")).error.code,
  "E002",
);
check(
  "analyze_json_schema_prose reads a tool declaration through prose",
  JSON.parse(
    registered.analyze_json_schema_prose(
      "Here you go:\n{\"query\":\"x\"}",
      "agent",
      JSON.stringify({ type: "object", properties: { query: { type: "string" } }, required: ["query"] }),
    ),
  ).schema_satisfied,
  1,
);

// The readiness curve: three document numbers plus the event stream.
const readiness = JSON.parse(
  registered.readiness(
    JSON.stringify({ query: "MoonBit", limit: 10, note: "x".repeat(60) }),
    "{!query:string,!limit:integer}",
  ),
);
check("readiness reports the syntax fraction", readiness.syntax_permille, 990);
check("readiness reports the settled fraction", readiness.settled_permille, 300);
check("readiness reports the schema fraction", readiness.schema_permille, 300);
check("readiness reports the verdict", readiness.verdict.ok, true);
check(
  "readiness lists the field events",
  readiness.events.map((e) => e.event.kind + ":" + e.event.path).join(","),
  "field_ready:query,field_ready:limit,root_ready:",
);
check("readiness lists the per-field positions", readiness.fields.length, 3);
const rejected = JSON.parse(
  registered.readiness('{"limit":-1,"tail":"' + "y".repeat(80) + '"}', "{!limit:integer(minimum:0)}"),
);
check("readiness publishes a value rejection", rejected.events[0].event.kind, "field_rejected");
check("readiness publishes the mismatch", rejected.verdict.mismatched[0].expected, "integer >= 0");
check("readiness refuses at the digit", rejected.settled_permille, 117);

// The delta stream: what a streaming consumer subscribes to.
const deltas = JSON.parse(registered.deltas('{"query":"Mo"}', 12));
check("deltas reports how much was consumed", deltas.consumed, 12);
check("deltas reports the whole stream", deltas.total, 14);
check(
  "deltas uses JSON Pointer paths",
  deltas.deltas.map((d) => d.op + d.pointer).join(" "),
  "set set/query append_text/query",
);
check("deltas carries the appended text", deltas.deltas[2].text, "Mo");

// The depth budget: 1.5 made the value walks iterative, so the nesting depth
// is bounded by the heap rather than by the native stack, and the budget is
// the caller's to choose.
const deep = "[".repeat(1000) + "]".repeat(1000);
const deepRefused = JSON.parse(registered.analyze_depth(deep, 512));
check("depth budget refuses a document past the limit", deepRefused.executable, false);
check("depth refusal names E020", deepRefused.error.code, "E020");
check("depth refusal reports the budget", deepRefused.max_depth, 512);
const allowed = JSON.parse(registered.analyze_depth(deep, 1000));
check("depth budget accepts the same document when raised", allowed.executable, true);
check("depth acceptance reports the budget", allowed.max_depth, 1000);
check("depth acceptance is a safe decision", allowed.decision, "safe");

if (failures > 0) {
  console.log(`\n${failures} demo check(s) failed`);
  process.exit(1);
}
console.log("\ndemo bundle smoke test passed");
