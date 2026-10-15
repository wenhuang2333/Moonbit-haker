// Public surface test (TC-E-API / NFR-API-01): every repair code and every
// fatal error code must expose a stable code string, a name, a severity and a
// message, and `Options::validate` must reject out-of-range limits. This is the
// machine-checked half of `docs/RULES.md` and `docs/ERRORS.md`.

///|
/// All 22 repair codes in table order.
fn all_repair_codes() -> Array[RepairCode] {
  [
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
}

///|
test "TC-E-API-01 repair code table is complete and self consistent" {
  let codes = all_repair_codes()
  assert_eq(codes.length().to_string(), "22")
  for i = 0; i < codes.length(); i = i + 1 {
    let c = codes[i]
    assert_eq(c.number().to_string(), (i + 1).to_string())
    let code = c.code()
    assert_eq(code.length().to_string(), "4")
    assert_eq(code[0:1].to_owned(), "R")
    assert_eq(c.name().length() > 0, true)
    assert_eq(c.message().length() > 0, true)
    // the code string must be unique across the table
    for j = i + 1; j < codes.length(); j = j + 1 {
      assert_eq(code == codes[j].code(), false)
    }
    // severity is exactly one of the two levels
    match c.severity() {
      Info | Warning => ()
    }
  }
  // the code string is R + zero padded number
  assert_eq(RepairCode::StripFence.code(), "R001")
  assert_eq(RepairCode::SkipProse.code(), "R021")
  assert_eq(RepairCode::NormalizeLiteral.code(), "R022")
  assert_eq(RepairCode::FixNumber.severity() == Warning, true)
  assert_eq(RepairCode::EscapeControl.severity() == Info, true)
  // notation-only repairs are Info; a completion or a dropped value is Warning
  assert_eq(RepairCode::MismatchedCloser.severity() == Info, true)
  assert_eq(RepairCode::DropExtraCloser.severity() == Info, true)
  assert_eq(RepairCode::SkipProse.severity() == Info, true)
  assert_eq(RepairCode::NormalizeLiteral.severity() == Info, true)
  assert_eq(RepairCode::ConvertLiteral.severity() == Warning, true)
  assert_eq(RepairCode::CloseString.severity() == Warning, true)
  // only `QuoteBareWord` depends on the slot
  assert_eq(RepairCode::QuoteBareWord.severity_in(KeySlot) == Info, true)
  assert_eq(RepairCode::QuoteBareWord.severity_in(ValueSlot) == Warning, true)
}

///|
test "TC-E-API-02 every fatal error exposes a code and a message" {
  let errors : Array[MendError] = [
    EmptyInput,
    NoJsonFound(0),
    StrictViolation(RemoveExtraComma, { offset: 6, line: 1, column: 7, }, "x"),
    DepthLimit(512, 600),
    SizeLimit(1024, 2048),
    TokenLimit(1024, 2048),
    InvalidState("x"),
    InvalidUtf8(3),
    InvalidOption("x"),
  ]
  let want = [
    "E001", "E002", "E010", "E020", "E021", "E022", "E030", "E040", "E050", "E060",
  ]
  for i = 0; i < errors.length(); i = i + 1 {
    assert_eq(errors[i].code(), want[i])
    assert_eq(errors[i].to_string().length() > 0, true)
  }
  // E001/E002 carry no position, E010 does
  assert_eq(EmptyInput.to_string().has_prefix("E001"), true)
  assert_eq(NoJsonFound(12).to_string().has_prefix("E002"), true)
  let s = StrictViolation(
    RemoveExtraComma,
    { offset: 6, line: 1, column: 7, },
    "x",
  ).to_string()
  assert_eq(s.has_prefix("E010 StrictViolation at 1:7"), true)
  assert_eq(s.contains("R005"), true)
}

///|
test "TC-E-API-03 options validate rejects out of range limits" {
  // defaults are valid
  Options::validate(Options::default())
  // every limit must be positive
  let cases : Array[Options] = [
    { ..Options::default(), max_depth: 0, },
    { ..Options::default(), max_input_len: 0, },
    { ..Options::default(), max_token_len: 0, },
    { ..Options::default(), max_depth: -1, },
    { ..Options::default(), indent: -1, },
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let mut saw = false
    Options::validate(cases[i]) catch {
      InvalidOption(_) => saw = true
      _ => ()
    }
    assert_eq(saw, true)
  }
}

///|
test "TC-E-API-04 public repair entry points reject after finish" {
  let p = PartialParser::new()
  p.feed("{\"a\":1}")
  let _ = p.finish()
  // a second finish and any further feed must raise InvalidState (E030)
  let mut saw = false
  p.feed(" ") catch {
    InvalidState(_) => saw = true
    _ => ()
  }
  assert_eq(saw, true)
}
