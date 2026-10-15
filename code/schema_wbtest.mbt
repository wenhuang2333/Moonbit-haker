// FR-36 — the skeleton declaration, its verdict, and semantic readiness.

///|
/// `Schema::parse`, or `Any` so that a test can assert on the string form.
fn schema_or_any(text : String) -> Schema {
  Schema::parse(text) catch {
    _ => Any
  }
}

///|
test "the text form round trips" {
  let text = "{!query:string,?opt:boolean,!empty:null,!any:any,!list:[integer],!deep:{!city:string}}"
  let s = schema_or_any(text)
  // Every member carries its marker in the canonical form, required or not.
  assert_eq(s.stringify(), text)
  let again = schema_or_any(s.stringify())
  assert_eq(again.stringify(), text)
}

///|
test "the text form reports what it could not read" {
  let bad : Array[String] = [
    "{!a:string", "{!a:string,!a:integer}", "{!a:intger}", "{!a:string}x", "string string",
  ]
  for text in bad {
    let code = try {
      ignore(Schema::parse(text))
      "no error"
    } catch {
      e => e.code()
    }
    assert_eq(code, "E070")
  }
  // A declaration that requires nothing is legal.
  assert_eq(schema_or_any("{}").stringify(), "{}")
  // `{a:string}` and `{!a:string}` are the same declaration: required is the
  // default, and the canonical spelling says so.
  assert_eq(schema_or_any("{?a:string}").stringify(), "{?a:string}")
  assert_eq(schema_or_any("{a:string}").stringify(), "{!a:string}")
}

///|
test "the declared kinds are checked, and integer is not number" {
  let s = schema_or_any(
    "{!a:integer,!b:number,!c:string,!d:boolean,!e:null,!f:any}",
  )
  assert_eq(s.accepts(Json::number(1.0)), false)
  let root = parse(
    "{\"a\":3,\"b\":1.5,\"c\":\"x\",\"d\":true,\"e\":null,\"f\":[1]}",
  ) catch {
    _ => return assert_true(false, msg="input did not parse")
  }
  let v = s.evaluate(root.value)
  assert_eq(v.ok, true)
  assert_eq(v.total, 6)
  assert_eq(v.satisfied, 6)
  // 3.0 is a whole number, 3.5 is not, and a string is not a number at all.
  assert_eq(schema_or_any("integer").accepts(Json::number(3.0)), true)
  assert_eq(schema_or_any("integer").accepts(Json::number(3.5)), false)
  assert_eq(schema_or_any("integer").accepts(Json::string("3")), false)
}

///|
test "a verdict separates a missing member from a wrong kind" {
  let s = schema_or_any("{!a:string,!b:integer}")
  let missing = parse("{\"a\":\"x\"}") catch { _ => return }
  let v1 = s.evaluate(missing.value)
  assert_eq(v1.ok, false)
  assert_eq(v1.missing, ["b"])
  assert_eq(v1.mismatched.length(), 0)
  let wrong = parse("{\"a\":1,\"b\":2}") catch { _ => return }
  let v2 = s.evaluate(wrong.value)
  assert_eq(v2.ok, false)
  assert_eq(v2.missing.length(), 0)
  assert_eq(v2.mismatched.length(), 1)
  assert_eq(v2.mismatched[0].path, "a")
  assert_eq(v2.mismatched[0].expected, "string")
  assert_eq(v2.mismatched[0].got, "number")
  // An optional member is checked for kind when present and never reported as
  // missing.
  let opt = schema_or_any("{!a:string,?b:integer}")
  let v3 = opt.evaluate(missing.value)
  assert_eq(v3.ok, true)
  assert_eq(v3.total, 2)
  assert_eq(v3.satisfied, 1)
}

///|
test "nested members are checked at their own paths" {
  let s = schema_or_any(
    "{!city:string,!location:{!city:string,!zip:string},!list:[integer]}",
  )
  assert_eq(s.required_paths(), [
    "city", "location", "location.city", "location.zip", "list",
  ])
  let good = parse(
    "{\"city\":\"Osaka\",\"location\":{\"city\":\"Kyoto\",\"zip\":\"600\"},\"list\":[1,2]}",
  ) catch {
    _ => return
  }
  assert_eq(s.evaluate(good.value).ok, true)
  let bad = parse(
    "{\"city\":\"Osaka\",\"location\":{\"city\":1,\"zip\":\"600\"},\"list\":[true]}",
  ) catch {
    _ => return
  }
  let v = s.evaluate(bad.value)
  assert_eq(v.ok, false)
  assert_eq(v.mismatched.length(), 2)
  assert_eq(v.mismatched[0].path, "location.city")
  assert_eq(v.mismatched[1].path, "list.0")
}

///|
test "a dotted path resolves through objects and array indices" {
  let v = parse("{\"a\":{\"b\":[10,{\"c\":20}]}}") catch { _ => return }
  assert_eq(
    lookup_path(v.value, "a.b.0").map(fn(x) { x.stringify() }),
    Some("10"),
  )
  assert_eq(
    lookup_path(v.value, "a.b.1.c").map(fn(x) { x.stringify() }),
    Some("20"),
  )
  assert_eq(lookup_path(v.value, "a.b.2"), None)
  assert_eq(lookup_path(v.value, "a.z"), None)
  assert_eq(lookup_path(v.value, "a.b.x"), None)
  assert_eq(
    lookup_path(v.value, "").map(fn(x) { x.stringify() }),
    Some(v.value.stringify()),
  )
}

///|
test "semantic readiness separates the JSON from the arguments" {
  // A model that finishes the two arguments it was asked for and then keeps
  // writing a long field it was not asked for.
  let text = "{\"query\":\"MoonBit\",\"limit\":10,\"note\":\"" +
    "x".repeat(120) +
    "\"}"
  let s = schema_or_any("{!query:string,!limit:integer}")
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  assert_eq(r.verdict.ok, true)
  assert_eq(r.verdict.satisfied, 2)
  // The arguments are final in the first fifth of the stream...
  assert_true(r.schema_permille > 0, msg=r.schema_permille.to_string())
  assert_true(r.schema_permille < 500, msg=r.schema_permille.to_string())
  // ...while the syntax is only closed at the very end. That gap is the whole
  // reason the library measures what it measures.
  assert_true(r.syntax_permille > 900, msg=r.syntax_permille.to_string())
  assert_true(
    r.schema_permille < r.syntax_permille,
    msg="skeleton before syntax",
  )
  assert_eq(r.step, 1)
}

///|
test "readiness does not wait for members nobody asked for" {
  let text = "{\"a\":1,\"b\":2,\"c\":3}"
  let only_a = schema_or_any("{!a:integer}")
  let r = semantic_readiness(text, only_a, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  // `a` is final as soon as the comma after it arrives settles the number, i.e.
  // after `{"a":1,` — a fifth of the document, and well before `b` or `c` have
  // been written. The measurement is per declared member, not per document.
  assert_true(r.schema_permille < 400, msg=r.schema_permille.to_string())
  assert_true(r.schema_permille > 0, msg=r.schema_permille.to_string())
  // A skeleton that requires nothing is satisfied from the start.
  let nothing = semantic_readiness(text, Any, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  assert_eq(nothing.schema_permille, 0)
}

///|
test "an unsatisfied skeleton is reported at the end of the stream" {
  // A long last member makes the two numbers tell different stories: the JSON
  // is committed one code unit before the end, the skeleton never.
  let text = "{\"a\":1,\"b\":\"" + "y".repeat(60) + "\"}"
  let s = schema_or_any("{!a:integer,!c:string}")
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  assert_eq(r.verdict.ok, false)
  assert_eq(r.verdict.missing, ["c"])
  // Never satisfied, so the curve says "not before the end".
  assert_eq(r.schema_permille, 1000)
  // Syntax, on the other hand, is ready as soon as the JSON itself is closed;
  // what makes the value unusable here is the skeleton, not the syntax. The two
  // numbers are different questions and the report keeps them apart.
  assert_true(r.syntax_permille < 1000, msg=r.syntax_permille.to_string())
}
