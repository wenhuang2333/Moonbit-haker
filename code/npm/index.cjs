"use strict";

// Node entry point. The MoonBit engine is compiled to a plain JavaScript
// script that registers its entry points through three host hooks. This module
// installs the hooks, loads the script once, and exports the captured
// functions. The global namespace is restored afterwards, so importing
// `interjson` does not leave `interjsonRegister*` or a `interjson` object behind.

const path = require("node:path");

const HOOKS = ["interjsonRegister1", "interjsonRegister2", "interjsonRegister3"];

function loadEngine() {
  const registered = Object.create(null);
  const previous = Object.create(null);
  for (const hook of HOOKS) {
    previous[hook] = globalThis[hook];
    globalThis[hook] = (name, fn) => {
      registered[name] = fn;
    };
  }
  try {
    require(path.join(__dirname, "vendor", "interjson.js"));
  } finally {
    for (const hook of HOOKS) {
      if (previous[hook] === undefined) {
        delete globalThis[hook];
      } else {
        globalThis[hook] = previous[hook];
      }
    }
  }
  return registered;
}

const engine = loadEngine();

function requireString(name, value) {
  if (typeof value !== "string") {
    throw new TypeError(`interjson.${name}: input must be a string`);
  }
}

function profileOf(options) {
  const profile = options && options.profile ? String(options.profile) : "";
  if (profile && !["permissive", "interactive", "execution", "agent", "strict"].includes(profile)) {
    throw new TypeError(`interjson: unknown profile "${profile}"`);
  }
  return profile;
}

/**
 * A structured refusal from the engine.
 *
 * The engine's string channel reports a failure as `ERROR: E010 ...`, and the
 * package used to detect that with a prefix test and throw a bare `Error`
 * whose message was the rest of the line. A caller that wanted the code, or
 * the position, had to parse the message back out of an exception. This class
 * keeps them as fields, and it still subclasses `Error`, so `catch (e) { e.message }`
 * keeps working.
 */
class InterJSONError extends Error {
  constructor(message) {
    super(message);
    this.name = "InterJSONError";
    const match = /^(E\d{3})\b\s*(.*)$/.exec(message);
    this.code = match ? match[1] : "";
    this.detail = match ? match[2] : message;
  }
}

function unwrap(text) {
  if (text.startsWith("ERROR: ")) {
    throw new InterJSONError(text.slice("ERROR: ".length));
  }
  return text;
}

/**
 * Repair `input` and return the repaired text.
 *
 * With `options.profile` set, the safety profile decides what may be repaired:
 * `agent` and `execution` refuse a lossy or ambiguous repair instead of
 * guessing, and throw.
 */
function repair(input, options = {}) {
  requireString("repair", input);
  const profile = profileOf(options);
  return unwrap(profile ? engine.repair_opts(input, profile) : engine.repair(input));
}

/**
 * The full decision plan. This is the call an agent integration should use
 * before executing tool arguments: it never throws on malformed JSON, and its
 * `executable` field is the gate.
 */
function analyze(input, options = {}) {
  requireString("analyze", input);
  const profile = profileOf(options);
  let plan;
  if (options.schemaJson !== undefined) {
    const json =
      typeof options.schemaJson === "string"
        ? options.schemaJson
        : JSON.stringify(options.schemaJson);
    plan = JSON.parse(engine.analyze_json_schema(input, profile, json));
  } else {
    plan = JSON.parse(engine.analyze(input, profile, options.schema || ""));
  }
  if (plan.decision === undefined) {
    throw new Error(plan.error || "interjson.analyze: could not build a plan");
  }
  return plan;
}

/**
 * Repair plus the decision fields, as one object.
 */
function repairResult(input, options = {}) {
  const plan = analyze(input, options);
  return {
    text: plan.text,
    exactness: plan.exactness,
    ambiguous: plan.ambiguous,
    repairs: plan.repairs,
    decision: plan.decision,
    executable: plan.executable,
    error: plan.error,
    retry: plan.retry,
  };
}

/** One `R005 3:14 message` line per repair, or `-`. */
function report(input) {
  requireString("report", input);
  return engine.report(input);
}

/**
 * The partial value of the first `upto` code units.
 *
 * The engine's own snapshot is a `value | completeness | open path` string,
 * which is what the browser demo draws. A programmatic caller wants the
 * three fields separately, so they are returned as an object: the string
 * form is still available through `snapshotText`.
 */
function snapshot(input, upto) {
  const parts = snapshotText(input, upto).split(" | ");
  return {
    value: parts.length > 0 && parts[0] !== "-" ? JSON.parse(parts[0]) : null,
    completeness: parts.length > 1 ? parts[1] : "",
    openPath: parts.length > 2 ? parts[2] : "",
  };
}

/** The partial value of the first `upto` code units, as `value | state | path`. */
function snapshotText(input, upto) {
  requireString("snapshot", input);
  return engine.snapshot(input, upto | 0);
}

/** One frame of the streaming view, as an object. */
function live(input, upto, schema = "") {
  requireString("live", input);
  return JSON.parse(engine.live(input, upto | 0, schema));
}

/**
 * The readiness curve for `input` against a skeleton declaration: the three
 * document-level numbers, every field-ready event, and the verdict.
 */
function readiness(input, schema = "") {
  requireString("readiness", input);
  return JSON.parse(engine.readiness(input, schema));
}

/**
 * The delta stream for the first `upto` code units: the protocol a consumer
 * subscribes to instead of re-reading the document on every frame.
 */
function deltas(input, upto) {
  requireString("deltas", input);
  return JSON.parse(engine.deltas(input, upto | 0));
}

/**
 * The gate, with the profile the MCP tools use.
 *
 * `analyze` with no profile used to run the *permissive* profile -- the
 * library's default -- while the MCP gate, which is the product, runs the
 * `agent` profile. A caller who read the MCP documentation and then called
 * the npm package got a different answer from the same input. The npm package
 * is the same product, so it defaults to the same profile; `permissive` is
 * one explicit argument away.
 */
function gate(input, options = {}) {
  return analyze(input, { profile: "agent", ...options });
}

module.exports = {
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
  // The engine version is the package version: one declaration, one source.
  // A literal here went stale once already (it said 1.1.0 while the
  // package was 1.1.1), and nothing noticed, because the test pinned the
  // same stale literal.
  version: require("./package.json").version,
};
