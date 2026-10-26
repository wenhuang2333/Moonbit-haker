// Option and byte-input coverage (TC-O / TC-S-UTF8): every policy enum must
// change behaviour in the documented way. These cases complement the golden
// suite, which mostly runs with default options.

///|
fn opt_repair(input : String, opts : Options) -> RepairResult raise MendError {
  repair(input, options=opts)
}

///|
test "TC-O-01 duplicate key policy" {
  let input = "{\"a\":1,\"a\":2}"
  // default: keep last, record R018
  let r = opt_repair(input, Options::default())
  assert_eq(r.text, "{\"a\":2}")
  assert_eq(r.repairs[0].code == MergeDuplicateKey, true)
  // keep first
  let r2 = opt_repair(input, {
    ..Options::default(),
    duplicate_keys: KeepFirst,
  })
  assert_eq(r2.text, "{\"a\":1}")
  // as error: E010 with the same code
  let mut saw = false
  try {
    let _ = opt_repair(input, { ..Options::default(), duplicate_keys: AsError, })
  } catch {
    StrictViolation(code, _, _) => saw = code is MergeDuplicateKey
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-02 non finite policy" {
  let input = "{\"a\":NaN}"
  assert_eq(opt_repair(input, Options::default()).text, "{\"a\":null}")
  assert_eq(
    opt_repair(input, { ..Options::default(), non_finite: AsString, }).text,
    "{\"a\":\"NaN\"}",
  )
  let mut saw = false
  try {
    let _ = opt_repair(input, { ..Options::default(), non_finite: AsError, })
  } catch {
    StrictViolation(code, _, _) => saw = code is ConvertLiteral
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-03 multi root policy" {
  let input = "{\"a\":1} {\"b\":2}"
  assert_eq(opt_repair(input, Options::default()).text, "{\"a\":1}")
  assert_eq(
    opt_repair(input, { ..Options::default(), multi_root: AsArray, }).text,
    "[{\"a\":1},{\"b\":2}]",
  )
  let mut saw = false
  try {
    let _ = opt_repair(input, { ..Options::default(), multi_root: AsError, })
  } catch {
    StrictViolation(code, _, _) => saw = code is DropUnexpected
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-04 rule switches turn one code into E010" {
  let input = "{\"a\":1,}"
  // RuleSet is immutable: disable/enable return a modified copy
  let all = RuleSet::all()
  let off = all.disable(RemoveExtraComma)
  assert_eq(all.is_enabled(RemoveExtraComma), true)
  assert_eq(off.is_enabled(RemoveExtraComma), false)
  assert_eq(off.enable(RemoveExtraComma).is_enabled(RemoveExtraComma), true)
  // every other rule stays enabled
  assert_eq(off.is_enabled(InsertComma), true)
  // disabling the rule that this input needs makes the call fail
  let mut saw = false
  try {
    let _ = opt_repair(input, { ..Options::default(), rules: off, })
  } catch {
    StrictViolation(code, _, _) => saw = code is RemoveExtraComma
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-05 collect_repairs does not hide strict violations" {
  let input = "{\"a\":1,}"
  let quiet = opt_repair(input, {
    ..Options::default(),
    collect_repairs: false,
  })
  assert_eq(quiet.text, "{\"a\":1}")
  assert_eq(quiet.repairs.length(), 0)
  let mut saw = false
  try {
    let _ = opt_repair(input, {
      ..Options::default(),
      collect_repairs: false,
      mode: Strict,
    })
  } catch {
    StrictViolation(_, _, _) => saw = true
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-06 fence stripping can be turned off" {
  let input = "```json\n{\"a\":1}\n```"
  assert_eq(opt_repair(input, Options::default()).text, "{\"a\":1}")
  // with stripping off the fence is not a JSON value at all
  let mut saw = false
  try {
    let _ = opt_repair(input, { ..Options::default(), strip_fence: false, })
  } catch {
    NoJsonFound(_) => saw = true
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-07 snapshot policies for unfinished numbers and keys" {
  let p = PartialParser::new(options={
    ..Options::default(),
    incomplete_number: TrimToValid,
  })
  p.feed("[1,2")
  assert_eq(p.snapshot().value.unwrap().stringify(), "[1,2]")
  let p2 = PartialParser::new(options={
    ..Options::default(),
    pending_key: NullKey,
  })
  p2.feed("{\"a\":")
  assert_eq(p2.snapshot().value.unwrap().stringify(), "{\"a\":null}")
  // the final result is unaffected by both snapshot policies
  let p3 = PartialParser::new(options={
    ..Options::default(),
    incomplete_number: TrimToValid,
  })
  p3.feed("[1,2")
  assert_eq(p3.finish().text, "[1,2]")
}

///|
test "TC-S-UTF8-01 feed_bytes matches feed for multibyte input" {
  let text = "{\"键\":\"值🙂\",\"n\":1}"
  // the same text as UTF-8 bytes, split below in the middle of a sequence
  let bytes : Bytes = b"{\"\xe9\x94\xae\":\"\xe5\x80\xbc\xf0\x9f\x99\x82\",\"n\":1}"
  // split the byte stream in the middle of a multibyte sequence on purpose
  let p = PartialParser::new()
  let mut i = 0
  while i < bytes.length() {
    let end = if i + 3 < bytes.length() { i + 3 } else { bytes.length() }
    p.feed_bytes(bytes[i:end].to_owned())
    i = end
  }
  let one = repair(text)
  let fin = p.finish()
  assert_eq(fin.text, one.text)
  assert_eq(fin.completeness == Complete, true)
  // The byte path batches plain ASCII runs; a long string fed in odd-sized
  // byte chunks must still match the one-shot string path.
  let sb = StringBuilder()
  sb.write_string("{\"s\":\"")
  for i = 0; i < 4000; i = i + 1 {
    sb.write_char('a')
  }
  sb.write_string("\"}")
  let long = sb.to_string()
  let long_bytes = @utf8.encode(long)
  let q = PartialParser::new()
  let mut j = 0
  while j < long_bytes.length() {
    let end = if j + 7 < long_bytes.length() {
      j + 7
    } else {
      long_bytes.length()
    }
    q.feed_bytes(long_bytes[j:end].to_owned())
    j = end
  }
  assert_eq(q.finish().text, repair(long).text)
}

///|
/// Feed `bytes` in `chunk` sized pieces and return the finished text.
fn feed_bytes_chunked(bytes : Bytes, chunk : Int32) -> String raise {
  let p = PartialParser::new()
  let mut i = 0
  while i < bytes.length() {
    let end = if i + chunk < bytes.length() {
      i + chunk
    } else {
      bytes.length()
    }
    p.feed_bytes(bytes[i:end].to_owned())
    i = end
  }
  p.finish().text
}

///|
/// A CJK/emoji document whose one string token is long enough that the byte
/// fast path has to batch complete multi-byte sequences rather than fall back
/// to one `push_char` per byte.
fn utf8_doc(repeat : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"文本\":\"")
  for _i = 0; _i < repeat; _i = _i + 1 {
    sb.write_string("中文内容🙂")
  }
  sb.write_string("\"}")
  sb.to_string()
}

///|
test "TC-S-UTF8-03 byte fast path batches multibyte runs" {
  // The byte entry point is the one the CLI and both language wrappers use, so
  // its cost has to match the string entry point's on text that is not ASCII.
  // Before the run batching, every non-ASCII byte fell through to `push_char`
  // and allocated one `String` per character: 25x slower than `feed` on the
  // same document, and the gap grew with the length of the text.
  let text = utf8_doc(500)
  let bytes = @utf8.encode(text)
  let want = repair(text).text
  for chunk in [1, 2, 3, 5, 7, 64, 4096] {
    assert_eq(
      feed_bytes_chunked(bytes, chunk),
      want,
      msg="byte path chunk " + chunk.to_string(),
    )
  }
  // A supplementary code point is one four-byte sequence but two code units;
  // the run must advance the position by units, not bytes, or every later
  // offset (and `max_input_len`) would be wrong.
  let emoji = "{\"e\":\"" + "🙂".repeat(300) + "\"}"
  assert_eq(
    feed_bytes_chunked(@utf8.encode(emoji), 6),
    repair(emoji).text,
    msg="supplementary code points",
  )
  // Curly quotes close a string too, and they are three-byte sequences: a run
  // must not swallow one, or the string would never end.
  let curly = "{\u{201C}key\u{201D}:\u{201C}" + "值".repeat(200) + "\u{201D}}"
  assert_eq(
    feed_bytes_chunked(@utf8.encode(curly), 4),
    repair(curly).text,
    msg="curly quote terminator",
  )
}

///|
test "TC-S-UTF8-03b byte run batching allocates per run, not per character" {
  // The observable-result tests above cannot see the defect this change fixes:
  // before it, every non-ASCII byte went through `push_char`, which allocates
  // one `String` per character and stores it in `parts`. The text came out the
  // same; the cost was 5.4x (native) / 7.1x (JS) and grew with the text length.
  //
  // Counting `parts` is the deterministic form of that statement -- no clock,
  // so it cannot flake -- and it fails the moment the batching is undone. The
  // string is left open on purpose: `finish_string` clears `parts` by moving
  // them into the value, so only an unfinished token shows the accumulation.
  let units = 200000
  let prefix = "{\"文本\":\""
  let body = "中文内容".repeat(units / 4)
  let open_doc = prefix + body
  let p = PartialParser::new()
  p.feed_bytes(@utf8.encode(open_doc))
  // A document cannot be abandoned mid-token, but the parser can be inspected
  // first: `parts` is the buffer the scanner has accumulated so far.
  let parts = p.engine.parts.length()
  assert_eq(
    parts <= 4,
    true,
    msg="expected one part per run, got " + parts.to_string(),
  )
  // The same text through the string entry point is one run as well, so the
  // two entry points now cost the same per code unit.
  let q = PartialParser::new()
  q.feed(open_doc)
  assert_eq(q.engine.parts.length(), parts)
}

///|
test "TC-S-UTF8-04 byte run batching keeps limits in code units" {
  // `max_input_len` counts UTF-16 code units, not bytes. A CJK document is
  // three bytes per unit, so a byte-counted limit would fire two thirds early.
  let text = "\"中文内容中文内容\""
  let small : Options = { ..Options::default(), max_input_len: 5, }
  let from_str = attempt(text, small)
  let p = PartialParser::new(options=small)
  let err = try {
    p.feed_bytes(@utf8.encode(text))
    ""
  } catch {
    e => err_text(e)
  }
  assert_eq(from_str.err, "E021(5,@5)")
  assert_eq(err, from_str.err, msg="byte path limit offset")
  // A supplementary code point straddling the limit is two steps: the first
  // fits, the second raises at the same offset the string path reports.
  let emoji = "\"a🙂🙂🙂\""
  let p2 = PartialParser::new(options=small)
  let err2 = try {
    p2.feed_bytes(@utf8.encode(emoji))
    ""
  } catch {
    e => err_text(e)
  }
  assert_eq(err2, attempt(emoji, small).err, msg="surrogate pair limit offset")
}

///|
test "TC-S-UTF8-05 invalid sequences still raise E040 from the run scanner" {
  // The run scanner must reject exactly what `feed_byte` rejects, so that the
  // error is raised by the one validator that owns it, with its own offset.
  let cases : Array[Bytes] = [
    b"{\"s\":\"a\xc0\x80\"}", // overlong encoding of NUL
     b"{\"s\":\"a\xf5\x80\x80\x80\"}", // lead byte out of range
     b"{\"s\":\"a\x80\"}", // lone continuation byte
     b"{\"s\":\"a\xe4\xb8\"}", // truncated at end of input
  ]
  for bs in cases {
    let p = PartialParser::new()
    let err = try {
      p.feed_bytes(bs)
      try {
        ignore(p.finish())
        ""
      } catch {
        e => err_text(e)
      }
    } catch {
      e => err_text(e)
    }
    assert_eq(err[:4] == "E040", true, msg="expected E040, got " + err)
  }
  // A surrogate encoded in UTF-8 is *not* rejected: it decodes to a lone half
  // pair, which R014 repairs to U+FFFD and records as `FixEscape`. That is the
  // behaviour of `feed_byte`, and the batcher must not change it — it declines
  // the sequence (`is_plain_str_cu` rejects surrogates) and lets the byte path
  // produce the same record.
  let lone : Bytes = b"{\"s\":\"a\xed\xa0\x80\"}"
  let p = PartialParser::new()
  p.feed_bytes(lone)
  let fin = p.finish()
  assert_eq(fin.text, "{\"s\":\"a\ufffd\"}")
  assert_eq(fin.repairs.length(), 1, msg="R014 is recorded once")
  // The same document through the string entry point, for comparison: the
  // string path receives the decoded code unit directly.
  assert_eq(fin.text, repair("{\"s\":\"a\\uD800\"}").text)
}

///|
test "TC-S-UTF8-06 byte batching does not change the delta stream" {
  // Batching changes how many `parts` entries a string has, so the only thing
  // that may stay the same is the observable result: the replay of the deltas
  // must still equal the snapshot, for byte chunk sizes that cut sequences.
  let text = utf8_doc(40)
  let bytes = @utf8.encode(text)
  let base = PartialParser::new(options=Options::for_llm())
  base.feed(text)
  let want = base.snapshot().value
  for chunk in [1, 3, 5, 17] {
    let p = PartialParser::new(options=Options::for_llm())
    let ops : Array[Delta] = []
    let mut i = 0
    while i < bytes.length() {
      let end = if i + chunk < bytes.length() {
        i + chunk
      } else {
        bytes.length()
      }
      p.feed_bytes(bytes[i:end].to_owned())
      for d in p.drain_deltas() {
        ops.push(d)
      }
      i = end
    }
    ignore(p.finish())
    assert_eq(
      dj_render(dj_replay(ops)),
      dj_render(want),
      msg="replay after byte chunk " + chunk.to_string(),
    )
  }
}

///|
test "TC-S-UTF8-02 invalid bytes raise E040" {
  let bad : Bytes = b"\x7b\x22\xff\x22\x7d"
  let p = PartialParser::new()
  let mut saw = false
  p.feed_bytes(bad) catch {
    InvalidUtf8(_) => saw = true
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-08 max_repairs caps the records and sets the flag" {
  let input = "['a','b','c','d','e']"
  let full = repair(input)
  assert_eq(full.repairs.length(), 5)
  assert_eq(full.repairs_truncated, false)
  let capped = repair(input, options={ ..Options::default(), max_repairs: 2, })
  assert_eq(capped.repairs.length(), 2)
  assert_eq(capped.repairs_truncated, true)
  // the text is unaffected by the record cap
  assert_eq(capped.text, full.text)
  // collect_repairs=false never sets the flag
  let quiet = repair(input, options={
    ..Options::default(),
    collect_repairs: false,
  })
  assert_eq(quiet.repairs.length(), 0)
  assert_eq(quiet.repairs_truncated, false)
}

///|
test "TC-O-09 max_repairs must be positive" {
  let mut saw = false
  try {
    let _ = PartialParser::new(options={ ..Options::default(), max_repairs: 0, })
    ()
  } catch {
    InvalidOption(_) => saw = true
    _ => ()
  }
  assert_eq(saw, true)
}

///|
test "TC-O-10 repeated snapshots are stable and stay correct after finish" {
  let p = PartialParser::new()
  p.feed("{\"a\":[1,2")
  let s1 = p.snapshot()
  let s2 = p.snapshot()
  assert_eq(s2.completeness == Partial, true)
  assert_eq(s2.open_path.length(), s1.open_path.length())
  // feeding invalidates the cache
  p.feed("]}")
  let s3 = p.snapshot()
  assert_eq(s3.completeness == Complete, true)
  let fin = p.finish()
  assert_eq(fin.text, "{\"a\":[1,2]}")
  assert_eq(fin.repairs_truncated, false)
}
