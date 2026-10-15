// FR-17: the exactness label of a result (I-1).
//
// `Exactness` is the highest risk among the repair records, and
// `Options::max_loss` turns a result that is riskier than the caller accepts
// into `E010` before it can be executed.

///|
/// Exactness plus the flattened records of one run.
struct ExOutcome {
  exactness : Exactness
  recs : String
  err : String
}

///|
/// Run `repair` and keep the exactness.
fn ex_run(input : String, opts : Options) -> ExOutcome {
  try {
    let r = repair(input, options=opts)
    { exactness: r.exactness, recs: recs_text(r.repairs), err: "", }
  } catch {
    e => { exactness: Exact, recs: "", err: err_text(e), }
  }
}

///|
/// A repair code from its stable string form.
fn ex_code(s : String) -> RepairCode? {
  let table : Array[(String, RepairCode)] = [
    ("R001", StripFence),
    ("R002", StripComment),
    ("R003", NormalizeQuote),
    ("R004", QuoteBareWord),
    ("R005", RemoveExtraComma),
    ("R006", InsertComma),
    ("R007", InsertColon),
    ("R008", FillNull),
    ("R009", CloseContainer),
    ("R010", CloseString),
    ("R011", FixNumber),
    ("R012", ConvertLiteral),
    ("R013", EscapeControl),
    ("R014", FixEscape),
    ("R015", MismatchedCloser),
    ("R016", DropUnexpected),
    ("R017", DropExtraCloser),
    ("R018", MergeDuplicateKey),
    ("R019", ConcatStrings),
    ("R020", DropEllipsis),
    ("R021", SkipProse),
    ("R022", NormalizeLiteral),
  ]
  for (name, code) in table {
    if name == s {
      return Some(code)
    }
  }
  None
}

///|
/// Exactness implied by a `R005@6,R006@7` string, using the static severity of
/// each code. `QuoteBareWord` is the one code whose severity depends on its
/// slot, so a value-position occurrence is expected to be riskier.
fn ex_from_recs(recs : String) -> Exactness {
  if recs == "" {
    return Exact
  }
  let mut lossy = false
  for item in recs.split(",") {
    let cut = item.find("@")
    let name = match cut {
      Some(i) => item[0:i].to_owned()
      None => item.to_owned()
    }
    match ex_code(name) {
      Some(c) => if c.severity() is Warning { lossy = true }
      None => ()
    }
  }
  if lossy {
    Lossy
  } else {
    Cosmetic
  }
}

///|
test "exactness of hand written cases" {
  let table : Array[(String, Options, String)] = [
    ("{\"a\":1}", Options::default(), "exact"),
    ("{\"a\":1}   ", Options::default(), "exact"),
    ("{\"a\":\"x\"}", Options::default(), "exact"),
    ("{'a':1}", Options::default(), "cosmetic"),
    ("{a:1}", Options::default(), "cosmetic"),
    ("{\"a\" 1}", Options::default(), "cosmetic"),
    ("[1 2]", Options::default(), "cosmetic"),
    ("[1,,2]", Options::default(), "cosmetic"),
    ("```json\n{\"a\":1}\n```", Options::default(), "cosmetic"),
    ("{\"a\":1, // c\n}", Options::default(), "cosmetic"),
    ("[\"a\" + \"b\"]", Options::default(), "cosmetic"),
    // A bare word in value position is a guess, not a notation fix.
    ("{\"mode\": fast}", Options::default(), "lossy"),
    ("[fast]", Options::default(), "lossy"),
    ("{\"a\":1", Options::default(), "lossy"),
    ("{\"a\":\"x}", Options::default(), "lossy"),
    ("tru", Options::default(), "lossy"),
    ("[1,2,3,]", Options::default(), "cosmetic"),
    ("{\"a\":1,\"a\":2}", Options::default(), "lossy"),
  ]
  for (input, opts, want) in table {
    let o = ex_run(input, opts)
    assert_eq(
      input + " -> " + o.recs + " " + o.exactness.name(),
      input + " -> " + o.recs + " " + want,
    )
  }
}

///|
test "exactness is the maximum risk among the records" {
  let inputs = tc_valid_docs(8181L, 120) + tc_fuzz_inputs(1919L, 120)
  for input in inputs {
    try {
      let r = repair(input)
      assert_eq(
        input + " " + recs_text(r.repairs),
        r.exactness.name() + "|" + exactness_of(r.repairs).name(),
      )
    } catch {
      _ => ()
    }
  }
}

///|
test "every golden case carries the exactness its records imply" {
  for c in cases_a() + cases_b() {
    // A case that switches record collection off cannot state an expectation
    // this way; it is covered by "exactness ignores whether records are
    // collected" instead.
    if !c.opts.collect_repairs {
      continue
    }
    let o = ex_run(c.input, c.opts)
    if o.err == "" {
      let want = ex_from_recs(c.recs)
      let ok = o.exactness == want ||
        // The only documented divergence: a value-position bare word is
        // `Warning`, so the result is one level riskier than the static table
        // says.
        (o.exactness is Lossy && want is Cosmetic && c.recs.contains("R004"))
      if !ok {
        assert_eq(
          c.id + " exactness " + c.recs,
          c.id + " exactness " + want.name() + " got " + o.exactness.name(),
        )
      }
    }
  }
}

///|
test "max_loss gates the result before it can be executed" {
  // `Cosmetic` accepts notation repairs ...
  let ex : Options = Options::for_execution()
  assert_eq(ex_run("{'a':1}", ex).err, "")
  assert_eq(ex_run("[1,,2]", ex).err, "")
  // ... and rejects anything invented or dropped.
  assert_true(
    ex_run("{\"mode\": fast}", ex).err.contains("E010"),
    msg=ex_run("{\"mode\": fast}", ex).err,
  )
  assert_true(
    ex_run("{\"a\":\"x}", ex).err.contains("E010"),
    msg=ex_run("{\"a\":\"x}", ex).err,
  )
  assert_true(ex_run("tru", ex).err.contains("E010"), msg=ex_run("tru", ex).err)
  // The message names both levels, so the caller can act on it.
  let msg = try {
    ignore(repair("{\"a\":\"x}", options=ex))
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("lossy"), msg~)
  assert_true(msg.contains("cosmetic"), msg~)
  // `Exact` accepts only an input that needed no repair at all.
  let ex2 : Options = { ..Options::default(), max_loss: Exact, }
  assert_eq(ex_run("{\"a\":1}", ex2).err, "")
  assert_true(
    ex_run("{'a':1}", ex2).err.contains("E010"),
    msg=ex_run("{'a':1}", ex2).err,
  )
  // The default never gates.
  assert_eq(ex_run("{\"a\":1", Options::default()).err, "")
  assert_eq(ex_run("{\"a\":1", Options::default()).exactness.name(), "lossy")
}

///|
test "presets are the documented profiles" {
  let l = Options::lenient()
  assert_eq(l.mode is Lenient, true)
  assert_eq(l.max_loss.name(), "lossy")
  assert_eq(l.collect_deltas, false)
  let s = Options::strict()
  assert_eq(s.mode is Strict, true)
  assert_eq(s.max_loss.name(), "lossy")
  let e = Options::for_execution()
  assert_eq(e.mode is Lenient, true)
  assert_eq(e.max_loss.name(), "cosmetic")
  let f = Options::for_llm()
  assert_eq(f.collect_deltas, true)
  assert_eq(f.max_loss.name(), "lossy")
  // Every preset must pass validation.
  l.validate()
  s.validate()
  e.validate()
  f.validate()
}

///|
test "exactness is carried by snapshots and one shot results" {
  let p = PartialParser::new()
  p.feed("{\"a\":1,")
  assert_eq(p.snapshot().exactness.name(), "exact")
  p.feed("\"b\":")
  assert_eq(p.snapshot().exactness.name(), "exact")
  p.feed("fast}")
  assert_eq(p.snapshot().exactness.name(), "lossy")
  let fin = p.finish()
  assert_eq(fin.exactness.name(), "lossy")
  assert_eq(parse("{\"a\":1}").exactness.name(), "exact")
  assert_eq(parse("{'a':1}").exactness.name(), "cosmetic")
}

///|
test "exactness ignores whether records are collected" {
  let quiet : Options = { ..Options::default(), collect_repairs: false, }
  let o = ex_run("{\"a\":1", quiet)
  assert_eq(o.recs, "")
  assert_eq(o.exactness.name(), "lossy")
  let tiny : Options = { ..Options::default(), max_repairs: 1, }
  let o2 = ex_run("[1 2 3 4 5]", tiny)
  assert_eq(o2.exactness.name(), "cosmetic")
  assert_eq(o2.recs, "R006@3")
}

///|
test "snapshot_copy is independent of the parser" {
  let p = PartialParser::new()
  p.feed("{\"a\":[1,2]}")
  let snap = p.snapshot()
  let copy = p.snapshot_copy()
  // Mutating the copy must not disturb the parser or the shared snapshot.
  match copy.value {
    Some(Json::Object(m)) =>
      match m.get("a") {
        Some(Json::Array(a)) => a.push(Json::number(99.0))
        _ => ()
      }
    _ => ()
  }
  assert_eq(snap.value.unwrap().stringify(), "{\"a\":[1,2]}")
  assert_eq(copy.value.unwrap().stringify(), "{\"a\":[1,2,99]}")
  assert_eq(p.snapshot().value.unwrap().stringify(), "{\"a\":[1,2]}")
}
