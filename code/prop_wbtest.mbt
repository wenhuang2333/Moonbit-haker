// Property-based and fuzz tests (family TC-P of the project document set,
// section 11.5 "属性与模糊测试").
//
// Every generator is deterministic: a single seeded LCG drives each property,
// so any failure is reproducible from the input printed by the assertion. The
// one-shot helpers (`attempt`, `recs_text`, `err_text`) come from
// `golden_wbtest.mbt`; the streaming helpers (`slice_units`, `run_stream`,
// `feed_try`, `finish_try`) come from `stream_wbtest.mbt`.

///|
/// Cases generated per property.
let tc_cases : Int32 = 400

///|
/// Tiny deterministic LCG. The state is `Int64` so that the classic
/// `(seed * 1103515245 + 12345) mod 2^31` step cannot overflow the 32-bit
/// `Int`.
struct TcLcg {
  mut seed : Int64
}

///|
fn tc_lcg(seed : Int64) -> TcLcg {
  { seed, }
}

///|
/// Next raw value in `[0, 2^31)`.
fn TcLcg::next(self : TcLcg) -> Int32 {
  self.seed = (self.seed * 1103515245L + 12345L) % 2147483648L
  self.seed.to_int()
}

///|
/// Uniform-ish value in `[0, n)`.
fn TcLcg::below(self : TcLcg, n : Int32) -> Int32 {
  if n <= 1 {
    0
  } else {
    self.next() % n
  }
}

///|
/// `true` with probability `num / den`.
fn TcLcg::chance(self : TcLcg, num : Int32, den : Int32) -> Bool {
  self.below(den) < num
}

// ---------------------------------------------------------------------------
// G1: deterministic generator of valid JSON documents.
// ---------------------------------------------------------------------------

///|
/// One whitespace fragment (valid between JSON tokens).
fn tc_ws(r : TcLcg) -> String {
  match r.below(4) {
    0 => " "
    1 => "\n"
    2 => "  "
    _ => ""
  }
}

///|
/// One string body: empty, or up to five fragments drawn from an alphabet that
/// covers plain text, escapes, non-ASCII text, surrogate escapes and escaped
/// control characters.
fn tc_str_body(r : TcLcg) -> String {
  let frags : Array[String] = [
    "a", "B", "7", "_", " ", "-", ".", "\\n", "\\t", "\\r", "\\b", "\\f", "\\\\",
    "\\\"", "\\/", "\\u00e9", "\\u0000", "\\u001f", "\\uD83D\\uDE00", "é", "中",
    "😀", "Ω", "ß",
  ]
  let n = r.below(6)
  let sb = StringBuilder()
  for _i = 0; _i < n; _i = _i + 1 {
    sb.write_string(frags[r.below(frags.length())])
  }
  sb.to_string()
}

///|
fn tc_string(r : TcLcg) -> String {
  "\"" + tc_str_body(r) + "\""
}

///|
/// Object key. The `m<index>_` prefix keeps every key of one object unique, so
/// a generated document never contains a duplicate key.
fn tc_key(r : TcLcg, idx : Int32) -> String {
  "\"m" + idx.to_string() + "_" + tc_str_body(r) + "\""
}

///|
/// Unsigned integer literal.
fn tc_uint(r : TcLcg) -> String {
  match r.below(4) {
    0 => "0"
    1 => (1 + r.below(9)).to_string()
    2 => (1 + r.below(1000)).to_string()
    _ => (1 + r.below(1000000000)).to_string()
  }
}

///|
/// Unsigned double literal, e.g. `12.007`, `5e-3`, `0.5e20`.
fn tc_udouble(r : TcLcg) -> String {
  let ip = tc_uint(r)
  let frac = r.below(1000000).to_string()
  let exp = (1 + r.below(30)).to_string()
  let esign = if r.chance(1, 2) { "e-" } else { "e" }
  match r.below(3) {
    0 => ip + "." + frac
    1 => ip + esign + exp
    _ => ip + "." + frac + esign + exp
  }
}

///|
/// Number literal: integer or double, optionally negative.
fn tc_number(r : TcLcg) -> String {
  let mag = if r.chance(1, 3) { tc_udouble(r) } else { tc_uint(r) }
  if r.chance(1, 2) {
    "-" + mag
  } else {
    mag
  }
}

///|
fn tc_scalar(r : TcLcg) -> String {
  match r.below(6) {
    0 => "true"
    1 => "false"
    2 => "null"
    3 | 4 => tc_number(r)
    _ => tc_string(r)
  }
}

///|
fn tc_value(r : TcLcg, depth : Int32) -> String {
  if depth <= 0 {
    tc_scalar(r)
  } else {
    match r.below(10) {
      0 | 1 | 2 => tc_scalar(r)
      3 | 4 | 5 | 6 => tc_array(r, depth - 1)
      _ => tc_object(r, depth - 1)
    }
  }
}

///|
fn tc_array(r : TcLcg, depth : Int32) -> String {
  let n = r.below(4)
  let sb = StringBuilder()
  sb.write_string("[")
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(tc_ws(r))
    sb.write_string(tc_value(r, depth))
  }
  sb.write_string(tc_ws(r))
  sb.write_string("]")
  sb.to_string()
}

///|
fn tc_object(r : TcLcg, depth : Int32) -> String {
  let n = r.below(4)
  let sb = StringBuilder()
  sb.write_string("{")
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(tc_ws(r))
    sb.write_string(tc_key(r, i))
    let colon = if r.chance(1, 3) { " : " } else { ":" }
    sb.write_string(colon)
    sb.write_string(tc_ws(r))
    sb.write_string(tc_value(r, depth))
  }
  sb.write_string(tc_ws(r))
  sb.write_string("}")
  sb.to_string()
}

///|
/// A valid JSON document, nested at most four levels deep, optionally padded
/// with leading and trailing whitespace.
fn tc_doc(r : TcLcg) -> String {
  let depth = 1 + r.below(4)
  tc_ws(r) + tc_value(r, depth) + tc_ws(r)
}

// ---------------------------------------------------------------------------
// G1 mutator: 1 to 4 deterministic byte-level mutations of a valid document.
// ---------------------------------------------------------------------------

///|
/// Insert the one-character string `u` at code-unit offset `at`.
fn tc_insert_unit(s : String, at : Int32, u : String) -> String {
  slice_units(s, 0, at) + u + slice_units(s, at, s.length())
}

///|
/// Delete the code unit at `at`.
fn tc_delete_unit(s : String, at : Int32) -> String {
  slice_units(s, 0, at) + slice_units(s, at + 1, s.length())
}

///|
/// Replace the code unit at `at` by the one-character string `u`.
fn tc_replace_unit(s : String, at : Int32, u : String) -> String {
  slice_units(s, 0, at) + u + slice_units(s, at + 1, s.length())
}

///|
/// Replace one `"` by `'`.
fn tc_replace_quote(r : TcLcg, s : String) -> String {
  let quotes : Array[Int32] = []
  for i = 0; i < s.length(); i = i + 1 {
    if s.at(i).to_int() == 0x22 {
      quotes.push(i)
    }
  }
  if quotes.length() == 0 {
    s
  } else {
    tc_replace_unit(s, quotes[r.below(quotes.length())], "'")
  }
}

///|
/// Duplicate the first member of the first object: `{"a":1}` becomes
/// `{"a":1,"a":1}`. Returns `s` unchanged when there is no complete member.
fn tc_dup_key(s : String) -> String {
  let n = s.length()
  let mut open = -1
  for i = 0; i < n; i = i + 1 {
    if s.at(i).to_int() == 0x7B {
      open = i
      break
    }
  }
  if open < 0 {
    return s
  }
  let mut depth = 0
  let mut in_str = false
  let mut esc = false
  let mut end = -1
  for i = open + 1; i < n; i = i + 1 {
    let u = s.at(i).to_int()
    if in_str {
      if esc {
        esc = false
      } else if u == 0x5C {
        esc = true
      } else if u == 0x22 {
        in_str = false
      }
    } else if u == 0x22 {
      in_str = true
    } else if u == 0x7B || u == 0x5B {
      depth = depth + 1
    } else if u == 0x7D || u == 0x5D {
      if depth == 0 {
        end = i
        break
      } else {
        depth = depth - 1
      }
    } else if u == 0x2C && depth == 0 {
      end = i
      break
    }
  }
  if end < 0 {
    return s
  }
  let head = slice_units(s, open + 1, end)
  slice_units(s, 0, end) + "," + head + slice_units(s, end, n)
}

///|
/// The punctuation alphabet of the mutator: `, { } [ ] " ' : / \`.
fn tc_punct(r : TcLcg) -> String {
  let punct : Array[String] = [
    ",", "{", "}", "[", "]", "\"", "'", ":", "/", "\\",
  ]
  punct[r.below(punct.length())]
}

///|
/// One random mutation of `s`.
fn tc_mutate(r : TcLcg, s : String) -> String {
  let n = s.length()
  match r.below(6) {
    0 => if n == 0 { s } else { slice_units(s, 0, r.below(n + 1)) }
    1 => if n == 0 { s } else { tc_delete_unit(s, r.below(n)) }
    2 => tc_insert_unit(s, r.below(n + 1), tc_punct(r))
    3 => tc_replace_quote(r, s)
    4 => tc_dup_key(s)
    _ => s + "..."
  }
}

///|
/// A valid document followed by between one and four mutations.
fn tc_fuzz_input(r : TcLcg) -> String {
  let mut s = tc_doc(r)
  let k = 1 + r.below(4)
  for _i = 0; _i < k; _i = _i + 1 {
    s = tc_mutate(r, s)
  }
  s
}

///|
fn tc_valid_docs(seed : Int64, count : Int32) -> Array[String] {
  let r = tc_lcg(seed)
  let out : Array[String] = []
  for _i = 0; _i < count; _i = _i + 1 {
    out.push(tc_doc(r))
  }
  out
}

///|
fn tc_fuzz_inputs(seed : Int64, count : Int32) -> Array[String] {
  let r = tc_lcg(seed)
  let out : Array[String] = []
  for _i = 0; _i < count; _i = _i + 1 {
    out.push(tc_fuzz_input(r))
  }
  out
}

// ---------------------------------------------------------------------------
// Shared helpers for the properties.
// ---------------------------------------------------------------------------

///|
/// `parse(input).value` rendered as text, or `"<raise>"` when `parse` rejects
/// the input.
fn tc_value_text(input : String) -> String {
  parse(input).value.stringify() catch {
    _ => "<raise>"
  }
}

///|
/// TC-P-01 core: a successful repair must yield strict JSON, and no input may
/// surface the internal `E030`.
fn tc_check_valid(input : String, opts : Options, tag : String) -> Unit raise {
  let o = attempt(input, opts)
  if o.err == "" {
    if !is_valid_json(o.text) {
      println(tag + " input: " + input)
      println(tag + " output: " + o.text)
      assert_true(false, msg="repair produced text that is not valid JSON")
    }
  } else if o.err == "E030" {
    println(tag + " input: " + input)
    assert_true(false, msg="repair raised the internal E030 InvalidState")
  }
}

///|
/// `k` random cut points, sorted and turned into `k + 1` chunks.
fn tc_chunks(r : TcLcg, s : String, k : Int32) -> Array[String] {
  let n = s.length()
  let cuts : Array[Int32] = [0, n]
  for _i = 0; _i < k; _i = _i + 1 {
    cuts.push(r.below(n + 1))
  }
  cuts.sort()
  let out : Array[String] = []
  for i = 0; i + 1 < cuts.length(); i = i + 1 {
    out.push(slice_units(s, cuts[i], cuts[i + 1]))
  }
  out
}

///|
/// TC-P-03 core: compare a chunked run with the one-shot result.
fn tc_expect_chunks(
  input : String,
  tag : String,
  got : Outcome,
  want : String,
) -> Unit raise {
  let g = got.text + " | " + got.recs + " | " + got.err
  if g != want {
    println(input)
    assert_eq(tag + " " + g, tag + " " + want)
  }
}

///|
/// Offset of the first non-whitespace code unit (or the length).
fn tc_first_content(s : String) -> Int32 {
  for i = 0; i < s.length(); i = i + 1 {
    let u = s.at(i).to_int()
    if u != 0x20 && u != 0x09 && u != 0x0A && u != 0x0D {
      return i
    }
  }
  s.length()
}

///|
/// Feed `s` truncated at `t` and finish.
fn tc_run_prefix(input : String, t : Int32, opts : Options) -> Outcome {
  try {
    let p = PartialParser::new(options=opts)
    p.feed(slice_units(input, 0, t))
    let fin = p.finish()
    { text: fin.text, recs: recs_text(fin.repairs), err: "", }
  } catch {
    e => { text: "", recs: "", err: err_text(e), }
  }
}

///|
fn tc_new_parser(opts : Options) -> PartialParser? {
  Some(PartialParser::new(options=opts)) catch {
    _ => None
  }
}

///|
/// `Key(a)/Index(2)` style rendering of an open path.
fn tc_path_text(path : Array[PathSegment]) -> String {
  let sb = StringBuilder()
  for i = 0; i < path.length(); i = i + 1 {
    if i > 0 {
      sb.write_string("/")
    }
    match path[i] {
      Key(k) => {
        sb.write_string("Key(")
        sb.write_string(k)
        sb.write_string(")")
      }
      Index(n) => {
        sb.write_string("Index(")
        sb.write_string(n.to_string())
        sb.write_string(")")
      }
    }
  }
  sb.to_string()
}

///|
/// Whether `path` can be walked inside the partial value `v`. A non-final
/// `Index(i)` needs the array to hold more than `i` elements (so the walk can
/// descend into element `i`); a final `Index(i)` needs at least `i` elements
/// (element `i` may still be under construction). A final `Key(k)` may be
/// pending, so its presence is not required.
fn tc_path_ok(v : Json, path : Array[PathSegment]) -> Bool {
  let mut cur = v
  let n = path.length()
  for i = 0; i < n; i = i + 1 {
    let is_last = i == n - 1
    match path[i] {
      Index(k) =>
        match cur {
          Json::Array(a) =>
            if is_last {
              if a.length() < k {
                return false
              }
            } else {
              if a.length() <= k {
                return false
              }
              cur = a[k]
            }
          _ => return false
        }
      Key(k) =>
        match cur {
          Json::Object(m) =>
            if !is_last {
              match m.get(k) {
                Some(x) => cur = x
                None => return false
              }
            }
          _ => return false
        }
    }
  }
  true
}

// ---------------------------------------------------------------------------
// TC-P-00: the generator itself is sound.
// ---------------------------------------------------------------------------

///|
/// Every generated "valid" document really is valid JSON.
test "TC-P-00 generator soundness" {
  for doc in tc_valid_docs(20261014L, tc_cases) {
    if !is_valid_json(doc) {
      println(doc)
      assert_true(false, msg="generator emitted a document core JSON rejects")
    }
  }
}

// ---------------------------------------------------------------------------
// TC-P-01: a successful repair yields strictly valid JSON.
// ---------------------------------------------------------------------------

///|
test "TC-P-01 repaired output is valid JSON" {
  let opts = Options::default()
  let indent2 : Options = { ..Options::default(), indent: 2, }
  let lookahead : Options = {
    ..Options::default(),
    quote_lookahead: true,
    skip_prose: true,
  }
  let multi : Options = { ..Options::default(), multi_root: AsArray, }
  for input in tc_fuzz_inputs(20261015L, tc_cases) {
    tc_check_valid(input, opts, "TC-P-01 default")
    tc_check_valid(input, indent2, "TC-P-01 indent")
    tc_check_valid(input, lookahead, "TC-P-01 lookahead")
    tc_check_valid(input, multi, "TC-P-01 multi_root")
  }
}

// ---------------------------------------------------------------------------
// TC-P-02: idempotence and the fixed point.
// ---------------------------------------------------------------------------

///|
/// TC-P-02 (a): repairing a repaired text is the identity with no records.
test "TC-P-02 repair is idempotent" {
  let opts = Options::default()
  for input in tc_fuzz_inputs(20261016L, tc_cases) {
    let first = attempt(input, opts)
    if first.err == "" {
      let second = attempt(first.text, opts)
      if second.text != first.text || second.recs != "" {
        println(input)
        println(first.text)
        assert_eq(second.text + " | " + second.recs, first.text + " | ")
      }
    }
  }
}

///|
/// TC-P-02 (b): a valid document is a fixed point — no records, and the
/// repaired text re-parses to the same `Json` value.
test "TC-P-02 valid documents are the fixed point" {
  let opts = Options::default()
  for doc in tc_valid_docs(20261017L, tc_cases) {
    let o = attempt(doc, opts)
    if o.err != "" || o.recs != "" {
      println(doc)
      assert_eq(o.err + " | " + o.recs, " | ")
    }
    let want = tc_value_text(doc)
    let got = tc_value_text(o.text)
    if got != want {
      println(doc)
      assert_eq(got, want)
    }
  }
}

// ---------------------------------------------------------------------------
// TC-P-03: chunk invariance.
// ---------------------------------------------------------------------------

///|
test "TC-P-03 chunk invariance" {
  let opts = Options::default()
  let r = tc_lcg(20261018L)
  for _case = 0; _case < tc_cases; _case = _case + 1 {
    let input = tc_fuzz_input(r)
    let one = attempt(input, opts)
    let want = one.text + " | " + one.recs + " | " + one.err
    let n = input.length()
    if n < 64 {
      let units : Array[String] = []
      for i = 0; i < n; i = i + 1 {
        units.push(slice_units(input, i, i + 1))
      }
      tc_expect_chunks(input, "per unit", run_stream(units, opts), want)
    } else {
      for k in [1, 7, 13] {
        let got = run_stream(tc_chunks(r, input, k), opts)
        tc_expect_chunks(input, "split " + k.to_string(), got, want)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// TC-P-04: truncated documents still complete to valid JSON.
// ---------------------------------------------------------------------------

///|
test "TC-P-04 truncated documents complete to valid JSON" {
  let opts = Options::default()
  let r = tc_lcg(20261019L)
  for _case = 0; _case < tc_cases; _case = _case + 1 {
    let doc = tc_doc(r)
    let n = doc.length()
    let fc = tc_first_content(doc)
    // A whitespace-only prefix is E001 and a lone `-` is E002 NoJsonFound;
    // both are outside the documented property, so the prefix is kept at
    // least one code unit past the first content code unit.
    let mut lo = fc + 1
    if fc < n && doc.at(fc).to_int() == 0x2D {
      lo = fc + 2
    }
    if lo > n {
      lo = n
    }
    let t = lo + r.below(n - lo + 1)
    let o = tc_run_prefix(doc, t, opts)
    if o.err != "" {
      println("prefix: " + slice_units(doc, 0, t))
      println("doc:    " + doc)
      assert_eq(o.err, "")
    }
    if !is_valid_json(o.text) {
      println("prefix: " + slice_units(doc, 0, t))
      println("text:   " + o.text)
      assert_true(false, msg="truncated completion is not valid JSON")
    }
  }
}

// ---------------------------------------------------------------------------
// TC-P-05: monotonic snapshots and valid open paths.
// ---------------------------------------------------------------------------

///|
test "TC-P-05 snapshots are monotonic after completion" {
  let opts = Options::default()
  let r = tc_lcg(20261020L)
  for _case = 0; _case < tc_cases; _case = _case + 1 {
    let doc = tc_doc(r)
    let chunks = tc_chunks(r, doc, 1 + r.below(4))
    // Trailing whitespace keeps the document valid while guaranteeing that
    // snapshots exist after the one that first reports `Complete`.
    chunks.push(" ")
    chunks.push("\n")
    chunks.push("\t")
    match tc_new_parser(opts) {
      None => {
        println(doc)
        assert_true(
          false,
          msg="PartialParser::new failed on the default options",
        )
      }
      Some(p) => {
        let mut seen_complete = false
        let mut complete_value = ""
        for c in chunks {
          let e = feed_try(p, c)
          if e != "" {
            println(doc)
            assert_eq(e, "")
          }
          let s = p.snapshot()
          match s.value {
            Some(v) =>
              if !tc_path_ok(v, s.open_path) {
                println(doc)
                println("path: " + tc_path_text(s.open_path))
                assert_true(false, msg="open_path is not a valid path")
              }
            None =>
              if s.open_path.length() != 0 {
                println(doc)
                assert_true(
                  false,
                  msg="empty snapshot with a non-empty open_path",
                )
              }
          }
          if s.completeness is Complete {
            let vs = match s.value {
              Some(v) => v.stringify()
              None => "<none>"
            }
            if seen_complete {
              if vs != complete_value {
                println(doc)
                assert_eq(vs, complete_value)
              }
            } else {
              seen_complete = true
              complete_value = vs
            }
          }
        }
        if !seen_complete {
          println(doc)
          assert_true(false, msg="a valid document never reported Complete")
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// TC-P-06: random token soup (spec G2 / G3) — arbitrary concatenations of the
// JSON alphabet, including comments, fences, partial escapes and lone
// surrogates. A successful repair must still be valid JSON and idempotent, and
// no input may surface the internal E030.
// ---------------------------------------------------------------------------

///|
/// A random concatenation of zero to 23 JSON-ish fragments.
fn tc_soup(r : TcLcg) -> String {
  let frags : Array[String] = [
    "{",
    "}",
    "[",
    "]",
    ",",
    ":",
    "\"",
    "'",
    "\\",
    "/",
    "*",
    " ",
    "\n",
    "\t",
    "\r",
    "0",
    "1",
    "9",
    "12",
    "1.5",
    "1e",
    "1e+",
    "-",
    "+",
    ".",
    "007",
    "tru",
    "true",
    "false",
    "nul",
    "null",
    "NaN",
    "Infinity",
    "-Infinity",
    "undefined",
    "None",
    "\\n",
    "\\u",
    "\\u00e9",
    "\\uD83D",
    "\\uDE00",
    "\\uD83D\\uDE00",
    "\\q",
    "\"a\"",
    "\"\\",
    "\\\"",
    "...",
    "```",
    "```json",
    "//",
    "/*",
    "*/",
    "<",
    ">",
    "&",
    "@",
    "#",
    "é",
    "中",
    "😀",
    lone(0xD83D),
    lone(0xDE00),
    lone(0xDC00),
    "e",
    "E",
    "-0",
    "0.0",
  ]
  let n = r.below(24)
  let sb = StringBuilder()
  for _i = 0; _i < n; _i = _i + 1 {
    sb.write_string(frags[r.below(frags.length())])
  }
  sb.to_string()
}

///|
test "TC-P-06 token soup" {
  let opts = Options::default()
  let r = tc_lcg(20261021L)
  for _case = 0; _case < tc_cases; _case = _case + 1 {
    let input = tc_soup(r)
    let first = attempt(input, opts)
    if first.err == "" {
      if !is_valid_json(first.text) {
        println("input:  " + input)
        println("output: " + first.text)
        assert_true(false, msg="token soup produced invalid JSON")
      }
      let second = attempt(first.text, opts)
      if second.text != first.text || second.recs != "" {
        println("input: " + input)
        println("first: " + first.text)
        assert_eq(second.text + " | " + second.recs, first.text + " | ")
      }
    } else if first.err == "E030" {
      println("input: " + input)
      assert_true(false, msg="token soup raised the internal E030")
    }
  }
}
