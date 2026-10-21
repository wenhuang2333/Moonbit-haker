"use strict";

// Node entry point. The MoonBit engine is compiled to a plain JavaScript
// script that registers its entry points through three host hooks. This module
// installs the hooks, loads the script once, and exports the captured
// functions. The global namespace is restored afterwards, so importing
// `jsonmend` does not leave `jsonmendRegister*` or a `jsonmend` object behind.

const path = require("node:path");

const HOOKS = ["jsonmendRegister1", "jsonmendRegister2", "jsonmendRegister3"];

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
    require(path.join(__dirname, "vendor", "jsonmend.js"));
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
    throw new TypeError(`jsonmend.${name}: input must be a string`);
  }
}

function profileOf(options) {
  const profile = options && options.profile ? String(options.profile) : "";
  if (profile && !["permissive", "interactive", "execution", "agent", "strict"].includes(profile)) {
    throw new TypeError(`jsonmend: unknown profile "${profile}"`);
  }
  return profile;
}

function unwrap(text) {
  if (text.startsWith("ERROR: ")) {
    throw new Error(text.slice("ERROR: ".length));
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
    throw new Error(plan.error || "jsonmend.analyze: could not build a plan");
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

/** The partial value of the first `upto` code units, as `value | state | path`. */
function snapshot(input, upto) {
  requireString("snapshot", input);
  return engine.snapshot(input, upto | 0);
}

/** One frame of the streaming view, as an object. */
function live(input, upto, schema = "") {
  requireString("live", input);
  return JSON.parse(engine.live(input, upto | 0, schema));
}

module.exports = {
  repair,
  repairResult,
  analyze,
  report,
  snapshot,
  live,
  // The engine version is the package version: one declaration, one source.
  // A literal here went stale once already (it said 1.1.0 while the
  // package was 1.1.1), and nothing noticed, because the test pinned the
  // same stale literal.
  version: require("./package.json").version,
};
