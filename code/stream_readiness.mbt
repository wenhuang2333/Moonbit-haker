// FR-39 — readiness as an event stream instead of an offline measurement.
//
// `semantic_readiness` (FR-36) answers "when could a caller have known" by
// re-reading the document about a thousand times: one partial parse per sample
// point, then a path lookup and a schema walk per declared member. That is fine
// for an audit and hopeless for a runtime. On the 0.5.0 gate corpus it costs
// 32.7–34.3x a plain `repair` of the same bytes, and `interjson explain --schema`
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
//   * *valid* — that value has the kind the skeleton declares;
//   * *acceptable* — that value also satisfies the declared value constraints
//     (`integer(minimum:0)`, `string(maxLength:64)`, `enum`, `pattern`, …;
//     0.7.0).
//
// `semantic_readiness` only fires when the whole document happens to satisfy the
// skeleton, so a document that is decidable-and-invalid gets
// `schema_permille = 1000`, which reads as "not before the end" when the truth
// is "this was decided long ago, and the answer is no". A runtime must tell
// those apart: `SemanticWatcher` emits `RootInvalid` at the offset where the
// refusal became final, which is the `"limit":"ten"` case of the product story —
// an argument that can be rejected while the rest of the stream is still
// arriving, and a generation that can be cancelled instead of paid for.
//
// 0.7.0 extends the same mechanism from the *kind* of a value to its *value*.
// A constraint is checked on the delta that makes the value final, so
// `{"limit":-1, "tail":"…"}` against `{!limit:integer(minimum:0)}` is refused at
// the digit `1`, not at the closing brace:
//
//   * the refusal is published as `FieldRejected` (path, expected, got) — a
//     verdict, so a caller that only reads verdicts sees it, and a caller that
//     wants to tell "wrong kind" from "wrong value" sees which one it was;
// ## Positions come from the deltas (Q-35)
//
// `Delta.at` is the input offset a delta was produced at, in UTF-16 code units,
// and it is independent of how the caller split the stream. Every position this
// module reports — `syntax_at`, `settled_at`, the stamp `watch_readiness` puts on
// each event, the fraction `decided_at_permille` returns, and the payload of
// `RootInvalid` — is read from it rather than from the number of code units fed
// so far. The latter is the end of the current chunk and therefore moved with the
// caller's chunking: a 1000-code-unit chunk reported the same "decided here" for
// an event that fired one code unit into it as for one that fired at its end.
// The fractions are now exact, which is why `semantic_readiness` feeds the
// document once instead of sampling it about a thousand times.
//
//   * `RootInvalid(offset)` is published at the same offset as before, so
//     `decided_at_permille` returns the fraction of the input at which the
//     refusal became final;
//   * `settled_permille` is the same number it always was — the fraction at
//     which every followed path was final — and it is now reachable *because*
//     of the refusal, since a rejected value settles at its own last delta.
//
// The contract, in one sentence: **the three readiness numbers keep their
// meaning (when the input stopped changing, when every declared member was
// final, when the skeleton was satisfied), and every refusal that a constraint
// makes possible is already known when the value is final.** No existing number
// is redefined, and no existing event changes meaning; `FieldRejected` is an
// addition.

///|
/// What the watcher learned while the document was arriving (FR-39).
pub(all) enum ReadinessEvent {
  /// The value at this dotted path is final and has the declared kind.
  FieldReady(String)
  /// The value at this path is final and does not have the declared kind.
  FieldInvalid(String, String)
  /// The value at this path is final and has the declared kind, but violates a
  /// declared value constraint (0.7.0). The three strings are the offending
  /// path, the constraint as it was written (`integer >= 0`,
  /// `string with length <= 64`, `one of ["low","high"]`,
  /// `string of characters in [a-z]`), and the kind of the value that arrived.
  /// The value is refused at the delta that made it final, so this event is
  /// always emitted together with a `RootInvalid` at the same offset.
  FieldRejected(String, String, String)
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
    FieldRejected(_, _, _) => "field_rejected"
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
    FieldRejected(p, _, _) => p
    FieldIncomplete(p, _) => p
    RootReady => ""
    RootInvalid(_) => ""
  }
}

///|
/// Whether the event is a verdict rather than a progress note.
pub fn ReadinessEvent::is_verdict(self : ReadinessEvent) -> Bool {
  match self {
    FieldReady(_)
    | FieldInvalid(_, _)
    | FieldRejected(_, _, _)
    | RootReady
    | RootInvalid(_) => true
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
    FieldRejected(p, e, got) =>
      "{" +
      k +
      ",\"path\":\"" +
      json_escape(p) +
      "\",\"expected\":\"" +
      json_escape(e) +
      "\",\"got\":\"" +
      json_escape(got) +
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
  /// The declaration as it was written: `integer` for a bare kind,
  /// `integer(minimum:0)` when constraints were declared (0.7.0).
  expect : String
  /// The declared kind and its constraints.
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
///
/// ## Duplicate keys: a documented composition, not a refusal (0.7.0, Q-36)
///
/// `duplicate_keys KeepFirst` is rewritten to `KeepLast` **for the measurement**
/// and nothing else changes. The reason is structural: the watcher reads the
/// delta stream, and a delta stream cannot represent a value that was dropped —
/// `KeepFirst` drops the later value of a repeated name, but its container was
/// already announced, so there is no delta to carry the drop. Before 0.7.0 this
/// pair was refused with `E050`.
///
/// What that means, stated plainly:
///
///   * *which duplicate wins*: observations are made under `KeepLast`, so a
///     value that was dropped is never invented. Which value a followed path is
///     judged against is the value the tree holds **when the delta is drained**,
///     and that is the whole subtlety: fed incrementally (the normal case, and
///     what the batch helpers do) the first value of a repeated name is judged
///     as soon as it is final, and the later duplicate arrives as `conflict()`
///     rather than as a retraction; fed as one chunk, every delta is drained
///     after the tree is complete, so the path is judged against the last value.
///     `verdict()` after `finish()` is the `KeepLast` verdict either way, i.e.
///     `Schema::evaluate(parse(input).value)` under the rewritten options. A
///     caller who asked for `KeepFirst` must take the verdict from
///     `parse(input, options=requested)` instead; `schema.mbt`'s
///     `semantic_readiness` does that, which is why its `verdict` is the
///     `KeepFirst` truth while its three numbers come from this stream.
///   * *when the watcher may still conclude early*: the first value of a
///     repeated name is announced as soon as it is final, so an early
///     `RootReady` can be published on a document that only satisfies the
///     skeleton under `KeepFirst`. A later value of the same name does not
///     retract it: the watcher sets `conflict()` and stops concluding, because
///     an event that was already emitted cannot be taken back. That early
///     `RootReady` is *true* under `KeepFirst` and provisional under `KeepLast`;
///     `conflict()` is how the caller learns which case they are in.
///   * *what does not change*: the type never emits a wrong event; a duplicate
///     whose second value differs from the first is visible as `conflict()`,
///     and callers who need "no duplicates at all" want `AsError` (which the
///     parser raises on), not a readiness measurement.
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
  /// The offset each queued event fired at, in the same unit as `Delta.at`:
  /// `-1` for an event only `finish()` could produce. Kept beside `events` so a
  /// timeline can be built without re-deriving the position from how the caller
  /// happened to split the stream (Q-35).
  mut events_at : Array[Int32]
  /// `Delta.at` of the delta being processed right now, or `-1` outside one.
  mut cur_at : Int32
  /// Whether the deltas being processed were produced by `finish()`.
  mut in_finish : Bool
  /// The offset at which the root verdict became final, or `-1` while it has
  /// not been reached. `settled_at` is the moment every followed path was
  /// final; this is the moment the *answer* was (they differ when the skeleton
  /// turns out unsatisfied, and when nothing needed following).
  mut verdict_at : Int32
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
) -> SemanticWatcher raise InterJSONError {
  let base = match options {
    Some(o) => o
    None => Options::default()
  }
  // `KeepFirst` drops a value whose container was already announced, which the
  // delta stream cannot express, so the measurement is taken under `KeepLast`
  // (Q-36: a composition, documented on the type). The caller's verdict is
  // theirs to take from `parse(input, options=…)`; `semantic_readiness` does.
  let opts : Options = {
    ..base,
    collect_deltas: true,
    duplicate_keys: match base.duplicate_keys {
      KeepFirst => KeepLast
      other => other
    },
  }
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
    watched.push({ path: p, expect: decl.expectation(), decl, segs, })
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
    events_at: [],
    cur_at: -1,
    in_finish: false,
    verdict_at: -1,
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
) -> Unit raise InterJSONError {
  self.parser.feed(chunk)
  self.bytes = self.bytes + chunk.length()
  for d in self.parser.drain_deltas() {
    self.on_delta(d)
  }
}

///|
/// Queue one event, stamped with the position it fired at.
///
/// The stamp is the `at` of the delta that produced it (`-1` for an event that
/// only `finish()` could produce), which is the whole point of Q-35: the
/// timeline is a property of the input, not of the caller's chunking.
fn SemanticWatcher::emit(self : SemanticWatcher, e : ReadinessEvent) -> Unit {
  self.events.push(e)
  self.events_at.push(self.cur_at)
}

///|
/// Consume one delta.
fn SemanticWatcher::on_delta(self : SemanticWatcher, d : Delta) -> Unit {
  // `Delta.at` is the input offset the delta was produced at, and it does not
  // depend on how the caller split the stream (`api.mbt`). Positions are taken
  // from it rather than from `self.bytes`, which is the *end of the chunk* and
  // therefore moves with the chunking (Q-35). An event produced by the
  // `finish()` drain is stamped `-1`: the document was not yet final when the
  // input ran out, so it has no position in the timeline.
  self.cur_at = if self.in_finish { -1 } else { d.at }
  // Syntax readiness is "the moment the value stopped changing", which is the
  // moment of the last delta that touched the value tree — not the root `Close`,
  // which only re-states a value the tree already holds (a snapshot auto-closes
  // open containers, so the last member's final `Set` is enough). Keeping the
  // two apart is the point of the report: on a document whose last member is
  // long, syntax is ready one code unit before the end, and a skeleton can be
  // ready far earlier than that.
  //
  // `AppendText` is skipped: its `at` is the *drain* point, not the text's
  // position (`api.mbt`), and text does not itself change the value tree — the
  // `Set` for the member it belongs to does. Reading a position off it would
  // reintroduce the chunk dependence this replaces.
  if !(d.path.length() == 0 && d.op is Close) {
    match d.op {
      AppendText => ()
      _ => if self.syntax_at < d.at { self.syntax_at = d.at }
    }
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
              self.settled_at = d.at
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
          self.settled_at = d.at
        }
      }
    }
  }
  // A verdict may only be published once it is final. When every required path
  // is watched, all of them being settled is that moment. When there is nothing
  // to watch — an array root such as `[{!a:integer}]` has no object member
  // paths, and a skeleton whose members are all decided by their own children
  // is skipped — the value tree is still open, and `evaluate` on a half-read
  // array would report the skeleton satisfied. Those wait for the root closer.
  let root_closed = d.path.length() == 0 && d.op is Close
  if !self.concluded &&
    !self.conflict &&
    !self.checked &&
    self.all_settled() &&
    (self.watched.length() > 0 || root_closed) {
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
///
/// This is also where a value-level declaration is enforced: `accepts` folds in
/// the declared constraints (0.7.0), so an out-of-range number is refused on
/// the delta that makes it final, and the refusal is named precisely — the
/// violated constraint rather than the kind it happens to share.
fn SemanticWatcher::settle(self : SemanticWatcher, i : Int32) -> Unit {
  self.settled[i] = true
  self.settled_count = self.settled_count + 1
  let v = self.value_at(i)
  let decl = self.watched[i].decl
  if decl.accepts(v) {
    match substructure_problem(decl, v) {
      Some((p, e)) => self.emit(FieldIncomplete(p, e))
      None => self.emit(FieldReady(self.watched[i].path))
    }
    return
  }
  match decl.constraint_problem(v) {
    Some(e) => self.emit(FieldRejected(self.watched[i].path, e, kind_of(v)))
    None =>
      self.emit(FieldInvalid(self.watched[i].path, self.watched[i].expect))
  }
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
    self.verdict_at = self.offset_now()
    self.emit(RootReady)
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
  self.verdict_at = self.offset_now()
  // The payload is a position even when the timeline stamp is `-1`: an event
  // produced by the `finish()` drain is at the end of the input, and saying so
  // is more useful than naming no offset at all.
  self.emit(RootInvalid(self.offset_now()))
}

///|
/// The offset an event produced outside a structural delta belongs to: the
/// current delta's `at`, or the end of the fed input when there is none.
fn SemanticWatcher::offset_now(self : SemanticWatcher) -> Int32 {
  if self.cur_at >= 0 {
    self.cur_at
  } else {
    self.bytes
  }
}

///|
/// Events produced since the previous drain.
pub fn SemanticWatcher::drain_events(
  self : SemanticWatcher,
) -> Array[ReadinessEvent] {
  let out = self.events
  self.events = []
  self.events_at = []
  out
}

///|
/// The offset the root verdict was reached at, or `-1` while it has not been
/// reached. The event list's stamp for a `RootReady`/`RootInvalid` is the same
/// number; this exists so `decided_at_permille` does not have to build the list.
fn SemanticWatcher::verdict_offset(self : SemanticWatcher) -> Int32 {
  self.verdict_at
}

///|
/// The queued events with the input offset each fired at, oldest first. `-1` is
/// an event that only `finish()` could produce. Both arrays are cleared.
///
/// The offset is the `at` of the delta that produced the event, so it does not
/// depend on how the caller split the stream. A streaming integration that
/// wants to act the moment a field became final reads this instead of
/// `drain_events`, which drops the position.
pub fn SemanticWatcher::drain_events_at(
  self : SemanticWatcher,
) -> Array[(ReadinessEvent, Int32)] {
  let out : Array[(ReadinessEvent, Int32)] = []
  for i = 0; i < self.events.length(); i = i + 1 {
    out.push((self.events[i], self.events_at[i]))
  }
  self.events = []
  self.events_at = []
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
///
/// The `at` of the delta that made the last path final: a property of the
/// input, not of the chunking (Q-35). When only `finish()` can make a path
/// final — a member the input never wrote — this is the total length.
pub fn SemanticWatcher::settled_at(self : SemanticWatcher) -> Int32 {
  self.settled_at
}

///|
/// Code units consumed when the root value became final, or `-1` while the
/// document still needs more input to be readable at all.
///
/// This is the `at` of the last structural delta that touched the value tree
/// (`Set`/`Close`, the root `Close` excluded), so it is the same number however
/// the caller split the stream — it used to be the end of the chunk the delta
/// was drained in, which moved with the chunking (Q-35). `AppendText` carries
/// the *drain* point rather than a position and does not move the tree, so it
/// does not advance this.
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
) -> FinalResult raise InterJSONError {
  let fin = self.parser.finish()
  // Deltas the input never produced: they close what the model left open. Their
  // positions are still the deltas' `at` (the total length, per `api.mbt`), but
  // an *event* they produce is not something the stream could have shown, so it
  // is stamped `-1`.
  self.in_finish = true
  for d in self.parser.drain_deltas() {
    self.on_delta(d)
  }
  self.in_finish = false
  self.cur_at = -1
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
///
/// The position is the `at` of the delta that produced the event, so the
/// timeline does not depend on the chunk size (Q-35): `chunk=1` and one whole
/// document produce the same permille for the same event. An event only
/// `finish()` could produce carries `-1`, as before. `chunk` now controls the
/// memory the feed loop holds, not the resolution of the answer.
pub fn watch_readiness(
  input : String,
  schema : Schema,
  chunk? : Int32,
  options? : Options,
) -> Array[ReadinessEventAt] raise InterJSONError {
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
    for pair in w.drain_events_at() {
      let (e, at) = pair
      // While the input is being fed every event was produced inside a delta,
      // so its offset is real; only the `finish()` drain below can produce one
      // that has no position.
      out.push({ event: e, permille: permille(at, n), })
    }
  }
  try {
    let _ = w.finish()
  } catch {
    _ => ()
  }
  for pair in w.drain_events_at() {
    let (e, at) = pair
    out.push({ event: e, permille: if at < 0 { -1 } else { permille(at, n) }, })
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
///
/// The fraction is the verdict event's own offset, not the end of the chunk it
/// was drained in (Q-35), so the answer no longer depends on `chunk`: the
/// parameter now only controls how finely the input is fed and the loop still
/// stops as soon as the answer is known.
pub fn decided_at_permille(
  input : String,
  schema : Schema,
  chunk? : Int32,
  options? : Options,
) -> Int32 raise InterJSONError {
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
    if w.concluded() {
      // The answer arrived at the delta that produced it, not at the end of the
      // chunk it happened to be drained in (Q-35). The offset is read from the
      // watcher rather than from the event list, so the hot loop allocates
      // nothing per chunk. A verdict reached while the input is still being fed
      // was always reached inside a delta, so its offset is real.
      return permille(w.verdict_offset(), n)
    }
    // Keep the queue bounded: the events themselves are not needed here.
    let _ = w.drain_events()
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
