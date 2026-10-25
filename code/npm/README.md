# jsonmend-moonbit (npm)

The MoonBit JSON engine, packaged for Node and the browser: streaming repair,
partial parsing, and the **execution gate** for LLM tool calls.

```bash
npm install ./code/npm   # from the repository root
```

> The npm name `jsonmend` is already taken by an unrelated package. This
> package is `jsonmend-moonbit`; it is installed from the repository until a
> registry publication under that name.

```js
import { analyze, repair } from "jsonmend-moonbit";

// The gate: decide before executing tool arguments.
const plan = analyze(modelOutput, {
  profile: "agent",
  schemaJson: tool.inputSchema, // the declaration you already have
});
if (!plan.executable) {
  throw new Error(plan.retry); // or re-emit `plan.retry` to the model
}

// The convenience: repair and return text.
const text = repair(modelOutput, { profile: "execution" });
```

## Exports

| Export | Returns | Use |
| --- | --- | --- |
| `repair(input, options?)` | repaired text | a document you will parse yourself |
| `repairResult(input, options?)` | `{text, exactness, ambiguous, repairs, decision, executable}` | text plus the decision |
| `analyze(input, options?)` | the full `RepairPlan` | **the gate**; never throws on malformed JSON |
| `report(input)` | `R005 3:14 message` lines, or `-` | diagnostics |
| `snapshot(input, upto)` | `value \| state \| path` | partial parse of a prefix |
| `live(input, upto, schema?)` | one streaming frame object | a UI that renders a model stream |

`options.profile` is one of `permissive`, `interactive`, `execution`, `agent`,
`strict`. `execution` and `agent` refuse a lossy or ambiguous repair instead of
inventing content; `repair` then throws, and `analyze` returns
`executable: false` with `error.code` and `retry`.

`options.schema` is the library's declaration language
(`{!query:string,!limit:integer}`). `options.schemaJson` is a JSON Schema
subset — `type`, `properties`, `required`, `items`, `enum`, `const`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `minLength`,
`maxLength`, `pattern` — so a tool's existing `inputSchema` can be passed
directly. Unsupported keywords raise `E070` rather than being silently
dropped.

## Streaming

`live` is the same frame the [demo page](https://wenhuang2333.github.io/Moonbit-haker/live.html)
draws: `consumed`, `total`, `completeness`, `snapshot`, `open_path`, `members`,
and (with a schema) `syntax_ready`, `schema_ready`, `settled_ready`,
`execution_ready`. It is stateless, so a caller can re-render on every frame;
for a token-by-token feed use the CLI protocol (`jsonmend serve`) or
the MoonBit `PartialParser`.

## Scope

This package wraps the same bundle as `static/demo/jsonmend.js`; it does not
reimplement the engine. The version is the engine version (`1.2.0`). The
MoonBit package on mooncakes is `0.8.0` because the registry currently accepts
only `0.x.y`; the bytes are the same.

License: Apache-2.0.
