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

import { createInterface } from "node:readline";
import { jsonrepair } from "jsonrepair";

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
