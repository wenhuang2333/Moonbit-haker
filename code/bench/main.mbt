// Throughput, scaling and streaming overhead benchmarks (TC-B).
//
//   moon run bench --target native --release
//   moon run bench --target js --release
//
// Memory (TC-B-04) is measured from the outside with `/usr/bin/time -l`,
// see `tests/bench.sh`; the wasm-gc artifact size (TC-B-05) is measured by
// the same script.

///|
/// Minimum milliseconds spent per measurement round.
let min_round_ms : UInt64 = 100

///|
/// Run `f` repeatedly for at least `min_round_ms` and return the average
/// milliseconds of a single call.
fn round_ms(f : () -> Unit) -> Double {
  let t0 = @env.now()
  let mut n = 0
  while @env.now() - t0 < min_round_ms && n < 1000000 {
    f()
    n = n + 1
  }
  let elapsed = @env.now() - t0
  if n == 0 {
    0.0
  } else {
    elapsed.to_double() / n.to_double()
  }
}

///|
/// Median of five measurement rounds, each of at least `min_round_ms`.
fn median5(f : () -> Unit) -> Double {
  f()
  let times : Array[Double] = []
  for i = 0; i < 5; i = i + 1 {
    times.push(round_ms(f))
  }
  times.sort()
  times[2]
}

///|
/// Throughput in MB/s of `bytes` bytes in `ms` milliseconds.
fn mbps(bytes : Int32, ms : Double) -> Double {
  if ms <= 0.0 {
    0.0
  } else {
    bytes.to_double() / 1048576.0 / (ms / 1000.0)
  }
}

///|
/// One decimal place, for stable report tables.
fn round1(x : Double) -> String {
  let scaled = (x * 10.0 + 0.5).to_int()
  (scaled / 10).to_string() + "." + (scaled % 10).to_string()
}

///|
/// Valid JSON array of at least `target` code units.
fn make_valid(target : Int32) -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  let mut n = 0
  let mut i = 0
  while n < target {
    if i > 0 {
      sb.write_char(',')
    }
    let item = "{\"id\":" +
      i.to_string() +
      ",\"name\":\"item-" +
      i.to_string() +
      "\",\"ok\":true,\"tags\":[\"alpha\",\"beta\"]}"
    sb.write_string(item)
    n = n + item.length()
    i = i + 1
  }
  sb.write_char(']')
  sb.to_string()
}

///|
/// Same shape, but with single quotes, unquoted keys, comments, `NaN`, a
/// trailing comma and a truncated tail.
fn make_flawed(target : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("{ // generated corpus\n")
  let mut n = 0
  let mut i = 0
  while n < target {
    let item = "  'key" +
      i.to_string() +
      "': 'value " +
      i.to_string() +
      "',  // line " +
      i.to_string() +
      "\n"
    sb.write_string(item)
    n = n + item.length()
    i = i + 1
  }
  sb.write_string("  score: NaN,\n")
  sb.to_string()
}

///|
/// Two decimal places, for per operation costs that are far below a millisecond.
fn round2(x : Double) -> String {
  let scaled = (x * 100.0 + 0.5).to_int()
  (scaled / 100).to_string() +
  "." +
  (scaled % 100 / 10).to_string() +
  (scaled % 10).to_string()
}

///|
/// Deeply nested arrays.
fn make_deep(depth : Int32) -> String {
  let sb = StringBuilder()
  for i = 0; i < depth; i = i + 1 {
    sb.write_char('[')
  }
  for i = 0; i < depth; i = i + 1 {
    sb.write_char(']')
  }
  sb.to_string()
}

///|
/// One very long string token.
fn make_long_string(target : Int32) -> String {
  let sb = StringBuilder()
  sb.write_char('"')
  for i = 0; i < target; i = i + 1 {
    sb.write_char('x')
  }
  sb.write_char('"')
  sb.to_string()
}

///|
/// One-shot repair, errors swallowed.
fn run_repair(input : String) -> Unit {
  ignore(@mend.repair(input)) catch {
    _ => ()
  }
}

///|
/// Streaming parse with `chunk` code units per `feed`, optionally taking a
/// snapshot after every chunk.
fn run_stream(input : String, chunk : Int32, snap : Bool) -> Unit {
  try {
    let parser = @mend.PartialParser::new()
    let n = input.length()
    let mut i = 0
    while i < n {
      let to = if i + chunk < n { i + chunk } else { n }
      parser.feed(input[i:to].to_owned())
      if snap {
        ignore(parser.snapshot())
      }
      i = to
    }
    ignore(parser.finish())
  } catch {
    _ => ()
  }
}

///|
/// One-shot `parse` (tree only, no text rendering).
fn run_parse(input : String) -> Unit {
  ignore(@mend.parse(input)) catch {
    _ => ()
  }
}

///|
/// `repair` throughput on one corpus size.
fn bench_throughput(kind : String, input : String) -> Unit {
  let bytes = input.length()
  let ms = median5(() => run_repair(input))
  println(
    "throughput\t" +
    kind +
    "\t" +
    bytes.to_string() +
    "\t" +
    round1(ms) +
    " ms\t" +
    round1(mbps(bytes, ms)) +
    " MB/s",
  )
}

///|
/// TC-B-01: n, 2n, 4n must stay within 2.3x per doubling.
fn bench_linearity() -> Unit {
  let base = make_valid(1048576)
  let double = make_valid(2097152)
  let quad = make_valid(4194304)
  let t1 = median5(() => run_repair(base))
  let t2 = median5(() => run_repair(double))
  let t4 = median5(() => run_repair(quad))
  println("linearity\tn\t" + round1(t1) + " ms")
  println("linearity\t2n\t" + round1(t2) + " ms\tratio " + round1(t2 / t1))
  println("linearity\t4n\t" + round1(t4) + " ms\tratio " + round1(t4 / t2))
}

///|
/// TC-B-03: chunk size and snapshot frequency on a 1 MB input.
fn bench_streaming() -> Unit {
  let input = make_valid(1048576)
  for chunk in [1, 16, 1024, 65536] {
    let ms = median5(() => run_stream(input, chunk, false))
    println(
      "stream\tchunk " +
      chunk.to_string() +
      "\t" +
      round1(ms) +
      " ms\t" +
      round1(mbps(input.length(), ms)) +
      " MB/s",
    )
  }
  for chunk in [1024, 65536] {
    let ms = median5(() => run_stream(input, chunk, true))
    println(
      "stream\tsnapshot every " +
      chunk.to_string() +
      "\t" +
      round1(ms) +
      " ms\t" +
      round1(mbps(input.length(), ms)) +
      " MB/s",
    )
  }
}

///|
/// Streaming with delta tracking (I-2): the same chunking, but the parser
/// records the changes and the caller drains them after every chunk. Returns
/// the total number of deltas as well, so the cost can be attributed.
fn run_deltas(input : String, chunk : Int32) -> Int32 {
  let n = input.length()
  try {
    let parser = @mend.PartialParser::new(options={
      ..@mend.Options::default(),
      collect_deltas: true,
    })
    let mut total = 0
    let mut i = 0
    while i < n {
      let to = if i + chunk < n { i + chunk } else { n }
      parser.feed(input[i:to].to_owned())
      total = total + parser.drain_deltas().length()
      i = to
    }
    ignore(parser.finish())
    total
  } catch {
    _ => 0
  }
}

///|
/// I-2 acceptance: delta tracking must stay within 10% of the same chunking
/// without it, and the replay of the deltas must reproduce the final value.
fn bench_deltas() -> Unit {
  let input = make_valid(1048576)
  for chunk in [1024, 65536] {
    let base = median5(() => run_stream(input, chunk, false))
    let ms = median5(() => ignore(run_deltas(input, chunk)))
    let deltas = run_deltas(input, chunk)
    println(
      "deltas\tchunk " +
      chunk.to_string() +
      "\t" +
      round1(ms) +
      " ms\t" +
      round1(mbps(input.length(), ms)) +
      " MB/s\t" +
      round1(100.0 * ms / base) +
      "% of baseline\t" +
      deltas.to_string() +
      " deltas",
    )
  }
}

///|
/// P3-8: repeated snapshots with no new input in between. A snapshot is
/// O(current value size), so this only stays cheap when the result is reused.
fn bench_snap_repeat() -> Unit {
  let input = make_valid(1048576)
  let half = input.length() / 2
  let ms = median5(() => {
    try {
      let parser = @mend.PartialParser::new()
      parser.feed(input[:half].to_owned())
      for _i = 0; _i < 1000; _i = _i + 1 {
        ignore(parser.snapshot())
      }
    } catch {
      _ => ()
    }
  })
  println("snapshot	repeat 1000x without feeding\t" + round1(ms) + " ms")
}

///|
/// A tool-call shaped document: one object whose `arguments` member grows with
/// many small fields. This is the shape an LLM writes while streaming.
fn make_call(target : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"name\":\"submit_record\",\"arguments\":{")
  let mut n = 0
  let mut i = 0
  while n < target {
    if i > 0 {
      sb.write_string(",")
    }
    let field = "\"field" + i.to_string() + "\":\"value-" + i.to_string() + "\""
    sb.write_string(field)
    n = n + field.length()
    i = i + 1
  }
  sb.write_string("}}")
  sb.to_string()
}

///|
/// Time to first usable value (I-4).
///
/// `first` is the offset at which `snapshot()` first exposes a value, `ttfv` is
/// the offset at which that value already covers 95% of the final value's
/// rendered length, `label` is the exactness the snapshot carried at `first`.
/// All offsets are divided by the document length, so the baseline "receive
/// everything, then repair" is 1.0.
fn ttfv_one(input : String, chunk : Int32) -> (Double, Double, String) {
  let len = input.length()
  let full = @mend.parse(input).value.stringify().length() catch { _ => 0 }
  let target = full * 95 / 100
  let parser = @mend.PartialParser::new() catch {
    _ => return (1.0, 1.0, "n/a")
  }
  let mut first = -1
  let mut first_label = "n/a"
  let mut ttfv = -1
  let mut i = 0
  while i < len {
    let to = if i + chunk < len { i + chunk } else { len }
    parser.feed(input[i:to].to_owned()) catch {
      _ => ()
    }
    let snap = parser.snapshot()
    match snap.value {
      Some(v) => {
        if first < 0 {
          first = to
          first_label = snap.exactness.name()
        }
        if ttfv < 0 && v.stringify().length() >= target {
          ttfv = to
        }
      }
      None => ()
    }
    i = to
  }
  let f = if first < 0 { len } else { first }
  let t = if ttfv < 0 { len } else { ttfv }
  (
    f.to_double() / len.to_double(),
    t.to_double() / len.to_double(),
    first_label,
  )
}

///|
/// Median of a list of doubles.
fn median(xs : Array[Double]) -> Double {
  let ys = xs.copy()
  ys.sort()
  if ys.length() == 0 {
    0.0
  } else {
    ys[ys.length() / 2]
  }
}

///|
/// I-4: how early a streaming consumer can see something. The registered
/// metric is `ttfv` (95% of the value); `first` is the weaker but more useful
/// number for a user interface, and is reported alongside it.
fn bench_ttfv() -> Unit {
  for size in [256, 1024, 4096] {
    let doc = make_call(size)
    let (first, ttfv, label) = ttfv_one(doc, 16)
    println(
      "ttfv\tcall " +
      doc.length().to_string() +
      "\tfirst " +
      round1(first * 100.0) +
      "%\tttfv95 " +
      round1(ttfv * 100.0) +
      "%\tlabel at first " +
      label,
    )
  }
  // Median over 20 documents of mixed size, the registered aggregate.
  let firsts : Array[Double] = []
  let ttfvs : Array[Double] = []
  for k = 0; k < 20; k = k + 1 {
    let doc = make_call(256 + k * 200)
    let (first, ttfv, _label) = ttfv_one(doc, 16)
    firsts.push(first)
    ttfvs.push(ttfv)
  }
  println(
    "ttfv\tmedian over 20 documents\tfirst " +
    round1(median(firsts) * 100.0) +
    "%\tttfv95 " +
    round1(median(ttfvs) * 100.0) +
    "%",
  )
}

///|
/// A 4 KB tool-call document fed in 3 code unit chunks: the shape of a provider
/// stream, and the scenario the round-5 document asks to be measured (I-4).
///
/// `@env.now()` has millisecond resolution on this runtime, so a single feed
/// cannot be timed on its own. Two measurements are therefore reported: the
/// amortised cost per feed (the whole document, repeated, divided by the number
/// of feeds) and the observation that no individual feed ever reached the
/// clock's resolution, which is a p99 <= 1 ms statement rather than a p99
/// measurement. The distribution is reported at the granularity the clock can
/// actually see.
fn bench_agent_scenario() -> Unit {
  let input = make_call(4096)
  let len = input.length()
  let rounds = 200
  for chunk in [1, 3, 16, 1024, 65536] {
    let feeds = (len + chunk - 1) / chunk
    let t0 = @env.now()
    let mut over_resolution = 0
    for _r = 0; _r < rounds; _r = _r + 1 {
      try {
        let parser = @mend.PartialParser::new()
        let mut i = 0
        while i < len {
          let to = if i + chunk < len { i + chunk } else { len }
          let f0 = @env.now()
          parser.feed(input[i:to].to_owned())
          if chunk <= 3 && @env.now() - f0 > 0 {
            over_resolution = over_resolution + 1
          }
          i = to
        }
        ignore(parser.finish())
      } catch {
        _ => ()
      }
    }
    let ms = (@env.now() - t0).to_double()
    let total_feeds = (feeds * rounds).to_double()
    println(
      "agent\t4KB in " +
      chunk.to_string() +
      "\t" +
      round1(ms) +
      " ms for " +
      rounds.to_string() +
      " streams\t" +
      round2(ms * 1000.0 / total_feeds) +
      " us/feed\t" +
      round1(mbps(len * rounds, ms)) +
      " MB/s\tfeeds above clock resolution " +
      over_resolution.to_string() +
      "/" +
      (feeds * rounds).to_string(),
    )
  }
}

///|
/// A record with many top-level members: the shape FR-25 measures, where each
/// member becomes final at a different point. `make_call` is not this shape —
/// its members are `name` and a single nested `arguments` object, so the curve
/// is flat until the very end.
fn make_record(target : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("{")
  let mut n = 0
  let mut i = 0
  while n < target {
    if i > 0 {
      sb.write_string(",")
    }
    let field = "\"field" + i.to_string() + "\":\"value-" + i.to_string() + "\""
    sb.write_string(field)
    n = n + field.length()
    i = i + 1
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// The cost of FR-24 readiness tracking: one sample per 1/1000 of the input,
/// each sample comparing two values. Reported per document and per 1000 fields
/// so the price is visible next to the metric it buys.
fn bench_readiness() -> Unit {
  let docs : Array[String] = []
  let mut bytes = 0
  for k = 0; k < 20; k = k + 1 {
    let doc = make_record(512 + k * 200)
    docs.push(doc)
    bytes = bytes + doc.length()
  }
  let ms = median5(() => ignore(@mend.readiness_median(docs)) catch { _ => () })
  println(
    "readiness\t" +
    docs.length().to_string() +
    " flat records, " +
    bytes.to_string() +
    " bytes\t" +
    round1(ms) +
    " ms\t" +
    round2(ms * 1000.0 / docs.length().to_double()) +
    " us/doc\t" +
    round2(ms * 1000.0 * 1024.0 / bytes.to_double()) +
    " us/KiB",
  )
  let deciles = @mend.readiness_deciles(docs) catch { _ => [] }
  let saving = @mend.early_stop_saving(docs) catch { _ => 0 }
  println(
    "readiness\tdeciles " +
    deciles.map(fn(x) { x.to_string() }).join(" ") +
    "\tearly-stop saving " +
    saving.to_string() +
    "/1000",
  )
}

///|
/// One live streaming watcher over `doc` (FR-39): a fresh `SemanticWatcher` for
/// the skeleton, fed in `chunk` code units with an event drain after every feed,
/// then closed. The events are dropped on purpose: this measures the cost of
/// *producing* readiness on the stream, not of noticing it.
fn run_watcher(doc : String, schema : @mend.Schema, chunk : Int32) -> Unit {
  try {
    let watcher = @mend.SemanticWatcher::new(schema)
    let n = doc.length()
    let mut i = 0
    while i < n {
      let to = if i + chunk < n { i + chunk } else { n }
      watcher.feed(doc[i:to].to_owned())
      let _ = watcher.drain_events()
      i = to
    }
    let _ = watcher.finish()
  } catch {
    _ => ()
  }
}

///|
/// The price of the safety layer (FR-32 … FR-36): repairing the same 4 KiB tool
/// call four ways.
///
/// `repair` is the engine alone. `analyze` adds the plan the gate decides on.
/// `for_agent` adds the two gates (exactness and ambiguity) and the protocol.
/// `+schema` adds the skeleton check on top of that. Reported per document and
/// as a ratio against the engine alone, because "how much does the decision
/// cost" is the number a caller weighing the API needs.
///
/// 0.6.0 adds the FR-39 rows on the same corpus and against the same `repair`
/// baseline, so the batch measurement and the runtime path are directly
/// comparable:
///
/// * `field_readiness` — the FR-29 curve, which used to cost an offline
///   re-reading of the document (two extra columns: µs/KiB);
/// * `watcher` — the live path: one watcher per document, 64 code unit chunks,
///   one drain per chunk;
/// * `decided` — `decided_at_permille` over the corpus.
///
/// The pre-0.6.0 sampling row is gone in 0.7.0 (Q-36): that implementation no
/// longer exists, so there is nothing to measure against on one machine. Its
/// figures are in `docs/BENCHMARK.md`, which points at the commit that
/// produced them.
fn bench_gate() -> Unit {
  let docs : Array[String] = []
  let mut bytes = 0
  for k = 0; k < 20; k = k + 1 {
    let doc = make_call(4096 + k * 64)
    docs.push(doc)
    bytes = bytes + doc.length()
  }
  let schema = @mend.Schema::parse("{!name:string,!arguments:any}") catch {
    _ => return
  }
  let agent = @mend.Options::for_agent()
  let plain = median5(() => {
    for doc in docs {
      try {
        let _ = @mend.repair(doc)
      } catch {
        _ => ()
      }
    }
  })
  let plan = median5(() => {
    for doc in docs {
      let _ = @mend.analyze(doc)
    }
  })
  let gated = median5(() => {
    for doc in docs {
      let _ = @mend.analyze(doc, options=agent)
    }
  })
  let checked = median5(() => {
    for doc in docs {
      let _ = @mend.analyze(doc, options=agent, schema~)
    }
  })
  let ready = median5(() => {
    for doc in docs {
      try {
        let _ = @mend.semantic_readiness(doc, schema)
      } catch {
        _ => ()
      }
    }
  })
  let curve = median5(() => {
    for doc in docs {
      ignore(@mend.field_readiness(doc)) catch {
        _ => ()
      }
    }
  })
  let watching = median5(() => {
    for doc in docs {
      run_watcher(doc, schema, 64)
    }
  })
  let decided = median5(() => {
    for doc in docs {
      ignore(@mend.decided_at_permille(doc, schema)) catch {
        _ => ()
      }
    }
  })
  let rows : Array[(String, Double, String)] = [
    ("repair", plain, ""),
    ("analyze", plan, ""),
    ("analyze for_agent", gated, ""),
    ("analyze +schema", checked, ""),
    ("semantic_readiness", ready, ""),
    (
      "field_readiness",
      curve,
      "\t" + round2(ms_per_kib(curve, bytes)) + " us/KiB",
    ),
    ("watcher chunk 64", watching, ""),
    ("decided", decided, ""),
  ]
  for row in rows {
    let (name, ms, extra) = row
    println(
      name +
      "\t" +
      docs.length().to_string() +
      " calls, " +
      bytes.to_string() +
      " bytes\t" +
      round1(ms) +
      " ms\t" +
      round2(ms * 1000.0 / docs.length().to_double()) +
      " us/call\t" +
      round2(ms / plain) +
      "x repair" +
      extra +
      "\t" +
      round1(mbps(bytes, ms)) +
      " MB/s",
    )
  }
}

///|
/// Microseconds per KiB of `bytes` bytes in `ms` milliseconds.
fn ms_per_kib(ms : Double, bytes : Int32) -> Double {
  if bytes <= 0 {
    0.0
  } else {
    ms * 1000.0 * 1024.0 / bytes.to_double()
  }
}

///|
/// One `drain_deltas` round trip is the whole delta cost (I-2): report it per
/// delta so the number can be compared with the 1 MB delta benchmark above.
fn bench_delta_size() -> Unit {
  let input = make_call(4096)
  let parser = @mend.PartialParser::new(options={
    ..@mend.Options::default(),
    collect_deltas: true,
  }) catch {
    _ => return
  }
  let mut n = 0
  try {
    for i = 0; i < input.length(); i = i + 3 {
      let to = if i + 3 < input.length() { i + 3 } else { input.length() }
      parser.feed(input[i:to].to_owned())
      n = n + parser.drain_deltas().length()
    }
    ignore(parser.finish())
  } catch {
    _ => ()
  }
  println(
    "deltas\t4KB call in 3 byte chunks\t" + n.to_string() + " deltas total",
  )
}

///|
/// Every benchmark.
fn main {
  for target in [1024, 102400, 1048576, 10485760] {
    bench_throughput("valid", make_valid(target))
  }
  for target in [1024, 102400, 1048576, 10485760] {
    bench_throughput("flawed", make_flawed(target))
  }
  for depth in [64, 512] {
    let input = make_deep(depth)
    let ms = median5(() => run_repair(input))
    println("deep\tdepth " + depth.to_string() + "\t" + round1(ms) + " ms")
  }
  let long = make_long_string(1048576)
  let ms = median5(() => run_repair(long))
  println(
    "long-string\t1 MB\t" +
    round1(ms) +
    " ms\t" +
    round1(mbps(long.length(), ms)) +
    " MB/s",
  )
  let tree = make_valid(1048576)
  let ms_tree = median5(() => run_parse(tree))
  println(
    "parse-only\t1 MB\t" +
    round1(ms_tree) +
    " ms\t" +
    round1(mbps(tree.length(), ms_tree)) +
    " MB/s",
  )
  bench_linearity()
  bench_streaming()
  bench_snap_repeat()
  bench_deltas()
  bench_ttfv()
  bench_agent_scenario()
  bench_readiness()
  bench_gate()
  bench_delta_size()
}
