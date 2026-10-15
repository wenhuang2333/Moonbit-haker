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
//
// A member is required by default: `!` is written for the reader, not for the
// parser. `Schema::stringify` always writes the marker back, so the text form
// has one canonical spelling and a round trip is exact.
//   [ schema ]
//
// The text form exists so that a demo, a test and a CLI flag can all use the
// same declaration without a JSON Schema implementation to parse it. It is a
// skeleton, not a contract: `integer` checks the value is a whole number,
// `string` checks it is a string, and nothing checks a range, a length or a
// format, because a streaming library that started checking those would be a
// validator with worse error messages.

///|
/// The kinds a skeleton declaration can name (FR-36).
pub(all) enum Schema {
  Any
  Null
  Bool
  Num
  Int
  Str
  Arr(Schema)
  Obj(Array[SchemaMember])
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
/// Stable name of a kind, as it is written in the text form.
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
        sb.write_string(m.key)
        sb.write_char(':')
        sb.write_string(m.schema.stringify())
      }
      sb.write_char('}')
      sb.to_string()
    }
    _ => self.name()
  }
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
    Any
  } else if sp_at(p, "null") {
    p.i = p.i + 4
    Null
  } else if sp_at(p, "boolean") {
    p.i = p.i + 7
    Bool
  } else if sp_at(p, "bool") {
    p.i = p.i + 4
    Bool
  } else if sp_at(p, "integer") {
    p.i = p.i + 7
    Int
  } else if sp_at(p, "int") {
    p.i = p.i + 3
    Int
  } else if sp_at(p, "number") {
    p.i = p.i + 6
    Num
  } else if sp_at(p, "string") {
    p.i = p.i + 6
    Str
  } else {
    raise SchemaError(
      "schema: unknown type at offset " +
      p.i.to_string() +
      ": " +
      p.text[p.i:].to_owned(),
    )
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
/// One declared member whose value does not have the declared kind (FR-36).
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
  /// Required members that are present and hold a value of the declared kind.
  satisfied : Int32
  /// Required members that are absent, as dotted paths.
  missing : Array[String]
  /// Present members that hold a value of the wrong kind.
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
/// Whether `v` has the declared kind (FR-36).
pub fn Schema::accepts(self : Schema, v : Json) -> Bool {
  match (self, v) {
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
                expected: m.schema.name(),
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
                expected: inner.name(),
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
  /// skeleton was already present and final, or `1000`.
  schema_permille : Int32
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
/// (FR-36).
///
/// The cost is the same as `field_readiness`: `O(n / step)` partial parses.
pub fn semantic_readiness(
  input : String,
  schema : Schema,
  step? : Int32,
  options? : Options,
) -> SemanticReadiness raise MendError {
  let n = input.length()
  let fin = parse(input, options?)
  let verdict = schema.evaluate(fin.value)
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  let parser = PartialParser::new(options?)
  let required = schema.required_paths()
  let mut syntax = 1000
  let mut schema_perm = 1000
  let mut syntax_seen = false
  // A skeleton that requires nothing is satisfied at the start; the value is
  // still reported as 0 so that "no work outstanding" is distinguishable from
  // "not before the end" (1000).
  let mut schema_seen = required.length() == 0
  if schema_seen {
    schema_perm = 0
  }
  let mut i = 0
  while i < n {
    let next = if i + st > n { n } else { i + st }
    parser.feed(input[i:next].to_owned())
    i = next
    let p = permille(i, n)
    let snap = parser.snapshot()
    if !syntax_seen {
      match snap.value {
        Some(v) =>
          if json_equal(v, fin.value) {
            syntax = p
            syntax_seen = true
          }
        None => ()
      }
    }
    if !schema_seen && verdict.ok {
      // "Every required member is already final": for each declared required
      // path, the value the snapshot holds there must be the value it ends up
      // with. Nothing else is required — not the end of the document, and not
      // the members the caller did not ask for.
      match snap.value {
        Some(v) => {
          let mut all = true
          for path in required {
            let now = lookup_path(v, path)
            let finv = lookup_path(fin.value, path)
            let same = match (now, finv) {
              (Some(x), Some(y)) => json_equal(x, y)
              _ => false
            }
            if !same {
              all = false
              break
            }
          }
          if all {
            schema_perm = p
            schema_seen = true
          }
        }
        None => ()
      }
    }
  }
  { syntax_permille: syntax, schema_permille: schema_perm, step: st, verdict, }
}
