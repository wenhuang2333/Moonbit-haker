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
