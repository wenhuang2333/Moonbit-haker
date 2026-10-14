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
}

///|
/// Result of `parse`.
pub(all) struct ParseResult {
  value : Json
  repairs : Array[Repair]
  completeness : Completeness
  repairs_truncated : Bool
}

///|
/// A non-destructive view of the value parsed so far.
pub(all) struct Snapshot {
  value : Json?
  completeness : Completeness
  open_path : Array[PathSegment]
}

///|
/// Result of `PartialParser::finish`.
pub(all) struct FinalResult {
  text : String
  value : Json
  repairs : Array[Repair]
  completeness : Completeness
  repairs_truncated : Bool
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
pub fn PartialParser::snapshot(self : PartialParser) -> Snapshot {
  self.engine.snapshot()
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
