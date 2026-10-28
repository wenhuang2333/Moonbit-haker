///|
test "TC-R-22 render matches core stringify" {
  let cases : Array[String] = [
    "{}", "[]", "null", "true", "false", "0", "-0", "1", "1.0", "1e100", "9007199254740993",
    "0.1", "\"\"", "\"a\"", "\"\\u0000\"", "\"héllo 世界\"", "{\"a\":1}", "{\"a\":[1,2,3]}",
    "{\"a\":{\"b\":{\"c\":[1,{\"d\":null}]}}}", "[[[[[[1]]]]]]", "[{\"a\":1},{\"b\":2},[],[{}],\"x\",null,true,1.5]",
    "{\"k\":\"v\",\"n\":-1.5e-3,\"t\":true,\"f\":false,\"z\":null,\"e\":{},\"r\":[]}",
  ]
  for text in cases {
    let v = @json.parse(text) catch { _ => continue }
    for indent in [0, 2, 4] {
      let mine = render(v, indent)
      let core = if indent > 0 { v.stringify(indent~) } else { v.stringify() }
      assert_eq(
        mine,
        core,
        msg="render(" + text + ", indent=" + indent.to_string() + ")",
      )
    }
  }
}

///|
test "TC-R-23 render handles deep values that core stringify cannot" {
  // `Json::stringify` is recursive; ours is not. This is the case the change
  // exists for.
  let mut v = Json::number(1.0)
  for _i = 0; _i < 20000; _i = _i + 1 {
    v = Json::array([v])
  }
  let out = render(v, 0)
  assert_eq(out.length(), 20000 * 2 + 1)
  assert_true(out.has_prefix("[[["), msg="renders the nesting")
}
