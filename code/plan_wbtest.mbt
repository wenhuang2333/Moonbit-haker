// FR-33/FR-34/FR-35 — the decision, the plan and the self-healing API.

///|
test "decide orders the risk the way the gate does" {
  assert_eq(decide(0, Exact, false).name(), Safe.name())
  assert_eq(decide(1, Cosmetic, false).name(), CosmeticRepair.name())
  assert_eq(decide(1, Lossy, false).name(), LossyRepair.name())
  // An ambiguity outranks a lossy repair: the caller cannot even tell what was
  // invented.
  assert_eq(decide(1, Cosmetic, true).name(), Ambiguous.name())
  assert_eq(decide(1, Lossy, true).name(), Ambiguous.name())
  assert_eq(decide_error("E011").name(), Ambiguous.name())
  assert_eq(decide_error("E010").name(), LossyRepair.name())
  assert_eq(decide_error("E001").name(), Invalid.name())
  // Only the two accepted-unchanged decisions may be executed.
  assert_eq(Safe.is_safe(), true)
  assert_eq(CosmeticRepair.is_safe(), true)
  assert_eq(LossyRepair.is_safe(), false)
  assert_eq(Ambiguous.is_safe(), false)
  assert_eq(Invalid.is_safe(), false)
  assert_eq(Safe.worse_of(LossyRepair).name(), LossyRepair.name())
  assert_eq(LossyRepair.worse_of(Safe).name(), LossyRepair.name())
}

///|
test "analyze never raises, not even on empty input" {
  let plan = analyze("")
  assert_eq(plan.decision.name(), "invalid")
  assert_eq(plan.error_code, "E001")
  assert_eq(plan.is_executable(), false)
  assert_true(plan.prompt() != "", msg="a plan always has a prompt")
  // The same call site handles a good document.
  let ok = analyze("{\"a\":1}")
  assert_eq(ok.decision.name(), "safe")
  assert_eq(ok.is_executable(), true)
  assert_eq(ok.text, "{\"a\":1}")
}

///|
test "a cosmetic repair says what it did" {
  let plan = analyze("{\"a\":1,}")
  assert_eq(plan.decision.name(), "cosmetic_repair")
  assert_eq(plan.exactness.name(), "cosmetic")
  assert_eq(plan.is_executable(), true)
  assert_eq(plan.repairs.length(), 1)
  let op = plan.repairs[0]
  assert_eq(op.rule, "R005")
  assert_eq(op.name, "RemoveExtraComma")
  assert_eq(op.action.name(), "remove")
  assert_eq(op.confidence_class, "certain")
  assert_eq(op.confidence, 1.0)
  assert_eq(op.information_loss(), false)
  assert_true(
    plan.explain_text().contains("SAFE TO EXECUTE"),
    msg=plan.explain_text(),
  )
}

///|
test "a lossy repair explains what the model should do instead" {
  let plan = analyze("{\"name\":\"Alice")
  assert_eq(plan.decision.name(), "lossy_repair")
  assert_eq(plan.exactness.name(), "lossy")
  assert_eq(plan.is_executable(), false)
  // No refusal happened, so there is no hint; the prompt is derived from the
  // rules that fired, which is the same instruction a refusal would carry.
  assert_true(plan.retry_hint is None, msg="no hint without a refusal")
  let advice = plan.suggestions()
  assert_true(advice.length() >= 2, msg=advice.length().to_string())
  assert_eq(advice[0], "Do not truncate string values.")
  assert_true(
    plan.prompt().contains("Do not truncate string values."),
    msg=plan.prompt(),
  )
  let text = plan.explain_text(input="{\"name\":\"Alice")
  assert_true(text.contains("REJECT"), msg=text)
  assert_true(text.contains("information_loss = true"), msg=text)
}

///|
test "an accepted ambiguity is reported, not hidden" {
  let plan = analyze("{\"words\":[\"colour\" \"color\"]}")
  assert_eq(plan.decision.name(), "ambiguous")
  assert_eq(plan.ambiguous, true)
  // The value was produced, so a display channel may still show it...
  assert_true(plan.value is Some(_), msg="the value is available")
  // ...but the execution channel must not act on it.
  assert_eq(plan.is_executable(), false)
  assert_eq(plan.prompt().contains("adjacent strings"), true)
}

///|
test "the execution profile turns an ambiguity into feedback for the model" {
  let plan = analyze(
    "{\"words\":[\"colour\" \"color\"]}",
    options=Options::for_execution(),
  )
  assert_eq(plan.decision.name(), "ambiguous")
  assert_eq(plan.error_code, "E011")
  assert_true(plan.value is None, msg="a refusal has no value")
  match plan.retry_hint {
    Some(h) => {
      assert_eq(h.error_code, "E011")
      assert_eq(h.repair_code, "R006")
      assert_eq(h.ambiguity.name(), "adjacent_strings")
    }
    None => assert_true(false, msg="no hint for E011")
  }
  assert_true(plan.prompt().contains("E011"), msg=plan.prompt())
  // The refused repair is still shown as an operation, so the caller can print
  // the same "why" for a refusal as for an accepted repair.
  assert_eq(plan.repairs.length(), 1)
  assert_eq(plan.repairs[0].action.name(), "insert")
  assert_eq(plan.repairs[0].confidence_class, "refused")
}

///|
test "a skeleton turns a valid document into a refusal" {
  let schema = Schema::parse("{!query:string,!limit:integer}") catch {
    _ => return assert_true(false, msg="schema did not parse")
  }
  // Valid JSON, usable value: the skeleton is what refuses.
  let plan = analyze("{\"query\":\"MoonBit\"}", schema~)
  assert_eq(plan.decision.name(), "invalid")
  assert_eq(plan.error_code, "E070")
  assert_eq(plan.schema_total, 2)
  assert_eq(plan.schema_satisfied, 1)
  assert_eq(plan.schema_missing, ["limit"])
  assert_eq(plan.is_executable(), false)
  assert_true(plan.prompt().contains("limit"), msg=plan.prompt())
  // With the member present the same input is executable.
  let ok = analyze("{\"query\":\"MoonBit\",\"limit\":10}", schema~)
  assert_eq(ok.decision.name(), "safe")
  assert_eq(ok.schema_satisfied, 2)
  assert_eq(ok.is_executable(), true)
  // A skeleton on top of a cosmetic repair keeps both signals.
  let cosmetic = analyze("{\"query\":\"MoonBit\",\"limit\":10,}", schema~)
  assert_eq(cosmetic.decision.name(), "cosmetic_repair")
  assert_eq(cosmetic.schema_total, 2)
}

///|
test "the machine readable plan is JSON" {
  let plan = analyze("{\"a\":1,}", readiness=1)
  let text = plan.to_json()
  let parsed = @json.parse(text) catch {
    _ => return assert_true(false, msg="to_json is not valid JSON: " + text)
  }
  let obj = match parsed {
    Json::Object(m) => m
    _ => return assert_true(false, msg="to_json is not an object")
  }
  let decision = match obj.get("decision") {
    Some(Json::String(s)) => s
    _ => ""
  }
  assert_eq(decision, "cosmetic_repair")
  assert_true(
    obj.get("executable") is Some(Json::True),
    msg="executable is true",
  )
  assert_true(
    obj.get("repairs") is Some(Json::Array(_)),
    msg="repairs is an array",
  )
  // The readiness measurement was asked for, so the plan carries it.
  assert_true(
    plan.readiness_permille >= 0,
    msg=plan.readiness_permille.to_string(),
  )
  // Without the argument the field says "not measured" rather than zero.
  assert_eq(analyze("{\"a\":1}").readiness_permille, -1)
}

///|
test "a streamed document and a one-shot document agree" {
  let text = "{\"words\":[\"colour\" \"color\"],\"limit\":10}"
  let pieces : Array[String] = [
    "{\"words\":[\"colo", "ur\" \"color\"],", "\"limit\":10}",
  ]
  // 1. The execution profile checks the gate *while* the input is read, so the
  //    parser stops at the ambiguous repair and cannot be finished afterwards.
  let gated = PartialParser::new(options=Options::for_execution()) catch {
    _ => return assert_true(false, msg="parser did not build")
  }
  for piece in pieces {
    gated.feed(piece) catch {
      _ => ()
    }
  }
  let stopped = gated.analyze(input=text)
  assert_eq(stopped.decision.name(), "invalid")
  assert_eq(stopped.error_code, "E030")
  // 2. The display profile records the ambiguity and keeps going; the finished
  //    plan is then exactly the plan the one-shot call produces.
  let parser = PartialParser::new(options=Options::for_llm()) catch {
    _ => return assert_true(false, msg="parser did not build")
  }
  for piece in pieces {
    parser.feed(piece)
  }
  let streamed = parser.analyze(input=text)
  let one_shot = analyze(text, options=Options::for_llm())
  assert_eq(streamed.decision.name(), one_shot.decision.name())
  assert_eq(streamed.decision.name(), "ambiguous")
  assert_eq(streamed.exactness.name(), one_shot.exactness.name())
  assert_eq(streamed.repairs.length(), one_shot.repairs.length())
  assert_eq(streamed.error_code, one_shot.error_code)
  assert_eq(streamed.repairs.length(), one_shot.repairs.length())
  // A finished parser cannot be finished twice, and the plan says so instead of
  // raising out of a call the caller is entitled to make.
  let again = parser.analyze(input=text)
  assert_eq(again.decision.name(), "invalid")
  assert_eq(again.error_code, "E030")
}

///|
test "every rule has an action and the actions are total" {
  let codes : Array[RepairCode] = [
    StripFence,
    StripComment,
    NormalizeQuote,
    QuoteBareWord,
    RemoveExtraComma,
    InsertComma,
    InsertColon,
    FillNull,
    CloseContainer,
    CloseString,
    FixNumber,
    ConvertLiteral,
    EscapeControl,
    FixEscape,
    MismatchedCloser,
    DropUnexpected,
    DropExtraCloser,
    MergeDuplicateKey,
    ConcatStrings,
    DropEllipsis,
    SkipProse,
    NormalizeLiteral,
  ]
  assert_eq(codes.length(), 22)
  for c in codes {
    // `plan_action` is total; the check that matters is that every code reaches
    // a plan with a non-empty name and a rule string of the documented shape.
    let op : PlanOp = {
      rule: c.code(),
      name: c.name(),
      action: plan_action(c),
      position: { offset: 0, line: 1, column: 1, },
      severity: Info,
      ambiguity: Unambiguous,
      confidence_class: "certain",
      confidence: 1.0,
    }
    assert_eq(op.rule.length(), 4)
    assert_true(op.name.length() > 0, msg=op.rule)
    assert_true(op.action.name().length() > 0, msg=op.rule)
  }
}

///|
test "every rule name maps back to its code" {
  let codes : Array[RepairCode] = [
    StripFence,
    StripComment,
    NormalizeQuote,
    QuoteBareWord,
    RemoveExtraComma,
    InsertComma,
    InsertColon,
    FillNull,
    CloseContainer,
    CloseString,
    FixNumber,
    ConvertLiteral,
    EscapeControl,
    FixEscape,
    MismatchedCloser,
    DropUnexpected,
    DropExtraCloser,
    MergeDuplicateKey,
    ConcatStrings,
    DropEllipsis,
    SkipProse,
    NormalizeLiteral,
  ]
  for c in codes {
    assert_eq(code_of_name(c.name()).name(), c.name())
  }
  // An unknown name is not a crash: the plan still has an action.
  assert_eq(code_of_name("R999").name(), "CloseContainer")
}

///|
test "a repair becomes an operation whose confidence is a class" {
  let certain : Repair = {
    code: RemoveExtraComma,
    position: { offset: 8, line: 1, column: 9, },
    severity: Info,
    message: "trailing comma removed",
    ambiguity: Unambiguous,
  }
  let op = PlanOp::of_repair(certain)
  assert_eq(op.confidence_class, "certain")
  assert_eq(op.confidence, 1.0)
  assert_eq(op.information_loss(), false)
  assert_eq(op.position.column, 9)
  // A `Warning` repair changed something the model wrote, but not a value.
  let warning = { ..certain, severity: Warning, }
  assert_eq(PlanOp::of_repair(warning).confidence_class, "probable")
  assert_eq(PlanOp::of_repair(warning).confidence, 0.75)
  assert_eq(PlanOp::of_repair(warning).information_loss(), true)
  // A second reading is the lowest confidence class there is.
  let ambiguous = { ..certain, ambiguity: TrailingContent, }
  assert_eq(PlanOp::of_repair(ambiguous).confidence_class, "ambiguous")
  assert_eq(PlanOp::of_repair(ambiguous).confidence, 0.5)
}

///|
test "strings reach JSON without losing anything" {
  let raw = "a\"b\\c\nd\u0001e\u001Ff"
  let escaped = json_escape(raw)
  assert_eq(escaped, "a\\\"b\\\\c\\nd\\u0001e\\u001ff")
  // A freshly escaped string always parses, whatever was in it.
  let back = @json.parse("\"" + escaped + "\"") catch {
    _ =>
      return assert_true(false, msg="escaped string did not parse: " + escaped)
  }
  assert_true(back is Json::String(_), msg="escaped string is a string")
  // `one_line` is the report form: a newline becomes the two characters `\n`
  // so a message built from a file excerpt stays on one line, and a long one is
  // cut with an ellipsis rather than wrapping the terminal.
  assert_eq(one_line("a\nb"), "a\\nb")
  assert_eq(one_line("x".repeat(250)).length(), 201)
  assert_eq(one_line("x".repeat(250))[200:], "…")
  assert_eq(hex_digit(0), '0')
  assert_eq(hex_digit(9), '9')
  // Lower case, which is what `JSON.stringify` emits and what the reports use.
  assert_eq(hex_digit(10), 'a')
  assert_eq(hex_digit(15), 'f')
  // `kv` is the string member writer: key and value both come out quoted, and
  // a value that needs escaping was escaped by the caller.
  assert_eq(kv("a", "b"), "\"a\":\"b\"")
}

///|
test "the machine form of a refusal carries the retry" {
  let plan = analyze(
    "{\"words\":[\"colour\" \"color\"]}",
    options=Options::for_execution(),
  )
  let parsed = @json.parse(plan.to_json()) catch {
    _ => return assert_true(false, msg="to_json is not valid JSON")
  }
  let obj = match parsed {
    Json::Object(m) => m
    _ => return assert_true(false, msg="not an object")
  }
  let decision = match obj.get("decision") {
    Some(Json::String(s)) => s
    _ => ""
  }
  assert_eq(decision, "ambiguous")
  assert_true(obj.get("executable") is Some(Json::False), msg="not executable")
  assert_true(
    obj.get("value") is Some(Json::Null),
    msg="a refusal has no value",
  )
  // The retry block is what a caller sends back to the model.
  let retry = match obj.get("retry") {
    Some(Json::Object(m)) => m
    _ => return assert_true(false, msg="no retry block")
  }
  let code = match retry.get("code") {
    Some(Json::String(s)) => s
    _ => ""
  }
  assert_eq(code, "E011")
  assert_true(retry.get("prompt") is Some(Json::String(_)), msg="retry prompt")
  // A refusal has no value to print, and `summary` says so in one line.
  assert_true(plan.summary().contains("ambiguous"), msg=plan.summary())
  assert_true(plan.summary().contains("repairs=1"), msg=plan.summary())
}

///|
test "a truncated repair log is reported as truncated" {
  let o = { ..Options::default(), max_repairs: 2, }
  let plan = analyze("{\"a\":1,,\"b\":2,,\"c\":3,}", options=o)
  assert_eq(plan.repairs.length(), 2)
  assert_eq(plan.repairs_truncated, true)
  let parsed = @json.parse(plan.to_json()) catch {
    _ => return assert_true(false, msg="to_json is not valid JSON")
  }
  let obj = match parsed {
    Json::Object(m) => m
    _ => return assert_true(false, msg="not an object")
  }
  assert_true(
    obj.get("repairs_truncated") is Some(Json::True),
    msg="repairs_truncated is true",
  )
}

///|
test "the explanation has a form with and without the input" {
  let plan = analyze("{\"a\" 1}")
  let with_input = plan.explain_text(input="{\"a\" 1}")
  let without = plan.explain_text()
  assert_true(with_input.contains("Input:"), msg=with_input)
  assert_true(with_input.contains("{\"a\" 1}"), msg=with_input)
  assert_true(without.contains("Decision:"), msg=without)
  // Without the input there is nothing to echo, and the block says so instead
  // of printing an empty line.
  assert_true(!without.contains("Input:"), msg=without)
}

///|
test "suggestions do not repeat themselves" {
  // Two members missing their commas say the same thing twice.
  let plan = analyze("[\"a\" \"b\",\"c\" \"d\"]")
  let advice = plan.suggestions()
  assert_eq(advice.length(), 1)
  assert_eq(
    advice[0],
    "Separate the two adjacent strings with a comma, or merge them into one string.",
  )
}
