// The 1.5 regression suite.
//
// Every case here is a defect that shipped in 1.4.x and was found by reading
// the code rather than by running it. They are grouped in one file so that
// the next reader can see, in one place, what the review found and what now
// holds.
//
// The order is the order of severity: the two that let a wrong value through
// first, then the ones that refuse wrongly, then the ones that crash.

///|
/// A plan for `input` under the default options.
fn reg_analyze(input : String) -> RepairPlan {
  analyze(input, options=Options::default())
}

///|
/// A plan for `input` under one profile.
fn reg_analyze_with(input : String, opts : Options) -> RepairPlan {
  analyze(input, options=opts)
}

// ---------------------------------------------------------------------------
// R018 must compare the numbers themselves, not their Double approximation.
// ---------------------------------------------------------------------------

///|
test "TC-R-01 two integers that share a Double are two different values" {
  // 9007199254740993 and 9007199254740992 are adjacent integers beyond
  // 2^53. As `Double`s they are the same number, so the old comparison
  // called them equal, recorded the merge as harmless (`Info`), and the gate
  // reported `executable: true` for a value it had silently changed.
  let plan = reg_analyze("{\"id\":9007199254740993,\"id\":9007199254740992}")
  assert_true(plan.exactness == Lossy, msg="exactness")
  assert_true(plan.decision == LossyRepair, msg="decision")
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.repairs.length(), 1)
  assert_eq(plan.repairs[0].rule, "R018")
  assert_true(plan.repairs[0].severity == Warning, msg="severity")
}

///|
test "TC-R-02 two spellings of one number are one value" {
  // The other direction matters too: `1` and `1.0` denote the same number,
  // so merging them loses nothing and must not be reported as a loss.
  for pair in [("1", "1.0"), ("100", "1e2"), ("0.5", "5e-1"), ("-0", "0")] {
    let (a, b) = pair
    let plan = reg_analyze("{\"v\":" + a + ",\"v\":" + b + "}")
    assert_true(
      plan.repairs[0].severity == Info,
      msg="merging " + a + " and " + b + " must not be a loss",
    )
    assert_true(plan.exactness == Cosmetic, msg="exactness")
    assert_eq(plan.is_executable(), true)
  }
}

///|
test "TC-R-03 equal duplicates stay harmless" {
  let plan = reg_analyze("{\"a\":[1,2],\"a\":[1,2]}")
  assert_eq(plan.repairs[0].rule, "R018")
  assert_true(plan.repairs[0].severity == Info, msg="severity")
  assert_true(plan.exactness == Cosmetic, msg="exactness")
}

///|
test "TC-R-04 different values still merge as a loss" {
  let plan = reg_analyze("{\"a\":1,\"a\":2}")
  assert_true(plan.repairs[0].severity == Warning, msg="severity")
  assert_true(plan.exactness == Lossy, msg="exactness")
}

// ---------------------------------------------------------------------------
// The rule table must be sized from the enum and must fail closed.
// ---------------------------------------------------------------------------

///|
test "TC-R-05 the rule table has a slot for every repair code" {
  // The table used to be a literal 22, which left `R022 NormalizeLiteral`
  // -- the code added in the same release -- outside it. The table is now
  // sized from `RepairCode::count()`, and this is the assertion that keeps
  // the two together when a 23rd code appears.
  assert_eq(RuleSet::all().flags.length(), RepairCode::count() + 1)
}

///|
test "TC-R-06 every repair code can be switched off" {
  // `disable` used to be a silent no-op for a code with no slot, so a caller
  // believed a rule was off when it was not.
  let all = RuleSet::all()
  let off = all.disable(NormalizeLiteral)
  assert_eq(off.is_enabled(NormalizeLiteral), false)
  assert_eq(off.enable(NormalizeLiteral).is_enabled(NormalizeLiteral), true)
  // The rule that fires on a re-cased literal is now really off.
  let mut saw = false
  try {
    let _ = repair("[True]", options={ ..Options::default(), rules: off, })
  } catch {
    StrictViolation(code, _, _) => saw = code is NormalizeLiteral
    _ => ()
  }
  assert_eq(saw, true)
}

// ---------------------------------------------------------------------------
// A refusal must carry the sentence to send back to the model, and no value.
// ---------------------------------------------------------------------------

///|
test "TC-R-07 a refusal carries a retry prompt" {
  // `plan_of_final` set `retry_hint: None` for an accepted result, so a plan
  // that was accepted but not executable serialised as `"retry": null` --
  // a refusal with no prompt, while the tool description told the caller to
  // send `retry.prompt` back to the model. Under `permissive` a lossy repair
  // is accepted (nothing was refused) and still not executable, which is
  // exactly the case that produced the empty retry.
  let plan = reg_analyze("{\"a\":1,\"a\":2}")
  assert_true(plan.decision == LossyRepair, msg="decision")
  assert_eq(plan.is_executable(), false)
  let json = plan.to_json()
  assert_true(json.contains("\"retry\":{"), msg=json)
  assert_true(json.contains("\"prompt\":"), msg=json)
  // A refusal under `strict` takes the other path -- `plan_of_error` with a
  // hint -- and must also carry a prompt.
  let strict_plan = analyze("{\"a\":1,}", options=Options::strict())
  assert_eq(strict_plan.is_executable(), false)
  assert_true(
    strict_plan.to_json().contains("\"prompt\":"),
    msg=strict_plan.to_json(),
  )
}

///|
test "TC-R-08 a value that fails its declaration is refused without a value" {
  let plan = analyze(
    "{\"a\":1}",
    options=Options::default(),
    schema=Schema::parse("{!a:string}"),
  )
  assert_true(plan.decision == Invalid, msg="decision")
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.value, None)
  assert_eq(plan.error_code, "E070")
  let json = plan.to_json()
  assert_true(json.contains("\"value\":null"), msg=json)
  assert_true(json.contains("\"retry\":{"), msg=json)
  assert_true(json.contains("E070"), msg=json)
}

///|
test "TC-R-09 an executable plan keeps its value" {
  let plan = reg_analyze("{\"a\":1}")
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.value is Some(_), true)
  let json = plan.to_json()
  assert_true(json.contains("\"value\":{\"a\":1}"), msg=json)
  assert_true(json.contains("\"retry\":null"), msg=json)
}

// ---------------------------------------------------------------------------
// The agent profile must be the agent profile, protocol included.
// ---------------------------------------------------------------------------

///|
test "TC-R-10 the agent profile skips prose" {
  // `Options::for_agent()` has always skipped prose, because a model in a
  // chat channel writes a sentence before the arguments. The MCP gate
  // selects its profile *by name*, and the name used to apply the safety
  // knobs only -- so the flagship tool refused the most common shape of
  // model output.
  let opts = Options::for_agent()
  assert_eq(opts.skip_prose, true)
  let plan = reg_analyze_with("Here are the args:\n{\"a\":1}", opts)
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.value is Some(_), true)
}

///|
test "TC-R-11 the agent profile by name is the agent profile" {
  let by_name = Options::default().with_profile(SafetyPolicy::for_agent())
  let preset = Options::for_agent()
  assert_eq(by_name.skip_prose, preset.skip_prose)
  assert_true(by_name.max_loss == preset.max_loss, msg="max_loss")
  assert_eq(by_name.reject_ambiguous, preset.reject_ambiguous)
  assert_eq(by_name.max_depth, preset.max_depth)
  assert_eq(by_name.max_input_len, preset.max_input_len)
  assert_true(by_name.mode == preset.mode, msg="mode")
  assert_true(
    by_name.duplicate_keys == preset.duplicate_keys,
    msg="duplicate_keys",
  )
}

///|
test "TC-R-12 the other profiles do not skip prose" {
  // Only the agent profile is a chat channel. `execution` is the policy
  // behind a host that executes without a human, and it must still refuse a
  // document whose beginning is not the value.
  for
    policy in [
      SafetyPolicy::permissive(),
      SafetyPolicy::interactive(),
      SafetyPolicy::for_execution(),
      SafetyPolicy::strict(),
    ] {
    let opts = Options::default().with_profile(policy)
    assert_eq(
      opts.skip_prose,
      false,
      msg="profile " + policy.name() + " must not skip prose",
    )
  }
}

///|
test "TC-R-13 the agent profile refuses a lossy repair" {
  // Skipping prose must not soften the profile: the agent profile is the
  // execution profile plus the chat-channel protocol.
  let opts = Options::for_agent()
  let plan = reg_analyze_with("{\"a\":1,\"a\":2}", opts)
  assert_eq(plan.is_executable(), false)
  assert_true(plan.decision == LossyRepair, msg="decision")
}

// ---------------------------------------------------------------------------
// Recursion must be bounded: a declaration is external input.
// ---------------------------------------------------------------------------

///|
test "TC-R-14 a deep declaration is refused, not crashed" {
  let deep = "[".repeat(400) + "]".repeat(400)
  let mut code = ""
  try {
    let _ = Schema::parse(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-15 a deep JSON Schema object is refused, not crashed" {
  let deep = "{\"type\":\"array\",\"items\":".repeat(300) +
    "{\"type\":\"string\"}" +
    "}".repeat(300)
  let mut code = ""
  try {
    let _ = Schema::parse_json_schema(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-16 a deep value no longer exhausts the stack" {
  // This is the defect the whole depth redesign is about. `max_depth` used to
  // be capped at 512 because four walks were recursive and the wasm stack
  // gives out between 896 and 1024 frames; a caller could tighten the limit
  // but never loosen it. Every walk is iterative now, so a deep value parses,
  // renders, compares and copies without touching the native stack.
  let depth = 5000
  let doc = "[".repeat(depth) + "1" + "]".repeat(depth)
  let plan = analyze(doc, options={ ..Options::default(), max_depth: 100000, })
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.text.length(), depth * 2 + 1)
}

///|
test "TC-R-17 max_depth above the ceiling is an option error" {
  // The ceiling still exists -- a typo should not ask for an allocation the
  // machine cannot make -- but it is now a sanity bound, not a stack bound.
  let plan = analyze("{}", options={
    ..Options::default(),
    max_depth: MAX_VALUE_DEPTH + 1,
  })
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.error_code, "E050")
}

///|
test "TC-R-18 the default depth still refuses what it always refused" {
  // Loosening the ceiling must not loosen the default: a document deeper than
  // the documented 512 is still refused with `E020`.
  let plan = reg_analyze("[".repeat(600) + "]".repeat(600))
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.error_code, "E020")
}

///|
test "TC-R-18b a legitimate nesting is still accepted" {
  let plan = reg_analyze("[".repeat(100) + "]".repeat(100))
  assert_eq(plan.is_executable(), true)
}

// ---------------------------------------------------------------------------
// The walks over a caller-supplied value are iterative, so their depth is
// bounded by the heap rather than by the native stack.
// ---------------------------------------------------------------------------

///|
test "TC-R-19 a deep value survives copy, compare, render and evaluate" {
  // The four walks that used to be recursive, all on one deep value. Before
  // the change each of these was a stack overflow waiting for a caller who
  // built the value themselves.
  let depth = 2000
  let mut v = Json::number(1.0)
  for _i = 0; _i < depth; _i = _i + 1 {
    v = Json::array([v])
  }
  let copy = copy_json(v)
  assert_eq(json_equal(v, copy), true)
  assert_eq(render(v, 0).length(), depth * 2 + 1)
  // The declaration is built, not parsed: the schema *parsers* are still
  // recursive and are still bounded by `MAX_SCHEMA_DEPTH` (TC-R-19c), but a
  // caller that constructs a `Schema` directly is not going through them.
  let mut schema = Schema::Int
  for _i = 0; _i < depth; _i = _i + 1 {
    schema = Schema::Arr(schema)
  }
  let verdict = schema.evaluate(v)
  assert_eq(verdict.ok, true)
}

///|
test "TC-R-19b the copy is independent of the original" {
  // The iterative copy has to be a real copy, not a share: mutating the copy
  // must not touch the source.
  let src = @json.parse("{\"a\":[1,2],\"b\":{\"c\":3}}") catch {
    _ => Json::null()
  }
  let copy = copy_json(src)
  match copy {
    Json::Object(m) =>
      match m.get("a") {
        Some(Json::Array(items)) => items.push(Json::number(9.0))
        _ => assert_true(false, msg="the copy has no array at a")
      }
    _ => assert_true(false, msg="the copy is not an object")
  }
  match src {
    Json::Object(m) =>
      match m.get("a") {
        Some(Json::Array(items)) => assert_eq(items.length(), 2)
        _ => assert_true(false, msg="the source has no array at a")
      }
    _ => assert_true(false, msg="the source is not an object")
  }
}

///|
test "TC-R-19c a declaration is still bounded" {
  // Declarations are parsed by two recursive parsers, so that bound is real
  // and stays: a declaration past `MAX_SCHEMA_DEPTH` is `E070`.
  let deep = "[".repeat(MAX_SCHEMA_DEPTH + 10) +
    "]".repeat(MAX_SCHEMA_DEPTH + 10)
  let mut code = ""
  try {
    let _ = Schema::parse(deep)
  } catch {
    e => code = e.code()
  }
  assert_eq(code, "E070")
}

///|
test "TC-R-20 a nested array mismatch names its path" {
  // The mismatch is reported against the path it was found at, not the root:
  // `[[integer]]` against `[["a"]]` fails at `.0.0`, and a report that says
  // `<root>` sends the caller to the wrong place.
  let schema = Schema::parse("[[integer]]")
  let value = @json.parse("[[\"a\"]]") catch { _ => Json::null() }
  let verdict = schema.evaluate(value)
  assert_eq(verdict.ok, false)
  assert_eq(verdict.mismatched.length(), 1)
  assert_eq(verdict.mismatched[0].path, "0.0")
}

///|
test "TC-R-21 a nested array where an array was expected names its path" {
  // The other half of the walk: the node is not an array at all.
  let schema = Schema::parse("[[integer]]")
  let value = @json.parse("[[1],2]") catch { _ => Json::null() }
  let verdict = schema.evaluate(value)
  assert_eq(verdict.ok, false)
  assert_eq(verdict.mismatched[0].path, "1")
}

///|
test "TC-R-25 syntax readiness samples a prefix with no value yet" {
  // The sampling loop asks the partial parser for a snapshot at every step.
  // Before the first value is complete the snapshot has no value, and that
  // branch has to do nothing rather than stop the search: the answer is the
  // first offset at which the document *already* equals its final value, and
  // an empty prefix is simply not that offset yet.
  //
  // Leading whitespace guarantees at least one such sample: at offset 1 the
  // input is `" "`, which has no value.
  let ready = syntax_readiness_permille("   1", step=1)
  assert_eq(ready, 1000)
  let same = syntax_readiness_permille("   1")
  assert_eq(same, 1000)
}
