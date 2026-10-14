// Golden tests: Appendix A (TC-G 77) and Appendix B (TC-G 45) of the project
// document set. Every case runs the one-shot `repair` entry point and compares
// the repaired text plus the repair codes with their offsets.

///|
/// Observed outcome of one run, flattened to comparable strings.
struct Outcome {
  text : String
  recs : String
  err : String
}

///|
/// One golden case.
struct Case {
  id : String
  input : String
  opts : Options
  text : String
  recs : String
  err : String
}

///|
/// `R005@6,R006@7` style rendering of a repair list.
fn recs_text(rs : Array[Repair]) -> String {
  let sb = StringBuilder()
  for i = 0; i < rs.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(rs[i].code.code())
    sb.write_string("@")
    sb.write_string(rs[i].position.offset.to_string())
  }
  sb.to_string()
}

///|
/// `E020(3,@3)` style rendering of a fatal error.
fn err_text(e : MendError) -> String {
  match e {
    EmptyInput => "E001"
    NoJsonFound(o) => "E002@" + o.to_string()
    StrictViolation(c, p, _m) =>
      "E010(" + c.code() + "@" + p.offset.to_string() + ")"
    DepthLimit(l, o) => "E020(" + l.to_string() + ",@" + o.to_string() + ")"
    SizeLimit(l, o) => "E021(" + l.to_string() + ",@" + o.to_string() + ")"
    TokenLimit(l, o) => "E022(" + l.to_string() + ",@" + o.to_string() + ")"
    InvalidState(_m) => "E030"
    InvalidUtf8(o) => "E040@" + o.to_string()
    InvalidOption(_m) => "E050"
  }
}

///|
/// Run `repair` and flatten the result.
fn attempt(input : String, opts : Options) -> Outcome {
  try {
    let r = repair(input, options=opts)
    { text: r.text, recs: recs_text(r.repairs), err: "", }
  } catch {
    e => { text: "", recs: "", err: err_text(e), }
  }
}

///|
/// Expected outcome of a case, flattened the same way.
fn expected(c : Case) -> String {
  if c.err != "" {
    "ERR " + c.err
  } else {
    "OK " + c.text + " || " + c.recs
  }
}

///|
/// Observed outcome of a case, flattened the same way.
fn observed(c : Case) -> String {
  let o = attempt(c.input, c.opts)
  if o.err != "" {
    "ERR " + o.err
  } else {
    "OK " + o.text + " || " + o.recs
  }
}

///|
/// Check every case, reporting the case id on failure.
fn check_all(cases : Array[Case]) -> Unit raise {
  for c in cases {
    assert_eq(c.id + " -> " + observed(c), c.id + " -> " + expected(c))
  }
}

///|
/// Case that succeeds with the default options.
fn ok(id : String, input : String, text : String, recs : String) -> Case {
  { id, input, opts: Options::default(), text, recs, err: "", }
}

///|
/// Case that succeeds with custom options.
fn ok_opt(
  id : String,
  input : String,
  opts : Options,
  text : String,
  recs : String,
) -> Case {
  { id, input, opts, text, recs, err: "", }
}

///|
/// Case that fails with the default options.
fn bad(id : String, input : String, err : String) -> Case {
  { id, input, opts: Options::default(), text: "", recs: "", err, }
}

///|
/// Case that fails with custom options.
fn bad_opt(id : String, input : String, opts : Options, err : String) -> Case {
  { id, input, opts, text: "", recs: "", err, }
}

///|
/// `s` repeated `n` times.
fn repeat_str(s : String, n : Int32) -> String {
  let sb = StringBuilder()
  for _i = 0; _i < n; _i = _i + 1 {
    sb.write_string(s)
  }
  sb.to_string()
}

///|
/// `item` repeated `n` times, comma separated.
fn repeat_join(item : String, n : Int32) -> String {
  let sb = StringBuilder()
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(item)
  }
  sb.to_string()
}

///|
/// A string holding one lone (unpaired) surrogate code unit.
fn lone(code : Int32) -> String {
  String::from_array([Int32::unsafe_to_char(code)])
}

///|
/// Appendix A.2 — one-shot repair cases.
fn cases_a() -> Array[Case] {
  let strict : Options = { ..Options::default(), mode: Strict, }
  let fence = "```json\n{\"a\":1}\n```"
  [
    ok("G-001", "{\"a\":1}", "{\"a\":1}", ""),
    ok("G-002", "[1, 2, 3]", "[1,2,3]", ""),
    ok("G-003", "\"x\"", "\"x\"", ""),
    ok(
      "G-004", "{\"a\":{\"b\":[true,false,null]}}", "{\"a\":{\"b\":[true,false,null]}}",
      "",
    ),
    ok("G-010", fence, "{\"a\":1}", "R001@0,R001@16"),
    ok_opt(
      "G-011",
      "Here: {\"a\":1}",
      { ..Options::default(), skip_prose: true, },
      "{\"a\":1}",
      "R021@0",
    ),
    ok("G-020", "{'a':'x'}", "{\"a\":\"x\"}", "R003@1,R003@5"),
    ok("G-021", "{\"a\":'it\"s'}", "{\"a\":\"it\\\"s\"}", "R003@5"),
    ok("G-022", "{“a”:“b”}", "{\"a\":\"b\"}", "R003@1,R003@5"),
    ok("G-030", "{a:1}", "{\"a\":1}", "R004@1"),
    ok("G-031", "{a_b:1,c$:2}", "{\"a_b\":1,\"c$\":2}", "R004@1,R004@7"),
    ok("G-032", "{\"a\":1,\"a\":2}", "{\"a\":2}", "R018@7"),
    ok_opt(
      "G-033",
      "{\"a\":1,\"a\":2}",
      { ..Options::default(), duplicate_keys: KeepFirst, },
      "{\"a\":1}",
      "R018@7",
    ),
    bad_opt(
      "G-034",
      "{\"a\":1,\"a\":2}",
      { ..Options::default(), duplicate_keys: AsError, },
      "E010(R018@7)",
    ),
    ok("G-040", "{\"a\":1 // c\n}", "{\"a\":1}", "R002@7"),
    ok("G-041", "[1,/* x */2]", "[1,2]", "R002@3"),
    ok("G-042", "{\"a\":\"http://x\"}", "{\"a\":\"http://x\"}", ""),
    ok("G-043", "[1] /* x", "[1]", "R002@4"),
    ok("G-050", "[1,2,]", "[1,2]", "R005@4"),
    ok("G-051", "{\"a\":1,}", "{\"a\":1}", "R005@6"),
    ok("G-052", "[1 2]", "[1,2]", "R006@3"),
    ok("G-053", "{\"a\":1 \"b\":2}", "{\"a\":1,\"b\":2}", "R006@7"),
    ok("G-054", "{\"a\" 1}", "{\"a\":1}", "R007@5"),
    ok("G-055", "[1,,2]", "[1,2]", "R005@3"),
    ok("G-056", "[,1]", "[1]", "R005@1"),
    ok(
      "G-060", "[True,False,None]", "[true,false,null]", "R012@1,R012@6,R012@12",
    ),
    ok("G-061", "[undefined]", "[null]", "R012@1"),
    ok(
      "G-062", "[NaN,Infinity,-Infinity]", "[null,null,null]", "R012@1,R012@5,R012@14",
    ),
    ok_opt(
      "G-063",
      "[NaN]",
      { ..Options::default(), non_finite: AsString, },
      "[\"NaN\"]",
      "R012@1",
    ),
    bad_opt(
      "G-064",
      "[NaN]",
      { ..Options::default(), non_finite: AsError, },
      "E010(R012@1)",
    ),
    ok("G-065", "[TRUE,Null]", "[true,null]", "R012@1,R012@6"),
    ok("G-070", "[+1,.5,5.,007]", "[1,0.5,5,7]", "R011@1,R011@4,R011@7,R011@10"),
    ok("G-071", "[-.5]", "[-0.5]", "R011@1"),
    ok("G-072", "[12345678901234567890]", "[12345678901234567890]", ""),
    ok("G-073", "[-0]", "[-0]", ""),
    ok("G-074", "[1e5,1E+5,1.5e-3]", "[1e5,1E+5,1.5e-3]", ""),
    ok("G-075", "[1e", "[1]", "R011@1,R009@3"),
    ok("G-076", "[-,1]", "[1]", "R011@1"),
    ok("G-077", "{\"a\":-}", "{\"a\":null}", "R008@5"),
    ok("G-078", "{\"a\":1.}", "{\"a\":1}", "R011@5"),
    ok("G-080", "{\"a\":\"x\ny\"}", "{\"a\":\"x\\ny\"}", "R013@7"),
    ok("G-081", "[\"a\\qb\"]", "[\"aqb\"]", "R014@3"),
    ok("G-082", "[\"it\\'s\"]", "[\"it's\"]", "R014@4"),
    ok("G-083", "[\"\\u12g\"]", "[\"g\"]", "R014@2"),
    ok("G-084", "[\"\\u00e9\"]", "[\"é\"]", ""),
    ok("G-085", "[\"\\/\"]", "[\"/\"]", ""),
    ok("G-087", "[\"a\u{0000}b\"]", "[\"a\\u0000b\"]", "R013@3"),
    ok("G-090", "{\"a\":[1,2", "{\"a\":[1,2]}", "R009@9,R009@9"),
    ok("G-091", "{\"a\":\"he", "{\"a\":\"he\"}", "R010@8,R009@8"),
    ok("G-092", "{\"a\":tru", "{\"a\":true}", "R012@5,R009@8"),
    ok("G-093", "{\"a\":", "{\"a\":null}", "R008@5,R009@5"),
    ok("G-094", "{\"a\"", "{\"a\":null}", "R008@4,R009@4"),
    ok("G-095", "{\"a", "{\"a\":null}", "R010@3,R008@3,R009@3"),
    ok("G-096", "[1,", "[1]", "R005@2,R009@3"),
    ok("G-097", "[", "[]", "R009@1"),
    ok("G-098", "{", "{}", "R009@1"),
    ok("G-099", "\"abc", "\"abc\"", "R010@4"),
    ok("G-100", "nul", "null", "R012@0"),
    ok("G-101", "[tr", "[true]", "R012@1,R009@3"),
    ok("G-102", "[[[", "[[[]]]", "R009@3,R009@3,R009@3"),
    ok("G-110", "[1,2}", "[1,2]", "R015@4"),
    ok("G-111", "{\"a\":1]", "{\"a\":1}", "R015@6"),
    ok("G-112", "{\"a\":1}}}", "{\"a\":1}", "R017@7,R017@8"),
    bad("G-113", "}", "E002@0"),
    ok("G-120", "{\"a\":1} xyz", "{\"a\":1}", "R016@8"),
    ok_opt(
      "G-121",
      "{\"a\":1}\n{\"b\":2}",
      { ..Options::default(), multi_root: AsArray, },
      "[{\"a\":1},{\"b\":2}]",
      "",
    ),
    bad_opt(
      "G-122",
      "{\"a\":1} xyz",
      { ..Options::default(), multi_root: AsError, },
      "E010(R016@8)",
    ),
    bad("G-130", "", "E001"),
    bad("G-131", "   ", "E001"),
    bad("G-132", "hello", "E002@0"),
    bad("G-133", "-", "E002@0"),
    ok_opt(
      "G-140",
      "{\"a\":\"he said \"hi\" ok\"}",
      { ..Options::default(), quote_lookahead: true, },
      "{\"a\":\"he said \\\"hi\\\" ok\"}",
      "R003@14,R003@17",
    ),
    bad_opt("G-150", "{\"a\":1,}", strict, "E010(R005@6)"),
    ok_opt("G-151", "{\"a\":1}", strict, "{\"a\":1}", ""),
    ok("G-160", "{\"a\":1,\n\"b\":2,}", "{\"a\":1,\"b\":2}", "R005@13"),
    ok("G-161", "{\"a\":1,\r\n\"b\":2,}", "{\"a\":1,\"b\":2}", "R005@14"),
    ok("G-162", "[\"😀\",]", "[\"😀\"]", "R005@5"),
  ]
}

///|
/// Appendix A.3 — streaming cases are exercised separately; Appendix B.2
/// continues the one-shot grid.
fn cases_b() -> Array[Case] {
  let d3 : Options = { ..Options::default(), max_depth: 3, }
  let d2 : Options = { ..Options::default(), max_depth: 2, }
  let input10 : Options = { ..Options::default(), max_input_len: 10, }
  let input13 : Options = { ..Options::default(), max_input_len: 13, }
  let tok5 : Options = { ..Options::default(), max_token_len: 5, }
  let fence = "```json\n{\"a\":1}\n```"
  let high = lone(0xD83D)
  let low = lone(0xDE00)
  [
    bad_opt("G-200", "[[[[1]]]]", d3, "E020(3,@3)"),
    ok_opt("G-201", "[[[1]]]", d3, "[[[1]]]", ""),
    bad_opt("G-202", "{\"a\":{\"b\":{\"c\":1}}}", d2, "E020(2,@10)"),
    bad_opt("G-203", "[1,2,3,4,5,6]", input10, "E021(10,@10)"),
    ok_opt("G-204", "[1,2,3,4,5,6]", input13, "[1,2,3,4,5,6]", ""),
    bad_opt("G-205", "[\"abcdef\"]", tok5, "E022(5,@1)"),
    bad_opt("G-206", "[1234567]", tok5, "E022(5,@1)"),
    bad_opt("G-207", repeat_str("[", 513), Options::default(), "E020(512,@512)"),
    ok_opt(
      "G-208",
      repeat_str("[", 512),
      Options::default(),
      repeat_str("[", 512) + repeat_str("]", 512),
      repeat_join("R009@512", 512),
    ),
    bad_opt(
      "G-209",
      repeat_str("[", 1000000),
      Options::default(),
      "E020(512,@512)",
    ),
    bad_opt("G-210", "[1]", { ..Options::default(), max_depth: 0, }, "E050"),
    bad_opt(
      "G-211",
      "[1]",
      { ..Options::default(), max_input_len: -1, },
      "E050",
    ),
    bad_opt("G-212", "[1]", { ..Options::default(), max_token_len: 0, }, "E050"),
    ok("G-220", "[\"a" + high + "b\"]", "[\"a\u{FFFD}b\"]", "R014@3"),
    ok("G-221", "[\"" + low + "\"]", "[\"\u{FFFD}\"]", "R014@2"),
    ok("G-222", "[\"a" + high + "\"]", "[\"a\u{FFFD}\"]", "R014@3"),
    ok("G-223", "[\"😀\"]", "[\"😀\"]", ""),
    ok("G-224", "[\"\\uD83D\"]", "[\"\u{FFFD}\"]", "R014@2"),
    ok("G-225", "[\"\\uD83D\\uDE00\"]", "[\"😀\"]", ""),
    ok("G-226", "[" + high + "1]", "[1]", "R016@1"),
    ok("G-230", "[@1]", "[1]", "R016@1"),
    ok("G-232", "{\"a\":@1}", "{\"a\":1}", "R016@5"),
    ok("G-240", "{\"a\":hello}", "{\"a\":\"hello\"}", "R004@5"),
    ok("G-241", "[\"x\",foo,bar]", "[\"x\",\"foo\",\"bar\"]", "R004@5,R004@9"),
    ok("G-244", "{\"d\":2024-01-01}", "{\"d\":\"2024-01-01\"}", "R004@5"),
    ok("G-245", "{\"a\":12abc}", "{\"a\":\"12abc\"}", "R004@5"),
    bad_opt(
      "G-250",
      fence,
      { ..Options::default(), strip_fence: false, },
      "E002@0",
    ),
    ok_opt(
      "G-251",
      "{'a':1,}",
      { ..Options::default(), collect_repairs: false, },
      "{\"a\":1}",
      "",
    ),
    bad_opt(
      "G-252",
      "{'a':1}",
      { ..Options::default(), collect_repairs: false, mode: Strict, },
      "E010(R003@1)",
    ),
    ok_opt(
      "G-260",
      "{\"a\":[1,2],\"b\":{}}",
      { ..Options::default(), indent: 2, },
      "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}",
      "",
    ),
    ok_opt("G-261a", "[]", { ..Options::default(), indent: 2, }, "[]", ""),
    ok_opt("G-261b", "{}", { ..Options::default(), indent: 2, }, "{}", ""),
    bad_opt(
      "G-262",
      "{'a':1}",
      { ..Options::default(), rules: RuleSet::all().disable(NormalizeQuote), },
      "E010(R003@1)",
    ),
    ok("G-270", "{\"a\":1,\"a\":2,\"a\":3}", "{\"a\":3}", "R018@7,R018@13"),
    ok("G-271", "{\"a\":1,\"b\":2,\"a\":3}", "{\"a\":3,\"b\":2}", "R018@13"),
    ok("G-280", "{\"a\":1}{\"b\":2}", "{\"a\":1}", "R016@7"),
    ok_opt(
      "G-281",
      "{\"a\":1}",
      { ..Options::default(), multi_root: AsArray, },
      "[{\"a\":1}]",
      "",
    ),
    bad_opt("G-282", "", { ..Options::default(), multi_root: AsArray, }, "E001"),
    ok_opt(
      "G-283",
      "{\"a\":1},{\"b\":2}",
      { ..Options::default(), multi_root: AsArray, },
      "[{\"a\":1},{\"b\":2}]",
      "",
    ),
    bad_opt(
      "G-290",
      "hello world",
      { ..Options::default(), skip_prose: true, },
      "E002@0",
    ),
    ok_opt(
      "G-291",
      "Sure!\n```json\n{\"a\":1}\n```",
      { ..Options::default(), skip_prose: true, },
      "{\"a\":1}",
      "R021@0,R001@22",
    ),
    ok("G-300", "[\"a\" + \"b\"]", "[\"ab\"]", "R019@5"),
    ok("G-300b", "{\"k\":\"a\" + \"b\"}", "{\"k\":\"ab\"}", "R019@9"),
    ok("G-300c", "[\"a\"+\"b\"+\"c\"]", "[\"abc\"]", "R019@4,R019@8"),
    ok("G-300d", "\"a\" + \"b\"", "\"ab\"", "R019@4"),
    ok("G-300e", "[\"a\" + 1]", "[\"a\",1]", "R016@5,R006@7"),
    ok("G-301", "[1,...,3]", "[1,3]", "R020@3"),
    ok("G-302", "[1,...]", "[1]", "R020@3"),
    ok("G-303", "{\"a\":1,...}", "{\"a\":1}", "R020@7"),
  ]
}

///|
/// Appendix A.2 golden grid.
test "golden appendix A" {
  check_all(cases_a())
}

///|
/// Appendix B.2 golden grid.
test "golden appendix B" {
  check_all(cases_b())
}
