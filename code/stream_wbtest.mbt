// Streaming cases (TC-S, Appendix A.3 / B.3) and the derived assertions of
// A.4: chunk invariance (TC-P-03), idempotence, strict validity and the
// Strict-mode variant derived from the record table.

///|
/// Code units `[from, to)` of `s` as a string.
fn slice_units(s : String, from : Int32, to : Int32) -> String {
  let sb = StringBuilder()
  for i = from; i < to; i = i + 1 {
    sb.write_char(Int32::unsafe_to_char(s.at(i).to_int()))
  }
  sb.to_string()
}

///|
/// `{"name":"Mo"}` style rendering of a snapshot.
fn snap_str(p : PartialParser) -> String {
  let s = p.snapshot()
  let v = match s.value {
    Some(j) => j.stringify()
    None => "<none>"
  }
  let c = match s.completeness {
    Empty => "Empty"
    Partial => "Partial"
    Complete => "Complete"
  }
  let sb = StringBuilder()
  sb.write_string(v)
  sb.write_string(" ")
  sb.write_string(c)
  sb.write_string(" ")
  for i = 0; i < s.open_path.length(); i = i + 1 {
    if i > 0 {
      sb.write_string("/")
    }
    match s.open_path[i] {
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
/// Feed one chunk, returning `""` or the error text.
fn feed_try(p : PartialParser, s : String) -> String {
  try {
    p.feed(s)
    ""
  } catch {
    e => err_text(e)
  }
}

///|
/// Finish, returning the outcome.
fn finish_try(p : PartialParser) -> Outcome {
  try {
    let fin = p.finish()
    { text: fin.text, recs: recs_text(fin.repairs), err: "", }
  } catch {
    e => { text: "", recs: "", err: err_text(e), }
  }
}

///|
/// Run a chunk sequence and flatten the result.
fn run_stream(chunks : Array[String], opts : Options) -> Outcome {
  try {
    let p = PartialParser::new(options=opts)
    for c in chunks {
      p.feed(c)
    }
    let fin = p.finish()
    { text: fin.text, recs: recs_text(fin.repairs), err: "", }
  } catch {
    e => { text: "", recs: "", err: err_text(e), }
  }
}

///|
/// Appendix A and B cases in one array.
fn all_cases() -> Array[Case] {
  let out = cases_a()
  for c in cases_b() {
    out.push(c)
  }
  out
}

///|
/// S-001 … S-005.
test "streaming A" {
  let p = PartialParser::new()
  ignore(feed_try(p, "{\"name\":\"Mo"))
  assert_eq(snap_str(p), "{\"name\":\"Mo\"} Partial Key(name)")
  ignore(feed_try(p, "n\"}"))
  assert_eq(snap_str(p), "{\"name\":\"Mon\"} Complete ")
  let fin = p.finish()
  assert_eq(fin.text, "{\"name\":\"Mon\"}")
  assert_eq(recs_text(fin.repairs), "")

  let q = PartialParser::new()
  ignore(feed_try(q, "[1, 12"))
  assert_eq(snap_str(q), "[1] Partial Index(1)")
  ignore(feed_try(q, "3]"))
  assert_eq(snap_str(q), "[1,123] Complete ")

  let r = PartialParser::new()
  ignore(feed_try(r, "{\"a\":"))
  assert_eq(snap_str(r), "{} Partial Key(a)")
  let rn = PartialParser::new(options={
    ..Options::default(),
    pending_key: NullKey,
  })
  ignore(feed_try(rn, "{\"a\":"))
  assert_eq(snap_str(rn), "{\"a\":null} Partial Key(a)")

  let s4 = PartialParser::new()
  ignore(feed_try(s4, "{\"a\":tr"))
  assert_eq(snap_str(s4), "{} Partial Key(a)")
  ignore(feed_try(s4, "ue}"))
  assert_eq(snap_str(s4), "{\"a\":true} Complete ")

  let s5 = PartialParser::new()
  ignore(feed_try(s5, "{\"a\":\"x\\"))
  assert_eq(snap_str(s5), "{\"a\":\"x\"} Partial Key(a)")
  ignore(feed_try(s5, "n\"}"))
  assert_eq(snap_str(s5), "{\"a\":\"x\\n\"} Complete ")
  assert_eq(finish_try(s5).text, "{\"a\":\"x\\n\"}")
}

///|
/// S-006 … S-010.
test "streaming B" {
  let p = PartialParser::new()
  ignore(feed_try(p, "```js"))
  assert_eq(snap_str(p), "<none> Empty ")
  ignore(feed_try(p, "on\n{\"a\":1}"))
  assert_eq(snap_str(p), "{\"a\":1} Complete ")
  let fin = p.finish()
  assert_eq(fin.text, "{\"a\":1}")
  assert_eq(recs_text(fin.repairs), "R001@0")

  let q = PartialParser::new()
  ignore(feed_try(q, "[\"" + lone(0xD83D)))
  assert_eq(snap_str(q), "[\"\"] Partial Index(0)")
  ignore(feed_try(q, lone(0xDE00) + "\"]"))
  assert_eq(snap_str(q), "[\"😀\"] Complete ")

  let r = PartialParser::new()
  ignore(feed_try(r, "[1,/"))
  assert_eq(snap_str(r), "[1] Partial Index(1)")
  ignore(feed_try(r, "* c */2]"))
  assert_eq(snap_str(r), "[1,2] Complete ")
  assert_eq(finish_try(r).recs, "R002@3")

  let s9 = PartialParser::new()
  assert_eq(snap_str(s9), "<none> Empty ")

  let s10 = PartialParser::new()
  ignore(feed_try(s10, "[1]"))
  assert_eq(finish_try(s10).err, "")
  assert_eq(feed_try(s10, "[2]"), "E030")
  assert_eq(finish_try(s10).err, "E030")
}

///|
/// S-011 … S-018, S-020.
test "streaming C" {
  let trim : Options = { ..Options::default(), incomplete_number: TrimToValid, }

  let p = PartialParser::new(options=trim)
  ignore(feed_try(p, "[1, 12"))
  assert_eq(snap_str(p), "[1,12] Partial Index(1)")
  ignore(feed_try(p, "3]"))
  assert_eq(snap_str(p), "[1,123] Complete ")

  let q = PartialParser::new(options=trim)
  ignore(feed_try(q, "[1, 1."))
  assert_eq(snap_str(q), "[1,1] Partial Index(1)")
  ignore(feed_try(q, "5]"))
  assert_eq(snap_str(q), "[1,1.5] Complete ")

  let r = PartialParser::new(options=trim)
  ignore(feed_try(r, "[1, -"))
  assert_eq(snap_str(r), "[1] Partial Index(1)")

  let s14 = PartialParser::new(options=trim)
  ignore(feed_try(s14, "[1, tr"))
  assert_eq(snap_str(s14), "[1] Partial Index(1)")

  let s15 = PartialParser::new()
  ignore(feed_try(s15, "{\"a\":1,\"b"))
  assert_eq(snap_str(s15), "{\"a\":1} Partial ")
  let s15n = PartialParser::new(options={
    ..Options::default(),
    pending_key: NullKey,
  })
  ignore(feed_try(s15n, "{\"a\":1,\"b"))
  ignore(feed_try(s15n, "\":"))
  assert_eq(snap_str(s15n), "{\"a\":1,\"b\":null} Partial Key(b)")

  let s16 = PartialParser::new()
  ignore(feed_try(s16, "[1,2"))
  let s1 = s16.snapshot()
  let s1_text = match s1.value {
    Some(j) => j.stringify()
    None => "<none>"
  }
  // S-016's documented snapshot is `[1,2]`, but with the default
  // incomplete_number=Drop the unfinished `2` is not shown (S-002, S-011);
  // the point of the case is that the snapshot is a deep copy.
  assert_eq(s1_text, "[1]")
  ignore(feed_try(s16, ",3]"))
  assert_eq(s1_text, "[1]")
  assert_eq(finish_try(s16).text, "[1,2,3]")

  let s17 = PartialParser::new(options={ ..Options::default(), max_depth: 1, })
  assert_eq(feed_try(s17, "[["), "E020(1,@1)")
  assert_eq(feed_try(s17, "["), "E030")
  ignore(snap_str(s17))

  let s18 = PartialParser::new()
  ignore(feed_try(s18, "{\"a\":[1,{\"b\":"))
  assert_eq(snap_str(s18), "{\"a\":[1,{}]} Partial Key(a)/Index(1)/Key(b)")

  let s20 = PartialParser::new()
  ignore(feed_try(s20, "[\"\\u00"))
  assert_eq(snap_str(s20), "[\"\"] Partial Index(0)")
  ignore(feed_try(s20, "e9\"]"))
  assert_eq(snap_str(s20), "[\"é\"] Complete ")
}

///|
/// TC-P-03: feeding by code unit or at any split point must give exactly the
/// one-shot result (text, records, error).
test "stream chunk invariance" {
  for c in all_cases() {
    let one = attempt(c.input, c.opts)
    let want = one.text + " | " + one.recs + " | " + one.err
    let n = c.input.length()
    if n <= 256 {
      let units : Array[String] = []
      for i = 0; i < n; i = i + 1 {
        units.push(slice_units(c.input, i, i + 1))
      }
      let got = run_stream(units, c.opts)
      assert_eq(
        c.id + " (per unit) | " + got.text + " | " + got.recs + " | " + got.err,
        c.id + " (per unit) | " + want,
      )
      for k = 0; k <= n; k = k + 1 {
        let parts = [slice_units(c.input, 0, k), slice_units(c.input, k, n)]
        let got2 = run_stream(parts, c.opts)
        assert_eq(
          c.id +
          " (split " +
          k.to_string() +
          ") | " +
          got2.text +
          " | " +
          got2.recs +
          " | " +
          got2.err,
          c.id + " (split " + k.to_string() + ") | " + want,
        )
      }
    } else {
      let parts = [
        slice_units(c.input, 0, n / 2),
        slice_units(c.input, n / 2, n),
      ]
      let got = run_stream(parts, c.opts)
      assert_eq(
        c.id + " (halves) | " + got.text + " | " + got.recs + " | " + got.err,
        c.id + " (halves) | " + want,
      )
      let many : Array[String] = []
      let mut i = 0
      while i < n {
        let to = if i + 1000 < n { i + 1000 } else { n }
        many.push(slice_units(c.input, i, to))
        i = to
      }
      let got2 = run_stream(many, c.opts)
      assert_eq(
        c.id +
        " (1k chunks) | " +
        got2.text +
        " | " +
        got2.recs +
        " | " +
        got2.err,
        c.id + " (1k chunks) | " + want,
      )
    }
  }
}

///|
/// First element of a comma separated record list.
fn first_rec(s : String) -> String {
  let sb = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    if s.at(i).to_int() == 0x2C {
      break
    }
    match s.at(i).to_char() {
      Some(c) => sb.write_char(c)
      None => ()
    }
  }
  sb.to_string()
}

///|
/// Whether an option set is exactly the documented default.
fn is_default_opts(o : Options) -> Bool {
  let mut rules_all = true
  for i = 0; i < o.rules.flags.length(); i = i + 1 {
    if !o.rules.flags[i] {
      rules_all = false
    }
  }
  o.mode is Lenient &&
  o.max_depth == 512 &&
  o.max_input_len == 67108864 &&
  o.max_token_len == 16777216 &&
  o.duplicate_keys is KeepLast &&
  o.incomplete_number is Drop &&
  o.pending_key is OmitKey &&
  o.non_finite is AsNull &&
  o.strip_fence &&
  o.collect_repairs &&
  o.want_text &&
  !o.skip_prose &&
  !o.quote_lookahead &&
  o.multi_root is KeepFirst &&
  o.indent == 0 &&
  rules_all
}

///|
/// A.4: idempotence, strict validity, and the Strict variant derived from the
/// first record.
test "derived golden assertions" {
  for c in all_cases() {
    if c.err != "" {
      continue
    }
    if is_default_opts(c.opts) {
      let again = attempt(c.text, Options::default())
      assert_eq(
        c.id +
        " idempotent | " +
        again.text +
        " | " +
        again.recs +
        " | " +
        again.err,
        c.id + " idempotent | " + c.text + " |  | ",
      )
      assert_eq(
        c.id + " valid | " + is_valid_json(c.text).to_string(),
        c.id + " valid | true",
      )
    }
    if c.recs != "" {
      let strict : Options = { ..c.opts, mode: Strict, }
      let got = attempt(c.input, strict)
      let first = first_rec(c.recs)
      assert_eq(
        c.id + " strict | " + got.err,
        c.id + " strict | E010(" + first + ")",
      )
    }
  }
}
