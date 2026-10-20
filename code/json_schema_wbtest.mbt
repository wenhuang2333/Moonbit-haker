// Tests for the JSON Schema subset bridge (`json_schema.mbt`).
//
// The bridge is judged by one property above all: a declaration that a tool
// already carries must produce the same skeleton the caller would have written
// by hand — and a keyword the skeleton cannot represent must be refused, not
// dropped.

///|
/// `Schema::parse_json_schema`, or `Any` so a test can assert on the text.
fn js_schema(text : String) -> Schema {
  Schema::parse_json_schema(text) catch {
    _ => Any
  }
}

///|
/// `"ok"`, or the `E` code the bridge raised.
fn js_code(text : String) -> String {
  try {
    ignore(Schema::parse_json_schema(text))
    "ok"
  } catch {
    e => e.code()
  }
}

///|
test "a tool declaration becomes the same skeleton as the DSL" {
  let text = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"query\"]}"
  assert_eq(
    js_schema(text).stringify(),
    "{!query:string,?limit:integer(minimum:1)}",
  )
  // And it accepts and refuses exactly what the hand-written form does.
  let s = js_schema(text)
  // `accepts` checks the kind; `evaluate` also checks required members.
  assert_true(s.evaluate(jv("{\"query\":\"MoonBit\",\"limit\":1}")).ok)
  assert_false(s.evaluate(jv("{\"limit\":1}")).ok)
  assert_false(s.evaluate(jv("{\"query\":42,\"limit\":1}")).ok)
  assert_false(s.evaluate(jv("{\"query\":\"x\",\"limit\":0}")).ok)
}

///|
test "arrays, enums, const and pattern map onto the skeleton" {
  assert_eq(
    js_schema(
      "{\"type\":\"array\",\"items\":{\"type\":\"string\",\"minLength\":1}}",
    ).stringify(),
    "[string(minLength:1)]",
  )
  assert_eq(
    js_schema("{\"type\":\"string\",\"enum\":[\"low\",\"high\"]}").stringify(),
    "string(enum:[\"low\",\"high\"])",
  )
  assert_eq(js_schema("{\"const\":42}").stringify(), "any(enum:[42])")
  assert_eq(
    js_schema("{\"type\":\"string\",\"pattern\":\"^[a-z0-9_]*$\"}").stringify(),
    "string(pattern:[a-z0-9_])",
  )
  // The quantifier is a length bound, and it is exact: `+` is minLength 1,
  // `{2,4}` is minLength 2 with maxLength 4.
  assert_eq(
    js_schema("{\"type\":\"string\",\"pattern\":\"^[a-z]+$\"}").stringify(),
    "string(minLength:1,pattern:[a-z])",
  )
  assert_eq(
    js_schema("{\"type\":\"string\",\"pattern\":\"^[A-Z]{2,4}$\"}").stringify(),
    "string(minLength:2,maxLength:4,pattern:[A-Z])",
  )
  assert_eq(
    js_schema("{\"type\":\"string\",\"pattern\":\"^[0-9]{3}$\"}").stringify(),
    "string(minLength:3,maxLength:3,pattern:[0-9])",
  )
  assert_eq(
    js_schema("{\"type\":\"string\",\"pattern\":\"^[a-z]?$\"}").stringify(),
    "string(maxLength:1,pattern:[a-z])",
  )
  assert_eq(
    js_schema("{\"type\":\"number\",\"exclusiveMaximum\":1.5,\"minimum\":0}").stringify(),
    "number(minimum:0,exclusiveMaximum:1.5)",
  )
}

///|
test "annotations are ignored, not refused" {
  let text = "{\"title\":\"search\",\"description\":\"find things\",\"default\":{},\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\",\"format\":\"email\",\"examples\":[\"a\"]}},\"required\":[\"q\"]}"
  assert_eq(js_schema(text).stringify(), "{!q:string}")
}

///|
test "additionalProperties is a no-op when true and refused when false" {
  assert_eq(
    js_schema(
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"additionalProperties\":true}",
    ).stringify(),
    "{?a:string}",
  )
  assert_eq(
    js_code(
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    ),
    "E070",
  )
}

///|
test "a required key with no properties entry means any value" {
  assert_eq(
    js_schema("{\"type\":\"object\",\"required\":[\"id\",\"note\"]}").stringify(),
    "{!id:any,!note:any}",
  )
}

///|
test "keywords the skeleton cannot represent are refused by name" {
  for
    text in [
      "{\"$ref\":\"#/definitions/x\"}", "{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"number\"}]}",
      "{\"anyOf\":[{\"type\":\"string\"}]}", "{\"allOf\":[{\"type\":\"string\"}]}",
      "{\"not\":{\"type\":\"string\"}}", "{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"uniqueItems\":true}",
      "{\"type\":\"string\",\"multipleOf\":2}",
    ] {
    assert_eq(js_code(text), "E070", msg=text)
  }
}

///|
test "a union type or a regex pattern is refused rather than approximated" {
  assert_eq(js_code("{\"type\":[\"string\",\"null\"]}"), "E070")
  assert_eq(js_code("{\"type\":\"string\",\"pattern\":\"^a.*b$\"}"), "E070")
  assert_eq(js_code("{\"type\":\"string\",\"pattern\":\"[a-z]+\"}"), "E070")
  // A one-element array is unambiguous and is accepted.
  assert_eq(js_schema("{\"type\":[\"string\"]}").stringify(), "string")
}

///|
test "a constraint on the wrong kind is refused" {
  assert_eq(js_code("{\"type\":\"integer\",\"maxLength\":4}"), "E070")
  assert_eq(js_code("{\"type\":\"string\",\"minimum\":1}"), "E070")
  assert_eq(js_code("{\"type\":\"boolean\",\"minimum\":1}"), "E070")
}

///|
test "a malformed schema is refused, never silently empty" {
  assert_eq(js_code("[]"), "E070")
  assert_eq(js_code("{\"type\":42}"), "E070")
  assert_eq(js_code("{\"type\":\"object\",\"properties\":[]}"), "E070")
  assert_eq(js_code("not json"), "E070")
}

///|
test "a realistic OpenAI-style tool schema translates whole" {
  let text = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City name\"},\"unit\":{\"type\":\"string\",\"enum\":[\"celsius\",\"fahrenheit\"]}},\"required\":[\"location\"],\"additionalProperties\":false}"
  // `additionalProperties: false` is the one common keyword the skeleton cannot
  // enforce, so the whole declaration is refused rather than half-checked.
  assert_eq(js_code(text), "E070")
  let without = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City name\"},\"unit\":{\"type\":\"string\",\"enum\":[\"celsius\",\"fahrenheit\"]}},\"required\":[\"location\"]}"
  assert_eq(
    js_schema(without).stringify(),
    "{!location:string,?unit:string(enum:[\"celsius\",\"fahrenheit\"])}",
  )
  // A missing required member is reported by the readiness machinery.
  let verdict = js_schema(without).evaluate(jv("{\"unit\":\"kelvin\"}"))
  assert_eq(verdict.ok, false)
  assert_eq(verdict.missing.length(), 1)
}

///|
/// `"ok"`, or the `E` code `Schema::of_json_schema` raised.
fn js_code_value(value : Json) -> String {
  try {
    ignore(Schema::of_json_schema(value))
    "ok"
  } catch {
    e => e.code()
  }
}

///|
test "every malformed declaration is an E070, never a silent empty schema" {
  for
    text in [
      "{\"type\":\"weird\"}", "{\"type\":null}", "{\"type\":[42]}", "{\"type\":\"object\",\"properties\":{\"a\":42}}",
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":\"a\"}",
      "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"additionalProperties\":\"no\"}",
      "{\"type\":\"string\",\"enum\":\"x\"}", "{\"type\":\"integer\",\"minimum\":\"1\"}",
      "{\"type\":\"integer\",\"minimum\":null}", "{\"type\":\"string\",\"minLength\":-1}",
      "{\"type\":\"string\",\"minLength\":1.5}", "{\"type\":\"string\",\"pattern\":\"^[a-z\"}",
      "{\"type\":\"string\",\"pattern\":\"^[a-z$\"}", "{\"type\":\"string\",\"pattern\":\"^[a-z]{2,1}$\"}",
      "{\"type\":\"string\",\"pattern\":\"^[a-z]{x}$\"}", "{\"type\":\"string\",\"pattern\":\"^[a-z]{1,2,3}$\"}",
      "{\"type\":\"string\",\"pattern\":\"^[a-z]*{2}$\"}", "{\"type\":\"string\",\"pattern\":\"^[a-z]$x\"}",
      "{\"type\":\"string\",\"pattern\":\"^[\\\\d]+$\"}", "{\"type\":\"string\",\"pattern\":\"^[[a-z]]+$\"}",
    ] {
    assert_eq(js_code(text), "E070", msg=text)
  }
}

///|
test "a non-finite bound is refused even though JSON cannot spell it" {
  assert_eq(js_code_value(Json::number(1.0 / 0.0)), "E070")
  assert_eq(js_code_value(Json::number(0.0 / 0.0)), "E070")
}

///|
test "an object shape without a type is inferred as an object" {
  assert_eq(
    js_schema("{\"properties\":{\"a\":{\"type\":\"string\"}}}").stringify(),
    "{?a:string}",
  )
  assert_eq(js_schema("{\"required\":[\"x\"]}").stringify(), "{!x:any}")
  assert_eq(js_schema("{\"type\":\"null\"}").stringify(), "null")
  assert_eq(js_schema("{\"type\":\"any\"}").stringify(), "any")
}

///|
test "enum and const accept structured values" {
  assert_eq(
    js_schema("{\"type\":\"boolean\",\"enum\":[true,false]}").stringify(),
    "boolean(enum:[true,false])",
  )
  assert_eq(
    js_schema("{\"const\":{\"a\":1}}").stringify(),
    "any(enum:[{\"a\":1}])",
  )
}
