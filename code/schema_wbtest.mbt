// FR-36 — the skeleton declaration, its verdict, and semantic readiness.

///|
/// `Schema::parse`, or `Any` so that a test can assert on the string form.
fn schema_or_any(text : String) -> Schema {
  Schema::parse(text) catch {
    _ => Any
  }
}

///|
/// `"ok"`, or the `E` code `Schema::parse` raised.
fn parse_code(text : String) -> String {
  try {
    ignore(Schema::parse(text))
    "ok"
  } catch {
    e => e.code()
  }
}

///|
/// The parsed value of `text`, or `Json::null()` when it does not parse.
fn jv(text : String) -> Json {
  let p = parse(text) catch { _ => return Json::null() }
  p.value
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

// ---------------------------------------------------------------------------
// Q-23 — the round-trip invariant of the text form.
//
// Frozen decision: keep "no marker means required" in the DSL, but
// `stringify()` must preserve the `?`, so `parse -> stringify -> parse` is
// semantically identical to the original. `!` is explicit-redundant syntax:
// written for the reader and reserved for a future strict mode, never a
// requirement marker, because a member is required by default.
// ---------------------------------------------------------------------------

///|
/// Declarations covering every kind, nesting, arrays, optional members and the
/// separator variants the parser accepts, plus the 0.7.0 constraint list in
/// every position it can appear.
fn round_trip_corpus() -> Array[String] {
  [
    "any", "null", "boolean", "bool", "number", "integer", "int", "string", "[integer]",
    "[{!a:string,?b:[number]}]", "{}", "{a:string}", "{?a:string}", "{!a:integer,?b:[string]}",
    "{a:string; b:integer}", "{ a : string }", "{!a:{!b:{?c:[boolean]}}}", "{!list:[{!x:number}],!map:{?k:string}}",
    "{!a:any,!b:null,!c:boolean,!d:number,!e:integer,!f:string}", "integer(minimum:0)",
    "integer(maximum:10)", "number(exclusiveMinimum:0)", "number(exclusiveMaximum:1.5)",
    "number(minimum:-1.5,maximum:2)", "int(minimum:0)", "string(minLength:1)", "string(maxLength:64)",
    "string(minLength:1,maxLength:8)", "string(pattern:[a-z])", "string(pattern:[^\"])",
    "string(pattern:[a-zA-Z0-9_])", "string(pattern:[\\d])", "string(pattern:[\\w\\s])",
    "any(enum:[1,\"two\",null,true])", "string(enum:[\"low\",\"high\"])", "integer(enum:[1,2,3])",
    "[integer(minimum:0)]", "{!limit:integer(minimum:1),?note:string(maxLength:80)}",
    "{!kind:string(enum:[\"a\",\"b\"]);?n:number(minimum:0,exclusiveMaximum:1)}",
    "{!items:[string(pattern:[A-Z])]}", "any(enum:[null])",
  ]
}

///|
/// The value every declaration in the corpus is judged against.
fn round_trip_value() -> Json {
  let p = parse(
    "{\"a\":1,\"b\":\"s\",\"c\":true,\"d\":null,\"e\":3,\"f\":[1,2],\"g\":{\"x\":1},\"list\":[{\"x\":2}],\"map\":{\"k\":\"v\"}}",
  ) catch {
    _ => return Json::null()
  }
  p.value
}

///|
/// Every mismatch of a verdict as `path|expected|got`, joined with `,`.
fn mismatch_text(v : SchemaVerdict) -> String {
  let parts : Array[String] = []
  for m in v.mismatched {
    parts.push(m.path + "|" + m.expected + "|" + m.got)
  }
  parts.join(",")
}

///|
/// The values the acceptance decision is compared over: one per kind, plus a
/// non-integer number so that `integer` and `number` cannot be confused, plus
/// the values that discriminate the constraints (0.7.0): below/at/above a bound,
/// short/long strings, a string outside a class, and a literal that is and is
/// not in an `enum`.
fn round_trip_probes() -> Array[Json] {
  [
    Json::null(),
    jv("true"),
    Json::number(1.0),
    Json::number(1.5),
    Json::number(0.0),
    Json::number(-1.0),
    Json::number(2.0),
    Json::number(3.0),
    Json::string("x"),
    Json::string(""),
    Json::string("abc"),
    Json::string("AZ_9"),
    Json::string("a-b"),
    Json::string("low"),
    Json::array([]),
    Json::object(Map([])),
  ]
}

///|
test "parse then stringify then parse is a fixed point" {
  for text in round_trip_corpus() {
    let first = Schema::parse(text) catch {
      _ => return assert_true(false, msg="corpus entry did not parse: " + text)
    }
    let canon = first.stringify()
    // One round trip normalises; a second changes nothing. That is what makes
    // the canonical spelling usable as a cache key or a diff.
    let second = Schema::parse(canon) catch {
      _ =>
        return assert_true(
          false,
          msg="canonical form did not parse: " + text + " -> " + canon,
        )
    }
    assert_eq(text + " -> " + second.stringify(), text + " -> " + canon)
  }
}

///|
test "a round trip preserves meaning, not just spelling" {
  let value = round_trip_value()
  for text in round_trip_corpus() {
    let first = Schema::parse(text) catch {
      _ => return assert_true(false, msg="corpus entry did not parse: " + text)
    }
    let second = Schema::parse(first.stringify()) catch {
      _ =>
        return assert_true(false, msg="canonical form did not parse: " + text)
    }
    // The same required paths, in the same declaration order.
    assert_eq(
      text + " required " + second.required_paths().join(","),
      text + " required " + first.required_paths().join(","),
    )
    // The same verdict against the same value.
    let a = first.evaluate(value)
    let b = second.evaluate(value)
    assert_eq(
      text + " ok " + b.ok.to_string(),
      text + " ok " + a.ok.to_string(),
    )
    assert_eq(
      text + " total " + b.total.to_string(),
      text + " total " + a.total.to_string(),
    )
    assert_eq(
      text + " satisfied " + b.satisfied.to_string(),
      text + " satisfied " + a.satisfied.to_string(),
    )
    assert_eq(
      text + " missing " + b.missing.join(","),
      text + " missing " + a.missing.join(","),
    )
    assert_eq(
      text + " mismatched " + b.mismatched.length().to_string(),
      text + " mismatched " + a.mismatched.length().to_string(),
    )
    // Not just how many, but what each one expected: a round trip that lost a
    // constraint would still have the same count only by coincidence, and the
    // `expected` string is what a caller acts on.
    assert_eq(
      text + " mismatches " + mismatch_text(b),
      text + " mismatches " + mismatch_text(a),
    )
    // The same acceptance decision on every probe, `integer` vs `number`
    // included.
    for probe in round_trip_probes() {
      assert_eq(
        text +
        " accepts " +
        probe.stringify() +
        " " +
        second.accepts(probe).to_string(),
        text +
        " accepts " +
        probe.stringify() +
        " " +
        first.accepts(probe).to_string(),
      )
    }
  }
}

///|
test "the optional marker is not lost, and it means something" {
  let required = schema_or_any("{a:string}")
  let optional = schema_or_any("{?a:string}")
  assert_eq(required.stringify(), "{!a:string}")
  assert_eq(optional.stringify(), "{?a:string}")
  // The two declarations stringify differently, which is the whole point: a
  // `?` that round-tripped to nothing would change the meaning of a skeleton
  // silently.
  assert_true(required.stringify() != optional.stringify(), msg="marker lost")
  assert_eq(required.required_paths(), ["a"])
  assert_eq(optional.required_paths(), [])
  // And the difference is semantic, not cosmetic: the same value is refused by
  // one and accepted by the other.
  let empty = parse("{}") catch { _ => return assert_true(false) }
  assert_eq(required.evaluate(empty.value).ok, false)
  assert_eq(optional.evaluate(empty.value).ok, true)
  assert_eq(empty.value.stringify(), "{}")
}

///|
test "`!` is explicit-redundant syntax, not a requirement marker" {
  // `{a:string}` and `{!a:string}` are one declaration; the canonical form
  // states the requirement the reader would otherwise have to remember.
  assert_eq(
    schema_or_any("{a:string}").stringify(),
    schema_or_any("{!a:string}").stringify(),
  )
  assert_eq(
    schema_or_any("a:string").required_paths(),
    schema_or_any("!a:string").required_paths(),
  )
  assert_eq(schema_or_any("{!a:string}").stringify(), "{!a:string}")
}

///|
test "the separators are interchangeable and normalise to `,`" {
  let comma = schema_or_any("{a:string,b:integer}")
  for
    text in [
      "{a:string;b:integer}", "{ a : string ; b : integer }", "{a:string, b:integer}",
      "{!a:string,!b:integer}",
    ] {
    assert_eq(
      text + " " + schema_or_any(text).stringify(),
      text + " " + comma.stringify(),
    )
  }
}

///|
test "a quoted member name is a known round-trip gap" {
  // A quoted name is accepted on input, including one that is not a bare
  // identifier. `stringify` used to write the name back *without* quoting, so
  // the canonical form of this one declaration class was not re-readable and
  // the invariant above could not cover it. `Schema::stringify` now quotes a
  // name that cannot be written bare, so this is a plain invariant check: the
  // canonical form is re-readable and means the same skeleton.
  let quoted = schema_or_any("{\"name with space\":string}")
  assert_eq(quoted.member_keys(), ["name with space"])
  assert_eq(quoted.required_paths(), ["name with space"])
  assert_eq(quoted.stringify(), "{!\"name with space\":string}")
  assert_eq(parse_code(quoted.stringify()), "ok")
  // The bare form would have parsed to a different skeleton, which is exactly
  // what the quoting prevents.
  assert_eq(parse_code("{!name with space:string}"), "E070")
  // A quoted name that is a bare identifier is fine, because the quotes were
  // never carrying information.
  assert_eq(schema_or_any("{\"a\":string}").stringify(), "{!a:string}")
  // A `:` inside a name has the same problem and the same fix.
  let colon = schema_or_any("{\"a:b\":integer}")
  assert_eq(colon.stringify(), "{!\"a:b\":integer}")
  assert_eq(parse_code(colon.stringify()), "ok")
}

// ---------------------------------------------------------------------------
// Accessors and the parse errors, so the map of the declaration language is
// complete rather than the happy path only.
// ---------------------------------------------------------------------------

///|
test "every kind has a stable name" {
  let table : Array[(String, String)] = [
    ("any", "any"),
    ("null", "null"),
    ("boolean", "boolean"),
    ("bool", "boolean"),
    ("number", "number"),
    ("integer", "integer"),
    ("int", "integer"),
    ("string", "string"),
    ("[integer]", "array"),
    ("{a:string}", "object"),
  ]
  for (decl, name) in table {
    assert_eq(decl + " " + schema_or_any(decl).name(), decl + " " + name)
  }
}

///|
test "members are looked up by name only in an object" {
  let s = schema_or_any("{!a:string,?b:integer}")
  assert_eq(s.member_keys(), ["a", "b"])
  let a_required = match s.field("a") {
    Some(m) => m.required
    None => false
  }
  let b_required = match s.field("b") {
    Some(m) => m.required
    None => true
  }
  assert_eq(a_required, true)
  assert_eq(b_required, false)
  assert_true(s.field("z") is None, msg="an undeclared member is None")
  // Member equality is structural, so two separately parsed declarations are
  // equal and two different ones are not.
  assert_true(s.field("a") == s.field("a"), msg="structural equality")
  assert_true(s.field("a") != s.field("b"), msg="required vs type")
  // A leaf has no members and no fields.
  let leaf = schema_or_any("integer")
  assert_eq(leaf.member_keys(), [])
  assert_true(leaf.field("a") is None, msg="a leaf has no members")
  assert_true(leaf.at_path("a") is None, msg="a leaf has no path")
}

///|
test "at_path walks members, indices and stops at a leaf" {
  let s = schema_or_any("{!a:{!b:[integer]},?c:string}")
  // `""` is the whole declaration.
  assert_eq(s.at_path("").map(fn(x) { x.stringify() }), Some(s.stringify()))
  assert_eq(s.at_path("a").map(fn(x) { x.stringify() }), Some("{!b:[integer]}"))
  assert_eq(s.at_path("a.b").map(fn(x) { x.name() }), Some("array"))
  // A numeric step selects the array element declaration.
  assert_eq(s.at_path("a.b.0").map(fn(x) { x.name() }), Some("integer"))
  assert_eq(s.at_path("a.b.7").map(fn(x) { x.name() }), Some("integer"))
  // Optional members resolve like required ones; `at_path` is a lookup, not a
  // readiness question.
  assert_eq(s.at_path("c").map(fn(x) { x.name() }), Some("string"))
  assert_true(s.at_path("a.z") is None, msg="an undeclared member")
  assert_true(s.at_path("a.b.x") is None, msg="a non numeric array step")
  assert_true(s.at_path("a.b.-1") is None, msg="a negative array step")
  assert_true(s.at_path("c.d") is None, msg="through a leaf")
}

///|
test "a mismatch is reported for every value kind" {
  // A value of the wrong kind at the root names `<root>`.
  let obj = schema_or_any("{!a:string}")
  let as_array = obj.evaluate(Json::array([]))
  assert_eq(as_array.ok, false)
  assert_eq(as_array.mismatched.length(), 1)
  assert_eq(as_array.mismatched[0].path, "<root>")
  assert_eq(as_array.mismatched[0].expected, "object")
  assert_eq(as_array.mismatched[0].got, "array")
  let arr = schema_or_any("[integer]")
  let as_number = arr.evaluate(Json::number(1.0))
  assert_eq(as_number.mismatched[0].path, "<root>")
  assert_eq(as_number.mismatched[0].expected, "array")
  assert_eq(as_number.mismatched[0].got, "number")
  // Nested arrays are walked by index path, and the path of a mismatch inside
  // an object member is the dotted path the caller declared.
  let nested = schema_or_any("{!a:[[integer]],!b:{!c:string}}")
  let bad = parse("{\"a\":[[1],[\"x\"]],\"b\":{\"c\":1}}") catch {
    _ => return assert_true(false, msg="input did not parse")
  }
  let v = nested.evaluate(bad.value)
  assert_eq(v.ok, false)
  assert_eq(v.mismatched.length(), 2)
  assert_eq(v.mismatched[0].path, "a.1.0")
  assert_eq(v.mismatched[0].expected, "integer")
  assert_eq(v.mismatched[1].path, "b.c")
  assert_eq(v.mismatched[1].expected, "string")
  // `kind_of` is total over the six kinds.
  assert_eq(kind_of(Json::null()), "null")
  assert_eq(kind_of(jv("true")), "boolean")
  assert_eq(kind_of(jv("false")), "boolean")
  assert_eq(kind_of(Json::number(1.0)), "number")
  assert_eq(kind_of(Json::string("")), "string")
  assert_eq(kind_of(Json::array([])), "array")
  assert_eq(kind_of(Json::object(Map([]))), "object")
}

///|
test "a lookup through an array is by index and never out of range" {
  let v = parse("[10,20]") catch { _ => return assert_true(false) }
  assert_eq(lookup_path(v.value, "0").map(fn(x) { x.stringify() }), Some("10"))
  assert_eq(lookup_path(v.value, "1").map(fn(x) { x.stringify() }), Some("20"))
  assert_true(lookup_path(v.value, "2") is None, msg="past the end")
  assert_true(lookup_path(v.value, "-1") is None, msg="negative")
  assert_true(lookup_path(v.value, "x") is None, msg="not an index")
  assert_true(lookup_path(Json::number(1.0), "0") is None, msg="through a leaf")
}

///|
test "the parser reports where a declaration went wrong" {
  let cases : Array[(String, String)] = [
    // An empty declaration, and text that is only spaces.
    ("", "E070"),
    ("   ", "E070"),
    // An array that is never closed, and an empty one (an element type is
    // mandatory).
    ("[integer", "E070"),
    ("[]", "E070"),
    // A quoted string where a type belongs: only members have names.
    ("\"x\"", "E070"),
    ("{a:\"x\"}", "E070"),
    // An object that is never closed, and a member with no `:`.
    ("{", "E070"),
    ("{a:string", "E070"),
    ("{a string}", "E070"),
    ("{a:}", "E070"),
    // A quoted member name that is never closed.
    ("{\"a:string}", "E070"),
    // A member name cannot be empty.
    ("{:string}", "E070"),
    // An unknown type.
    ("{a:strng}", "E070"),
    ("true", "E070"),
    // Text after the declaration.
    ("{a:string}x", "E070"),
    // A member declared twice, whatever its marker.
    ("{a:string,!a:integer}", "E070"),
    ("{?a:string,a:string}", "E070"),
  ]
  for (text, code) in cases {
    assert_eq(text + " " + parse_code(text), text + " " + code)
  }
  // And the aliases and case-insensitive keywords are accepted.
  assert_eq(parse_code("BOOL"), "ok")
  assert_eq(parse_code("{a:Int,b:Boolean,c:ANY}"), "ok")
}

// ---------------------------------------------------------------------------
// The measured helpers behind `semantic_readiness`.
// ---------------------------------------------------------------------------

///|
test "the sampling step is explicit or automatic" {
  assert_eq(auto_step(10000, 7), 7)
  assert_eq(auto_step(10000, 0), 10)
  // A short document is sampled one code unit at a time rather than zero.
  assert_eq(auto_step(5, 0), 1)
  assert_eq(auto_step(0, 0), 1)
  // The per mille conversion never divides by zero.
  assert_eq(permille(50, 100), 500)
  assert_eq(permille(1, 3), 333)
  assert_eq(permille(1, 0), 1000)
  assert_eq(permille(0, 0), 1000)
}

///|
test "syntax readiness is the moment the value stopped changing" {
  // A trailing space is already there when the value is closed, so the value
  // is final before the end.
  let early = syntax_readiness_permille("{\"a\":1}   ", step=1)
  assert_true(early > 0 && early < 1000, msg=early.to_string())
  // The last member is a number that cannot be final until the root closes.
  assert_eq(syntax_readiness_permille("{\"a\":1}", step=1), 1000)
  // An unclosed container is auto-closed at the end, so it is final there.
  assert_eq(syntax_readiness_permille("{", step=1), 1000)
  // Nothing to measure, or nothing parseable at all.
  assert_eq(syntax_readiness_permille("", step=1), -1)
  assert_eq(syntax_readiness_permille("   ", step=1), -1)
}

///|
test "a whole number is an integer, a fractional one is only a number" {
  assert_eq(is_integer(Json::number(3.0)), true)
  assert_eq(is_integer(Json::number(3.5)), false)
  assert_eq(is_integer(Json::string("3")), false)
  assert_eq(schema_or_any("number").accepts(Json::number(3.5)), true)
  assert_eq(schema_or_any("integer").accepts(Json::number(3.5)), false)
  assert_eq(schema_or_any("integer").accepts(Json::number(3.0)), true)
  // Every kind accepts exactly its own shape.
  let table : Array[(String, Json, Bool)] = [
    ("any", Json::null(), true),
    ("null", Json::null(), true),
    ("null", jv("true"), false),
    ("boolean", jv("true"), true),
    ("boolean", jv("false"), true),
    ("boolean", Json::null(), false),
    ("string", Json::string(""), true),
    ("string", Json::number(1.0), false),
    ("[integer]", Json::array([]), true),
    ("[integer]", Json::object(Map([])), false),
    ("{a:string}", Json::object(Map([])), true),
    ("{a:string}", Json::array([]), false),
  ]
  for (decl, value, want) in table {
    assert_eq(
      decl +
      " " +
      value.stringify() +
      " " +
      schema_or_any(decl).accepts(value).to_string(),
      decl + " " + value.stringify() + " " + want.to_string(),
    )
  }
}

// ---------------------------------------------------------------------------
// The plan the verdict feeds (FR-33/FR-34).
//
// `plan_wbtest.mbt` is not this task's file, so the plan surface that the
// skeleton and the decision touch is exercised from here. Every case is a
// behavioural assertion about `analyze`, not a reach into a private helper,
// except where the helper *is* the public API (`advice_for`, `json_escape`).
// ---------------------------------------------------------------------------

///|
/// A `PlanOp` with the given rule name and ambiguity, for `advice_for`.
fn advice_op(name : String, ambiguity : Ambiguity) -> PlanOp {
  {
    rule: "R000",
    name,
    action: Remove,
    position: { offset: 0, line: 1, column: 1, },
    severity: Info,
    ambiguity,
    confidence_class: "certain",
    confidence: 1.0,
  }
}

///|
test "every rule has a sentence of advice and every reading has its own" {
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
    let advice = advice_for(advice_op(c.name(), Unambiguous))
    assert_true(advice.length() > 0, msg=c.name() + " has no advice")
  }
  // A second reading is more specific than the rule that produced it, which is
  // the reason the four sentences name the ambiguity rather than the code.
  assert_eq(
    advice_for(advice_op("InsertComma", AdjacentStrings)),
    "Separate the two adjacent strings with a comma, or merge them into one string.",
  )
  assert_eq(
    advice_for(advice_op("ConcatStrings", ConcatOperator)),
    "Remove the `+`, or merge the two strings into one string.",
  )
  assert_eq(
    advice_for(advice_op("QuoteBareWord", BareWord)),
    "Quote the bare word, or spell it as a JSON literal.",
  )
  assert_eq(
    advice_for(advice_op("DropUnexpected", TrailingContent)),
    "Return exactly one JSON value.",
  )
  // And the pipeline reaches the same sentences from real input.
  assert_eq(analyze("[fast]").suggestions(), [
    "Quote the bare word, or spell it as a JSON literal.",
  ])
  assert_eq(analyze("{\"a\":1} {\"b\":2}").suggestions(), [
    "Return exactly one JSON value.",
  ])
}

///|
test "a refusal keeps the rule that was refused as an operation" {
  // The strict profile refuses the first repair with `E010`; the plan still
  // shows *what* was refused, so a caller can print the same "why" for a
  // refusal as for an accepted repair.
  let strict = analyze("{'a':1}", options=Options::strict())
  assert_eq(strict.error_code, "E010")
  assert_eq(strict.decision.name(), "lossy_repair")
  assert_eq(strict.repairs.length(), 1)
  assert_eq(strict.repairs[0].rule, "R003")
  assert_eq(strict.repairs[0].confidence_class, "refused")
  assert_true(strict.explain_text().contains("R003"), msg=strict.explain_text())
  assert_true(strict.prompt().contains("JSONMend refused"), msg=strict.prompt())
  // The other refusal shape is an ambiguity refused by the execution profile.
  let ambiguous = analyze("[\"a\" \"b\"]", options=Options::for_execution())
  assert_eq(ambiguous.error_code, "E011")
  assert_eq(ambiguous.decision.name(), "ambiguous")
  assert_true(
    ambiguous.explain_text().contains("ambiguous"),
    msg=ambiguous.explain_text(),
  )
  assert_true(ambiguous.prompt().contains("E011"), msg=ambiguous.prompt())
}

///|
test "the explanation says which of the three shapes it is" {
  let clean = analyze("{\"a\":1}")
  let text = clean.explain_text()
  assert_true(text.contains("none (valid JSON)"), msg=text)
  assert_true(text.contains("SAFE TO EXECUTE"), msg=text)
  assert_true(clean.prompt().contains("accepted"), msg=clean.prompt())
  // A refusal with no recorded operation says `none` rather than claiming the
  // input was valid.
  let refused = analyze("")
  assert_true(
    refused.explain_text().contains("  none\n"),
    msg=refused.explain_text(),
  )
  // The echo of a long input is cut so a log line stays one line.
  let long = analyze("{\"a\":\"" + "x".repeat(300) + "\"}")
  assert_true(
    long.explain_text(input=long.text).contains("…"),
    msg="the input echo is truncated",
  )
}

///|
test "the plan carries the skeleton verdict and the readiness number" {
  let s = schema_or_any("{!a:integer,!b:string}")
  // One member is the wrong kind and one is absent: the sentence names both,
  // because they are two different instructions to the model.
  let plan = analyze("{\"a\":\"x\"}", readiness=1, schema=s)
  assert_eq(plan.decision.name(), "invalid")
  assert_eq(plan.error_code, "E070")
  assert_eq(plan.schema_total, 2)
  assert_eq(plan.schema_satisfied, 0)
  assert_eq(plan.schema_missing, ["b"])
  let prompt = plan.prompt()
  assert_true(prompt.contains("missing b"), msg=prompt)
  assert_true(prompt.contains("expected integer, got string"), msg=prompt)
  assert_true(prompt.contains("0/2 declared members"), msg=prompt)
  let json = plan.to_json()
  assert_true(json.contains("\"schema_missing\":[\"b\"]"), msg=json)
  assert_true(json.contains("\"error\":{"), msg=json)
  // `summary` adds the two measurements when they exist.
  let summary = plan.summary()
  assert_true(summary.contains("syntax-ready="), msg=summary)
  assert_true(summary.contains("schema=0/2"), msg=summary)
  // And the machine form of the same plan is valid JSON.
  let parsed = @json.parse(json) catch {
    _ => return assert_true(false, msg="to_json is not valid JSON: " + json)
  }
  assert_true(parsed is Json::Object(_), msg="the plan is an object")
}

///|
test "the plan is JSON even when a value needs escaping" {
  let plan = analyze("{\"a\":\"x\ty\"}")
  let json = plan.to_json()
  let parsed = @json.parse(json) catch {
    _ => return assert_true(false, msg="to_json is not valid JSON: " + json)
  }
  assert_true(parsed is Json::Object(_), msg="the plan is an object")
  // `json_escape` covers the four cases the JSON objects in this library emit.
  assert_eq(json_escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
  assert_eq(json_escape("a\rb\tc"), "a\\rb\\tc")
  assert_eq(json_escape("a\u0001b"), "a\\u0001b")
}

///|
test "a streamed parser reaches the plan without an input echo" {
  let p = PartialParser::new() catch {
    _ => return assert_true(false, msg="parser did not build")
  }
  p.feed("{\"a\":1}") catch {
    _ => return assert_true(false, msg="feed failed")
  }
  // No `input` was kept, so the plan cannot quote a window; it still decides.
  let plan = p.analyze()
  assert_eq(plan.decision.name(), "safe")
  assert_eq(plan.text, "{\"a\":1}")
  assert_eq(plan.is_executable(), true)
}

///|
test "operations and decisions compare by the reading they denote" {
  // `PlanAction` and `PlanOp` carry explicit `Eq` so that two separately built
  // plans can be compared in a test without a debug rendering.
  assert_true(plan_action(RemoveExtraComma) == Remove, msg="action equality")
  assert_true(plan_action(RemoveExtraComma) != Insert, msg="action inequality")
  let plan = analyze("{\"a\":1,}")
  assert_true(plan.repairs[0] == plan.repairs[0], msg="operation equality")
  // `ExecutionDecision` is ordered by risk, and Safe is the least risky.
  assert_eq(Safe.rank(), 0)
  assert_eq(CosmeticRepair.rank(), 1)
  assert_eq(LossyRepair.rank(), 2)
  assert_eq(Ambiguous.rank(), 3)
  assert_eq(Invalid.rank(), 4)
  assert_eq(CosmeticRepair.worse_of(Invalid).name(), "invalid")
  assert_eq(Ambiguous.worse_of(Safe).name(), "ambiguous")
  assert_true(Safe == Safe, msg="decision equality")
  assert_true(Safe != Invalid, msg="decision inequality")
  assert_eq(CosmeticRepair.label(), "SAFE TO EXECUTE (notation normalised)")
  assert_eq(Invalid.label(), "REJECT (not repairable)")
  // The safety profiles are named by the string a command line accepts.
  assert_eq(SafetyPolicy::for_agent().name(), "agent")
  assert_eq(SafetyPolicy::for_execution().name(), "execution")
  assert_eq(SafetyPolicy::permissive().name(), "permissive")
  assert_eq(SafetyPolicy::strict().name(), "strict")
  assert_eq(SafetyPolicy::interactive().name(), "interactive")
}

///|
test "R018 is duplicate key normalisation, and valid JSON can still be blocked" {
  // Q-26, checked against the code rather than against prose: the input is
  // well-formed JSON, the only repair is `R018`, the action is `merge`, and the
  // result is still not executable because merging two different values loses
  // information.
  let plan = analyze("{\"a\":\"b\",\"a\":\"c\"}")
  assert_eq(plan.valid_json, true)
  assert_eq(plan.normalized(), true)
  assert_eq(plan.repairs.length(), 1)
  assert_eq(plan.repairs[0].rule, "R018")
  assert_eq(plan.repairs[0].name, "MergeDuplicateKey")
  assert_eq(plan.repairs[0].action.name(), "merge")
  assert_eq(plan.repairs[0].information_loss(), true)
  assert_eq(plan.exactness.name(), "lossy")
  assert_eq(plan.ambiguity_kind(), "semantic")
  assert_eq(plan.execution(), "blocked")
  assert_eq(plan.is_executable(), false)
  // Under an execution profile it is refused outright, with `E010`.
  let gated = analyze(
    "{\"a\":\"b\",\"a\":\"c\"}",
    options=Options::for_execution(),
  )
  assert_eq(gated.error_code, "E010")
  assert_eq(gated.decision.name(), "lossy_repair")
  assert_eq(gated.valid_json, true)
  assert_eq(gated.execution(), "blocked")
  // Two structurally equal values lose nothing: the record is Info, the result
  // is cosmetic, and a display channel may execute it.
  let equal = analyze("{\"a\":1,\"a\":1}")
  assert_eq(equal.repairs[0].information_loss(), false)
  assert_eq(equal.exactness.name(), "cosmetic")
  assert_eq(equal.execution(), "allowed")
  // Merging two structurally equal values is not a second meaning: both
  // readings produce the same value, so the plan reports no ambiguity at all.
  assert_eq(equal.ambiguity_kind(), "none")
  // A document that needed no repair at all is the other half of the pair.
  let clean = analyze("{\"a\":1}")
  assert_eq(clean.valid_json, true)
  assert_eq(clean.normalized(), false)
  assert_eq(clean.execution(), "allowed")
  assert_eq(clean.decision.name(), "safe")
}

// ---------------------------------------------------------------------------
// 0.7.0 — value constraints.
//
// A constraint is part of the declaration language, not a separate validator:
// it parses with the same `E070`, it stringifies back (the corpus above proves
// the round trip), it is checked by `accepts`/`evaluate`, and the streaming
// watcher refuses a value on the delta that makes it final
// (`stream_readiness_wbtest.mbt`).
// ---------------------------------------------------------------------------

///|
/// The `E070` diagnostic of a declaration, or `"ok"`.
fn parse_error(text : String) -> String {
  try {
    ignore(Schema::parse(text))
    "ok"
  } catch {
    e => e.to_string()
  }
}

///|
test "the constraint list round trips in a canonical spelling" {
  // Whitespace, `;` and the written order are normalised; the kind is not.
  assert_eq(
    schema_or_any("integer( minimum : 0 )").stringify(),
    "integer(minimum:0)",
  )
  assert_eq(
    schema_or_any("number(maximum:10,minimum:0)").stringify(),
    "number(minimum:0,maximum:10)",
  )
  assert_eq(
    schema_or_any("string(maxLength:8;minLength:1)").stringify(),
    "string(minLength:1,maxLength:8)",
  )
  assert_eq(schema_or_any("NUMBER(MINIMUM:0)").stringify(), "number(minimum:0)")
  assert_eq(schema_or_any("int(minimum:0)").stringify(), "integer(minimum:0)")
  assert_eq(
    schema_or_any("any(enum:[1,\"two\",null,true])").stringify(),
    "any(enum:[1,\"two\",null,true])",
  )
  assert_eq(
    schema_or_any("string(pattern:[a-z])").stringify(),
    "string(pattern:[a-z])",
  )
  // `pattern` is stored as written, so its escapes survive the trip.
  assert_eq(
    schema_or_any("string(pattern:[\\d\\-])").stringify(),
    "string(pattern:[\\d\\-])",
  )
  // A kind with no constraint list is the plain kind, exactly as in 0.6.x.
  assert_eq(schema_or_any("integer").stringify(), "integer")
  assert_eq(schema_or_any("{!a:integer}").stringify(), "{!a:integer}")
  // The expectation is the declaration as written.
  assert_eq(schema_or_any("integer").expectation(), "integer")
  assert_eq(
    schema_or_any("integer(minimum:0)").expectation(),
    "integer(minimum:0)",
  )
  assert_eq(schema_or_any("integer(minimum:0)").name(), "integer")
}

///|
test "a numeric constraint reports the violated bound, not the kind" {
  let s = schema_or_any("{!limit:integer(minimum:1)}")
  let v = s.evaluate(jv("{\"limit\":0}"))
  assert_eq(v.ok, false)
  assert_eq(v.satisfied, 0)
  assert_eq(v.mismatched[0].path, "limit")
  assert_eq(v.mismatched[0].expected, "integer >= 1")
  assert_eq(v.mismatched[0].got, "number")
  // Inclusive at the bound.
  assert_eq(s.evaluate(jv("{\"limit\":1}")).ok, true)
  // Exclusive variants.
  let e = schema_or_any("{!n:number(exclusiveMinimum:0)}")
  assert_eq(e.evaluate(jv("{\"n\":0}")).mismatched[0].expected, "number > 0")
  assert_eq(e.evaluate(jv("{\"n\":0.5}")).ok, true)
  let x = schema_or_any("{!n:number(exclusiveMaximum:1)}")
  assert_eq(x.evaluate(jv("{\"n\":1}")).mismatched[0].expected, "number < 1")
  assert_eq(x.evaluate(jv("{\"n\":0.999}")).ok, true)
  let m = schema_or_any("{!n:number(maximum:2)}")
  assert_eq(m.evaluate(jv("{\"n\":2}")).ok, true)
  assert_eq(m.evaluate(jv("{\"n\":2.5}")).mismatched[0].expected, "number <= 2")
  // Two bounds: the one that failed is the one named.
  let both = schema_or_any("{!n:number(minimum:0,maximum:10)}")
  assert_eq(
    both.evaluate(jv("{\"n\":11}")).mismatched[0].expected,
    "number <= 10",
  )
  assert_eq(
    both.evaluate(jv("{\"n\":-1}")).mismatched[0].expected,
    "number >= 0",
  )
  // The whole declaration is what `expected` says when the kind is wrong.
  assert_eq(
    both.evaluate(jv("{\"n\":\"x\"}")).mismatched[0].expected,
    "number(minimum:0,maximum:10)",
  )
  assert_eq(both.evaluate(jv("{\"n\":\"x\"}")).mismatched[0].got, "string")
  // A constraint does not make a non-integer an integer.
  assert_eq(
    schema_or_any("integer(minimum:0)").accepts(Json::number(1.5)),
    false,
  )
}

///|
test "a string constraint measures code units and a character class" {
  let len = schema_or_any("{!name:string(minLength:1,maxLength:3)}")
  assert_eq(
    len.evaluate(jv("{\"name\":\"\"}")).mismatched[0].expected,
    "string with length >= 1",
  )
  assert_eq(len.evaluate(jv("{\"name\":\"\"}")).ok, false)
  assert_eq(len.evaluate(jv("{\"name\":\"abc\"}")).ok, true)
  assert_eq(len.evaluate(jv("{\"name\":\"abcd\"}")).ok, false)
  assert_eq(
    len.evaluate(jv("{\"name\":\"abcd\"}")).mismatched[0].expected,
    "string with length <= 3",
  )
  // An emoji is one character and two code units, which is the unit the rest of
  // the library counts in (BR-20).
  assert_eq(len.evaluate(jv("{\"name\":\"x😀\"}")).ok, true)
  assert_eq(len.evaluate(jv("{\"name\":\"😀😀\"}")).ok, false)
  // A character class: every code unit of the value must be in the set.
  let cls = schema_or_any("{!code:string(pattern:[A-Za-z0-9_])}")
  assert_eq(cls.evaluate(jv("{\"code\":\"AZ_9\"}")).ok, true)
  assert_eq(cls.evaluate(jv("{\"code\":\"a-b\"}")).ok, false)
  assert_eq(
    cls.evaluate(jv("{\"code\":\"a-b\"}")).mismatched[0].expected,
    "string of characters in [A-Za-z0-9_]",
  )
  // The empty string has no character outside the class.
  assert_eq(cls.evaluate(jv("{\"code\":\"\"}")).ok, true)
  // These are literal characters inside a class, not regex operators.
  assert_eq(schema_or_any("string(pattern:[.+*])").accepts(jv("\"+.*\"")), true)
  assert_eq(schema_or_any("string(pattern:[.+*])").accepts(jv("\"a\"")), false)
  // Negation, and the `-` at either end staying a literal.
  assert_eq(schema_or_any("string(pattern:[^ab])").accepts(jv("\"c\"")), true)
  assert_eq(schema_or_any("string(pattern:[^ab])").accepts(jv("\"a\"")), false)
  assert_eq(schema_or_any("string(pattern:[-a])").accepts(jv("\"-\"")), true)
  assert_eq(schema_or_any("string(pattern:[a-])").accepts(jv("\"-\"")), true)
  // Shorthands.
  assert_eq(schema_or_any("string(pattern:[\\d])").accepts(jv("\"42\"")), true)
  assert_eq(schema_or_any("string(pattern:[\\d])").accepts(jv("\"4a\"")), false)
  assert_eq(schema_or_any("string(pattern:[\\w])").accepts(jv("\"a_9\"")), true)
  assert_eq(schema_or_any("string(pattern:[\\s])").accepts(jv("\" \t\"")), true)
  assert_eq(schema_or_any("string(pattern:[\\n])").accepts(jv("\"\\n\"")), true)
  assert_eq(schema_or_any("string(pattern:[\\S])").accepts(jv("\"\\S\"")), true)
}

///|
test "enum admits exactly its literals" {
  let s = schema_or_any("{!kind:string(enum:[\"low\",\"high\"])}")
  assert_eq(s.evaluate(jv("{\"kind\":\"low\"}")).ok, true)
  assert_eq(s.evaluate(jv("{\"kind\":\"high\"}")).ok, true)
  assert_eq(s.evaluate(jv("{\"kind\":\"medium\"}")).ok, false)
  assert_eq(
    s.evaluate(jv("{\"kind\":\"medium\"}")).mismatched[0].expected,
    "one of [\"low\",\"high\"]",
  )
  assert_eq(s.evaluate(jv("{\"kind\":\"medium\"}")).mismatched[0].got, "string")
  // Kind and list are both required.
  // The declaration checked against a bare value is the scalar one.
  assert_eq(
    schema_or_any("string(enum:[\"low\",\"high\"])").accepts(jv("\"low\"")),
    true,
  )
  assert_eq(
    schema_or_any("string(enum:[\"low\",\"high\"])").accepts(jv("1")),
    false,
  )
  let n = schema_or_any("{!n:integer(enum:[1,2,3])}")
  assert_eq(n.evaluate(jv("{\"n\":2}")).ok, true)
  assert_eq(n.evaluate(jv("{\"n\":4}")).ok, false)
  assert_eq(
    n.evaluate(jv("{\"n\":4}")).mismatched[0].expected,
    "one of [1,2,3]",
  )
  assert_eq(n.evaluate(jv("{\"n\":2.5}")).ok, false)
  // 2 and 2.0 are the same JSON number, on the scalar declaration.
  assert_eq(
    schema_or_any("integer(enum:[1,2,3])").accepts(Json::number(2.0)),
    true,
  )
  assert_eq(
    schema_or_any("integer(enum:[1,2,3])").accepts(Json::number(4.0)),
    false,
  )
  // `enum` is allowed on any kind, and only literals the kind can hold.
  assert_eq(
    schema_or_any("any(enum:[null,true,1,\"a\"])").accepts(Json::null()),
    true,
  )
  assert_eq(
    schema_or_any("any(enum:[null,true,1,\"a\"])").accepts(jv("false")),
    false,
  )
  assert_eq(schema_or_any("null(enum:[null])").accepts(Json::null()), true)
}

///|
test "a constrained scalar root is checked, a bare kind root is not" {
  // A bare kind at the root declares no members, and `evaluate` walks members:
  // this is 0.6.x behaviour and it does not change.
  assert_eq(schema_or_any("integer").evaluate(Json::string("x")).ok, true)
  assert_eq(schema_or_any("integer").accepts(Json::string("x")), false)
  // A constraint is a claim about the value, so it is checked at the root.
  let s = schema_or_any("integer(minimum:0)")
  assert_eq(s.evaluate(Json::number(-1.0)).ok, false)
  assert_eq(s.evaluate(Json::number(-1.0)).mismatched[0].path, "<root>")
  assert_eq(
    s.evaluate(Json::number(-1.0)).mismatched[0].expected,
    "integer >= 0",
  )
  assert_eq(s.evaluate(Json::number(-1.0)).mismatched[0].got, "number")
  assert_eq(s.evaluate(Json::number(0.0)).ok, true)
  assert_eq(s.evaluate(Json::string("x")).ok, false)
  assert_eq(
    s.evaluate(Json::string("x")).mismatched[0].expected,
    "integer(minimum:0)",
  )
  assert_eq(
    schema_or_any("string(enum:[\"a\"])").evaluate(jv("\"b\"")).ok,
    false,
  )
}

///|
test "constraints are checked where the declaration nests" {
  let s = schema_or_any(
    "{!items:[integer(minimum:0)],!meta:{?tags:[string(maxLength:2)]}}",
  )
  assert_eq(
    s.accepts(jv("{\"items\":[0,1],\"meta\":{\"tags\":[\"ab\"]}}")),
    true,
  )
  let bad = s.evaluate(jv("{\"items\":[1,-2],\"meta\":{\"tags\":[\"abc\"]}}"))
  assert_eq(bad.ok, false)
  assert_eq(bad.mismatched.length(), 2)
  assert_eq(bad.mismatched[0].path, "items.1")
  assert_eq(bad.mismatched[0].expected, "integer >= 0")
  assert_eq(bad.mismatched[1].path, "meta.tags.0")
  assert_eq(bad.mismatched[1].expected, "string with length <= 2")
  // A required member that satisfies its constraints counts as satisfied.
  assert_eq(s.evaluate(jv("{\"items\":[2],\"meta\":{}}")).satisfied, 2)
  // An absent optional member is not a mismatch.
  assert_eq(s.evaluate(jv("{\"items\":[2],\"meta\":{}}")).ok, true)
}

///|
test "a constraint the kind cannot carry is E070, not a rule that never fires" {
  assert_eq(parse_code("integer(maxLength:3)"), "E070")
  assert_true(
    parse_error("integer(maxLength:3)").contains(
      "`maxLength` applies to `string`, not to `integer`, at offset 8",
    ),
    msg=parse_error("integer(maxLength:3)"),
  )
  assert_true(
    parse_error("integer(pattern:[a-z])").contains(
      "`pattern` applies to `string`, not to `integer`",
    ),
    msg=parse_error("integer(pattern:[a-z])"),
  )
  assert_true(
    parse_error("string(minimum:0)").contains(
      "`minimum` applies to `number` and `integer`, not to `string`",
    ),
    msg=parse_error("string(minimum:0)"),
  )
  assert_true(
    parse_error("boolean(minimum:0)").contains("not to `boolean`"),
    msg=parse_error("boolean(minimum:0)"),
  )
}

///|
test "the constraint value itself is checked, with its offset" {
  // A number is expected and something else arrived.
  assert_true(
    parse_error("integer(minimum:abc)").contains(
      "`minimum` expects a number at offset 16",
    ),
    msg=parse_error("integer(minimum:abc)"),
  )
  // `+1` is not a JSON number, so the token is named rather than coerced.
  assert_true(
    parse_error("integer(minimum:+1)").contains(
      "`minimum` expects a number at offset 16: `+1`",
    ),
    msg=parse_error("integer(minimum:+1)"),
  )
  // Lengths are non-negative integers.
  assert_true(
    parse_error("string(minLength:-1)").contains(
      "`minLength` expects a non-negative integer at offset 17",
    ),
    msg=parse_error("string(minLength:-1)"),
  )
  assert_true(
    parse_error("string(maxLength:1.5)").contains(
      "`maxLength` expects a non-negative integer",
    ),
    msg=parse_error("string(maxLength:1.5)"),
  )
  // An unknown name is named, with the vocabulary.
  assert_true(
    parse_error("integer(nope:1)").contains(
      "unknown constraint `nope` at offset 8",
    ),
    msg=parse_error("integer(nope:1)"),
  )
  assert_true(
    parse_error("integer(nope:1)").contains(
      "minimum, exclusiveMinimum, maximum, exclusiveMaximum",
    ),
    msg=parse_error("integer(nope:1)"),
  )
  // A missing `:` is named.
  assert_true(
    parse_error("integer(minimum 0)").contains(
      "constraint `minimum` has no `:` at offset 8",
    ),
    msg=parse_error("integer(minimum 0)"),
  )
}

///|
test "pattern is a character class, not a regular expression" {
  // A quantifier, an alternation and an anchor are all rejected at the offset
  // they appear, so no declaration can mean something a regex engine would.
  assert_true(
    parse_error("string(pattern:[a-z]+)").contains(
      "unexpected `+` in a constraint list at offset 20",
    ),
    msg=parse_error("string(pattern:[a-z]+)"),
  )
  assert_true(
    parse_error("string(pattern:[a-z]*)").contains(
      "unexpected `*` in a constraint list",
    ),
    msg=parse_error("string(pattern:[a-z]*)"),
  )
  assert_true(
    parse_error("string(pattern:^(a|b)$)").contains(
      "`pattern` accepts a character class `[...]` and nothing else, at offset 15",
    ),
    msg=parse_error("string(pattern:^(a|b)$)"),
  )
  assert_true(
    parse_error("string(pattern:a-z)").contains(
      "`pattern` accepts a character class `[...]` and nothing else",
    ),
    msg=parse_error("string(pattern:a-z)"),
  )
  // Malformed classes are named at the class.
  assert_true(
    parse_error("string(pattern:[])").contains(
      "an empty character class matches nothing, at offset 15",
    ),
    msg=parse_error("string(pattern:[])"),
  )
  assert_true(
    parse_error("string(pattern:[^])").contains(
      "`[^]` negates an empty character class, at offset 15",
    ),
    msg=parse_error("string(pattern:[^])"),
  )
  assert_true(
    parse_error("string(pattern:[z-a])").contains(
      "the character class range at offset 15 is inverted",
    ),
    msg=parse_error("string(pattern:[z-a])"),
  )
  assert_true(
    parse_error("string(pattern:[\\q])").contains(
      "`\\q` is not a character class escape at offset 15",
    ),
    msg=parse_error("string(pattern:[\\q])"),
  )
  assert_true(
    parse_error("string(pattern:[\\d-z])").contains(
      "a character class range cannot start at an escape",
    ),
    msg=parse_error("string(pattern:[\\d-z])"),
  )
  assert_true(
    parse_error("string(pattern:[a-z)").contains(
      "the character class of `pattern` is never closed at offset 15",
    ),
    msg=parse_error("string(pattern:[a-z)"),
  )
  // A `]` that does not close the whole declaration is an error, not a member.
  assert_eq(parse_code("{!a:string(pattern:[a-z])}"), "ok")
}

///|
test "enum is a JSON literal list, and only literals it can hold" {
  assert_true(
    parse_error("integer(enum:[])").contains(
      "`enum` needs at least one value at offset 13",
    ),
    msg=parse_error("integer(enum:[])"),
  )
  assert_true(
    parse_error("integer(enum:[[]])").contains(
      "`enum` admits only scalar literals at offset 13",
    ),
    msg=parse_error("integer(enum:[[]])"),
  )
  assert_true(
    parse_error("string(enum:[1,2])").contains(
      "`enum` value 1 is not a string, at offset 12",
    ),
    msg=parse_error("string(enum:[1,2])"),
  )
  assert_true(
    parse_error("integer(enum:[1,2.5])").contains(
      "`enum` value 2.5 is not a integer, at offset 13",
    ),
    msg=parse_error("integer(enum:[1,2.5])"),
  )
  assert_true(
    parse_error("integer(enum:[1,2").contains(
      "the array of `enum` is never closed at offset 13",
    ),
    msg=parse_error("integer(enum:[1,2"),
  )
  // Escapes in an enum literal are JSON escapes.
  let s = schema_or_any("string(enum:[\"a\\\"b\"])")
  assert_eq(s.accepts(jv("\"a\\\"b\"")), true)
  assert_eq(s.stringify(), "string(enum:[\"a\\\"b\"])")
}

///|
test "every declaration that parsed before 0.7.0 still parses the same" {
  // The old corpus, unchanged, one stringify away from its own canonical form.
  for
    text in [
      "any", "null", "boolean", "integer", "number", "string", "{!a:integer,?b:[string]}",
      "{a:string; b:integer}", "{!list:[{!x:number}],!map:{?k:string}}",
    ] {
    let s = schema_or_any(text)
    assert_true(s.stringify() != "any" || text == "any", msg=text)
    assert_eq(parse_code(s.stringify()), "ok")
    assert_eq(schema_or_any(s.stringify()).stringify(), s.stringify())
  }
  // A space after the kind is a space between members, as it always was, so a
  // constraint list has to be attached to the kind.
  assert_eq(
    schema_or_any("{a:integer b:string}").stringify(),
    "{!a:integer,!b:string}",
  )
  assert_eq(parse_code("{a:integer (minimum:0)}"), "E070")
}
