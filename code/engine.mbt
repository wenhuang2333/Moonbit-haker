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
  mut last_assigned_key : String?
  mut key_pos : Position
  mut after_comma : Bool
  mut last_comma : Position
  synthetic : Bool
  mut dirty : Bool
  /// Full delta path of this container (FR-18); empty unless delta tracking is
  /// on, in which case it is the path at which the container was announced.
  mut path : Array[PathSegment]
  /// Whether a `Set` delta was emitted for this container.
  mut announced : Bool
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
  mut repairs_truncated : Bool
  mut concat_pending : Bool
  mut concat_pos : Position
  mut snap_stamp : Int32
  mut snap_cache : Snapshot?
  mut snap_cache_stamp : Int32
  mut prose_start : Position
  mut prose_skipped : Int32
  mut saw_content : Bool
  mut nojson_pos : Position
  mut epilogue_reported : Bool
  mut block_star : Bool
  mut utf8_need : Int32
  mut utf8_cp : Int32
  mut utf8_min : Int32
  mut utf8_start : Int32
  mut fed_bytes : Int32
  /// Worst exactness seen so far (FR-17), updated even when records are not
  /// collected.
  mut exactness : Exactness
  /// Whether an ambiguous repair was seen (FR-27), updated even when records
  /// are not collected.
  mut ambiguous : Bool
  /// Deltas recorded since the last `drain_deltas` (FR-18).
  mut deltas : Array[Delta]
  /// Code units of the string being scanned already reported as `AppendText`.
  mut delta_str_reported : Int32
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
    last_assigned_key: None,
    key_pos: start,
    after_comma: false,
    last_comma: start,
    synthetic,
    dirty: false,
    path: [],
    announced: false,
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
    repairs_truncated: false,
    concat_pending: false,
    concat_pos: pos0(),
    snap_stamp: 0,
    snap_cache: None,
    snap_cache_stamp: -1,
    prose_start: start,
    prose_skipped: 0,
    saw_content: false,
    nojson_pos: start,
    epilogue_reported: false,
    block_star: false,
    utf8_need: 0,
    utf8_cp: 0,
    utf8_min: 0,
    utf8_start: 0,
    fed_bytes: 0,
    exactness: Exact,
    ambiguous: false,
    deltas: [],
    delta_str_reported: 0,
  }
  if opts.multi_root is AsArray {
    let f = new_frame(FArr, start, true)
    if opts.collect_deltas {
      f.path = []
      f.announced = true
      e.push_delta(Set, [], Some(Json::array([])), "")
    }
    e.stack.push(f)
  }
  e
}

///|
/// Record a repair, or raise `E010` when the rule is disabled, the parser runs
/// in strict mode, or the repair would make the result riskier than
/// `Options::max_loss` (D09 9.5, FR-17).
fn Engine::report(
  self : Engine,
  code : RepairCode,
  p : Position,
  slot~ : Slot = KeySlot,
  severity~ : Severity? = None,
  ambiguity~ : Ambiguity = Unambiguous,
) -> Unit raise MendError {
  // A few codes are only notation-level in some situations: quoting a key,
  // re-casing a literal, merging two identical duplicate keys. Those sites
  // pass an explicit severity; everything else derives it from the code.
  let severity = match severity {
    Some(s) => s
    None => code.severity_in(slot)
  }
  if self.opts.mode is Strict || !self.opts.rules.is_enabled(code) {
    raise StrictViolation(code, p, code.message())
  }
  // The ambiguity gate comes before the exactness gate: when both apply, the
  // ambiguity is the more specific diagnosis and the one a retry can act on.
  if ambiguity.is_ambiguous() && self.opts.reject_ambiguous {
    raise AmbiguousRepair(code, p, ambiguity)
  }
  let level = if severity is Warning { Lossy } else { Cosmetic }
  if !level.within(self.opts.max_loss) {
    raise StrictViolation(
      code,
      p,
      "exactness " +
      level.name() +
      " exceeds max_loss " +
      self.opts.max_loss.name(),
    )
  }
  if level.rank() > self.exactness.rank() {
    self.exactness = level
  }
  if ambiguity.is_ambiguous() {
    self.ambiguous = true
  }
  if self.opts.collect_repairs {
    if self.reps.length() < self.opts.max_repairs {
      self.reps.push({
        code,
        position: p,
        severity,
        message: code.message(),
        ambiguity,
      })
    } else {
      self.repairs_truncated = true
    }
  }
}

///|
/// Feed a whole string chunk.
fn Engine::feed_str(self : Engine, s : String) -> Unit raise MendError {
  match self.phase {
    PFinished | PFailed => raise InvalidState("cannot feed a finished parser")
    _ => ()
  }
  let n = s.length()
  let mut i = 0
  while i < n {
    let mut batched = false
    // Fast path (P3-9): inside an open string, a run of ordinary characters is
    // appended in one piece and the position advances in one step. Only code
    // units that `step_str` would pass straight to `push_cu` qualify, so the
    // observable behaviour is identical.
    match self.tok {
      TStr(kind, _is_key) =>
        if self.esc == 0 && self.pending_high == 0 {
          let mut j = i
          while j < n && is_plain_str_cu(s.at(j), kind) {
            j = j + 1
          }
          // never consume code units beyond max_input_len (E021)
          while j > i && self.pos.offset + (j - i) > self.opts.max_input_len {
            j = j - 1
          }
          if j > i {
            self.push_run(s, i, j)
            i = j
            batched = true
          }
        }
      _ => ()
    }
    if !batched {
      self.step(s.at(i))
      i = i + 1
    }
  }
}

///|
/// Whether a code unit is plain string content for the given quote style:
/// it cannot close the string, cannot start an escape, is not a control
/// character and is not a surrogate (those need the pair logic).
fn is_plain_str_cu(u : UInt16, kind : StrKind) -> Bool {
  let n = u.to_int()
  n >= 0x20 && n != 0x5C && !closes_str(kind, u) && (n < 0xD800 || n > 0xDFFF)
}

///|
/// Append a run of plain string content as a single part (P3-9). The run
/// contains no line break, so the column advances by the run length.
fn Engine::push_run(
  self : Engine,
  s : String,
  from : Int32,
  to : Int32,
) -> Unit raise MendError {
  let len = to - from
  self.parts.push(s[from:to].to_owned())
  self.parts_len = self.parts_len + len
  if self.parts_len > self.opts.max_token_len {
    raise TokenLimit(self.opts.max_token_len, self.tok_start.offset)
  }
  self.pos = {
    offset: self.pos.offset + len,
    line: self.pos.line,
    column: self.pos.column + len,
  }
  self.snap_stamp = self.snap_stamp + 1
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
  self.snap_stamp = self.snap_stamp + 1
}

///|
/// Feed raw UTF-8 bytes (FR-12). Invalid bytes raise `E040`.
///
/// The payload of `E040` is an absolute byte offset from the start of the whole
/// input, counted across every `feed_bytes` call, so the diagnostic does not
/// depend on how the caller split the stream into chunks (BR-22).
fn Engine::feed_bytes(self : Engine, bs : Bytes) -> Unit raise MendError {
  for i = 0; i < bs.length(); i = i + 1 {
    self.feed_byte(bs[i].to_char().to_int(), i)
  }
  self.fed_bytes = self.fed_bytes + bs.length()
}

///|
/// Feed one UTF-8 byte. `idx` is the offset inside the current chunk; the
/// absolute offset is `fed_bytes + idx` (BR-22).
fn Engine::feed_byte(
  self : Engine,
  b : Int32,
  idx : Int32,
) -> Unit raise MendError {
  let abs = self.fed_bytes + idx
  if self.utf8_need == 0 {
    if b < 0x80 {
      self.step(b.to_uint16())
      return
    }
    if b >= 0xC2 && b <= 0xDF {
      self.utf8_need = 1
      self.utf8_cp = b & 0x1F
      self.utf8_min = 0x80
      self.utf8_start = abs
      return
    }
    if b >= 0xE0 && b <= 0xEF {
      self.utf8_need = 2
      self.utf8_cp = b & 0x0F
      self.utf8_min = 0x800
      self.utf8_start = abs
      return
    }
    if b >= 0xF0 && b <= 0xF4 {
      self.utf8_need = 3
      self.utf8_cp = b & 0x07
      self.utf8_min = 0x10000
      self.utf8_start = abs
      return
    }
    raise InvalidUtf8(abs)
  }
  if b < 0x80 || b > 0xBF {
    self.utf8_need = 0
    raise InvalidUtf8(abs)
  }
  self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3F)
  self.utf8_need = self.utf8_need - 1
  if self.utf8_need == 0 {
    let cp = self.utf8_cp
    if cp < self.utf8_min || cp > 0x10FFFF {
      raise InvalidUtf8(self.utf8_start)
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
