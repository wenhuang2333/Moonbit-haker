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
}
