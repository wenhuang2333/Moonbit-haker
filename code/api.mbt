// M1 api — the public facade: `repair`, `parse` and `PartialParser`.
//
// The facade is the only place that turns engine state into user visible
// results, and the only place that owns the public result types.

///|
/// How complete a value is.
pub(all) enum Completeness {
  Empty
  Partial
  Complete
}

///|
/// Explicit `Eq` implementation for `Completeness`.
pub impl Eq for Completeness with fn equal(
  self : Completeness,
  other : Completeness,
) -> Bool {
  (self is Empty && other is Empty) ||
  (self is Partial && other is Partial) ||
  (self is Complete && other is Complete)
}

///|
/// Explicit `Eq` extension for `Completeness`.
pub extend Completeness with Eq::{not_equal, equal}

///|
/// One step of `Snapshot::open_path`.
pub(all) enum PathSegment {
  Key(String)
  Index(Int32)
}

///|
/// Explicit `Eq` implementation for `PathSegment`.
pub impl Eq for PathSegment with fn equal(
  self : PathSegment,
  other : PathSegment,
) -> Bool {
  match (self, other) {
    (Key(a), Key(b)) => a == b
    (Index(a), Index(b)) => a == b
    _ => false
  }
}

///|
/// Explicit `Eq` extension for `PathSegment`.
pub extend PathSegment with Eq::{not_equal, equal}

///|
/// Result of `repair`.
pub(all) struct RepairResult {
  text : String
  repairs : Array[Repair]
  completeness : Completeness
  repairs_truncated : Bool
  exactness : Exactness
  /// Whether any recorded repair admits a second reading (FR-27).
  ambiguous : Bool
}

///|
/// Result of `parse`.
pub(all) struct ParseResult {
  value : Json
  repairs : Array[Repair]
  completeness : Completeness
  repairs_truncated : Bool
  exactness : Exactness
  /// Whether any recorded repair admits a second reading (FR-27).
  ambiguous : Bool
}

///|
/// A non-destructive view of the value parsed so far.
pub(all) struct Snapshot {
  value : Json?
  completeness : Completeness
  open_path : Array[PathSegment]
  /// Exactness of everything consumed so far. A snapshot is a display channel,
  /// so this is informational; the execution channel is `finish`.
  exactness : Exactness
  /// Whether anything consumed so far was repaired ambiguously (FR-27).
  ambiguous : Bool
}

///|
/// Result of `PartialParser::finish`.
pub(all) struct FinalResult {
  text : String
  value : Json
  repairs : Array[Repair]
  completeness : Completeness
  repairs_truncated : Bool
  exactness : Exactness
  /// Whether any recorded repair admits a second reading (FR-27).
  ambiguous : Bool
}

///|
/// Operation of one `Delta` (FR-18). The names follow JSON Patch (RFC 6902)
/// where an equivalent exists; `AppendText` has no RFC 6902 counterpart.
pub(all) enum DeltaOp {
  /// The value at `path` was created or replaced; `value` is its content.
  Set
  /// `text` was appended to the string at `path`.
  AppendText
  /// The container at `path` is complete; `value` is its final content. A
  /// later `Set` on the same path is still legal: `duplicate_keys KeepLast`
  /// overwrites a member after its container was closed.
  Close
}

///|
/// One incremental change to the value built so far.
pub(all) struct Delta {
  /// JSON Pointer style path (RFC 6901): `Key` segments are object members,
  /// `Index` segments are array positions, the root is the empty path.
  path : Array[PathSegment]
  op : DeltaOp
  value : Json?
  text : String
}

///|
/// `DeltaOp` as a stable lowercase word, e.g. `append_text`.
pub fn DeltaOp::name(self : DeltaOp) -> String {
  match self {
    Set => "set"
    AppendText => "append_text"
    Close => "close"
  }
}

///|
/// Explicit `Eq` implementation for `DeltaOp`.
pub impl Eq for DeltaOp with fn equal(self : DeltaOp, other : DeltaOp) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `DeltaOp`.
pub extend DeltaOp with Eq::{not_equal, equal}

///|
/// Render a path as an RFC 6901 JSON Pointer, e.g. `/items/0/name`.
pub fn Delta::pointer(self : Delta) -> String {
  let sb = StringBuilder()
  for seg in self.path {
    sb.write_char('/')
    match seg {
      Key(k) =>
        sb.write_string(
          k.replace_all(old="~", new="~0").replace_all(old="/", new="~1"),
        )
      Index(i) => sb.write_string(i.to_string())
    }
  }
  sb.to_string()
}

///|
/// Streaming partial parser. `feed` any number of chunks, then `finish`; the
/// one-shot functions are built on exactly this type.
pub struct PartialParser {
  priv engine : Engine
}

///|
/// Create a parser. Invalid options raise `E050`.
pub fn PartialParser::new(options? : Options) -> PartialParser raise MendError {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  opts.validate()
  { engine: Engine::make(opts), }
}

///|
/// Feed one chunk. A chunk may split any token, including a surrogate pair.
pub fn PartialParser::feed(
  self : PartialParser,
  chunk : String,
) -> Unit raise MendError {
  errdefer {
    self.engine.phase = PFailed
  }
  self.engine.feed_str(chunk)
}

///|
/// Feed raw UTF-8 bytes. Invalid or truncated UTF-8 raises `E040`.
pub fn PartialParser::feed_bytes(
  self : PartialParser,
  bytes : Bytes,
) -> Unit raise MendError {
  errdefer {
    self.engine.phase = PFailed
  }
  self.engine.feed_bytes(bytes)
}

///|
/// Snapshot the value parsed so far. Never raises, never mutates the parser.
///
/// The returned value may share structure with the parser's cache, so it must
/// be treated as immutable; use `snapshot_copy` when the caller needs to
/// mutate it (FR-13).
pub fn PartialParser::snapshot(self : PartialParser) -> Snapshot {
  self.engine.snapshot()
}

///|
/// A deep copy of the snapshot: safe to mutate without disturbing the parser
/// or any earlier snapshot (FR-13).
pub fn PartialParser::snapshot_copy(self : PartialParser) -> Snapshot {
  let s = self.engine.snapshot()
  {
    value: match s.value {
      Some(v) => Some(copy_json(v))
      None => None
    },
    completeness: s.completeness,
    open_path: s.open_path.copy(),
    exactness: s.exactness,
    ambiguous: s.ambiguous,
  }
}

///|
/// Deep copy of a `Json` value.
pub fn copy_json(v : Json) -> Json {
  match v {
    Json::Array(items) => Json::array(items.map(copy_json))
    Json::Object(map) => {
      let out : Map[String, Json] = Map([])
      for k, item in map {
        out[k] = copy_json(item)
      }
      Json::object(out)
    }
    _ => v
  }
}

///|
/// Take the deltas recorded since the previous call (FR-18).
///
/// Requires `Options::for_llm()` (or any options with `collect_deltas: true`);
/// otherwise this raises `E050`. Applying the returned operations in order to
/// the value obtained from the previous drain yields the current
/// `snapshot().value`.

///|
/// FR-16, the event interface, as a thin wrapper over `drain_deltas`.
///
/// `on_delta` is called once per change, in the order `drain_deltas` would
/// return them, immediately after the change happened. This is deliberately not
/// a separate engine: it is the same log, consumed as it is produced, because
/// the callback is what a caller integrating with an event loop needs and a
/// second implementation would be a second place for the two to diverge.
///
/// The callback runs while the parser is inside `feed`, so it must not feed the
/// parser again; callbacks that need to do so should collect the deltas and act
/// after `feed` returns.
pub fn PartialParser::feed_with(
  self : PartialParser,
  chunk : String,
  on_delta : (Delta) -> Unit,
) -> Unit raise MendError {
  self.feed(chunk)
  for d in self.drain_deltas() {
    on_delta(d)
  }
}

///|
/// The same, for byte input (FR-12, FR-16).
pub fn PartialParser::feed_bytes_with(
  self : PartialParser,
  bytes : Bytes,
  on_delta : (Delta) -> Unit,
) -> Unit raise MendError {
  self.feed_bytes(bytes)
  for d in self.drain_deltas() {
    on_delta(d)
  }
}

///|
/// `drain_deltas` on the parser that the stream produced, keeping the existing
/// documentation in one place.
pub fn PartialParser::drain_deltas(
  self : PartialParser,
) -> Array[Delta] raise MendError {
  if !self.engine.opts.collect_deltas {
    raise InvalidOption(
      "drain_deltas requires collect_deltas: use Options::for_llm()",
    )
  }
  self.engine.drain_deltas()
}

///|
/// Finish parsing: close open containers, produce the repaired text and the
/// value. Calling it twice, or after a fatal error, raises `E030`.
pub fn PartialParser::finish(
  self : PartialParser,
) -> FinalResult raise MendError {
  errdefer {
    self.engine.phase = PFailed
  }
  self.engine.finish_engine()
}

///|
/// Repair `input` in one shot. Returns the repaired text, the repair records
/// and `Complete`.
pub fn repair(
  input : String,
  options? : Options,
) -> RepairResult raise MendError {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  opts.validate()
  let engine = Engine::make(opts)
  engine.feed_str(input)
  let fin = engine.finish_engine()
  {
    text: fin.text,
    repairs: fin.repairs,
    completeness: fin.completeness,
    repairs_truncated: fin.repairs_truncated,
    exactness: fin.exactness,
    ambiguous: fin.ambiguous,
  }
}

///|
/// Repair `input` and return the resulting `Json` value.
pub fn parse(input : String, options? : Options) -> ParseResult raise MendError {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  opts.validate()
  let engine = Engine::make(opts)
  engine.feed_str(input)
  let fin = engine.finish_engine()
  {
    value: fin.value,
    repairs: fin.repairs,
    completeness: fin.completeness,
    repairs_truncated: fin.repairs_truncated,
    exactness: fin.exactness,
    ambiguous: fin.ambiguous,
  }
}

///|
/// Whether `text` is valid JSON according to the strict core parser. This is
/// the validation used by the test suite to prove that every repaired output
/// is legal JSON; it performs no repair of its own.
pub fn is_valid_json(text : String) -> Bool {
  try {
    ignore(@json.parse(text))
    true
  } catch {
    _ => false
  }
}
