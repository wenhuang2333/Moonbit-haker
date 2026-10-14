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
