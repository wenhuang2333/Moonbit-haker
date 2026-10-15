// FR-27 — the ambiguity marker and the `for_execution` gate.
//
// The marker exists because the exactness ladder answers "was a value
// invented?" and not "is the reading unique?". `["a" "b"]` invents nothing yet
// reads two ways, so a consumer that is about to execute the value must be
// able to refuse it without falling back to `strict()` (which would also
// refuse a normalised quote).

///|
/// Ambiguity name of the first record, "-" when there is none, "!" on error.
fn amb_of(input : String, opts : Options) -> String {
  let r = repair(input, options=opts) catch { _ => return "!" }
  if r.repairs.length() == 0 || r.repairs[0].ambiguity is Unambiguous {
    "-"
  } else {
    r.repairs[0].ambiguity.name()
  }
}

///|
/// Error code of a repair, or "ok".
fn code_of(input : String, opts : Options) -> String {
  try {
    ignore(repair(input, options=opts))
    "ok"
  } catch {
    e => e.code()
  }
}

///|
/// Full message of a repair, or "" when it succeeds.
fn msg_of(input : String, opts : Options) -> String {
  try {
    ignore(repair(input, options=opts))
    ""
  } catch {
    e => e.to_string()
  }
}

///|
/// Severity of the first record, "none" when there is none, "!" on error.
fn sev_of(input : String) -> String {
  let r = repair(input) catch { _ => return "!" }
  if r.repairs.length() == 0 {
    "none"
  } else {
    match r.repairs[0].severity {
      Info => "Info"
      Warning => "Warning"
    }
  }
}

///|
test "ambiguity marks the concrete second reading" {
  let table = [
    // R006 between two string literals: two elements or one concatenation.
    ("[\"a\" \"b\"]", "adjacent_strings"),
    ("[\"a\" 'b']", "adjacent_strings"),
    // R006 between two numbers, or before a number, has only one reading.
    ("[1 2]", "-"),
    ("[1 \"a\"]", "-"),
    // R019: a `+` between strings.
    ("[\"a\" + \"b\"]", "concat_operator"),
    ("{\"a\": \"x\" + \"y\"}", "concat_operator"),
    // R004 in value position.
    ("[fast]", "bare_word"),
    ("{\"mode\": fast}", "bare_word"),
    // R004 as a member name is a notation fix.
    ("{a:1}", "-"),
    // R016 drops trailing content after a complete root.
    ("{\"a\":1} {\"b\":2}", "trailing_content"),
    ("[1] 2", "trailing_content"),
    // Nothing ambiguous at all.
    ("{'a':1}", "-"),
    ("{\"a\":1,}", "-"),
    ("tru", "-"),
    ("{\"a\":1,\"a\":2}", "-"),
  ]
  for (input, want) in table {
    let got = amb_of(input, Options::default())
    assert_eq(input + " " + want, input + " " + got)
  }
}

///|
test "an ambiguous repair is Info but not transparent" {
  // The point of the marker: `["a" "b"]` is `Cosmetic`, not `Lossy`.
  let r = repair("[\"a\" \"b\"]")
  assert_eq(r.exactness.name(), "cosmetic")
  assert_eq(r.text, "[\"a\",\"b\"]")
  assert_eq(r.ambiguous, true)
  assert_eq(sev_of("[\"a\" \"b\"]"), "Info")
  // A snapshot reports the same flag, so a streaming caller sees it early.
  let p = PartialParser::new()
  p.feed("[\"a\" ")
  assert_eq(p.snapshot().ambiguous, false)
  p.feed("\"b\"]")
  assert_eq(p.snapshot().ambiguous, true)
  assert_eq(p.finish().ambiguous, true)
}

///|
test "reject_ambiguous raises E011 and is off by default" {
  assert_eq(amb_of("[\"a\" \"b\"]", Options::default()), "adjacent_strings")
  let strict : Options = { ..Options::default(), reject_ambiguous: true, }
  let msg = msg_of("[\"a\" \"b\"]", strict)
  assert_true(msg.contains("E011"), msg~)
  assert_true(msg.contains("R006"), msg~)
  assert_true(msg.contains("two adjacent strings"), msg~)
  // An unambiguous repair of the same code passes the gate.
  assert_eq(amb_of("[1 2]", strict), "-")
  // So does an unambiguous notation fix.
  assert_eq(amb_of("{'a':1}", strict), "-")
  assert_eq(amb_of("{\"a\":1} {\"b\":2}", strict), "!")
}

///|
test "for_execution rejects only what it must" {
  let ex = Options::for_execution()
  let accepted = [
    "{\"a\":1}", "[1,2,3,]", "{'a':1}", "[1 2]", "{\"a\":1,\"b\":2}",
  ]
  for input in accepted {
    assert_eq(input + " ok", input + " " + code_of(input, ex))
  }
  let refused = [
    ("[\"a\" \"b\"]", "E011"),
    ("[\"a\" + \"b\"]", "E011"),
    ("[fast]", "E011"),
    ("{\"a\":1} {\"b\":2}", "E011"),
    ("{\"a\":\"x}", "E010"),
    ("tru", "E010"),
    ("{\"a\":1", "E010"),
  ]
  for (input, want) in refused {
    assert_eq(input + " " + want, input + " " + code_of(input, ex))
  }
}

///|
test "the exactness ladder is unchanged by the ambiguity marker" {
  // Ambiguity is orthogonal: it never moves a result up the ladder.
  let inputs = [
    "[\"a\" \"b\"]", "[\"a\"+\"b\"]", "[fast]", "{\"a\":1} 2", "{\"a\":1}",
  ]
  for input in inputs {
    try {
      let r = repair(input)
      assert_eq(
        input + " " + exactness_of(r.repairs).name(),
        input + " " + r.exactness.name(),
      )
      assert_eq(
        input + " " + has_ambiguity(r.repairs).to_string(),
        input + " " + r.ambiguous.to_string(),
      )
    } catch {
      _ => ()
    }
  }
}
