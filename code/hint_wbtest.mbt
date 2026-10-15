// FR-28 — reject as feedback, tested end to end on a real refusal.

///|
/// The hint of a refused input, or a panic marker.
fn hint_of(input : String, opts : Options) -> String {
  let h = try {
    ignore(repair(input, options=opts))
    return "accepted"
  } catch {
    e => RetryHint::of_error(e, input~)
  }
  match h {
    Some(x) => x.to_prompt()
    None => "no-hint"
  }
}

///|
test "a refusal produces a structured hint" {
  let ex = Options::for_execution()
  let h = try {
    ignore(repair("[\"a\" \"b\"]", options=ex))
    None
  } catch {
    e => RetryHint::of_error(e, input="[\"a\" \"b\"]")
  }
  let hint = match h {
    Some(x) => x
    None => {
      assert_true(false, msg="no hint for a refused ambiguous input")
      return
    }
  }
  assert_eq(hint.error_code, "E011")
  assert_eq(hint.repair_code, "R006")
  assert_eq(hint.repair_name, "InsertComma")
  assert_eq(hint.ambiguity.name(), "adjacent_strings")
  assert_eq(hint.position.offset, 5)
  assert_eq(hint.context, "[\"a\" \"b\"]")
  let p = hint.to_prompt()
  assert_true(p.contains("E011"), msg=p)
  assert_true(p.contains("R006 InsertComma"), msg=p)
  assert_true(p.contains("Ambiguity: adjacent_strings"), msg=p)
  assert_true(p.contains("Re-emit the arguments"), msg=p)
  assert_true(p.contains("^"), msg=p)
}

///|
test "hints exist only for refusals a model can fix" {
  let ex = Options::for_execution()
  // An unambiguous input is accepted: no refusal, no hint.
  assert_eq(hint_of("{'a':1}", ex), "accepted")
  // A lossy input is refused for the exactness gate, and the hint says why.
  let lossy = hint_of("{\"a\":\"x}", ex)
  assert_true(lossy.contains("E010"), msg=lossy)
  assert_true(lossy.contains("Ambiguity") == false, msg=lossy)
  // A bare-word refusal names the ambiguity.
  let bare = hint_of("[fast]", ex)
  assert_true(bare.contains("bare_word"), msg=bare)
  // Structural failures are not the model's argument syntax, so no hint.
  let none = try {
    ignore(repair("", options=ex))
    "accepted"
  } catch {
    e =>
      match RetryHint::of_error(e, input="") {
        Some(_) => "hint"
        None => "no-hint"
      }
  }
  assert_eq(none, "no-hint")
}

///|
test "the hint window is bounded and independent of the input length" {
  let long = "{\"a\":[" + "\"x\",".repeat(500) + "\"y\" \"z\"]}"
  let h = try {
    ignore(repair(long, options=Options::for_execution()))
    None
  } catch {
    e => RetryHint::of_error(e, input=long, radius=24)
  }
  match h {
    Some(x) => {
      assert_true(x.context.length() <= 49, msg=x.context.length().to_string())
      assert_true(x.caret >= 0, msg=x.caret.to_string())
      assert_true(x.context.contains("\"y\" \"z\""), msg=x.context)
      // The prompt stays short even for a huge input.
      assert_true(x.to_prompt().length() < 400, msg=x.to_prompt())
    }
    None => assert_true(false, msg="expected a hint")
  }
}

///|
test "MendError::retry_hint is the same hint" {
  let e : MendError = AmbiguousRepair(
    InsertComma,
    { offset: 6, line: 1, column: 7, },
    AdjacentStrings,
  )
  let a = hint_line(e)
  let b = match RetryHint::of_error(e, input="[\"a\" \"b\"]") {
    Some(x) => x.to_string()
    None => ""
  }
  assert_eq(a, b)
  assert_eq(
    a, "E011 R006 InsertComma at 1:7 two adjacent strings may be two elements or one concatenated string",
  )
}

///|
/// `retry_hint` without an input, as a string.
fn hint_line(e : MendError) -> String {
  match e.retry_hint() {
    Some(x) => x.to_string()
    None => ""
  }
}
