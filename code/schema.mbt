// FR-36 — Schema-aware readiness: not "is this valid JSON", but "how much of
// what the caller needs do I already have".
//
// The library has never been and is still not a JSON Schema validator. There is
// no `$ref`, no `oneOf`, no `format`, no `pattern`, and no plan to add them:
// validating a finished document is a solved problem with mature
// implementations, and JSONMend's contribution is the streaming half.
//
// What a streaming consumer actually knows that the document does not is *what
// it is waiting for*. A tool call declares its arguments; a UI declares the
// three fields it renders. Given that declaration, "readiness" stops being
// "the JSON is complete" and becomes "the arguments I promised to use are
// final", which is available long before the end of the stream — and, more
// importantly, is available *together with* the decision that says whether
// acting on it is safe (FR-34).
//
// The subset is deliberately tiny:
//
//   any | null | boolean | number | integer | string
//   { member* }        member := ("!" key | "?" key) ":" schema (";" | ",")?
//   [ schema ]
//   kind ( constraints )?      constraints := constraint ("," | ";")*
//
// A member is required by default: `!` is written for the reader, not for the
// parser. `Schema::stringify` always writes the marker back, so the text form
// has one canonical spelling and a round trip is exact.
//
// The text form exists so that a demo, a test and a CLI flag can all use the
// same declaration without a JSON Schema implementation to parse it. It is a
// skeleton, not a contract, and it is still not a JSON Schema implementation.
//
// Since 0.7.0 a kind may carry *value* constraints, because a streaming caller
// that refuses `{"limit":-1}` the moment `-1` is final saves the rest of the
// stream and the shape check alone could not do that:
//
//   integer(minimum:1)                     number(exclusiveMaximum:1.5)
//   string(maxLength:64,minLength:1)       any(enum:["low","high"])
//   [string(pattern:[a-zA-Z0-9_])]
//
// The names are JSON Schema's (`minimum`, `exclusiveMinimum`, `maximum`,
// `exclusiveMaximum`, `minLength`, `maxLength`, `enum`), the spelling is the
// declaration language's own (`key:value`, separated by `,` or `;`), and the
// set of constraints each kind accepts is enforced at parse time: `maxLength`
// on an `integer` is an `E070`, not a rule that silently never fires. `enum`
// takes a JSON literal array and is allowed on any kind. The one deliberate
// restriction is `pattern`: it is a *character-class subset*, not a regular
// expression. `pattern:[...]` accepts a value whose every character is in the
// class, and any other regular-expression syntax (`*`, `+`, `?`, `|`, `.`,
// anchors, groups, alternation) is an `E070` rather than a silently different
// meaning. There is no regex engine behind this file and there is no plan to
// add one.
//
// Backward compatibility: a declaration that parsed before 0.7.0 parses to the
// same schema, `stringify()` still writes it the same way, and `accepts` /
// `evaluate` on it do exactly what they did. A constraint is only visible when
// one was written.

///|
/// The kinds a skeleton declaration can name (FR-36), plus a scalar kind with
/// value constraints written after it (0.7.0).
///
/// `parse` never builds `Constrained` with an empty constraint list, so a
/// declaration without constraints is the plain kind and matches exactly the
/// schema 0.6.x produced.
pub(all) enum Schema {
  Any
  Null
  Bool
  Num
  Int
  Str
  Arr(Schema)
  Obj(Array[SchemaMember])
  Constrained(Schema, Constraints)
}

///|
/// One declared object member (FR-36).
pub(all) struct SchemaMember {
  key : String
  /// A member that is not required does not hold up readiness.
  required : Bool
  schema : Schema
}

///|
/// Value constraints attached to a declared kind (0.7.0).
///
/// Every field is optional and `None` means "declared nothing", so an empty
/// `Constraints` is exactly the absence of constraints. The type is public so
/// that a caller can build a declaration in MoonBit as well as in text; the
/// text form and this struct carry the same information.
pub(all) struct Constraints {
  mut minimum : Double?
  mut exclusive_minimum : Double?
  mut maximum : Double?
  mut exclusive_maximum : Double?
  mut min_length : Int32?
  mut max_length : Int32?
  /// The exact values `enum` admits, in declaration order.
  mut enum_values : Array[Json]?
  /// The character class of `pattern`, exactly as written between the brackets
  /// (`a-z0-9_`), including a leading `^` for a negated class.
  mut pattern : String?
}

///|
/// A constraint list with nothing declared.
pub fn Constraints::none() -> Constraints {
  {
    minimum: None,
    exclusive_minimum: None,
    maximum: None,
    exclusive_maximum: None,
    min_length: None,
    max_length: None,
    enum_values: None,
    pattern: None,
  }
}

///|
/// Whether nothing is constrained.
fn Constraints::is_empty(self : Constraints) -> Bool {
  match self {
    {
      minimum: None,
      exclusive_minimum: None,
      maximum: None,
      exclusive_maximum: None,
      min_length: None,
      max_length: None,
      enum_values: None,
      pattern: None,
    } => true
    _ => false
  }
}

///|
/// Canonical text of a constraint number, so that `minimum:0` round trips as
/// `minimum:0` rather than `minimum:0.0`.
fn constraint_number_text(d : Double) -> String {
  Json::number(d).stringify()
}

///|
/// Canonical text of the constraint list, in a fixed order, as it is written
/// between the parentheses. `Constraints::none().text() == ""`.
fn Constraints::text(self : Constraints) -> String {
  let parts : Array[String] = []
  match self.minimum {
    Some(d) => parts.push("minimum:" + constraint_number_text(d))
    None => ()
  }
  match self.exclusive_minimum {
    Some(d) => parts.push("exclusiveMinimum:" + constraint_number_text(d))
    None => ()
  }
  match self.maximum {
    Some(d) => parts.push("maximum:" + constraint_number_text(d))
    None => ()
  }
  match self.exclusive_maximum {
    Some(d) => parts.push("exclusiveMaximum:" + constraint_number_text(d))
    None => ()
  }
  match self.min_length {
    Some(n) => parts.push("minLength:" + n.to_string())
    None => ()
  }
  match self.max_length {
    Some(n) => parts.push("maxLength:" + n.to_string())
    None => ()
  }
  match self.enum_values {
    Some(vs) => parts.push("enum:" + enum_literals_text(vs))
    None => ()
  }
  match self.pattern {
    Some(cls) => parts.push("pattern:[" + cls + "]")
    None => ()
  }
  parts.join(",")
}

///|
/// Canonical text of an `enum` list.
fn enum_literals_text(vs : Array[Json]) -> String {
  let parts : Array[String] = []
  for v in vs {
    parts.push(v.stringify())
  }
  "[" + parts.join(",") + "]"
}

///|
/// Whether code unit `u` belongs to the character class `inner`.
///
/// The class language is intentionally not a regular expression: a set of
/// literals and ranges, a leading `^` to negate it, and the six common
/// shorthands. Every code unit of the *value* is tested against the set; there
/// is nothing to concatenate and nothing to quantify.
fn class_unit_in(inner : String, u : Int32) -> Bool {
  let n = inner.length()
  let mut i = 0
  let mut negated = false
  if n > 0 && inner.at(0).to_int() == 0x5E {
    negated = true
    i = 1
  }
  let mut hit = false
  while i < n {
    let c = inner.at(i).to_int()
    if c == 0x5C && i + 1 < n {
      let e = inner.at(i + 1).to_int()
      match e {
        0x64 => if u >= 0x30 && u <= 0x39 { hit = true } // \d
        0x77 =>
          if (u >= 0x30 && u <= 0x39) ||
            (u >= 0x41 && u <= 0x5A) ||
            (u >= 0x61 && u <= 0x7A) ||
            u == 0x5F {
            hit = true
          } // \w
        0x73 =>
          if u == 0x20 ||
            u == 0x09 ||
            u == 0x0A ||
            u == 0x0D ||
            u == 0x0B ||
            u == 0x0C {
            hit = true
          } // \s
        0x6E => if u == 0x0A { hit = true } // \n
        0x74 => if u == 0x09 { hit = true } // \t
        0x72 => if u == 0x0D { hit = true } // \r
        0x5C | 0x5D | 0x2D | 0x5E => if u == e { hit = true } // \\ \] \- \^
        _ => ()
      }
      i = i + 2
      continue
    }
    // `a-z`: a `-` that has a character on both sides is a range, and the
    // character before it was already allowed to match on its own, so only the
    // upper end is new.
    if c == 0x2D && i > 0 && i + 1 < n {
      let lo = inner.at(i - 1).to_int()
      let hi = inner.at(i + 1).to_int()
      if u >= lo && u <= hi {
        hit = true
      }
      i = i + 2
      continue
    }
    if u == c {
      hit = true
    }
    i = i + 1
  }
  if negated {
    !hit
  } else {
    hit
  }
}

///|
/// Whether every code unit of `s` is in the class `inner`. The empty string is
/// in every class by vacuity; use `minLength` for "at least one".
fn class_accepts(inner : String, s : String) -> Bool {
  for k = 0; k < s.length(); k = k + 1 {
    if !class_unit_in(inner, s.at(k).to_int()) {
      return false
    }
  }
  true
}

///|
/// The first declared constraint `v` violates, as the phrase `evaluate` and the
/// watcher report it, or `None` when `v` satisfies all of them.
///
/// `base` is the kind the constraint is attached to (`integer`, `string`, …)
/// so that the phrase reads the way a caller would write it. Only the value
/// matters: whether the kind matches is the caller's check.
fn Constraints::violation(
  self : Constraints,
  base : String,
  v : Json,
) -> String? {
  let d = match v {
    Json::Number(x, ..) => Some(x)
    _ => None
  }
  match d {
    Some(x) => {
      match self.minimum {
        Some(m) =>
          if x < m {
            return Some(base + " >= " + constraint_number_text(m))
          }
        None => ()
      }
      match self.exclusive_minimum {
        Some(m) =>
          if x <= m {
            return Some(base + " > " + constraint_number_text(m))
          }
        None => ()
      }
      match self.maximum {
        Some(m) =>
          if x > m {
            return Some(base + " <= " + constraint_number_text(m))
          }
        None => ()
      }
      match self.exclusive_maximum {
        Some(m) =>
          if x >= m {
            return Some(base + " < " + constraint_number_text(m))
          }
        None => ()
      }
    }
    None => ()
  }
  match v {
    Json::String(s) => {
      match self.min_length {
        Some(n) =>
          if s.length() < n {
            return Some("string with length >= " + n.to_string())
          }
        None => ()
      }
      match self.max_length {
        Some(n) =>
          if s.length() > n {
            return Some("string with length <= " + n.to_string())
          }
        None => ()
      }
      match self.pattern {
        Some(cls) =>
          if !class_accepts(cls, s) {
            return Some("string of characters in [" + cls + "]")
          }
        None => ()
      }
    }
    _ => ()
  }
  match self.enum_values {
    Some(vs) => {
      let mut hit = false
      for e in vs {
        if json_equal(e, v) {
          hit = true
          break
        }
      }
      if !hit {
        return Some("one of " + enum_literals_text(vs))
      }
    }
    None => ()
  }
  None
}

///|
/// Explicit `Eq` implementation for `SchemaMember` (structural, for tests).
pub impl Eq for SchemaMember with fn equal(
  self : SchemaMember,
  other : SchemaMember,
) -> Bool {
  self.key == other.key &&
  self.required == other.required &&
  self.schema.stringify() == other.schema.stringify()
}

///|
/// Explicit `Eq` extension for `SchemaMember`.
pub extend SchemaMember with Eq::{not_equal, equal}

///|
/// Stable name of a kind, as it is written in the text form. Constraints are
/// not part of the kind, so a constrained `integer` is still named `integer`;
/// see `Schema::expectation` for the declaration as it was written.
pub fn Schema::name(self : Schema) -> String {
  match self {
    Any => "any"
    Null => "null"
    Bool => "boolean"
    Num => "number"
    Int => "integer"
    Str => "string"
    Arr(_) => "array"
    Obj(_) => "object"
    Constrained(inner, _) => inner.name()
  }
}

///|
/// The declaration as a caller would have written it: the kind alone when
/// nothing is constrained, `integer(minimum:0)` when something is.
pub fn Schema::expectation(self : Schema) -> String {
  match self {
    Constrained(inner, c) =>
      if c.is_empty() {
        inner.name()
      } else {
        inner.name() + "(" + c.text() + ")"
      }
    _ => self.name()
  }
}

///|
/// The text form of a schema, the inverse of `Schema::parse`.
pub fn Schema::stringify(self : Schema) -> String {
  match self {
    Arr(inner) => "[" + inner.stringify() + "]"
    Obj(members) => {
      let sb = StringBuilder()
      sb.write_char('{')
      for i = 0; i < members.length(); i = i + 1 {
        if i > 0 {
          sb.write_char(',')
        }
        let m = members[i]
        sb.write_string(if m.required { "!" } else { "?" })
        // A name containing `:`, whitespace or a quote cannot be written bare:
        // the parser would stop at the first delimiter and read a different
        // skeleton back. Quoting it is what makes `parse(stringify(s))` mean the
        // same as `s` (Q-23) for names like `{"name with space":string}`.
        if name_needs_quotes(m.key) {
          sb.write_char('"')
          sb.write_string(m.key)
          sb.write_char('"')
        } else {
          sb.write_string(m.key)
        }
        sb.write_char(':')
        sb.write_string(m.schema.stringify())
      }
      sb.write_char('}')
      sb.to_string()
    }
    // A container carries no constraint anywhere the text form can express one:
    // the parser accepts a constraint list only after a scalar kind, so writing
    // one back would produce text that does not parse.
    Constrained(inner, c) =>
      match inner {
        Arr(_) | Obj(_) => inner.stringify()
        _ =>
          if c.is_empty() {
            inner.stringify()
          } else {
            inner.stringify() + "(" + c.text() + ")"
          }
      }
    _ => self.name()
  }
}

///|
/// Whether a member name cannot be written as a bare identifier.
///
/// The bare form ends at `:`, space, tab, newline or carriage return, so a name
/// containing any of those has to be quoted. A name containing `"` cannot be
/// represented at all — the parser has no escape — but such a name can only
/// come from a hand-built `Obj`, because parsing stops at the first quote.
fn name_needs_quotes(key : String) -> Bool {
  if key == "" {
    return true
  }
  for i = 0; i < key.length(); i = i + 1 {
    let c = key.at(i).to_int()
    if c == 0x3A ||
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0x22 {
      return true
    }
  }
  false
}

///|
/// Member names declared under `parent`, in declaration order.
pub fn Schema::member_keys(self : Schema) -> Array[String] {
  let out : Array[String] = []
  match self {
    Obj(members) =>
      for m in members {
        out.push(m.key)
      }
    _ => ()
  }
  out
}

///|
/// The declared schema of member `key`, or `None`.
pub fn Schema::field(self : Schema, key : String) -> SchemaMember? {
  match self {
    Obj(members) => {
      for m in members {
        if m.key == key {
          return Some(m)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// The declaration a dotted path points at, or `None` (FR-36, FR-39).
///
/// A path is spelled the way `Schema::required_paths` produces it: member names
/// joined with `.`, where a numeric step selects an array element. A member
/// name that itself contains a `.` is therefore ambiguous; the declaration
/// language has no way to write one, so `required_paths` cannot produce one
/// either, and the two agree by construction.
pub fn Schema::at_path(self : Schema, path : String) -> Schema? {
  if path == "" {
    return Some(self)
  }
  let mut cur = self
  for seg in path.split(".") {
    cur = match cur {
      Obj(members) => {
        let mut next : Schema? = None
        for m in members {
          if m.key == seg.to_owned() {
            next = Some(m.schema)
          }
        }
        match next {
          Some(s) => s
          None => return None
        }
      }
      Arr(inner) => {
        let idx = @string.parse_int(seg.to_owned()) catch { _ => -1 }
        if idx < 0 {
          return None
        }
        inner
      }
      _ => return None
    }
  }
  Some(cur)
}

// ---------------------------------------------------------------------------
// The text form.
// ---------------------------------------------------------------------------

///|
/// Cursor over a schema declaration.
priv struct SchemaParser {
  text : String
  mut i : Int32
}

///|
/// Skip spaces, tabs and line breaks.
fn sp_skip_ws(p : SchemaParser) -> Unit {
  while p.i < p.text.length() {
    let c = p.text.at(p.i).to_int()
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      p.i = p.i + 1
    } else {
      break
    }
  }
}

///|
/// Case-insensitive comparison against an ASCII literal at `p.i`.
fn sp_at(p : SchemaParser, word : String) -> Bool {
  let n = word.length()
  if p.i + n > p.text.length() {
    return false
  }
  for k = 0; k < n; k = k + 1 {
    let a = p.text.at(p.i + k).to_int()
    let b = word.at(k).to_int()
    // The keywords are ASCII, so a plain `| 0x20` is a correct fold.
    let fold = if a >= 0x41 && a <= 0x5A { a | 0x20 } else { a }
    if fold != b && a != b {
      return false
    }
  }
  true
}

///|
/// Parse a schema at `p.i`, leaving the cursor after it.
fn sp_schema(p : SchemaParser) -> Schema raise MendError {
  sp_skip_ws(p)
  let n = p.text.length()
  if p.i >= n {
    raise SchemaError(" unexpected end of declaration")
  }
  let c = p.text.at(p.i).to_int()
  if c == 0x7B {
    // {
    p.i = p.i + 1
    let members : Array[SchemaMember] = []
    while true {
      sp_skip_ws(p)
      if p.i >= n {
        raise SchemaError(" `{` is never closed")
      }
      if p.text.at(p.i).to_int() == 0x7D {
        // }
        p.i = p.i + 1
        break
      }
      let mut required = true
      if p.text.at(p.i).to_int() == 0x21 {
        // !
        p.i = p.i + 1
      } else if p.text.at(p.i).to_int() == 0x3F {
        // ?
        required = false
        p.i = p.i + 1
      }
      sp_skip_ws(p)
      let key = sp_key(p)
      sp_skip_ws(p)
      if p.i >= n || p.text.at(p.i).to_int() != 0x3A {
        raise SchemaError(" member `" + key + "` has no `:`")
      }
      p.i = p.i + 1
      let inner = sp_schema(p)
      members.push({ key, required, schema: inner, })
      sp_skip_ws(p)
      if p.i < n {
        let d = p.text.at(p.i).to_int()
        if d == 0x2C || d == 0x3B {
          p.i = p.i + 1
        }
      }
    }
    guard_no_dup(members)
    Obj(members)
  } else if c == 0x5B {
    // [
    p.i = p.i + 1
    let inner = sp_schema(p)
    sp_skip_ws(p)
    if p.i >= n || p.text.at(p.i).to_int() != 0x5D {
      raise SchemaError(" `[` is never closed")
    }
    p.i = p.i + 1
    Arr(inner)
  } else if c == 0x22 {
    // A quoted key is not a type here; only members have names.
    raise SchemaError(" expected a type or `{`, found a quoted string")
  } else if sp_at(p, "any") {
    p.i = p.i + 3
    sp_wrap_constraints(p, Any)
  } else if sp_at(p, "null") {
    p.i = p.i + 4
    sp_wrap_constraints(p, Null)
  } else if sp_at(p, "boolean") {
    p.i = p.i + 7
    sp_wrap_constraints(p, Bool)
  } else if sp_at(p, "bool") {
    p.i = p.i + 4
    sp_wrap_constraints(p, Bool)
  } else if sp_at(p, "integer") {
    p.i = p.i + 7
    sp_wrap_constraints(p, Int)
  } else if sp_at(p, "int") {
    p.i = p.i + 3
    sp_wrap_constraints(p, Int)
  } else if sp_at(p, "number") {
    p.i = p.i + 6
    sp_wrap_constraints(p, Num)
  } else if sp_at(p, "string") {
    p.i = p.i + 6
    sp_wrap_constraints(p, Str)
  } else {
    raise SchemaError(
      "schema: unknown type at offset " +
      p.i.to_string() +
      ": " +
      p.text[p.i:].to_owned(),
    )
  }
}

// ---------------------------------------------------------------------------
// The constraint list (0.7.0).
//
// It is written immediately after a scalar kind — `integer(minimum:0)` — and
// not after a space, because a space is already how the language separates a
// schema from the next member (`{a:integer b:string}` has two members). Only
// the `(` is treated as attached, so every declaration that parsed before this
// existed still parses the same way.
// ---------------------------------------------------------------------------

///|
/// The constraint list of a kind, or the kind itself when there is none.
fn sp_wrap_constraints(
  p : SchemaParser,
  base : Schema,
) -> Schema raise MendError {
  if p.i >= p.text.length() || p.text.at(p.i).to_int() != 0x28 {
    return base
  }
  let c = sp_constraints(p, base)
  if c.is_empty() {
    base
  } else {
    Constrained(base, c)
  }
}

///|
/// Parse `(name:value, ...)`. `p.i` is at the `(`.
fn sp_constraints(
  p : SchemaParser,
  base : Schema,
) -> Constraints raise MendError {
  let n = p.text.length()
  p.i = p.i + 1
  let out = Constraints::none()
  while true {
    sp_skip_ws(p)
    if p.i >= n {
      raise SchemaError(" `(` of the constraint list is never closed")
    }
    if p.text.at(p.i).to_int() == 0x29 {
      p.i = p.i + 1
      break
    }
    let name_at = p.i
    let name = sp_constraint_name(p)
    sp_skip_ws(p)
    if p.i >= n || p.text.at(p.i).to_int() != 0x3A {
      raise SchemaError(
        " schema: constraint `" +
        name +
        "` has no `:` at offset " +
        name_at.to_string(),
      )
    }
    p.i = p.i + 1
    sp_skip_ws(p)
    sp_constraint_value(p, name, base, name_at, out)
    sp_skip_ws(p)
    if p.i >= n {
      raise SchemaError(" `(` of the constraint list is never closed")
    }
    let d = p.text.at(p.i).to_int()
    if d == 0x2C || d == 0x3B {
      p.i = p.i + 1
    } else if d == 0x29 {
      p.i = p.i + 1
      break
    } else {
      raise SchemaError(
        " schema: unexpected `" +
        sp_char_text(p.text.at(p.i)) +
        "` in a constraint list at offset " +
        p.i.to_string() +
        "; expected `,`, `;` or `)`",
      )
    }
  }
  out
}

///|
/// One constraint name: ASCII letters, matched case-insensitively against the
/// eight names the language has.
fn sp_constraint_name(p : SchemaParser) -> String raise MendError {
  let n = p.text.length()
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
      sb.write_char(Int32::unsafe_to_char(c))
      p.i = p.i + 1
    } else {
      break
    }
  }
  let name = sb.to_string()
  if name == "" {
    raise SchemaError(
      " schema: expected a constraint name at offset " + p.i.to_string(),
    )
  }
  name
}

///|
/// One character of input as it appears in a diagnostic.
fn sp_char_text(u : UInt16) -> String {
  match u.to_int() {
    0x0A => "\\n"
    0x09 => "\\t"
    0x0D => "\\r"
    _ => Int32::unsafe_to_char(u.to_int()).to_string()
  }
}

///|
/// Whether two ASCII names are equal ignoring case.
fn name_eq_ci(a : String, b : String) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    let x = a.at(i).to_int()
    let y = b.at(i).to_int()
    let fx = if x >= 0x41 && x <= 0x5A { x | 0x20 } else { x }
    let fy = if y >= 0x41 && y <= 0x5A { y | 0x20 } else { y }
    if fx != fy {
      return false
    }
  }
  true
}

///|
/// Parse and check the value of one constraint, writing it into `out`.
fn sp_constraint_value(
  p : SchemaParser,
  name : String,
  base : Schema,
  name_at : Int32,
  out : Constraints,
) -> Unit raise MendError {
  let kind = base.name()
  if name_eq_ci(name, "minimum") ||
    name_eq_ci(name, "exclusiveMinimum") ||
    name_eq_ci(name, "maximum") ||
    name_eq_ci(name, "exclusiveMaximum") {
    if kind != "number" && kind != "integer" {
      raise SchemaError(
        " schema: `" +
        name +
        "` applies to `number` and `integer`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    let d = sp_constraint_number(p, name)
    if name_eq_ci(name, "minimum") {
      out.minimum = Some(d)
    } else if name_eq_ci(name, "exclusiveMinimum") {
      out.exclusive_minimum = Some(d)
    } else if name_eq_ci(name, "maximum") {
      out.maximum = Some(d)
    } else {
      out.exclusive_maximum = Some(d)
    }
    return
  }
  if name_eq_ci(name, "minLength") || name_eq_ci(name, "maxLength") {
    if kind != "string" {
      raise SchemaError(
        " schema: `" +
        name +
        "` applies to `string`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    let len = sp_constraint_length(p, name)
    if name_eq_ci(name, "minLength") {
      out.min_length = Some(len)
    } else {
      out.max_length = Some(len)
    }
    return
  }
  if name_eq_ci(name, "enum") {
    out.enum_values = Some(sp_constraint_enum(p, base))
    return
  }
  if name_eq_ci(name, "pattern") {
    if kind != "string" {
      raise SchemaError(
        " schema: `pattern` applies to `string`, not to `" +
        kind +
        "`, at offset " +
        name_at.to_string(),
      )
    }
    out.pattern = Some(sp_constraint_class(p))
    return
  }
  raise SchemaError(
    " schema: unknown constraint `" +
    name +
    "` at offset " +
    name_at.to_string() +
    "; the language has minimum, exclusiveMinimum, maximum, exclusiveMaximum, minLength, maxLength, enum and pattern",
  )
}

///|
/// The token of a numeric constraint, parsed as JSON so that the accepted
/// spellings are exactly JSON's (`1`, `-1`, `1.5`, `1e3`) and nothing else.
fn sp_constraint_number(
  p : SchemaParser,
  name : String,
) -> Double raise MendError {
  let at = p.i
  let tok = sp_constraint_token(p)
  if tok == "" {
    raise SchemaError(
      " schema: `" + name + "` expects a number at offset " + at.to_string(),
    )
  }
  let parsed = @json.parse(tok) catch {
    _ =>
      raise SchemaError(
        " schema: `" +
        name +
        "` expects a number at offset " +
        at.to_string() +
        ": `" +
        tok +
        "`",
      )
  }
  match parsed {
    Json::Number(d, ..) => d
    _ =>
      raise SchemaError(
        " schema: `" +
        name +
        "` expects a number at offset " +
        at.to_string() +
        ": `" +
        tok +
        "`",
      )
  }
}

///|
/// A run of characters that can appear in a number.
fn sp_constraint_token(p : SchemaParser) -> String {
  let n = p.text.length()
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if (c >= 0x30 && c <= 0x39) ||
      c == 0x2D ||
      c == 0x2B ||
      c == 0x2E ||
      c == 0x65 ||
      c == 0x45 {
      sb.write_char(Int32::unsafe_to_char(c))
      p.i = p.i + 1
    } else {
      break
    }
  }
  sb.to_string()
}

///|
/// A length constraint: a non-negative integer, so that `minLength:-1` and
/// `maxLength:1.5` are `E070` rather than a rule that never fires.
fn sp_constraint_length(
  p : SchemaParser,
  name : String,
) -> Int32 raise MendError {
  let at = p.i
  let d = sp_constraint_number(p, name)
  if !(d >= 0.0) || d > 2147483647.0 || d != d.to_int().to_double() {
    raise SchemaError(
      " schema: `" +
      name +
      "` expects a non-negative integer at offset " +
      at.to_string() +
      ": `" +
      constraint_number_text(d) +
      "`",
    )
  }
  d.to_int()
}

///|
/// An `enum` value: a JSON array of scalars, so that the spelling, the escapes
/// and the number forms are JSON's and not a new dialect.
fn sp_constraint_enum(
  p : SchemaParser,
  base : Schema,
) -> Array[Json] raise MendError {
  let n = p.text.length()
  if p.i >= n || p.text.at(p.i).to_int() != 0x5B {
    raise SchemaError(
      " schema: `enum` expects a JSON array of literals at offset " +
      p.i.to_string(),
    )
  }
  let open = p.i
  let close = sp_scan_brackets(p, open)
  let slice = p.text[open:close].to_owned()
  let parsed = @json.parse(slice) catch {
    _ =>
      raise SchemaError(
        " schema: `enum` is not a valid JSON array at offset " +
        open.to_string(),
      )
  }
  let items = match parsed {
    Json::Array(a) => a
    _ =>
      raise SchemaError(
        " schema: `enum` expects a JSON array at offset " + open.to_string(),
      )
  }
  if items.length() == 0 {
    raise SchemaError(
      " schema: `enum` needs at least one value at offset " + open.to_string(),
    )
  }
  for v in items {
    match v {
      Json::Null
      | Json::True
      | Json::False
      | Json::Number(_, ..)
      | Json::String(_) => ()
      _ =>
        raise SchemaError(
          " schema: `enum` admits only scalar literals at offset " +
          open.to_string(),
        )
    }
    // A literal the declared kind can never hold would be a rule that silently
    // never fires, which is the failure mode this parser exists to prevent.
    if !kind_accepts(base, v) {
      raise SchemaError(
        " schema: `enum` value " +
        v.stringify() +
        " is not a " +
        base.name() +
        ", at offset " +
        open.to_string(),
      )
    }
  }
  p.i = close
  items
}

///|
/// Index just after the bracket run that starts at `start`: a JSON array (or
/// any bracketed text) balanced across strings and escapes.
fn sp_scan_brackets(p : SchemaParser, start : Int32) -> Int32 raise MendError {
  let n = p.text.length()
  let mut i = start
  let mut depth = 0
  while i < n {
    let c = p.text.at(i).to_int()
    if c == 0x22 {
      i = i + 1
      while i < n {
        let q = p.text.at(i).to_int()
        if q == 0x5C {
          i = i + 2
          continue
        }
        if q == 0x22 {
          i = i + 1
          break
        }
        i = i + 1
      }
      continue
    }
    if c == 0x5B || c == 0x7B {
      depth = depth + 1
    } else if c == 0x5D || c == 0x7D {
      depth = depth - 1
      if depth <= 0 {
        return i + 1
      }
    }
    i = i + 1
  }
  raise SchemaError(
    " schema: the array of `enum` is never closed at offset " +
    start.to_string(),
  )
}

///|
/// A `pattern` value: one character class, `[...]`, and nothing else.
fn sp_constraint_class(p : SchemaParser) -> String raise MendError {
  let n = p.text.length()
  if p.i >= n || p.text.at(p.i).to_int() != 0x5B {
    raise SchemaError(
      " schema: `pattern` accepts a character class `[...]` and nothing else, at offset " +
      p.i.to_string(),
    )
  }
  let open = p.i
  p.i = p.i + 1
  let sb = StringBuilder()
  while p.i < n && p.text.at(p.i).to_int() != 0x5D {
    let c = p.text.at(p.i).to_int()
    if c == 0x5C && p.i + 1 < n {
      sb.write_char(Int32::unsafe_to_char(c))
      sb.write_char(Int32::unsafe_to_char(p.text.at(p.i + 1).to_int()))
      p.i = p.i + 2
      continue
    }
    sb.write_char(Int32::unsafe_to_char(c))
    p.i = p.i + 1
  }
  if p.i >= n {
    raise SchemaError(
      " schema: the character class of `pattern` is never closed at offset " +
      open.to_string(),
    )
  }
  p.i = p.i + 1
  let inner = sb.to_string()
  guard_class(inner, open)
  inner
}

///|
/// Reject anything a character class cannot mean, at parse time and with the
/// offset of the class: an empty class, an escape that is not one of the eight,
/// a range that starts or ends at an escape, and an inverted range. Everything
/// else (including `.`, `*` and `+` inside the brackets) is a literal character,
/// which is the whole point of "a character class, not a regular expression".
fn guard_class(inner : String, open : Int32) -> Unit raise MendError {
  let n = inner.length()
  let mut i = 0
  let mut prev_escape = false
  if n == 0 {
    raise SchemaError(
      " schema: an empty character class matches nothing, at offset " +
      open.to_string(),
    )
  }
  if inner.at(0).to_int() == 0x5E {
    i = 1
    if i >= n {
      raise SchemaError(
        " schema: `[^]` negates an empty character class, at offset " +
        open.to_string(),
      )
    }
  }
  while i < n {
    let c = inner.at(i).to_int()
    if c == 0x5C {
      if i + 1 >= n {
        raise SchemaError(
          " schema: `\\` ends the character class of `pattern` at offset " +
          open.to_string(),
        )
      }
      let e = inner.at(i + 1).to_int()
      if !(e == 0x5C ||
        e == 0x5D ||
        e == 0x2D ||
        e == 0x5E ||
        e == 0x6E ||
        e == 0x74 ||
        e == 0x72 ||
        e == 0x64 ||
        e == 0x77 ||
        e == 0x73) {
        raise SchemaError(
          " schema: `\\" +
          Int32::unsafe_to_char(e).to_string() +
          "` is not a character class escape at offset " +
          open.to_string() +
          "; the language has \\\\ \\] \\- \\^ \\n \\t \\r \\d \\w \\s",
        )
      }
      prev_escape = true
      i = i + 2
      continue
    }
    if c == 0x2D && i > 0 && i + 1 < n {
      if prev_escape {
        raise SchemaError(
          " schema: a character class range cannot start at an escape, at offset " +
          open.to_string(),
        )
      }
      let hi = inner.at(i + 1).to_int()
      if hi == 0x5C {
        raise SchemaError(
          " schema: a character class range cannot end at an escape, at offset " +
          open.to_string(),
        )
      }
      if inner.at(i - 1).to_int() > hi {
        raise SchemaError(
          " schema: the character class range at offset " +
          open.to_string() +
          " is inverted",
        )
      }
      prev_escape = false
      i = i + 2
      continue
    }
    prev_escape = false
    i = i + 1
  }
}

///|
/// A member name: a bare identifier, or a double quoted string.
fn sp_key(p : SchemaParser) -> String raise MendError {
  let n = p.text.length()
  if p.i < n && p.text.at(p.i).to_int() == 0x22 {
    p.i = p.i + 1
    let sb = StringBuilder()
    while p.i < n && p.text.at(p.i).to_int() != 0x22 {
      sb.write_char(Int32::unsafe_to_char(p.text.at(p.i).to_int()))
      p.i = p.i + 1
    }
    if p.i >= n {
      raise SchemaError(" quoted member name is never closed")
    }
    p.i = p.i + 1
    return sb.to_string()
  }
  let sb = StringBuilder()
  while p.i < n {
    let c = p.text.at(p.i).to_int()
    if c == 0x3A || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      break
    }
    sb.write_char(Int32::unsafe_to_char(p.text.at(p.i).to_int()))
    p.i = p.i + 1
  }
  if sb.to_string() == "" {
    raise SchemaError(" a member name cannot be empty")
  }
  sb.to_string()
}

///|
/// Reject a declaration that names the same member twice: the order of the two
/// would decide which one wins, which is exactly the kind of silent choice this
/// library refuses to make elsewhere.
fn guard_no_dup(members : Array[SchemaMember]) -> Unit raise MendError {
  for i = 0; i < members.length(); i = i + 1 {
    for j = i + 1; j < members.length(); j = j + 1 {
      if members[i].key == members[j].key {
        raise SchemaError(
          "schema: member `" + members[i].key + "` is declared twice",
        )
      }
    }
  }
}

///|
/// Parse the text form of a skeleton (FR-36). Raises `E070` with the offset of
/// the problem; the text is never partially accepted.
pub fn Schema::parse(text : String) -> Schema raise MendError {
  let p : SchemaParser = { text, i: 0, }
  let s = sp_schema(p)
  sp_skip_ws(p)
  if p.i < text.length() {
    raise SchemaError(
      "schema: unexpected text after the declaration at offset " +
      p.i.to_string(),
    )
  }
  s
}

// ---------------------------------------------------------------------------
// Evaluation.
// ---------------------------------------------------------------------------

///|
/// One declared member whose value does not satisfy its declaration (FR-36).
///
/// `expected` is the violated constraint when there is exactly one to name
/// (`integer >= 0`, `string with length <= 64`, `one of ["low","high"]`,
/// `string of characters in [a-z]`) and the whole declaration otherwise
/// (`integer(minimum:0)`).
pub(all) struct SchemaMismatch {
  path : String
  expected : String
  got : String
}

///|
/// The verdict of one value against a skeleton (FR-36).
pub(all) struct SchemaVerdict {
  /// Declared members, counting nesting, that a value is expected to provide.
  /// A member of an `any` or `array` node is not walked: the skeleton says
  /// nothing about it.
  total : Int32
  /// Required members that are present and satisfy the declared kind and the
  /// declared constraints.
  satisfied : Int32
  /// Required members that are absent, as dotted paths.
  missing : Array[String]
  /// Present members that hold a value of the wrong kind or violate a declared
  /// constraint.
  mismatched : Array[SchemaMismatch]
  /// Whether every required member is satisfied. Optional members are checked
  /// for kind when present and never counted as missing.
  ok : Bool
}

///|
/// Whether `v` is a whole number.
fn is_integer(v : Json) -> Bool {
  match v {
    Json::Number(d, ..) => {
      let f = d.to_int()
      f.to_double() == d
    }
    _ => false
  }
}

///|
/// Whether `v` has the declared kind (FR-36), ignoring constraints.
fn kind_accepts(schema : Schema, v : Json) -> Bool {
  match (schema, v) {
    (Any, _) => true
    (Null, Json::Null) => true
    (Bool, Json::True) | (Bool, Json::False) => true
    (Num, Json::Number(_, ..)) => true
    (Int, Json::Number(_, ..)) => is_integer(v)
    (Str, Json::String(_)) => true
    (Arr(_), Json::Array(_)) => true
    (Obj(_), Json::Object(_)) => true
    _ => false
  }
}

///|
/// Whether `v` has the declared kind **and** satisfies the declared value
/// constraints (FR-36, 0.7.0). A declaration with no constraints accepts
/// exactly what it accepted in 0.6.x.
pub fn Schema::accepts(self : Schema, v : Json) -> Bool {
  match self {
    Constrained(inner, c) => {
      if !kind_accepts(inner, v) {
        return false
      }
      match c.violation(inner.name(), v) {
        None => true
        Some(_) => false
      }
    }
    _ => kind_accepts(self, v)
  }
}

///|
/// The constraint `v` violates, when the kind is right. `None` means either
/// "no constraint was violated" or "the kind itself is wrong"; the caller
/// reports the whole declaration in the second case.
fn Schema::constraint_problem(self : Schema, v : Json) -> String? {
  match self {
    Constrained(inner, c) =>
      if kind_accepts(inner, v) {
        c.violation(inner.name(), v)
      } else {
        None
      }
    _ => None
  }
}

///|
/// The `expected` string of a mismatch: the violated constraint when there is
/// exactly one to name, the whole declaration otherwise.
fn mismatch_expected(schema : Schema, v : Json) -> String {
  match schema.constraint_problem(v) {
    Some(e) => e
    None => schema.expectation()
  }
}

///|
/// Join a path with one more step.
fn join_path(base : String, step : String) -> String {
  if base == "" {
    step
  } else {
    base + "." + step
  }
}

///|
/// Walk `value` against `schema` (FR-36). `path` is the dotted prefix of the
/// node, empty at the root.
///
/// `evaluate` walks *declared members*: a root that declares no members has
/// none to walk, which is why a bare kind at the root (`integer`, `string`) is
/// only answered by `accepts` and not by a mismatch. A constrained kind is the
/// exception, and deliberately so: a constraint is an explicit claim about the
/// value, and a claim that is silently dropped is worse than no claim, so a
/// constrained scalar at the root is checked here (`integer(minimum:0)` against
/// `-1` reports `integer >= 0` as `expected`).
pub fn Schema::evaluate(self : Schema, value : Json) -> SchemaVerdict {
  let total : Array[Int32] = [0]
  let satisfied : Array[Int32] = [0]
  let missing : Array[String] = []
  let mismatched : Array[SchemaMismatch] = []
  walk_schema(self, value, "", total, satisfied, missing, mismatched)
  let ok = missing.length() == 0 && mismatched.length() == 0
  { total: total[0], satisfied: satisfied[0], missing, mismatched, ok, }
}

///|
/// Recursive half of `Schema::evaluate`.
fn walk_schema(
  schema : Schema,
  value : Json,
  path : String,
  total : Array[Int32],
  satisfied : Array[Int32],
  missing : Array[String],
  mismatched : Array[SchemaMismatch],
) -> Unit {
  match schema {
    Obj(members) =>
      match value {
        Json::Object(map) =>
          for m in members {
            let here = join_path(path, m.key)
            let child = match map.get(m.key) {
              Some(v) => v
              None => {
                if m.required {
                  missing.push(here)
                }
                total[0] = total[0] + 1
                continue
              }
            }
            total[0] = total[0] + 1
            if m.schema.accepts(child) {
              satisfied[0] = satisfied[0] + 1
              // A container is walked: the skeleton can constrain deeper.
              match m.schema {
                Obj(_) | Arr(_) =>
                  walk_schema(
                    m.schema,
                    child,
                    here,
                    total,
                    satisfied,
                    missing,
                    mismatched,
                  )
                _ => ()
              }
            } else {
              mismatched.push({
                path: here,
                expected: mismatch_expected(m.schema, child),
                got: kind_of(child),
              })
            }
          }
        _ =>
          mismatched.push({
            path: if path == "" {
              "<root>"
            } else {
              path
            },
            expected: "object",
            got: kind_of(value),
          })
      }
    Arr(inner) =>
      match value {
        Json::Array(items) =>
          for i = 0; i < items.length(); i = i + 1 {
            let here = join_path(path, i.to_string())
            if inner.accepts(items[i]) {
              walk_schema(
                inner,
                items[i],
                here,
                total,
                satisfied,
                missing,
                mismatched,
              )
            } else {
              mismatched.push({
                path: here,
                expected: mismatch_expected(inner, items[i]),
                got: kind_of(items[i]),
              })
            }
          }
        _ =>
          mismatched.push({
            path: if path == "" {
              "<root>"
            } else {
              path
            },
            expected: "array",
            got: kind_of(value),
          })
      }
    Constrained(_, _) =>
      if path == "" && !schema.accepts(value) {
        mismatched.push({
          path: "<root>",
          expected: mismatch_expected(schema, value),
          got: kind_of(value),
        })
      }
    _ => ()
  }
}

///|
/// The JSON kind of a value, for a mismatch message.
pub fn kind_of(v : Json) -> String {
  match v {
    Json::Null => "null"
    Json::True | Json::False => "boolean"
    Json::Number(_, ..) => "number"
    Json::String(_) => "string"
    Json::Array(_) => "array"
    Json::Object(_) => "object"
  }
}

///|
/// The dotted paths of the required members of a skeleton, in declaration
/// order (FR-36).
///
/// A required object contributes its own path and, recursively, the required
/// members inside it. An optional member contributes nothing: a member that may
/// be absent cannot hold up readiness. An array is one path, because the number
/// of elements a model will emit is not declared.
pub fn Schema::required_paths(self : Schema) -> Array[String] {
  let out : Array[String] = []
  collect_required(self, "", out)
  out
}

///|
/// Recursive half of `Schema::required_paths`.
fn collect_required(
  schema : Schema,
  base : String,
  out : Array[String],
) -> Unit {
  match schema {
    Obj(members) =>
      for m in members {
        if m.required {
          let here = join_path(base, m.key)
          out.push(here)
          match m.schema {
            Obj(_) => collect_required(m.schema, here, out)
            _ => ()
          }
        }
      }
    _ => ()
  }
}

///|
/// Look up a dotted path in a value, where a numeric step is an array index
/// (FR-36). `""` is the value itself.
pub fn lookup_path(v : Json, path : String) -> Json? {
  if path == "" {
    return Some(v)
  }
  let mut cur = v
  for seg in path.split(".") {
    let key = seg.to_owned()
    cur = match cur {
      Json::Object(map) =>
        match map.get(key) {
          Some(inner) => inner
          None => return None
        }
      Json::Array(items) => {
        let idx = @string.parse_int(key) catch { _ => return None }
        if idx < 0 || idx >= items.length() {
          return None
        }
        items[idx]
      }
      _ => return None
    }
  }
  Some(cur)
}

// ---------------------------------------------------------------------------
// Semantic readiness: syntax + schema.
// ---------------------------------------------------------------------------

///|
/// How much of a skeleton was already final, and when (FR-36).
pub(all) struct SemanticReadiness {
  /// First input fraction, in per mille, at which the document needed no more
  /// closing, or `1000` when that never happened before the end.
  syntax_permille : Int32
  /// First input fraction, in per mille, at which every required member of the
  /// skeleton was already present and final *and* the document satisfied the
  /// skeleton, or `1000` when that never happened before the end. A document
  /// that is decidable and invalid never fires here: see `settled_permille`.
  schema_permille : Int32
  /// First input fraction, in per mille, at which every required member of the
  /// skeleton was already present and final, whether or not it had the declared
  /// kind (FR-39). This is the moment a *runtime* can decide: `schema_permille`
  /// answers "may I execute", this answers "do I know yet".
  settled_permille : Int32
  /// Sampling step actually used.
  step : Int32
  /// Verdict of the finished document.
  verdict : SchemaVerdict
}

///|
/// Per mille of `whole` that `part` is, without dividing by zero.
fn permille(part : Int32, whole : Int32) -> Int32 {
  if whole <= 0 {
    1000
  } else {
    part * 1000 / whole
  }
}

///|
/// Sampling step: `step` when positive, otherwise one that samples a document
/// about a thousand times.
pub fn auto_step(n : Int32, step : Int32) -> Int32 {
  if step > 0 {
    step
  } else {
    let auto = n / 1000
    if auto < 1 {
      1
    } else {
      auto
    }
  }
}

///|
/// The first input fraction at which the document was already the value it ends
/// up as (FR-29, FR-36). `-1` when the input cannot be parsed at all.
///
/// This is the "JSON syntax ready" number of the readiness report: it is 1000%
/// semantics but per mille of the input, i.e. 1000 means "not before the end".
pub fn syntax_readiness_permille(input : String, step? : Int32) -> Int32 {
  let n = input.length()
  if n == 0 {
    return -1
  }
  let fin = parse(input) catch { _ => return -1 }
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  let parser = PartialParser::new() catch { _ => return -1 }
  let mut i = 0
  while i < n {
    let next = if i + st > n { n } else { i + st }
    parser.feed(input[i:next].to_owned()) catch {
      _ => return -1
    }
    i = next
    match parser.snapshot().value {
      Some(v) => if json_equal(v, fin.value) { return permille(i, n) }
      None => ()
    }
  }
  1000
}

///|
/// Syntax readiness and schema readiness of one document against one skeleton
/// (FR-36, FR-39).
///
/// Since 0.6.0 this is a thin report over `SemanticWatcher`: the document is fed
/// in `step`-sized pieces and the numbers are read off the events, so the cost
/// is one pass plus one delta drain per piece instead of one partial parse *and
/// one snapshot* per piece. The result is the same kind of measurement — a
/// fraction of the input — but it no longer rebuilds the value tree a thousand
/// times, and `settled_permille` is new: the moment the answer became final
/// even when the answer is no.
///
/// ## `duplicate_keys KeepFirst` (Q-36)
///
/// There is one implementation, not two. Before 0.7.0 this function had a second
/// one — the 0.5.0 sampling loop — reachable only through `KeepFirst`, because
/// the watcher's delta stream cannot carry a value that `KeepFirst` dropped. The
/// second implementation measured the same quantity by a different mechanism, so
/// its numbers were the *same kind* of number and not the same number, and it
/// was the last caller of the sampling loop.
///
/// It is gone. What happens now is a **composition**, and the split is stated
/// here because the two halves are answered from different places:
///
///   * the three permille numbers come from the watcher, which measures under
///     `duplicate_keys: KeepLast` (see `SemanticWatcher`): when the value at
///     each followed path stopped changing, and when the skeleton was
///     satisfied. On a document with a repeated name whose two values differ,
///     `settled_permille` is the first time every followed path was final — the
///     *first* value's offset, the same number the sampling loop reported — and
///     `syntax_permille` is measured on a tree the second value also touched, so
///     it can be *later* than before; never earlier, and only on documents with
///     duplicate names. `schema_permille` follows `settled` and the verdict;
///   * the `verdict` comes from `parse(input, options=opts)`, i.e. from the
///     caller's own duplicate-key policy. Under `KeepFirst` the first value is
///     the real one, so `verdict` is the `KeepFirst` truth even though the
///     watcher observed the last value. This is what keeps the two from
///     disagreeing silently: the numbers are a property of the *input*, the
///     verdict is a property of the *policy*.
///
/// `RepairPlan` and the analysis path are unaffected: they take their verdict
/// from `parse` under the requested options, as they always did.
pub fn semantic_readiness(
  input : String,
  schema : Schema,
  step? : Int32,
  options? : Options,
) -> SemanticReadiness raise MendError {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  let n = input.length()
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  let w = SemanticWatcher::new(schema, options?)
  let mut i = 0
  while i < n {
    let next = if i + st > n { n } else { i + st }
    w.feed(input[i:next].to_owned())
    i = next
    // The events are consumed to keep the watcher's array from growing; the
    // numbers come from the offsets it recorded.
    let _ = w.drain_events()
  }
  let fin = w.finish()
  let required = schema.required_paths()
  let none_required = required.length() == 0
  // The verdict is the caller's: the watcher measured under `KeepLast`, so when
  // `KeepFirst` was asked for, the truth is what `parse` under those options
  // produces (Q-36).
  let verdict = if opts.duplicate_keys is KeepFirst {
    schema.evaluate(parse(input, options=opts).value)
  } else {
    schema.evaluate(fin.value)
  }
  let syntax = if w.syntax_at() < 0 { 1000 } else { permille(w.syntax_at(), n) }
  let settled = if none_required {
    0
  } else if w.settled_at() < 0 {
    1000
  } else {
    permille(w.settled_at(), n)
  }
  let schema_perm = if verdict.ok {
    if none_required {
      0
    } else if w.settled_at() < 0 {
      1000
    } else {
      permille(w.settled_at(), n)
    }
  } else {
    1000
  }
  {
    syntax_permille: syntax,
    schema_permille: schema_perm,
    settled_permille: settled,
    step: st,
    verdict,
  }
}
