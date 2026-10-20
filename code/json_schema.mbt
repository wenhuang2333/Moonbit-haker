// A bridge from the JSON Schema subset that agent tool declarations already
// use into the library's skeleton (`Schema`).
//
// The library is not a JSON Schema validator and does not aim to become one
// (`schema.mbt` explains why). What this file adds is narrower and more
// useful: the shape of a tool's `inputSchema` — object with typed properties,
// a `required` list, array items and the handful of value constraints the
// skeleton already understands — can be read directly, so an integration does
// not have to hand-translate the declaration it already has.
//
// The contract is deliberately strict:
//
//   * a supported keyword is mapped;
//   * an annotation (`title`, `description`, `default`, `examples`, `$schema`,
//     `$id`, `deprecated`, `readOnly`, `writeOnly`, `format`) is ignored;
//   * `additionalProperties: true` is a no-op, `false` is refused because the
//     skeleton cannot enforce "no other members";
//   * anything else (`$ref`, `oneOf`, `anyOf`, `allOf`, `not`, `minItems`,
//     `uniqueItems`, `multipleOf`, …) is an `E070`, never a silent ignore.
//
// A gate that silently drops half of a declaration is worse than one that
// refuses it: the caller would believe a guarantee that was never checked.

///|
/// Fields of a JSON Schema node that carry no validation meaning here.
fn json_schema_annotation(key : String) -> Bool {
  key == "title" ||
  key == "description" ||
  key == "default" ||
  key == "examples" ||
  key == "$schema" ||
  key == "$id" ||
  key == "$comment" ||
  key == "deprecated" ||
  key == "readOnly" ||
  key == "writeOnly" ||
  key == "format" ||
  key == "contentEncoding" ||
  key == "contentMediaType"
}

///|
/// Refuse a keyword the skeleton cannot represent.
fn json_schema_unsupported(key : String) -> Unit raise MendError {
  raise SchemaError(
    "json schema: unsupported keyword `" +
    key +
    "`; supported: type, properties, required, items, enum, const, minimum, maximum, exclusiveMinimum, exclusiveMaximum, minLength, maxLength, pattern, additionalProperties",
  )
}

///|
/// A numeric field, accepting an integer or a finite double.
fn json_schema_number(v : Json, key : String) -> Double raise MendError {
  match v {
    Json::Number(d, ..) =>
      if d.is_nan() || d.is_inf() {
        raise SchemaError("json schema: `" + key + "` must be finite")
      } else {
        d
      }
    _ => raise SchemaError("json schema: `" + key + "` must be a number")
  }
}

///|
/// A non-negative integer field.
fn json_schema_uint(v : Json, key : String) -> Int32 raise MendError {
  let d = json_schema_number(v, key)
  let n = d.to_int()
  if n.to_double() != d || n < 0 {
    raise SchemaError(
      "json schema: `" + key + "` must be a non-negative integer",
    )
  }
  n
}

///|
/// A string field.
fn json_schema_string(v : Json, key : String) -> String raise MendError {
  match v {
    Json::String(s) => s
    _ => raise SchemaError("json schema: `" + key + "` must be a string")
  }
}

///|
/// `required` as a lookup table.
fn json_schema_required(v : Json) -> Map[String, Bool] raise MendError {
  let out : Map[String, Bool] = Map([])
  match v {
    Json::Array(items) =>
      for item in items {
        out[json_schema_string(item, "required")] = true
      }
    _ =>
      raise SchemaError("json schema: `required` must be an array of strings")
  }
  out
}

///|
/// A `pattern` translated into the skeleton's character class plus the length
/// bounds its quantifier implies.
priv struct PatternSpec {
  class_text : String
  min_len : Int32?
  max_len : Int32?
}

///|
/// Parse a decimal integer used in a `{n,m}` quantifier.
fn json_schema_quantifier_int(s : StringView) -> Int32 raise MendError {
  if s.length() == 0 {
    raise SchemaError("json schema: empty quantifier bound")
  }
  let mut n = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      raise SchemaError(
        "json schema: quantifier bounds must be decimal integers",
      )
    }
    n = n * 10 + (c - 0x30)
  }
  n
}

///|
/// Translate a JSON Schema `pattern` only when it is an anchored character
/// class, and turn its quantifier into length bounds.
///
/// JSON Schema's `pattern` is a regular expression and is *not* anchored: the
/// validator only requires a match somewhere in the string. The skeleton's
/// `pattern` requires every character to be in the class. Mapping an
/// unanchored expression onto it would be stricter (safe) but would silently
/// mean something else, so only anchored forms are accepted. The quantifier
/// then has an exact translation:
///
/// | pattern | skeleton |
/// | --- | --- |
/// | `^[a-z]*$` | `string(pattern:[a-z])` |
/// | `^[a-z]+$` | `string(minLength:1,pattern:[a-z])` |
/// | `^[a-z]?$` | `string(maxLength:1,pattern:[a-z])` |
/// | `^[a-z]$` | `string(minLength:1,maxLength:1,pattern:[a-z])` |
/// | `^[A-Z]{2,4}$` | `string(minLength:2,maxLength:4,pattern:[A-Z])` |
///
/// Everything else — `.`, `*` inside the class, escapes, alternation, groups —
/// is an `E070`.
fn json_schema_pattern(s : String) -> PatternSpec raise MendError {
  let n = s.length()
  if n < 4 || s.at(0).to_int() != 0x5E || s.at(n - 1).to_int() != 0x24 {
    raise SchemaError(
      "json schema: `pattern` must be an anchored character class such as `^[a-z0-9_]*$`; unanchored or general regular expressions are not supported",
    )
  }
  // Drop the anchors.
  let body = s[1:n - 1].to_owned()
  if body.length() < 2 || body.at(0).to_int() != 0x5B {
    raise SchemaError("json schema: `pattern` must be a single character class")
  }
  // Find the closing bracket. Escapes are not supported, so the first `]`
  // closes the class.
  let mut close = 1
  while close < body.length() && body.at(close).to_int() != 0x5D {
    close = close + 1
  }
  if close >= body.length() {
    raise SchemaError("json schema: `pattern` has an unterminated class")
  }
  let inner = body[1:close].to_owned()
  if inner.contains("\\") || inner.contains("[") {
    raise SchemaError(
      "json schema: `pattern` character classes may not contain escapes or nested classes",
    )
  }
  let rest = body[close + 1:].to_owned()
  let (min_len, max_len) : (Int32?, Int32?) = if rest == "" {
    (Some(1), Some(1))
  } else if rest == "*" {
    (Some(0), None)
  } else if rest == "+" {
    (Some(1), None)
  } else if rest == "?" {
    (Some(0), Some(1))
  } else if rest.length() >= 2 &&
    rest.at(0).to_int() == 0x7B &&
    rest.at(rest.length() - 1).to_int() == 0x7D {
    let spec = rest[1:rest.length() - 1].to_owned()
    let parts = spec.split(",").to_array()
    if parts.length() == 1 {
      let k = json_schema_quantifier_int(parts[0])
      (Some(k), Some(k))
    } else if parts.length() == 2 {
      let lo = json_schema_quantifier_int(parts[0])
      if parts[1].length() == 0 {
        (Some(lo), None)
      } else {
        let hi = json_schema_quantifier_int(parts[1])
        if hi < lo {
          raise SchemaError(
            "json schema: quantifier upper bound is below its lower bound",
          )
        }
        (Some(lo), Some(hi))
      }
    } else {
      raise SchemaError("json schema: malformed quantifier")
    }
  } else {
    raise SchemaError(
      "json schema: unsupported `pattern` quantifier `" + rest + "`",
    )
  }
  { class_text: inner, min_len, max_len, }
}

///|
/// Build the constraint record of one leaf, or `None` when the node declared
/// no value constraint.
fn json_schema_constraints(
  obj : Map[String, Json],
  kind : Schema,
) -> Constraints? raise MendError {
  let c = Constraints::none()
  let mut any = false
  let mut pattern_spec : PatternSpec? = None
  for key, value in obj {
    if key == "enum" {
      match value {
        Json::Array(items) => {
          c.enum_values = Some(items.copy())
          any = true
        }
        _ => raise SchemaError("json schema: `enum` must be an array")
      }
    } else if key == "const" {
      c.enum_values = Some([value])
      any = true
    } else if key == "minimum" {
      c.minimum = Some(json_schema_number(value, key))
      any = true
    } else if key == "exclusiveMinimum" {
      c.exclusive_minimum = Some(json_schema_number(value, key))
      any = true
    } else if key == "maximum" {
      c.maximum = Some(json_schema_number(value, key))
      any = true
    } else if key == "exclusiveMaximum" {
      c.exclusive_maximum = Some(json_schema_number(value, key))
      any = true
    } else if key == "minLength" {
      c.min_length = Some(json_schema_uint(value, key))
      any = true
    } else if key == "maxLength" {
      c.max_length = Some(json_schema_uint(value, key))
      any = true
    } else if key == "pattern" {
      let spec = json_schema_pattern(json_schema_string(value, key))
      c.pattern = Some(spec.class_text)
      pattern_spec = Some(spec)
      any = true
    }
  }
  match pattern_spec {
    Some(spec) => {
      // The quantifier is a length bound. Combine it with an explicit
      // `minLength`/`maxLength` by intersection; an empty intersection means
      // the declaration can never match, which is an E070 rather than a gate
      // that rejects everything at runtime.
      let lo = match (c.min_length, spec.min_len) {
        (Some(a), Some(b)) => Some(if a > b { a } else { b })
        (Some(a), None) => Some(a)
        (None, b) => b
      }
      let hi = match (c.max_length, spec.max_len) {
        (Some(a), Some(b)) => Some(if a < b { a } else { b })
        (Some(a), None) => Some(a)
        (None, b) => b
      }
      match (lo, hi) {
        (Some(a), Some(b)) =>
          if a > b {
            raise SchemaError(
              "json schema: `pattern` quantifier and length bounds cannot be satisfied together",
            )
          }
        _ => ()
      }
      c.min_length = match lo {
        Some(0) => None
        _ => lo
      }
      c.max_length = hi
    }
    None => ()
  }
  if !any {
    return None
  }
  // The kind determines which constraints make sense. Refusing a mismatched
  // constraint here is the same policy as `Schema::parse`: a declaration that
  // can never fire is an `E070`, not a silently weaker gate.
  let has_number_constraint = c.minimum is Some(_) ||
    c.maximum is Some(_) ||
    c.exclusive_minimum is Some(_) ||
    c.exclusive_maximum is Some(_)
  let has_string_constraint = c.min_length is Some(_) ||
    c.max_length is Some(_) ||
    c.pattern is Some(_)
  match kind {
    Int | Num =>
      if has_string_constraint {
        raise SchemaError(
          "json schema: length/pattern constraints apply to strings, not numbers",
        )
      }
    Str =>
      if has_number_constraint {
        raise SchemaError(
          "json schema: numeric constraints apply to numbers, not strings",
        )
      }
    _ =>
      if has_number_constraint || has_string_constraint {
        raise SchemaError(
          "json schema: value constraints are not supported on this kind",
        )
      }
  }
  Some(c)
}

///|
/// Translate one JSON Schema node into a skeleton.
fn json_schema_node(v : Json) -> Schema raise MendError {
  match v {
    Json::Object(obj) => {
      // Walk every keyword first so an unsupported one is named even if another
      // field is malformed.
      for key, value in obj {
        if json_schema_annotation(key) ||
          key == "type" ||
          key == "properties" ||
          key == "required" ||
          key == "items" ||
          key == "enum" ||
          key == "const" ||
          key == "minimum" ||
          key == "maximum" ||
          key == "exclusiveMinimum" ||
          key == "exclusiveMaximum" ||
          key == "minLength" ||
          key == "maxLength" ||
          key == "pattern" {
          continue
        }
        if key == "additionalProperties" {
          // `true` (the JSON Schema default) adds nothing the skeleton can
          // check; `false` is a constraint it cannot enforce.
          match value {
            Json::True => continue
            Json::False =>
              raise SchemaError(
                "json schema: `additionalProperties: false` is not supported; the skeleton does not close objects",
              )
            _ =>
              raise SchemaError(
                "json schema: `additionalProperties` must be a boolean",
              )
          }
        }
        json_schema_unsupported(key)
      }
      let mut kind_name = ""
      match obj.get("type") {
        Some(Json::String(s)) => kind_name = s
        Some(Json::Array(items)) => {
          // `["string","null"]`-style unions are common but the skeleton has
          // no union. A one-element array is harmless; anything else is not.
          if items.length() != 1 {
            raise SchemaError(
              "json schema: `type` arrays are not supported; use a single type",
            )
          }
          kind_name = json_schema_string(items[0], "type")
        }
        Some(_) => raise SchemaError("json schema: `type` must be a string")
        None =>
          // No `type` but an object shape: treat it as an object, which is
          // what every tool declaration means.
          if obj.contains("properties") || obj.contains("required") {
            kind_name = "object"
          }
      }
      let base : Schema = if kind_name == "" || kind_name == "any" {
        Any
      } else if kind_name == "null" {
        Null
      } else if kind_name == "boolean" {
        Bool
      } else if kind_name == "number" {
        Num
      } else if kind_name == "integer" {
        Int
      } else if kind_name == "string" {
        Str
      } else if kind_name == "array" {
        let item = match obj.get("items") {
          Some(s) => json_schema_node(s)
          None => Any
        }
        Arr(item)
      } else if kind_name == "object" {
        let required = match obj.get("required") {
          Some(r) => json_schema_required(r)
          None => Map([])
        }
        let members : Array[SchemaMember] = []
        let seen : Map[String, Bool] = Map([])
        match obj.get("properties") {
          Some(Json::Object(props)) =>
            for key, sub in props {
              members.push({
                key,
                required: required.get(key).unwrap_or(false),
                schema: json_schema_node(sub),
              })
              seen[key] = true
            }
          Some(_) =>
            raise SchemaError("json schema: `properties` must be an object")
          None => ()
        }
        // A required member may be declared without a `properties` entry; in
        // JSON Schema that means "present, any value".
        for key, _ in required {
          if !seen.get(key).unwrap_or(false) {
            members.push({ key, required: true, schema: Any, })
          }
        }
        Obj(members)
      } else {
        raise SchemaError("json schema: unknown type `" + kind_name + "`")
      }
      match json_schema_constraints(obj, base) {
        Some(c) => Constrained(base, c)
        None => base
      }
    }
    _ =>
      raise SchemaError(
        "json schema: a schema node must be an object with a `type`, `properties`, `items`, `enum` or `const`",
      )
  }
}

///|
/// Translate a JSON Schema subset into the library's skeleton.
///
/// The supported subset is the part a tool declaration actually uses:
///
/// ```
/// { "type": "object",
///   "properties": { "query": { "type": "string" },
///                   "limit": { "type": "integer", "minimum": 1 } },
///   "required": ["query"] }
/// ```
///
/// is the same skeleton as `{!query:string,?limit:integer(minimum:1)}`.
/// Unsupported keywords raise `E070`; annotations are ignored.
pub fn Schema::of_json_schema(value : Json) -> Schema raise MendError {
  json_schema_node(value)
}

///|
/// Parse JSON Schema text and translate it.
pub fn Schema::parse_json_schema(text : String) -> Schema raise MendError {
  let value = @json.parse(text) catch {
    _ => raise SchemaError("json schema: input is not valid JSON")
  }
  json_schema_node(value)
}
