// M2 engine — one incremental engine behind both one-shot repair and streaming
// partial parsing (ADR-001, ADR-007).
//
// The engine is a pushdown automaton over UTF-16 code units: an explicit
// container stack plus a token state, no recursion and no regular expressions.
// Every mutation of the input is recorded as an `R` repair; fatal conditions
// raise `MendError` (`E` codes).

///|
/// Container kind of an open frame.
priv enum FrameKind {
  FObj
  FArr
}

///|
/// Grammar context inside an open container (D08 8.2).
priv enum Ctx {
  CObjKeyOrEnd
  CObjColon
  CObjValue
  CObjCommaOrEnd
  CArrValueOrEnd
  CArrCommaOrEnd
}

///|
/// One open container.
priv struct Frame {
  kind : FrameKind
  mut ctx : Ctx
  items : Array[Json]
  map : Map[String, Json]
  mut last_key : String?
  mut key_pos : Position
  mut after_comma : Bool
  mut last_comma : Position
  synthetic : Bool
  mut dirty : Bool
}

///|
/// Whether a bare token is in key or value position.
priv enum BareKind {
  BareKey
  BareValue
}

///|
/// Current unfinished token.
priv enum Tok {
  TIdle
  TStr(StrKind, Bool)
  TStrPending(StrKind, Bool)
  TBare(BareKind)
  TSlash
  TLineComment
  TBlockComment
  TFence(Int32)
  TFenceLine
}

///|
/// Document lifecycle.
priv enum Phase {
  PPrelude
  PBody
  PEpilogue
  PFinished
  PFailed
}

///|
/// Literal classification of a bare word.
priv enum LitKind {
  LNone
  LTrue
  LFalse
  LNull
}

///|
/// The incremental engine.
priv struct Engine {
  opts : Options
  mut phase : Phase
  stack : Array[Frame]
  parts : Array[String]
  mut parts_len : Int32
  mut esc : Int32
  mut esc_val : Int32
  mut esc_digits : Int32
  mut esc_pos : Position
  mut pending_high : Int32
  mut pending_high_pos : Position
  bare : StringBuilder
  mut bare_len : Int32
  pending_ws : StringBuilder
  mut pending_quote : Int32
  mut pending_quote_pos : Position
  mut fence_start : Position
  mut fence_body : Bool
  mut pos : Position
  mut tok : Tok
  mut tok_start : Position
  mut root : Json?
  reps : Array[Repair]
  mut prose_start : Position
  mut prose_skipped : Int32
  mut saw_content : Bool
  mut nojson_pos : Position
  mut epilogue_reported : Bool
  mut block_star : Bool
  mut utf8_need : Int32
  mut utf8_cp : Int32
  mut utf8_min : Int32
}

///|
/// Advance a position by one code unit. Only LF starts a new line (BR-20).
fn advance(p : Position, u : UInt16) -> Position {
  if u.to_int() == 0x0A {
    { offset: p.offset + 1, line: p.line + 1, column: 1, }
  } else {
    { offset: p.offset + 1, line: p.line, column: p.column + 1, }
  }
}

///|
/// Position at the very start of the input.
fn pos0() -> Position {
  { offset: 0, line: 1, column: 1, }
}

///|
/// A fresh frame.
fn new_frame(kind : FrameKind, start : Position, synthetic : Bool) -> Frame {
  {
    kind,
    ctx: if kind is FObj {
      CObjKeyOrEnd
    } else {
      CArrValueOrEnd
    },
    items: [],
    map: Map([]),
    last_key: None,
    key_pos: start,
    after_comma: false,
    last_comma: start,
    synthetic,
    dirty: false,
  }
}

///|
/// Whether `u` is the first code unit of a number.
fn is_number_start(u : UInt16) -> Bool {
  let n = u.to_int()
  n == 0x2B || n == 0x2D || n == 0x2E || (n >= 0x30 && n <= 0x39)
}

///|
/// Build a JSON number, keeping the source text verbatim as `repr` so that
/// integers beyond `Double` precision survive (ADR-004).
fn build_number(text : String) -> Json {
  let d = @string.parse_double(text) catch { _ => 0.0 }
  Json::number(d, repr=text)
}

///|
/// Literal classification, accepting case variants and Python / JavaScript
/// spellings (`None`, `undefined`) as R012 material (D08 8.7).
fn literal_kind(lower : String) -> LitKind {
  let n = lower.length()
  if n == 0 || n > 9 {
    return LNone
  }
  if lower == "true" || "true".has_prefix(lower) {
    return LTrue
  }
  if lower == "false" || "false".has_prefix(lower) {
    return LFalse
  }
  if lower == "null" ||
    lower == "none" ||
    lower == "undefined" ||
    "null".has_prefix(lower) ||
    "none".has_prefix(lower) ||
    "undefined".has_prefix(lower) {
    return LNull
  }
  LNone
}

///|
/// Canonical spelling of a literal.
fn literal_canonical(k : LitKind) -> String {
  match k {
    LTrue => "true"
    LFalse => "false"
    LNull => "null"
    LNone => ""
  }
}

///|
/// Non-finite literal spellings (BR-12).
fn is_non_finite(lower : String) -> Bool {
  lower == "nan" || lower == "infinity" || lower == "-infinity"
}

///|
/// Serialise a value, honouring the indent option.
fn render(v : Json, indent : Int32) -> String {
  if indent > 0 {
    v.stringify(indent~)
  } else {
    v.stringify()
  }
}

///|
/// Create an engine for the given options.
fn Engine::make(opts : Options) -> Engine {
  let start = pos0()
  let e : Engine = {
    opts,
    phase: PPrelude,
    stack: [],
    parts: [],
    parts_len: 0,
    esc: 0,
    esc_val: 0,
    esc_digits: 0,
    esc_pos: start,
    pending_high: 0,
    pending_high_pos: start,
    bare: StringBuilder(),
    bare_len: 0,
    pending_ws: StringBuilder(),
    pending_quote: 0,
    pending_quote_pos: start,
    fence_start: start,
    fence_body: false,
    pos: start,
    tok: TIdle,
    tok_start: start,
    root: None,
    reps: [],
    prose_start: start,
    prose_skipped: 0,
    saw_content: false,
    nojson_pos: start,
    epilogue_reported: false,
    block_star: false,
    utf8_need: 0,
    utf8_cp: 0,
    utf8_min: 0,
  }
  if opts.multi_root is AsArray {
    e.stack.push(new_frame(FArr, start, true))
  }
  e
}

///|
/// Record a repair, or raise `E010` when the rule is disabled or the parser
/// runs in strict mode (D09 9.5).
fn Engine::report(
  self : Engine,
  code : RepairCode,
  sev : Severity,
  p : Position,
) -> Unit raise MendError {
  if self.opts.mode is Strict || !self.opts.rules.is_enabled(code) {
    raise StrictViolation(code, p, code.message())
  }
  if self.opts.collect_repairs && self.reps.length() < 10000 {
    self.reps.push({
      code,
      position: p,
      severity: sev,
      message: code.message(),
    })
  }
}

///|
/// Feed a whole string chunk.
fn Engine::feed_str(self : Engine, s : String) -> Unit raise MendError {
  match self.phase {
    PFinished | PFailed => raise InvalidState("cannot feed a finished parser")
    _ => ()
  }
  for i = 0; i < s.length(); i = i + 1 {
    self.step(s.at(i))
  }
}

///|
/// Feed one UTF-16 code unit.
fn Engine::step(self : Engine, u : UInt16) -> Unit raise MendError {
  if self.pos.offset >= self.opts.max_input_len {
    raise SizeLimit(self.opts.max_input_len, self.pos.offset)
  }
  let p = self.pos
  match self.tok {
    TIdle => self.step_idle(u, p)
    TStr(kind, is_key) => self.step_str(u, p, kind, is_key)
    TStrPending(kind, is_key) => self.step_str_pending(u, p, kind, is_key)
    TBare(kind) => self.step_bare(u, p, kind)
    TSlash => self.step_slash(u, p)
    TLineComment => if u.to_int() == 0x0A { self.tok = TIdle }
    TBlockComment => self.step_block(u, p)
    TFence(count) => self.step_fence(u, p, count)
    TFenceLine => if u.to_int() == 0x0A { self.finish_fence_line() }
  }
  self.pos = advance(p, u)
}

///|
/// Feed raw UTF-8 bytes (FR-12). Invalid bytes raise `E040`.
fn Engine::feed_bytes(self : Engine, bs : Bytes) -> Unit raise MendError {
  for i = 0; i < bs.length(); i = i + 1 {
    self.feed_byte(bs[i].to_char().to_int(), i)
  }
}

///|
/// Feed one UTF-8 byte.
fn Engine::feed_byte(
  self : Engine,
  b : Int32,
  idx : Int32,
) -> Unit raise MendError {
  if self.utf8_need == 0 {
    if b < 0x80 {
      self.step(b.to_uint16())
      return
    }
    if b >= 0xC2 && b <= 0xDF {
      self.utf8_need = 1
      self.utf8_cp = b & 0x1F
      self.utf8_min = 0x80
      return
    }
    if b >= 0xE0 && b <= 0xEF {
      self.utf8_need = 2
      self.utf8_cp = b & 0x0F
      self.utf8_min = 0x800
      return
    }
    if b >= 0xF0 && b <= 0xF4 {
      self.utf8_need = 3
      self.utf8_cp = b & 0x07
      self.utf8_min = 0x10000
      return
    }
    raise InvalidUtf8(idx)
  }
  if b < 0x80 || b > 0xBF {
    self.utf8_need = 0
    raise InvalidUtf8(idx)
  }
  self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3F)
  self.utf8_need = self.utf8_need - 1
  if self.utf8_need == 0 {
    let cp = self.utf8_cp
    if cp < self.utf8_min || cp > 0x10FFFF {
      raise InvalidUtf8(idx)
    }
    if cp <= 0xFFFF {
      self.step(cp.to_uint16())
    } else {
      let v = cp - 0x10000
      self.step((0xD800 + (v >> 10)).to_uint16())
      self.step((0xDC00 + (v & 0x3FF)).to_uint16())
    }
  }
}
