// Oracle driver: repair each input with the `jsonrepair` npm package and print
// one JSON object per line on stdout.
//
//   node code/tests/eval/oracle_node.mjs < corpus.jsonl > out.jsonl
//
// Input lines are `{"id", "input"}`; output lines are
// `{"id", "ok", "valid", "value", "error"}`. `valid` means the repaired text
// could be parsed by `JSON.parse`, which is what a caller would do next.

import { createInterface } from "node:readline";
import { jsonrepair } from "jsonrepair";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
const out = [];

rl.on("line", (line) => {
  if (!line.trim()) return;
  const row = JSON.parse(line);
  let ok = true;
  let valid = false;
  let value = null;
  let error = "";
  try {
    const text = jsonrepair(row.input);
    try {
      value = JSON.parse(text);
      valid = true;
    } catch (e) {
      error = "repaired text is not JSON: " + String(e).slice(0, 120);
    }
  } catch (e) {
    ok = false;
    error = String(e).slice(0, 120);
  }
  out.push(JSON.stringify({ id: row.id, ok, valid, value, error }));
});

rl.on("close", () => {
  process.stdout.write(out.join("\n") + "\n");
});
