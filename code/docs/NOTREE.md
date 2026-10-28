# The no-tree mode: what it is for, what it costs, and why it is not here yet

> **Status: designed, not implemented.** This file exists so that the next
> person to work on it starts from measurements and a plan rather than from a
> sentence in a review saying "no-tree mode is not implemented". Nothing in
> this document is a claim about the current build.

## The problem, measured

InterJSON's `repair` builds the parsed value as it goes. That value is a
`Json` tree: every scalar is a boxed `Json` enum, every object is a
`Map[String, Json]`, every array is an `Array[Json]`. The cost is not
proportional to the input, it is proportional to the *number of values*, and a
value can be one byte long.

Measured with `code/tests/memory_gate.py` (marginal peak RSS over the process
baseline, for a 200 000-element document):

| shape | input | marginal | ratio |
| --- | --- | --- | --- |
| `[0,1,2,…]` | 1.23 MiB | 6.4 MiB | 5.2× |
| `[0.5,1.5,…]` | 1.61 MiB | 12.3 MiB | 7.7× |
| `["xy","xy",…]` | 0.95 MiB | 6.2 MiB | 6.5× |
| `[{"a":1},…]` | 1.53 MiB | 36.8 MiB | 24.1× |
| `[[1],[1],…]` | 0.76 MiB | 18.4 MiB | 24.2× |
| `[[[1]],…]` | 1.14 MiB | 30.7 MiB | 26.8× |
| `[{},{},…]` | 0.57 MiB | 15.0 MiB | 26.2× |

Scalars are inside the 4× budget the project declares. Containers are not, and
**they cannot be while the value is built**:

* `{}` is `Json::Object(Map([]))`. An empty `Map` is one allocation and a
  hash-table header, and the value keeps it for as long as the caller holds the
  value. There is no smaller `Json::Object`.
* `[1]` is `Json::Array(Array[Json])` holding one boxed `Json::Number`. Three
  allocations for three bytes of input.

The container ratios are therefore a property of core's `Json` type, not of
this parser. No amount of care inside the engine removes them.

## What a no-tree mode is

A mode in which the engine never materialises a `Json` value. Each frame keeps
a text buffer; a value is serialised into its parent's buffer as soon as it
completes; the root buffer is the answer. Peak memory becomes the output text
plus the open path, which is 1–2× the input rather than 24×.

`Options::for_text()` already reads as if it were this mode, and is not: it
turns off the repair log and the indentation but still builds the tree, because
the tree is what `render` walks.

## The four places the value is load-bearing

These are the whole difficulty. Everything else is mechanical.

1. **Duplicate keys (`R018`).** `Engine::assign` compares the value already
   stored under a key with the incoming one (`json_equal`) to decide whether
   the merge lost information, and under `KeepLast` it replaces the stored
   value. In text mode the "stored value" is text that has already been written
   into the enclosing object's buffer, and the output must keep the key in its
   *first* position with the *last* value:
   `{"a":1,"b":2,"a":3}` → `{"a":3,"b":2}`.
   *Plan:* each object frame keeps a small index of `key → [start, end)` into
   its own buffer, plus a **comparison key** per member. A duplicate rewrites
   the recorded range in place — the new member is the last thing written, so
   the range ends at the buffer's end — and the index keeps the member's
   original position, which is the order the tree produces today.

   The comparison key is the part that is easy to get subtly wrong. `json_equal`
   is a *structural* comparison: `{"x":1,"y":2}` and `{"y":2,"x":1}` are the
   same object, and so are `[1,2]` and `[1,2]`. Comparing the rendered text
   instead would call both pairs different and report the merge as a loss
   (`Warning`) where the tree reports `Info` — a divergence in the *severity* of
   a repair, which is exactly the kind of thing that would pass a golden corpus
   and fail a user. The comparison key therefore has to be canonical: the exact
   decimal key for numbers (`1` equals `1.0`, `9007199254740993` does not equal
   `9007199254740992`), the text for scalars, and for containers a canonical
   rendering — object members sorted by key, arrays in order. That is a second
   serialisation, computed only for members that could collide, and it is the
   main piece of real work in the change.
2. **`+` concatenation (`R019`).** `Engine::concat_last` appends to the
   previously delivered value. In text mode that is the tail of the buffer:
   truncate back by the length of the last rendered value and re-append the
   merged string. Each frame already needs the last member's range for (1), so
   this is the same bookkeeping.
3. **`fill_null` on a dangling key.** Appends `null` for the key in flight.
   Forward-only; no new state.
4. **The render itself.** `render` walks the value. In text mode there is
   nothing to walk: the text is already the answer. This removes the second
   copy of the document that `repair` currently holds (tree + output).

Everything else — `CloseContainer`, `CloseString`, `RemoveExtraComma`,
`InsertComma`, `DropUnexpected`, `StripFence`, `SkipProse`, `DropEllipsis`,
`FixNumber`, `EscapeControl`, `FixEscape`, `MismatchedCloser`,
`DropExtraCloser`, `NormalizeQuote`, `QuoteBareWord`, `InsertColon`,
`NormalizeLiteral`, `ConvertLiteral` — is forward-only and unaffected.

## What it does not do

* **It cannot produce a value.** `analyze`, `serve`'s `analyze` method and
  anything that evaluates a schema need the value; those paths keep the tree.
  The mode belongs to `repair` and to `Options::for_text()`.
* **Snapshots and deltas need the value** and are therefore unavailable in the
  mode. `Options::validate` must refuse the combination rather than ignore it.
* **It does not make the engine faster**, only smaller. The parsing work is the
  same; the mode trades the tree for a string builder.

## The guard that makes it safe to attempt

A second output path is exactly the kind of change this project warns itself
about: two implementations of one behaviour drift. The guard is differential
and it already exists in spirit — `tests/diff/run_diff.py` compares the engine
against other implementations, and the golden suite compares it against
recorded output.

The new mode must satisfy, over **every** corpus in the repository (golden,
property, stream, differential, the evaluation corpora, the conformance
cases):

```
repair(text, options={..opts, build_value: false}).text
  == repair(text, options=opts).text      # byte for byte
```

That comparison is the acceptance criterion. A mode that agrees on the golden
corpus and disagrees on a truncated document is worse than no mode, because it
would ship two answers to the same question.

## Suggested order

1. Add `Options::build_value` (default `true`), `for_text()` sets it false,
   `validate()` refuses it together with `collect_deltas`, `want_text: false`
   and a snapshot-using entry point.
2. Add `Frame.text : StringBuilder?` and `Frame.members : Array[Member]?` where
   `Member` is `{key, start, end, comparison_key}`; allocate them only when
   `build_value` is false.
3. Teach `value_done` to append to the enclosing buffer instead of pushing a
   value, and `close_container` / `unwind_top` to wrap and hand the text up.
4. Teach `assign` and `concat_last` the text-mode branches described above.
5. Make `finish_engine` return the root buffer as `text` and refuse to be asked
   for a value.
6. Write the differential test first, run it over every corpus, and only then
   wire the mode into `Options::for_text()` and the CLI.
7. Add a `text_only` arm to `code/tests/memory_gate.py` with a 4× ceiling, and
   move the `repair` ratios in the table above into a "with value" section.

## Why it is not done yet

It is a second output path through the core of the parser — the same code that
carries the four invariants (valid output, idempotent repair, chunk
invariance, stable-prefix snapshots) and 249 tests across four backends. Doing
it in the same change as the depth and allocation work would have put two large
risks in one commit with one review. It is written up here, with the
measurements it has to beat, so that it can be done on its own and verified by
the differential guard above.
