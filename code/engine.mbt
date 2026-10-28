// M2 engine — one incremental engine behind both one-shot repair and streaming
// partial parsing (ADR-001, ADR-007).
//
// The engine is a pushdown automaton over UTF-16 code units: an explicit
// container stack plus a token state, no recursion and no regular expressions.
// Every mutation of the input is recorded as an `R` repair; fatal conditions
// raise `InterJSONError` (`E` codes).

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
  /// The values of an array frame, and of a synthetic frame (which aggregates
  /// several root values). `None` for an object frame: an object stores its
  /// members in `map` and never touches this.
  ///
  /// Both containers used to be allocated for every frame, so an array frame
  /// paid for a `Map` it could not use and an object frame for an `Array` it
  /// could not use. The map is the expensive one -- an empty `Map` is most of
  /// what an object frame costs -- and for a document of a million small
  /// arrays the unused maps were the single largest allocation in the parse.
  items : Array[Json]?
  /// The members of an object frame. `None` for an array or synthetic frame.
  map : Map[String, Json]?
  mut last_key : String?
  mut last_assigned_key : String?
  mut key_pos : Position
  mut after_comma : Bool
  mut last_comma : Position
  synthetic : Bool
  mut dirty : Bool
  /// Arena index of this container's own delta path (FR-18); `-1` unless delta
  /// tracking is on, in which case it is the path at which the container was
  /// announced. An index rather than an array: recording a change must not copy
  /// a path per change.
  mut path_id : Int32
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
  /// Current position, kept as three integers rather than a `Position`.
  /// The scanner advances once per code unit, so allocating a `Position` there
  /// made the JS backend allocate once per code unit and the cost of the run
  /// grow with the live heap (n/2n/4n drifted above 2.3). Historical positions
  /// — token starts, error sites, the last comma — stay frozen `Position`
  /// values and are produced by `Engine::position`.
  mut pos_offset : Int32
  mut pos_line : Int32
  mut pos_column : Int32
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
  /// Code units fed while the document is still in the prelude, so that a
  /// prelude which was skipped as prose can be retried as JSON at `finish`.
  /// Bounded by `max_prose_buffer`.
  prose_buf : Array[UInt16]
  /// Set when the skipped prelude outgrew `max_prose_buffer`: the retry is then
  /// impossible and the document is refused as it was before.
  mut prose_overflow : Bool
  /// True while `finish_engine` is running. Deltas produced then describe the
  /// state at the end of the input, so their `at` is the total length rather
  /// than the offset of the code unit being processed plus one.
  mut finishing : Bool
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
  /// Whether a `DropUnexpected` repair was seen. The `skip_prose` retry uses
  /// this to tell a scalar root apart from prose that happens to begin with a
  /// scalar (`42 is the answer`): the latter drops the tail, and must stay
  /// refused. Kept even when records are not collected.
  mut saw_dropped_content : Bool
  /// The delta log (FR-18): parallel arrays of the recorded changes plus the
  /// path arena they index. See `delta.mbt`.
  dlog : DeltaLog
  /// Code units of the string being scanned already reported as `AppendText`.
  mut delta_str_reported : Int32
  /// Cursor into `parts` for the next `AppendText` tail. Without it every
  /// drain would rescan the whole string, which is quadratic when a long
  /// string is drained once per small chunk.
  mut delta_part_idx : Int32
  mut delta_part_off : Int32
}

///|
/// Advance the current position by one code unit. Only LF starts a new line
/// (BR-20). Updating three integers is the whole cost: nothing is allocated.
fn Engine::advance(self : Engine, u : UInt16) -> Unit {
  self.pos_offset = self.pos_offset + 1
  if u.to_int() == 0x0A {
    self.pos_line = self.pos_line + 1
    self.pos_column = 1
  } else {
    self.pos_column = self.pos_column + 1
  }
}

///|
/// Freeze the current position into a `Position`.
///
/// Every position that has to outlive the scan — a token start, an error site,
/// the last comma of a container — is materialised through this and stored as
/// an immutable value, so advancing cannot rewrite it. The scanner itself calls
/// it only where such a value is actually needed, not per code unit.
fn Engine::position(self : Engine) -> Position {
  { offset: self.pos_offset, line: self.pos_line, column: self.pos_column, }
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
    items: if kind is FObj {
      None
    } else {
      Some([])
    },
    map: if kind is FObj {
      Some(Map([]))
    } else {
      None
    },
    last_key: None,
    last_assigned_key: None,
    key_pos: start,
    after_comma: false,
    last_comma: start,
    synthetic,
    dirty: false,
    path_id: -1,
    announced: false,
  }
}

///|
/// The values of an array frame, or of a synthetic frame. An object frame has
/// none, and asking for them is a programming error the caller avoids by
/// branching on the frame's kind first.
fn frame_items(f : Frame) -> Array[Json] {
  match f.items {
    Some(a) => a
    None => []
  }
}

///|
/// The members of an object frame. An array frame has none.
fn frame_map(f : Frame) -> Map[String, Json] {
  match f.map {
    Some(m) => m
    None => Map([])
  }
}

///|
/// A map holding exactly the entries it has.
///
/// `Map([])` is created with room for eight entries, and an object that holds
/// one keeps paying for the other seven: the map is the value the caller
/// retains, so the padding lives as long as the value does. A tool argument
/// object is usually one or two keys, and a document of a million small
/// objects is the case where the padding is the whole memory profile. The copy
/// happens once, when the container closes, and only when it would actually
/// shrink.
fn shrink_map(m : Map[String, Json]) -> Map[String, Json] {
  if m.capacity() <= m.length() {
    return m
  }
  let out : Map[String, Json] = Map([], capacity=m.length())
  for k, v in m {
    out[k] = v
  }
  out
}

///|
/// An array holding exactly the elements it has. See `shrink_map`.
fn shrink_array(a : Array[Json]) -> Array[Json] {
  if a.capacity() <= a.length() {
    return a
  }
  let out : Array[Json] = Array::make(a.length(), Json::null())
  for i = 0; i < a.length(); i = i + 1 {
    out[i] = a[i]
  }
  out
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
  // The source text is kept only when the `Double` cannot reproduce it.
  //
  // `repr` exists so that `1.0` stays `1.0` and an integer past 2^53 keeps
  // every digit; without it the value round-trips through the double and
  // `9007199254740993` would come back as `9007199254740992`. But storing it
  // for *every* number costs a `String` allocation per number, which for a
  // document full of integers is the single largest thing the parser
  // allocates -- and for a plain integer the text and the double agree, so the
  // allocation buys nothing.
  //
  // `number_repr_is_redundant` is the conservative test: it answers "yes" only
  // when the text is a canonical decimal integer that a `Double` holds
  // exactly, where core's serialiser is known to print the text back verbatim.
  // Everything else -- `1.0`, `1e2`, `-0`, `0.0000001`, `12345678901234567890`
  // -- keeps its text. `TC-R-24` asserts the rule against core over a table of
  // awkward numbers.
  if number_repr_is_redundant(text) {
    Json::number(d)
  } else {
    Json::number(d, repr=text)
  }
}

///|
/// Whether core's serialiser prints `text` back verbatim for the `Double` it
/// denotes, so that storing the text is redundant.
///
/// True only for a canonical plain decimal integer: an optional `-`, digits
/// with no leading zero (unless the value is exactly `0`), no fraction, no
/// exponent, and at most 15 digits so that the double holds it exactly. `-0`
/// is excluded because core prints `0` for it.
fn number_repr_is_redundant(text : String) -> Bool {
  let n = text.length()
  if n == 0 {
    return false
  }
  let mut i = 0
  if text.at(i) == 0x2D {
    i = i + 1
    if i == n {
      return false
    }
  }
  let digits = n - i
  if digits > 15 {
    return false
  }
  for j = i; j < n; j = j + 1 {
    let c = text.at(j).to_int()
    if c < 0x30 || c > 0x39 {
      return false
    }
  }
  // A leading zero is only canonical for the value zero itself, and `-0` is
  // printed as `0` by core, so it must keep its text.
  if text.at(i) == 0x30 && (digits > 1 || i > 0) {
    return false
  }
  true
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
///
/// The renderer is **iterative**. `Json::stringify` from core is recursive, so
/// a value deep enough to outrun the native stack could be parsed and then
/// crash on the way out -- a refusal turned into a crash, which is the failure
/// `Options::max_depth` exists to prevent, arriving one step later. With an
/// explicit work list the depth a caller may configure is bounded by the heap
/// rather than by the stack, so `max_depth` can mean what it says.
///
/// The output is byte-identical to `Json::stringify`; `TC-R-22` asserts that
/// against core on the golden corpus and on generated values.
fn render(v : Json, indent : Int32) -> String {
  let sb = StringBuilder()
  let work : Array[RenderStep] = [Value(v, 0)]
  while work.length() > 0 {
    match work.remove(work.length() - 1) {
      Value(x, depth) => render_value(sb, x, depth, work)
      ArrayAt(items, i, depth) =>
        render_array_at(sb, items, i, indent, depth, work)
      ObjectAt(entries, i, depth) =>
        render_object_at(sb, entries, i, indent, depth, work)
    }
  }
  sb.to_string()
}

///|
/// One pending piece of a render.
///
/// A container is rendered one element at a time, by cursor, rather than by
/// queueing every child at once. Queueing them all is simpler and is what this
/// code did first, but it makes the work list as large as the container: for a
/// million-element array the queue itself was the peak allocation, which is
/// the memory the mode exists to avoid. A cursor keeps the work list as deep
/// as the document, not as wide.
priv enum RenderStep {
  /// Write this value at this depth.
  Value(Json, Int32)
  /// Continue writing `items` from index `i` at this depth.
  ArrayAt(Array[Json], Int32, Int32)
  /// Continue writing `entries` from index `i` at this depth.
  ObjectAt(Array[(String, Json)], Int32, Int32)
}

///|
/// Write one value, starting a cursor when it is a container.
fn render_value(
  sb : StringBuilder,
  v : Json,
  depth : Int32,
  work : Array[RenderStep],
) -> Unit {
  match v {
    Json::Null => sb.write_string("null")
    Json::True => sb.write_string("true")
    Json::False => sb.write_string("false")
    // A number keeps its source text when it has one, so `1.0` stays `1.0`
    // and an integer past 2^53 keeps every digit.
    Json::Number(_, repr~) =>
      match repr {
        Some(text) => sb.write_string(text)
        None => sb.write_string(v.stringify())
      }
    Json::String(_) => sb.write_string(v.stringify())
    Json::Array(items) =>
      if items.length() == 0 {
        sb.write_string("[]")
      } else {
        sb.write_char('[')
        work.push(ArrayAt(items, 0, depth))
      }
    Json::Object(map) =>
      if map.length() == 0 {
        sb.write_string("{}")
      } else {
        sb.write_char('{')
        // The map iterates in insertion order, which is the order the document
        // had. Collecting the entries once per object is O(keys); the cursor
        // then walks them without holding the whole container on the stack.
        let entries : Array[(String, Json)] = []
        for k, item in map {
          entries.push((k, item))
        }
        work.push(ObjectAt(entries, 0, depth))
      }
  }
}

///|
/// Write element `i` of an array and queue the rest.
fn render_array_at(
  sb : StringBuilder,
  items : Array[Json],
  i : Int32,
  indent : Int32,
  depth : Int32,
  work : Array[RenderStep],
) -> Unit {
  if i >= items.length() {
    sb.write_string(close_pad(depth, indent))
    sb.write_char(']')
    return
  }
  if i > 0 {
    sb.write_string(separator(depth, indent))
  } else {
    sb.write_string(open_pad(depth, indent))
  }
  work.push(ArrayAt(items, i + 1, depth))
  work.push(Value(items[i], depth + 1))
}

///|
/// Write member `i` of an object and queue the rest.
fn render_object_at(
  sb : StringBuilder,
  entries : Array[(String, Json)],
  i : Int32,
  indent : Int32,
  depth : Int32,
  work : Array[RenderStep],
) -> Unit {
  if i >= entries.length() {
    sb.write_string(close_pad(depth, indent))
    sb.write_char('}')
    return
  }
  if i > 0 {
    sb.write_string(separator(depth, indent))
  } else {
    sb.write_string(open_pad(depth, indent))
  }
  let (k, item) = entries[i]
  sb.write_string(Json::string(k).stringify())
  sb.write_string(if indent > 0 { ": " } else { ":" })
  work.push(ObjectAt(entries, i + 1, depth))
  work.push(Value(item, depth + 1))
}

///|
/// What sits between two elements of a container: a comma, then the newline and
/// indent that the next element starts with.
fn separator(depth : Int32, indent : Int32) -> String {
  if indent > 0 {
    "," + "\n" + pad(depth + 1, indent)
  } else {
    ","
  }
}

///|
/// What sits between the opening bracket and the first element.
fn open_pad(depth : Int32, indent : Int32) -> String {
  if indent > 0 {
    "\n" + pad(depth + 1, indent)
  } else {
    ""
  }
}

///|
/// What sits between the last element and the closing bracket.
fn close_pad(depth : Int32, indent : Int32) -> String {
  if indent > 0 {
    "\n" + pad(depth, indent)
  } else {
    ""
  }
}

///|
/// `depth * indent` spaces.
fn pad(depth : Int32, indent : Int32) -> String {
  let sb = StringBuilder()
  let mut i = 0
  let total = depth * indent
  while i < total {
    sb.write_char(' ')
    i = i + 1
  }
  sb.to_string()
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
    pos_offset: 0,
    pos_line: 1,
    pos_column: 1,
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
    prose_buf: [],
    prose_overflow: false,
    finishing: false,
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
    saw_dropped_content: false,
    dlog: DeltaLog::new(),
    delta_str_reported: 0,
    delta_part_idx: 0,
    delta_part_off: 0,
  }
  if opts.multi_root is AsArray {
    let f = new_frame(FArr, start, true)
    if opts.collect_deltas {
      f.path_id = root_path
      f.announced = true
      e.push_delta(Set, root_path, Some(Json::array([])), "")
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
) -> Unit raise InterJSONError {
  // A few codes are only notation-level in some situations: quoting a key,
  // re-casing a literal, merging two identical duplicate keys. Those sites
  // pass an explicit severity; everything else derives it from the code.
  let severity = match severity {
    Some(s) => s
    None => code.severity_in(slot)
  }
  if code is DropUnexpected {
    self.saw_dropped_content = true
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
fn Engine::feed_str(self : Engine, s : String) -> Unit raise InterJSONError {
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
          while j > i && self.pos_offset + (j - i) > self.opts.max_input_len {
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
) -> Unit raise InterJSONError {
  let len = to - from
  // A whole-string run (the byte fast path always passes one) can be stored
  // as-is; slicing would copy it again.
  let part = if from == 0 && to == s.length() {
    s
  } else {
    s[from:to].to_owned()
  }
  self.parts.push(part)
  self.parts_len = self.parts_len + len
  if self.parts_len > self.opts.max_token_len {
    raise TokenLimit(self.opts.max_token_len, self.tok_start.offset)
  }
  self.pos_offset = self.pos_offset + len
  self.pos_column = self.pos_column + len
  self.snap_stamp = self.snap_stamp + 1
}

///|
/// Feed one UTF-16 code unit.
fn Engine::step(self : Engine, u : UInt16) -> Unit raise InterJSONError {
  if self.pos_offset >= self.opts.max_input_len {
    raise SizeLimit(self.opts.max_input_len, self.pos_offset)
  }
  // Keep what the prelude sees. `step` is the single funnel for both `feed_str`
  // and `feed_bytes`, so the buffer is the same however the caller split the
  // input — which is what makes the `finish` retry chunk-invariant.
  if self.phase is PPrelude {
    if self.prose_buf.length() < self.opts.max_prose_buffer {
      self.prose_buf.push(u)
    } else {
      self.prose_overflow = true
    }
  }
  match self.tok {
    TIdle => self.step_idle(u)
    TStr(kind, is_key) => self.step_str(u, kind, is_key)
    TStrPending(kind, is_key) => self.step_str_pending(u, kind, is_key)
    TBare(kind) => self.step_bare(u, kind)
    TSlash => self.step_slash(u)
    TLineComment => if u.to_int() == 0x0A { self.tok = TIdle }
    TBlockComment => self.step_block(u)
    TFence(count) => self.step_fence(u, count)
    TFenceLine => if u.to_int() == 0x0A { self.finish_fence_line() }
  }
  self.advance(u)
  self.snap_stamp = self.snap_stamp + 1
}

///|
/// Feed raw UTF-8 bytes (FR-12). Invalid bytes raise `E040`.
///
/// The payload of `E040` is an absolute byte offset from the start of the whole
/// input, counted across every `feed_bytes` call, so the diagnostic does not
/// depend on how the caller split the stream into chunks (BR-22).
fn Engine::feed_bytes(self : Engine, bs : Bytes) -> Unit raise InterJSONError {
  let n = bs.length()
  let mut i = 0
  while i < n {
    let mut batched = false
    // Same fast path as `feed_str`: inside a plain string, a run of ASCII
    // content is appended in one piece. Bytes >= 0x80, escapes and an
    // unfinished multibyte sequence fall through to `feed_byte`, so UTF-8
    // validation and its absolute offsets are unchanged.
    if self.utf8_need == 0 && self.esc == 0 && self.pending_high == 0 {
      match self.tok {
        TStr(kind, _) => {
          // Two scans, because one costs more than the other. The first is the
          // original plain-ASCII run: no counter, no limit check, `j - i` is
          // both the byte count and the code unit count. The second extends the
          // run across complete multi-byte sequences, and needs a code unit
          // counter because three bytes are one unit there. Folding the two
          // into one counter-carrying loop made the plain-ASCII case 15%
          // slower, which is the case most documents are made of.
          let mut j = i
          while j < n {
            let b = bs[j].to_int()
            if b >= 0x80 || !is_plain_str_cu(b.to_uint16(), kind) {
              break
            }
            j = j + 1
          }
          let budget = self.opts.max_input_len - self.pos_offset
          let mut units = j - i
          if units > budget {
            j = i + budget
            units = budget
          }
          while j < n && units < budget {
            let b = bs[j].to_int()
            if b < 0x80 {
              if !is_plain_str_cu(b.to_uint16(), kind) {
                break
              }
              j = j + 1
              units = units + 1
            } else {
              let len = plain_utf8_run(bs, j, kind)
              if len == 0 {
                break
              }
              let u = if len == 4 { 2 } else { 1 }
              if units + u > budget {
                break
              }
              j = j + len
              units = units + u
            }
          }
          if j > i {
            let run = @utf8.decode_lossy(bs[i:j])
            self.push_run(run, 0, units)
            i = j
            batched = true
          }
        }
        _ => ()
      }
    }
    if !batched {
      self.feed_byte(bs[i].to_char().to_int(), i)
      i = i + 1
    }
  }
  self.fed_bytes = self.fed_bytes + n
}

///|
/// Length in bytes of a complete, minimal UTF-8 sequence at `bs[i]` that the
/// run batching may consume in one piece; `0` when the bytes are not such a
/// sequence and the caller must fall back to `feed_byte`.
///
/// A non-zero answer is always 2, 3 or 4, and `4` also tells the caller that the
/// sequence decodes to two UTF-16 code units (see the last comment below).
///
/// This mirrors `feed_byte`'s validator exactly — same lead-byte ranges, same
/// continuation-byte check, same overlong (`utf8_min`) and range checks — and
/// additionally rejects the code points `step_str` handles itself: the closing
/// quote, the backslash, and control characters below 0x20. Falling back is
/// always safe; batching a sequence this function wrongly accepts is not, so
/// the checks are duplicated rather than approximated.
///
/// The code unit count matters because `max_input_len` and `Position` are
/// counted in UTF-16 code units, not bytes: a supplementary code point is one
/// four-byte sequence but advances the parser twice.
fn plain_utf8_run(bs : Bytes, i : Int32, kind : StrKind) -> Int32 {
  let n = bs.length()
  let b0 = bs[i].to_int()
  let mut need = 0
  let mut cp = 0
  let mut cmin = 0
  if b0 >= 0xC2 && b0 <= 0xDF {
    need = 1
    cp = b0 & 0x1F
    cmin = 0x80
  } else if b0 >= 0xE0 && b0 <= 0xEF {
    need = 2
    cp = b0 & 0x0F
    cmin = 0x800
  } else if b0 >= 0xF0 && b0 <= 0xF4 {
    need = 3
    cp = b0 & 0x07
    cmin = 0x10000
  } else {
    return 0
  }
  let len = need + 1
  if i + len > n {
    return 0
  }
  for k = 1; k < len; k = k + 1 {
    let b = bs[i + k].to_int()
    if b < 0x80 || b > 0xBF {
      return 0
    }
    cp = (cp << 6) | (b & 0x3F)
  }
  if cp < cmin || cp > 0x10FFFF {
    return 0
  }
  // A three-byte sequence never encodes above U+FFFF, so a supplementary code
  // point is exactly a four-byte sequence -- the caller can count code units
  // from the length alone, with no second return value to allocate.
  if len == 4 {
    return 4
  }
  if !is_plain_str_cu(cp.to_uint16(), kind) {
    return 0
  }
  len
}

///|
/// Feed one UTF-8 byte. `idx` is the offset inside the current chunk; the
/// absolute offset is `fed_bytes + idx` (BR-22).
fn Engine::feed_byte(
  self : Engine,
  b : Int32,
  idx : Int32,
) -> Unit raise InterJSONError {
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
