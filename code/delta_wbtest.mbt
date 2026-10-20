// FR-18 property: the delta stream replays to exactly the snapshot it was
// drained from (I-2).
//
// The replay is done here, in the test, with a tiny applier, so that the
// library side has no code in common with the check.

///|
/// Child of a container at `seg`, if present.
fn dj_get(v : Json, seg : PathSegment) -> Json? {
  match (v, seg) {
    (Json::Object(m), Key(k)) => m.get(k)
    (Json::Array(a), Index(i)) =>
      if i >= 0 && i < a.length() {
        Some(a[i])
      } else {
        None
      }
    _ => None
  }
}

///|
/// Store `child` under `seg`, growing an array with `null` as needed.
fn dj_put(v : Json, seg : PathSegment, child : Json) -> Unit {
  match (v, seg) {
    (Json::Object(m), Key(k)) => m[k] = child
    (Json::Array(a), Index(i)) => {
      while a.length() <= i {
        a.push(Json::null())
      }
      a[i] = child
    }
    _ => ()
  }
}

///|
/// Empty container of the shape `seg` implies.
fn dj_make(seg : PathSegment) -> Json {
  match seg {
    Key(_) => Json::object(Map([]))
    Index(_) => Json::array([])
  }
}

///|
/// Apply one delta at `path[at:]`.
fn dj_apply(
  root : Json?,
  path : Array[PathSegment],
  at : Int32,
  d : Delta,
) -> Json? {
  if at == path.length() {
    return match d.op {
      Set | Close => d.value
      AppendText =>
        Some(
          match root {
            Some(Json::String(s)) => Json::string(s + d.text)
            _ => Json::string(d.text)
          },
        )
    }
  }
  let seg = path[at]
  let cur = match root {
    Some(v) => v
    None => dj_make(seg)
  }
  let child = dj_apply(dj_get(cur, seg), path, at + 1, d)
  match child {
    Some(c) => dj_put(cur, seg, c)
    None => ()
  }
  Some(cur)
}

///|
/// Value obtained by replaying `ops` from scratch.
fn dj_replay(ops : Array[Delta]) -> Json? {
  let mut acc : Json? = None
  for d in ops {
    acc = dj_apply(acc, d.path, 0, d)
  }
  acc
}

///|
/// Render a possibly absent value for comparison.
fn dj_render(v : Json?) -> String {
  match v {
    Some(j) => j.stringify()
    None => "<none>"
  }
}

///|
/// One delta profile under test.
fn dj_profiles() -> Array[(String, Options)] {
  let base = Options::for_llm()
  [
    ("for_llm", base),
    ("null_key", { ..base, pending_key: NullKey, }),
    ("multi_root_array", { ..base, multi_root: AsArray, }),
    ("quote_lookahead", { ..base, quote_lookahead: true, }),
    ("skip_prose", { ..base, skip_prose: true, }),
    ("no_fence", { ..base, strip_fence: false, }),
    ("deep", { ..base, max_depth: 64, max_repairs: 64, }),
  ]
}

///|
/// Feed `input` in `k` random chunks, draining after every chunk, and check
/// that replaying everything drained so far reproduces the snapshot, and that
/// after `finish` it reproduces the final value.
fn dj_check(
  input : String,
  opts : Options,
  r : TcLcg,
  tag : String,
) -> Unit raise {
  let p = PartialParser::new(options=opts) catch { _ => return }
  let chunks = tc_chunks(r, input, 5)
  let ops : Array[Delta] = []
  for c in chunks {
    let ok = try {
      p.feed(c)
      true
    } catch {
      _ => false
    }
    if !ok {
      return
    }
    for d in p.drain_deltas() {
      ops.push(d)
    }
    let got = dj_render(dj_replay(ops))
    let want = dj_render(p.snapshot().value)
    if got != want {
      println(tag + " input: " + input)
      println(tag + " after chunk: " + c)
      assert_eq(tag + " replay", tag + " snapshot: " + want + " got " + got)
    }
  }
  let fin = Some(p.finish()) catch { _ => None }
  match fin {
    Some(f) => {
      for d in p.drain_deltas() {
        ops.push(d)
      }
      let got = dj_render(dj_replay(ops))
      let want = dj_render(Some(f.value))
      if got != want {
        println(tag + " input: " + input)
        assert_eq(
          tag + " final replay",
          tag + " final: " + want + " got " + got,
        )
      }
    }
    None => ()
  }
}

///|
test "delta replay equals snapshot on generated documents" {
  let docs = tc_valid_docs(20261015L, 400)
  let r = tc_lcg(777L)
  for input in docs {
    dj_check(input, Options::for_llm(), r, "P-D1")
  }
}

///|
test "delta replay equals snapshot on mutated and fuzzed inputs" {
  let inputs = tc_fuzz_inputs(31337L, 400)
  let r = tc_lcg(4242L)
  for input in inputs {
    dj_check(input, Options::for_llm(), r, "P-D2")
  }
}

///|
test "delta replay holds for every option profile" {
  let docs = tc_valid_docs(5150L, 60)
  for (name, opts) in dj_profiles() {
    let r = tc_lcg(99L)
    for input in docs {
      dj_check(input, opts, r, "P-D3/" + name)
    }
  }
}

///|
test "Close is not final: a later Set overwrites the same path" {
  // `duplicate_keys KeepLast` may overwrite a member *after* its container was
  // announced and closed. The contract is therefore "apply in order", not
  // "Close is the last word on a path".
  let p = PartialParser::new(options=Options::for_llm())
  p.feed("{\"a\":{\"x\":1},\"a\":2}")
  let ops : Array[Delta] = []
  for d in p.drain_deltas() {
    ops.push(d)
  }
  let f = p.finish()
  for d in p.drain_deltas() {
    ops.push(d)
  }
  assert_eq(dj_render(dj_replay(ops)), dj_render(Some(f.value)))
  assert_eq(dj_render(dj_replay(ops)), "{\"a\":2}")
  // The `/a` slot is closed with the first object and then set again.
  let mut closers = 0
  let mut setters = 0
  for d in ops {
    if d.pointer() == "/a" {
      match d.op {
        Close => closers = closers + 1
        Set => setters = setters + 1
        _ => ()
      }
    }
  }
  assert_eq(closers.to_string() + "/" + setters.to_string(), "1/2")
}

///|
test "delta path is an RFC 6901 pointer" {
  let p = PartialParser::new(options=Options::for_llm())
  p.feed("{\"a/b\":[1,2,{\"c~d\":3}]}")
  let ops = p.drain_deltas()
  let ptrs : Array[String] = []
  for d in ops {
    ptrs.push(d.op.name() + " " + d.pointer())
  }
  let seen = ptrs.join(",")
  // The escaped key and the array index must both appear verbatim.
  assert_true(seen.contains("/a~1b/0"), msg=seen)
  assert_true(seen.contains("/a~1b/2/c~0d"), msg=seen)
  assert_true(seen.contains("close /a~1b/2"), msg=seen)
  assert_true(seen.contains("close /a~1b"), msg=seen)
}

///|
test "delta drain is empty when no input arrived" {
  let p = PartialParser::new(options=Options::for_llm())
  p.feed("[1,2]")
  ignore(p.drain_deltas())
  assert_eq(p.drain_deltas().length(), 0)
  assert_eq(p.drain_deltas().length(), 0)
}

///|
test "drain_deltas requires collect_deltas" {
  let p = PartialParser::new()
  let msg = try {
    ignore(p.drain_deltas())
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("E050"), msg~)
  assert_true(msg.contains("collect_deltas"), msg~)
}

///|
test "collect_deltas rejects incompatible options" {
  let a = try {
    { ..Options::default(), collect_deltas: true, duplicate_keys: KeepFirst, }.validate()
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(a.contains("duplicate_keys"), msg=a)
  let b = try {
    {
      ..Options::default(),
      collect_deltas: true,
      incomplete_number: TrimToValid,
    }.validate()
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(b.contains("incomplete_number"), msg=b)
}

///|
test "FR-16: the callback sees exactly the deltas drain_deltas returns" {
  let text = "{\"a\":1,\"b\":[1,\"x\\ny\"],\"c\":{\"d\":true}}"
  let p = PartialParser::new(options=Options::for_llm())
  let via_drain : Array[String] = []
  for i = 0; i < text.length(); i = i + 1 {
    p.feed(text[i:i + 1].to_owned())
    for d in p.drain_deltas() {
      via_drain.push(d.op.name() + " " + d.pointer())
    }
  }
  ignore(p.finish())
  let q = PartialParser::new(options=Options::for_llm())
  let via_callback : Array[String] = []
  for i = 0; i < text.length(); i = i + 1 {
    q.feed_with(text[i:i + 1].to_owned(), fn(d) {
      via_callback.push(d.op.name() + " " + d.pointer())
    })
  }
  ignore(q.finish())
  assert_true(via_drain.length() > 0, msg="no deltas observed")
  assert_eq(via_callback.join(","), via_drain.join(","))
}

///|
test "FR-16: the byte input callback matches the string input callback" {
  // The same document as UTF-8 bytes, split inside the multibyte sequence.
  let bytes : Bytes = b"{\"a\":[1,2],\"b\":\"caf\xc3\xa9\"}"
  let a = PartialParser::new(options=Options::for_llm())
  let via_bytes : Array[String] = []
  let mut i = 0
  while i < bytes.length() {
    let end = if i + 3 < bytes.length() { i + 3 } else { bytes.length() }
    a.feed_bytes_with(bytes[i:end].to_owned(), fn(d) {
      via_bytes.push(d.op.name() + " " + d.pointer())
    })
    i = end
  }
  ignore(a.finish())
  assert_true(via_bytes.length() > 0, msg="no deltas observed")
  assert_true(via_bytes.contains("set /a/1"), msg=via_bytes.join(","))
  assert_true(via_bytes.contains("set /b"), msg=via_bytes.join(","))
}

// ---------------------------------------------------------------------------
// Q-35 (FR-41): every delta carries the consumed count it was produced at.
// ---------------------------------------------------------------------------

///|
/// The `(op, pointer, at)` triples of the structural deltas of a document fed
/// in chunks of `k` code units (`k = 0` means one chunk). `AppendText` is left
/// out for the reason given on `Delta.at`.
/// units (`k = 0` means one chunk). Also checks that no delta claims to have
/// been produced past the end of the input, which is where the `at` value is
/// still an `Int32` and does not need converting back from text.
fn dj_at_seq(doc : String, k : Int32) -> String raise {
  let opts : Options = { ..Options::default(), collect_deltas: true, }
  let p = PartialParser::new(options=opts)
  let out : Array[String] = []
  let take = fn(ds : Array[Delta]) raise {
    for d in ds {
      assert_true(
        d.at >= 0 && d.at <= doc.length(),
        msg="at out of range: " + d.at.to_string() + " for " + doc,
      )
      // `AppendText` is flushed at drain time, so its count and its `at`
      // belong to the caller's chunking, not to the input: the structural
      // deltas are the ones whose position is a property of the document.
      if !(d.op is AppendText) {
        out.push(d.op.name() + " " + d.pointer() + "@" + d.at.to_string())
      }
    }
  }
  if k <= 0 {
    p.feed(doc)
    take(p.drain_deltas())
  } else {
    let mut i = 0
    while i < doc.length() {
      let j = i + k
      let end = if j < doc.length() { j } else { doc.length() }
      p.feed(slice_units(doc, i, end))
      take(p.drain_deltas())
      i = end
    }
  }
  ignore(p.finish())
  take(p.drain_deltas())
  out.join(",")
}

///|
/// The consumed count is a property of the input, not of the chunking, and it
/// never exceeds the number of code units fed. Before Q-35 the only number a
/// caller had was "how much have I fed so far", which changes with the chunk
/// size and is why batch readiness had to sample a thousand times.
test "delta consumed offset is chunk invariant" {
  // Only the structural deltas: `AppendText` is drained, not produced, so its
  // position is the caller's business rather than the document's.
  for
    doc in [
      "{\"a\":1,\"b\":[1,2,{\"c\":\"xy\"}]}", "{\"q\":\"MoonBit\"}", "{\"a\":{}}",
      "{\"a\":1", "[1,2,3]", "{", "42",
    ] {
    let want = dj_at_seq(doc, 0)
    for k in [1, 2, 3, 5, 8] {
      let got = dj_at_seq(doc, k)
      if got != want {
        println("doc: " + doc + " k=" + k.to_string())
        println("want: " + want)
        println("got:  " + got)
        assert_eq(got, want)
      }
    }
  }
}

///|
test "R019 concatenation lands as AppendText at the merged slot" {
  // The `+` merge (BR-21) changes a value that already landed, so the delta
  // stream has to carry the change too: an `AppendText` at that string's slot.
  // Root, array and object slots all route through `concat_target_path`.
  let cases : Array[(String, String)] = [
    ("\"a\" + \"b\"", ""),
    ("[\"a\" + \"b\"]", "/0"),
    ("{\"k\":\"a\" + \"b\"}", "/k"),
  ]
  for (input, pointer) in cases {
    let p = PartialParser::new(options=Options::for_llm())
    p.feed(input)
    let ops : Array[Delta] = []
    for d in p.drain_deltas() {
      ops.push(d)
    }
    let mut merged = false
    for d in ops {
      if d.op is AppendText && d.pointer() == pointer && d.text == "b" {
        merged = true
      }
    }
    assert_true(merged, msg="no AppendText at `" + pointer + "` for " + input)
    let fin = p.finish()
    for d in p.drain_deltas() {
      ops.push(d)
    }
    assert_eq(
      dj_render(dj_replay(ops)),
      fin.value.stringify(),
      msg="replay after concat for " + input,
    )
  }
}

///|
test "AppendText flushes the string tail at drain time" {
  // A string drained between chunks reports only the growth since the last
  // drain (`delta_str_reported`), and an escape splits `parts` mid-string; the
  // replayed deltas must still reconstruct the whole value.
  let p = PartialParser::new(options=Options::for_llm())
  let ops : Array[Delta] = []
  p.feed("{\"s\":\"abc")
  for d in p.drain_deltas() {
    ops.push(d)
  }
  p.feed("def")
  for d in p.drain_deltas() {
    ops.push(d)
  }
  p.feed("\\nghi\"}")
  for d in p.drain_deltas() {
    ops.push(d)
  }
  let fin = p.finish()
  for d in p.drain_deltas() {
    ops.push(d)
  }
  assert_eq(
    dj_render(dj_replay(ops)),
    fin.value.stringify(),
    msg="tail flush replay",
  )
}

///|
test "drains after every code unit still replay" {
  // A drain taken between any two code units exercises `flush_delta_text`
  // while the scanner is in every token state (idle, in a string, in a
  // pending escape, inside a bare word); the replays must hold everywhere.
  let text = "{\"a\":[1,2,{\"b\":\"x\"}],\"c\":\"y\"}"
  let p = PartialParser::new(options=Options::for_llm())
  let ops : Array[Delta] = []
  for i = 0; i < text.length(); i = i + 1 {
    p.feed(text[i:i + 1].to_owned())
    for d in p.drain_deltas() {
      ops.push(d)
    }
    assert_eq(
      dj_render(dj_replay(ops)),
      dj_render(p.snapshot().value),
      msg="per-unit replay",
    )
  }
  let fin = p.finish()
  for d in p.drain_deltas() {
    ops.push(d)
  }
  assert_eq(
    dj_render(dj_replay(ops)),
    fin.value.stringify(),
    msg="per-unit final replay",
  )
}
