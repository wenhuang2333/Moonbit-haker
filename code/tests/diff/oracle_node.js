// Oracle wrapper around the TypeScript `jsonrepair` package.
//
//   NODE_PATH=/private/tmp/node_modules node oracle_node.js < input.json
//
// Prints the repaired text on success (exit 0) or a one line error on stderr
// (exit 1). Install with `npm install jsonrepair` in a scratch directory and
// point NODE_PATH at its parent.

const { jsonrepair } = require("jsonrepair");

let data = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  data += chunk;
});
process.stdin.on("end", () => {
  try {
    const text = jsonrepair(data);
    process.stdout.write(text);
  } catch (err) {
    process.stderr.write(String(err && err.message ? err.message : err));
    process.exit(1);
  }
});
