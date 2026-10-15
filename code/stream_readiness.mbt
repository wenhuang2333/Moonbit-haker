// FR-39 — readiness as an event stream instead of an offline measurement.
//
// `semantic_readiness` (FR-36) answers "when could a caller have known" by
// re-reading the document about a thousand times: one partial parse per sample
// point, then a path lookup and a schema walk per declared member. That is fine
// for an audit and hopeless for a runtime. On the 0.5.0 gate corpus it costs
// 32.7–34.3x a plain `repair` of the same bytes, and `jsonmend explain --schema`
// on a 100 KiB payload spends ~200 ms on the curve alone.
//
// The document does not have to be re-read, because the engine already emits
// exactly the evidence needed. With `collect_deltas` on, every member that
// reaches its final value produces a `Set` on that member's path, and every
// container a `Close`. A member is therefore *known* the moment its own final
// delta arrives — no waiting for the end of the document, no second look at the
// text. One pass, one delta drain per chunk, one schema check per member:
// this file turns "compute readiness" into "produce readiness events".
//
// The delta contract this relies on, read off the engine rather than assumed:
//
//   {"a":1,"b":2}        Set / ({}), Set /a 1, Set /b 2, Close / {...}
//   {"q":"MoonBit"}      Set /q "" (slot announced), AppendText, Set /q "MoonBit"
//   {"a":{}}             Set /a {} (announcement), Close /a {}
//   {"a":[1,2]}          Set /a [], Set /a/0, Set /a/1, Close /a [1,2]
//   {"a":1,"a":2}        Set /a 1, Set /a 2, Close / {a:2}   (last wins)
//   {"a":"x","a":"y"}    Set /a "", Set /a "x", Set /a "", AppendText, Set /a "y"
//   truncated anywhere   the missing values appear when `finish()` runs
//
// Three rules follow, and each one is load-bearing:
//
//   * A `Set` on exactly the member's path with a *container* value is the
//     announcement that the container opened, not its value: only `Close`
//     finalises it.
//   * A `Set` with an *empty* string is the placeholder that opens a string
//     slot. An empty final string is therefore settled at `finish()` rather
//     than mid-stream: conservative, and the alternative cannot be told apart
//     from the placeholder in the stream.
//   * A second final delta on an already-settled path is a duplicate key. It is
//     recorded as a conflict instead of silently overwriting: see
//     `SemanticWatcher::conflict`.
//
// What the batch measurement conflates, and this file separates:
//
//   * *settled* — the member's last value is known. A fact about the input,
//     independent of any declaration, and the moment a caller can stop reading
//     if it has all the members it asked for;
//   * *valid* — that value has the kind the skeleton declares.
//
// `semantic_readiness` only fires when the whole document happens to satisfy the
// skeleton, so a document that is decidable-and-invalid gets
// `schema_permille = 1000`, which reads as "not before the end" when the truth
// is "this was decided long ago, and the answer is no". A runtime must tell
// those apart: `SemanticWatcher` emits `RootInvalid` at the offset where the
// refusal became final, which is the `"limit":"ten"` case of the product story —
// an argument that can be rejected while the rest of the stream is still
// arriving, and a generation that can be cancelled instead of paid for.

///|
/// What the watcher learned while the document was arriving (FR-39).
pub(all) enum ReadinessEvent {
  /// The value at this dotted path is final and has the declared kind.
  FieldReady(String)
  /// The value at this path is final and does not have the declared kind.
  FieldInvalid(String, String)
  /// The value at this path is final and has the declared kind, but a member
  /// the skeleton requires deeper is absent or of the wrong kind. The two
  /// strings are the offending path and the kind it was declared with.
  FieldIncomplete(String, String)
  /// Every required path is final and valid: the value may be handed on.
  RootReady
  /// No required path will ever improve: the document cannot become
  /// executable, whatever the model writes next. The payload is the number of
  /// code units consumed when that became final.
  RootInvalid(Int32)
}

///|
/// Stable lowercase name of an event kind, for output and for tests.
pub fn ReadinessEvent::kind(self : ReadinessEvent) -> String {
  match self {
    FieldReady(_) => "field_ready"
    FieldInvalid(_, _) => "field_invalid"
    FieldIncomplete(_, _) => "field_incomplete"
    RootReady => "root_ready"
    RootInvalid(_) => "root_invalid"
  }
}

///|
/// Path the event is about; `""` for the root events.
pub fn ReadinessEvent::path(self : ReadinessEvent) -> String {
  match self {
    FieldReady(p) => p
    FieldInvalid(p, _) => p
    FieldIncomplete(p, _) => p
    RootReady => ""
    RootInvalid(_) => ""
  }
}

///|
/// Whether the event is a verdict rather than a progress note.
pub fn ReadinessEvent::is_verdict(self : ReadinessEvent) -> Bool {
  match self {
    FieldReady(_) | FieldInvalid(_, _) | RootReady | RootInvalid(_) => true
    FieldIncomplete(_, _) => false
  }
}

///|
/// JSON form of one event. Field names are part of the contract.
pub fn ReadinessEvent::to_json(self : ReadinessEvent) -> String {
  let k = "\"kind\":\"" + self.kind() + "\""
  match self {
    FieldReady(p) => "{" + k + ",\"path\":\"" + json_escape(p) + "\"}"
    FieldInvalid(p, e) =>
      "{" +
      k +
      ",\"path\":\"" +
      json_escape(p) +
      "\",\"expected\":\"" +
      json_escape(e) +
      "\"}"
    FieldIncomplete(p, e) =>
      "{" +
      k +
      ",\"path\":\"" +
      json_escape(p) +
      "\",\"expected\":\"" +
      json_escape(e) +
      "\"}"
    RootReady => "{" + k + ",\"path\":\"\"}"
    RootInvalid(off) =>
      "{" + k + ",\"path\":\"\",\"offset\":" + off.to_string() + "}"
  }
}

///|
/// JSON array of events.
pub fn readiness_events_json(events : Array[ReadinessEvent]) -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  for i = 0; i < events.length(); i = i + 1 {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(events[i].to_json())
  }
  sb.write_char(']')
  sb.to_string()
}

// ---------------------------------------------------------------------------
// The watcher.
// ---------------------------------------------------------------------------

///|
/// One declared path the watcher follows.
priv struct WatchedPath {
  path : String
  /// The kind declared at this path, as a name.
  expect : String
  /// The kind declared at this path.
  decl : Schema
  /// The path, split once, so that matching a delta allocates nothing.
  segs : Array[PathSegment]
}

///|
/// Streams a skeleton verdict: feed the model's chunks, drain the events
/// (FR-39).
///
/// The watcher owns its own `PartialParser` and forces `collect_deltas` on, so
/// the caller does not have to know that the mechanism is the delta stream.
/// `duplicate_keys KeepFirst` is refused (E050): a delta stream cannot retract
/// a value it already announced, and this type reads the stream.
pub struct SemanticWatcher {
  priv parser : PartialParser
  priv schema : Schema
  priv watched : Array[WatchedPath]
  /// Watched indices by their first path segment, so a delta is matched against
  /// the members it could possibly be about instead of against every member.
  /// This is what keeps a 132-member object linear rather than quadratic.
  priv index : Map[String, Array[Int32]]
  priv settled : Array[Bool]
  mut settled_count : Int32
  mut concluded : Bool
  mut conflict : Bool
  mut checked : Bool
  mut events : Array[ReadinessEvent]
  mut bytes : Int32
  /// Code units consumed when the last followed path became final, or `-1`.
  mut settled_at : Int32
  /// Code units consumed when the root value became final, or `-1`.
  mut syntax_at : Int32
}

///|
/// Build a watcher for `schema`.
///
/// Only the required paths whose declaration is *decided by their own value*
/// are followed: a required object with required members is decided by those
/// members, which are followed instead, and the whole skeleton is checked once
/// they are all in.
pub fn SemanticWatcher::new(
  schema : Schema,
  options? : Options,
) -> SemanticWatcher raise MendError {
  let base = match options {
    Some(o) => o
    None => Options::default()
  }
  let opts : Options = { ..base, collect_deltas: true, }
  opts.validate()
  let parser = PartialParser::new(options=opts)
  let watched : Array[WatchedPath] = []
  let settled : Array[Bool] = []
  let index : Map[String, Array[Int32]] = Map([])
  for p in schema.required_paths() {
    let decl = match schema.at_path(p) {
      Some(d) => d
      None => Any
    }
    if decided_by_children(decl) {
      continue
    }
    let segs = treated_segments(p)
    let head = match segs[0] {
      Key(k) => k
      Index(i) => i.to_string()
    }
    let at = match index.get(head) {
      Some(list) => list
      None => {
        let list : Array[Int32] = []
        index[head] = list
        list
      }
    }
    at.push(watched.length())
    watched.push({ path: p, expect: decl.name(), decl, segs, })
    settled.push(false)
  }
  {
    parser,
    schema,
    watched,
    index,
    settled,
    settled_count: 0,
    concluded: false,
    conflict: false,
    checked: false,
    events: [],
    bytes: 0,
    settled_at: -1,
    syntax_at: -1,
  }
}

///|
/// Whether a declaration is decided by the required members inside it rather
/// than by its own value.
fn decided_by_children(decl : Schema) -> Bool {
  match decl {
    Obj(members) => {
      for m in members {
        if m.required {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Split a dotted path into segments. A segment that names an index is an
/// `Index`, which is what `Delta::path` carries for an array slot.
fn treated_segments(path : String) -> Array[PathSegment] {
  let out : Array[PathSegment] = []
  if path == "" {
    return out
  }
  for seg in path.split(".") {
    let s = seg.to_owned()
    let idx = @string.parse_int(s) catch { _ => -1 }
    if idx >= 0 && s.length() > 0 && s.at(0).to_int() != 0x30 {
      out.push(Index(idx))
    } else {
      out.push(Key(s))
    }
  }
  out
}

///|
/// Structural equality of two path segments.
fn seg_equal(a : PathSegment, b : PathSegment) -> Bool {
  match (a, b) {
    (Key(x), Key(y)) => x == y
    (Index(x), Index(y)) => x == y
    _ => false
  }
}

///|
/// Whether a delta talks about exactly the watched path.
fn on_path(d : Delta, segs : Array[PathSegment]) -> Bool {
  if d.path.length() != segs.length() {
    return false
  }
  for i = 0; i < segs.length(); i = i + 1 {
    if !seg_equal(d.path[i], segs[i]) {
      return false
    }
  }
  true
}

///|
/// Whether a delta settles the value it talks about.
///
/// Read off the delta contract in the file header: a container `Set` announces
/// the container opening, an empty-string `Set` announces a string slot, and
/// everything else on the path is the final value.
fn delta_final(d : Delta) -> Bool {
  match d.op {
    Close => true
    Set =>
      match d.value {
        None => false
        Some(v) =>
          match v {
            Json::Array(_) | Json::Object(_) => false
            Json::String(s) => s != ""
            _ => true
          }
      }
    AppendText => false
  }
}

///|
/// Feed one chunk of the model's output.
///
/// Raises what the parser raises: a profile with `reject_ambiguous` or
/// `max_loss` set refuses a document mid-stream instead of at the end, which is
/// exactly the reason to watch rather than to measure afterwards.
pub fn SemanticWatcher::feed(
  self : SemanticWatcher,
  chunk : String,
) -> Unit raise MendError {
  self.parser.feed(chunk)
  self.bytes = self.bytes + chunk.length()
  for d in self.parser.drain_deltas() {
    self.on_delta(d)
  }
}

///|
/// Consume one delta.
fn SemanticWatcher::on_delta(self : SemanticWatcher, d : Delta) -> Unit {
  // Syntax readiness is "the moment the value stopped changing", which is the
  // moment of the last delta that touched the value tree — not the root `Close`,
  // which only re-states a value the tree already holds (a snapshot auto-closes
  // open containers, so the last member's final `Set` is enough). Keeping the
  // two apart is the point of the report: on a document whose last member is
  // long, syntax is ready one code unit before the end, and a skeleton can be
  // ready far earlier than that.
  if !(d.path.length() == 0 && d.op is Close) {
    self.syntax_at = self.bytes
  }
  let closed = delta_final(d)
  if closed && d.path.length() > 0 {
    let head = match d.path[0] {
      Key(k) => k
      Index(i) => i.to_string()
    }
    match self.index.get(head) {
      Some(cands) =>
        for i in cands {
          if !on_path(d, self.watched[i].segs) {
            continue
          }
          if self.settled[i] {
            // A duplicate key re-opened a member that was already decided. Its
            // events were true when they were emitted and cannot be taken back,
            // so the watcher stops concluding early and says so.
            self.conflict = true
          } else {
            self.settle(i)
            if self.settled_count == self.watched.length() {
              self.settled_at = self.bytes
            }
          }
        }
      None => ()
    }
  }
  if d.op is Close {
    // A closer fixes everything inside it: `Close /a` decides a missing `a.b`,
    // and the root closer decides every member of the root. Without this the
    // watcher reports `settled = 1000` — "decided at the end" — for a document
    // that simply omits a required member, when the closer decided it earlier;
    // a runtime reading `settled` would keep waiting for an answer it already
    // has. A wrong kind is decided by its own value, an absent member by the
    // closer that made it absent, and those are different offsets.
    for i = 0; i < self.watched.length(); i = i + 1 {
      if !self.settled[i] && is_prefix(d.path, self.watched[i].segs) {
        self.settle(i)
        if self.settled_count == self.watched.length() {
          self.settled_at = self.bytes
        }
      }
    }
  }
  if !self.concluded && !self.conflict && !self.checked && self.all_settled() {
    self.checked = true
    self.decide()
  }
}

///|
/// Whether `prefix` is a proper prefix of `segs`: whether the value at `segs`
/// lives inside the container at `prefix`, and is therefore fixed by the moment
/// that container closes.
fn is_prefix(prefix : Array[PathSegment], segs : Array[PathSegment]) -> Bool {
  if prefix.length() >= segs.length() {
    return false
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    if !seg_equal(prefix[i], segs[i]) {
      return false
    }
  }
  true
}

///|
/// Record that a path is final and emit its event.
fn SemanticWatcher::settle(self : SemanticWatcher, i : Int32) -> Unit {
  self.settled[i] = true
  self.settled_count = self.settled_count + 1
  let v = self.value_at(i)
  let decl = self.watched[i].decl
  if decl.accepts(v) {
    match substructure_problem(decl, v) {
      Some((p, e)) => self.events.push(FieldIncomplete(p, e))
      None => self.events.push(FieldReady(self.watched[i].path))
    }
    return
  }
  self.events.push(FieldInvalid(self.watched[i].path, self.watched[i].expect))
  self.conclude_invalid()
}

///|
/// The first declaration inside `v` that is absent or of the wrong kind, as
/// (path, expected kind). Names the real offender when a container is final but
/// not yet valid, so the message is about the member that is wrong rather than
/// about the container that holds it.
fn substructure_problem(decl : Schema, v : Json) -> (String, String)? {
  let verdict = decl.evaluate(v)
  for m in verdict.mismatched {
    return Some((m.path, m.expected))
  }
  for p in verdict.missing {
    return Some((p, "missing"))
  }
  None
}

///|
/// The whole skeleton against the current value, once every required path is
/// final.
fn SemanticWatcher::decide(self : SemanticWatcher) -> Unit {
  let verdict = self.schema.evaluate(self.value_at_root())
  if verdict.ok {
    self.concluded = true
    self.events.push(RootReady)
  } else {
    self.conclude_invalid()
  }
}

///|
/// The value as it stands: the aggregate is judged on the parser's snapshot.
fn SemanticWatcher::value_at_root(self : SemanticWatcher) -> Json {
  match self.parser.snapshot().value {
    Some(root) => root
    None => Json::object(Map([]))
  }
}

///|
/// The current value at watched path `i`.
fn SemanticWatcher::value_at(self : SemanticWatcher, i : Int32) -> Json {
  match lookup_path(self.value_at_root(), self.watched[i].path) {
    Some(x) => x
    None => Json::null()
  }
}

///|
/// Emit the refusal, once.
fn SemanticWatcher::conclude_invalid(self : SemanticWatcher) -> Unit {
  if self.concluded {
    return
  }
  self.concluded = true
  self.events.push(RootInvalid(self.bytes))
}

///|
/// Events produced since the previous drain.
pub fn SemanticWatcher::drain_events(
  self : SemanticWatcher,
) -> Array[ReadinessEvent] {
  let out = self.events
  self.events = []
  out
}

///|
/// Code units fed so far.
pub fn SemanticWatcher::bytes(self : SemanticWatcher) -> Int32 {
  self.bytes
}

///|
/// Code units consumed when the last followed path became final, or `-1` while
/// that has not happened.
pub fn SemanticWatcher::settled_at(self : SemanticWatcher) -> Int32 {
  self.settled_at
}

///|
/// Code units consumed when the root value became final, or `-1` while the
/// document still needs more input to be readable at all.
pub fn SemanticWatcher::syntax_at(self : SemanticWatcher) -> Int32 {
  self.syntax_at
}

///|
/// Whether the root verdict has been reached: `RootReady` or `RootInvalid`.
pub fn SemanticWatcher::concluded(self : SemanticWatcher) -> Bool {
  self.concluded
}

///|
/// Whether a duplicate key re-opened a member after it had been decided. The
/// events of that member were true when they were emitted; a caller that cares
/// must re-read the final document (`analyze` reports the duplicate as `R018`).
pub fn SemanticWatcher::conflict(self : SemanticWatcher) -> Bool {
  self.conflict
}

///|
/// Whether every followed path is final.
pub fn SemanticWatcher::all_settled(self : SemanticWatcher) -> Bool {
  self.settled_count == self.watched.length()
}

///|
/// Required paths that are final and hold a value of the declared kind.
pub fn SemanticWatcher::ready_count(self : SemanticWatcher) -> Int32 {
  let mut n = 0
  for i = 0; i < self.watched.length(); i = i + 1 {
    if self.settled[i] && self.watched[i].decl.accepts(self.value_at(i)) {
      n = n + 1
    }
  }
  n
}

///|
/// How many paths the watcher follows.
pub fn SemanticWatcher::total_required(self : SemanticWatcher) -> Int32 {
  self.watched.length()
}

///|
/// The paths the watcher follows, in declaration order.
pub fn SemanticWatcher::watched_paths(self : SemanticWatcher) -> Array[String] {
  let out : Array[String] = []
  for w in self.watched {
    out.push(w.path)
  }
  out
}

///|
/// The verdict of what has arrived so far, against the whole skeleton. Never
/// raises: an unfinished document is simply not `ok` yet.
pub fn SemanticWatcher::verdict(self : SemanticWatcher) -> SchemaVerdict {
  self.schema.evaluate(self.value_at_root())
}

///|
/// Close the document: drain what the model never got to and decide.
pub fn SemanticWatcher::finish(
  self : SemanticWatcher,
) -> FinalResult raise MendError {
  let fin = self.parser.finish()
  for d in self.parser.drain_deltas() {
    self.on_delta(d)
  }
  for i = 0; i < self.watched.length(); i = i + 1 {
    if !self.settled[i] {
      self.settle(i)
    }
  }
  if self.settled_at < 0 && self.all_settled() {
    self.settled_at = self.bytes
  }
  if self.syntax_at < 0 {
    self.syntax_at = self.bytes
  }
  if !self.checked && !self.conflict {
    self.checked = true
    self.decide()
  }
  if !self.concluded {
    self.conclude_invalid()
  }
  fin
}

// ---------------------------------------------------------------------------
// The one-shot form, for tests and for an offline audit of the same events.
// ---------------------------------------------------------------------------

///|
/// One event with the input fraction at which it fired.
pub(all) struct ReadinessEventAt {
  event : ReadinessEvent
  /// Per mille of the input consumed when the event fired, or `-1` when only
  /// `finish()` could produce it.
  permille : Int32
}

///|
/// Watch `input` in `chunk`-sized pieces and return every event (FR-39). The
/// events are the same the streaming API produces; this form exists so that an
/// audit can print them with a position.
pub fn watch_readiness(
  input : String,
  schema : Schema,
  chunk? : Int32,
  options? : Options,
) -> Array[ReadinessEventAt] raise MendError {
  let n = input.length()
  let size = auto_step(
    n,
    match chunk {
      Some(c) => c
      None => 0
    },
  )
  let w = SemanticWatcher::new(schema, options?)
  let out : Array[ReadinessEventAt] = []
  let mut i = 0
  while i < n {
    let next = if i + size > n { n } else { i + size }
    w.feed(input[i:next].to_owned())
    i = next
    for e in w.drain_events() {
      out.push({ event: e, permille: permille(i, n), })
    }
  }
  try {
    let _ = w.finish()
  } catch {
    _ => ()
  }
  for e in w.drain_events() {
    out.push({ event: e, permille: -1, })
  }
  out
}

///|
/// The input fraction at which `input` was decided, or `-1` when it never was
/// (FR-39).
///
/// `RootReady` and `RootInvalid` both count: what the caller needs to know is
/// that the answer is final, not that the answer is yes. `""` when the input is
/// decided only at the end.
pub fn decided_at_permille(
  input : String,
  schema : Schema,
  chunk? : Int32,
  options? : Options,
) -> Int32 raise MendError {
  let n = input.length()
  if n == 0 {
    return -1
  }
  let size = auto_step(
    n,
    match chunk {
      Some(c) => c
      None => 0
    },
  )
  let w = SemanticWatcher::new(schema, options?)
  let mut i = 0
  while i < n {
    let next = if i + size > n { n } else { i + size }
    w.feed(input[i:next].to_owned())
    i = next
    for e in w.drain_events() {
      match e {
        RootReady | RootInvalid(_) => return permille(i, n)
        _ => ()
      }
    }
  }
  try {
    let _ = w.finish()
  } catch {
    _ => ()
  }
  for e in w.drain_events() {
    match e {
      RootReady | RootInvalid(_) => return 1000
      _ => ()
    }
  }
  -1
}
