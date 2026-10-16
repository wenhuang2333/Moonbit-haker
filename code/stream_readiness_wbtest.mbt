// FR-39 — readiness as an event stream (0.6.0 "Streaming Semantic Safety").
//
// `semantic_readiness` answers "when could a caller have known" as a fraction
// of the input. `SemanticWatcher` answers the same question as events, at the
// moment they happen, which is the form a runtime needs: a member is ready as
// soon as its own final delta arrives, long before the document that contains
// it ends. Every test below feeds code unit by code unit and asserts *when* the
// event fires, not just that it fires — the offset is half of the contract.

///|
/// One event with the code units consumed when it arrived; `-1` when only
/// `finish()` could produce it.
struct SrEvent {
  bytes : Int32
  event : ReadinessEvent
}

///|
/// `kind:path` of every event, joined with `,` — the order is the assertion.
fn sr_names_of(events : Array[ReadinessEvent]) -> String {
  let sb = StringBuilder()
  for i = 0; i < events.length(); i = i + 1 {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(events[i].kind())
    sb.write_char(':')
    sb.write_string(events[i].path())
  }
  sb.to_string()
}

///|
/// `sr_names_of` over the timed form.
fn sr_names(events : Array[SrEvent]) -> String {
  let raw : Array[ReadinessEvent] = []
  for e in events {
    raw.push(e.event)
  }
  sr_names_of(raw)
}

///|
/// Feed `text` one code unit at a time and collect every event. `None` when a
/// chunk or `finish` raises.
fn sr_feed_one_by_one(text : String, schema : Schema) -> Array[SrEvent]? {
  let w = SemanticWatcher::new(schema) catch { _ => return None }
  let out : Array[SrEvent] = []
  for i = 0; i < text.length(); i = i + 1 {
    w.feed(text[i:i + 1].to_owned()) catch {
      _ => return None
    }
    for e in w.drain_events() {
      out.push({ bytes: i + 1, event: e, })
    }
  }
  let _ = w.finish() catch { _ => return None }
  for e in w.drain_events() {
    out.push({ bytes: -1, event: e, })
  }
  Some(out)
}

///|
/// The same, for a caller that only wants the sequence of names.
fn sr_name_sequence(text : String, schema : Schema, chunk : Int32) -> String? {
  let w = SemanticWatcher::new(schema) catch { _ => return None }
  let raw : Array[ReadinessEvent] = []
  let mut i = 0
  while i < text.length() {
    let to = if i + chunk > text.length() { text.length() } else { i + chunk }
    w.feed(text[i:to].to_owned()) catch {
      _ => return None
    }
    i = to
    for e in w.drain_events() {
      raw.push(e)
    }
  }
  let _ = w.finish() catch { _ => return None }
  for e in w.drain_events() {
    raw.push(e)
  }
  Some(sr_names_of(raw))
}

///|
/// Feed `text` in `chunk`-sized pieces, drain, finish.
fn sr_watch(text : String, schema : Schema, chunk : Int32) -> SemanticWatcher? {
  let w = SemanticWatcher::new(schema) catch { _ => return None }
  let mut i = 0
  while i < text.length() {
    let to = if i + chunk > text.length() { text.length() } else { i + chunk }
    w.feed(text[i:to].to_owned()) catch {
      _ => return None
    }
    i = to
    let _ = w.drain_events()
  }
  let _ = w.finish() catch { _ => return None }
  Some(w)
}

///|
/// `sr_watch` with explicit options.
fn sr_watch_opts(
  text : String,
  schema : Schema,
  chunk : Int32,
  options : Options,
) -> SemanticWatcher? {
  let w = SemanticWatcher::new(schema, options~) catch { _ => return None }
  let mut i = 0
  while i < text.length() {
    let to = if i + chunk > text.length() { text.length() } else { i + chunk }
    w.feed(text[i:to].to_owned()) catch {
      _ => return None
    }
    i = to
    let _ = w.drain_events()
  }
  let _ = w.finish() catch { _ => return None }
  Some(w)
}

///|
/// How many events have kind `kind`.
fn sr_count(events : Array[SrEvent], kind : String) -> Int32 {
  let mut n = 0
  for e in events {
    if e.event.kind() == kind {
      n = n + 1
    }
  }
  n
}

///|
/// Code units consumed when the first event of kind `kind` arrived, or `-1`.
fn sr_at(events : Array[SrEvent], kind : String) -> Int32 {
  for e in events {
    if e.event.kind() == kind {
      return e.bytes
    }
  }
  -1
}

///|
/// Offset carried by `RootInvalid`, or `-1`.
fn sr_root_offset(events : Array[SrEvent]) -> Int32 {
  for e in events {
    match e.event {
      RootInvalid(off) => return off
      _ => ()
    }
  }
  -1
}

///|
/// `Schema::parse` or `Any`, so a test can assert on the string form.
fn sr_schema(decl : String) -> Schema {
  Schema::parse(decl) catch {
    _ => Any
  }
}

///|
/// Permille of the first event of kind `kind`, or `-1`.
fn sr_event_permille(events : Array[ReadinessEventAt], kind : String) -> Int32 {
  for e in events {
    if e.event.kind() == kind {
      return e.permille
    }
  }
  -1
}

///|
/// Permille of the last settle event (`field_ready` / `field_invalid` /
/// `field_rejected`), or `-1` when only `finish()` settled a path.
fn sr_last_settle(events : Array[ReadinessEventAt]) -> Int32 {
  let mut last = -1
  for e in events {
    match e.event {
      FieldReady(_) | FieldInvalid(_, _) | FieldRejected(_, _, _) =>
        last = e.permille
      _ => ()
    }
  }
  last
}

///|
/// The `(expected, got)` of the first `field_rejected` event, or `None`.
fn sr_rejected(events : Array[SrEvent]) -> (String, String)? {
  for e in events {
    match e.event {
      FieldRejected(_, want, got) => return Some((want, got))
      _ => ()
    }
  }
  None
}

// ---------------------------------------------------------------------------
// When a member becomes final.
// ---------------------------------------------------------------------------

///|
test "the first member is ready while the document is still arriving" {
  let text = "{\"a\":1,\"b\":2}"
  let s = sr_schema("{!a:integer,!b:integer}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a,field_ready:b,root_ready:")
  // `a` is final the moment the `,` after it settles the number, i.e. after
  // `{"a":1,` — half the document, with six code units still to arrive. That
  // gap is the whole point of watching instead of measuring afterwards.
  assert_true(evs[0].event is FieldReady(_), msg="first event is a field_ready")
  assert_eq(evs[0].event.path(), "a")
  assert_true(evs[0].bytes > 0, msg=evs[0].bytes.to_string())
  assert_true(
    evs[0].bytes < text.length(),
    msg="a fired with bytes left: " +
      evs[0].bytes.to_string() +
      "/" +
      text.length().to_string(),
  )
  // `b` is the last member, so it settles only when the root closes.
  assert_eq(sr_at(evs, "root_ready"), text.length())
}

///|
test "a string member is ready exactly once" {
  let text = "{\"q\":\"MoonBit\"}"
  let s = sr_schema("{!q:string}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  // The stream carries three deltas on `q` — the `Set ""` that opens the slot,
  // the `AppendText` growth and the final `Set` — and only the last one is the
  // value. One event, not one per delta.
  assert_eq(sr_names(evs), "field_ready:q,root_ready:")
  assert_eq(sr_count(evs, "field_ready"), 1)
}

///|
test "a container is ready when it closes, not when it opens" {
  let s = sr_schema("{!a:any}")
  for text in ["{\"a\":{}}", "{\"a\":[1,2]}"] {
    let evs = match sr_feed_one_by_one(text, s) {
      Some(e) => e
      None =>
        return assert_true(false, msg="byte-wise stream failed for " + text)
    }
    assert_eq(text + " " + sr_names(evs), text + " field_ready:a,root_ready:")
  }
  // The opening `Set` announces a container; only `Close` finalises it. Feed up
  // to and including the opening brace and nothing may fire.
  let w = SemanticWatcher::new(s) catch {
    _ => return assert_true(false, msg="watcher did not build")
  }
  w.feed("{\"a\":{") catch {
    _ => return assert_true(false, msg="feed failed")
  }
  assert_eq(w.drain_events().length(), 0)
  w.feed("}}") catch {
    _ => return assert_true(false, msg="feed failed")
  }
  assert_eq(sr_names_of(w.drain_events()), "field_ready:a,root_ready:")
  // Same for an array: the elements settle, `a` does not.
  let v = SemanticWatcher::new(s) catch { _ => return assert_true(false) }
  v.feed("{\"a\":[1,2") catch {
    _ => return assert_true(false)
  }
  assert_eq(v.drain_events().length(), 0)
  v.feed("]}") catch {
    _ => return assert_true(false)
  }
  assert_eq(sr_names_of(v.drain_events()), "field_ready:a,root_ready:")
}

// ---------------------------------------------------------------------------
// Duplicate keys, refusal offsets, absence.
// ---------------------------------------------------------------------------

///|
test "a repeated member cannot retract what the watcher published" {
  // One required member: `a` settles on its first value and the root is
  // decided from that snapshot, so `RootReady` *is* published before the
  // duplicate arrives. It cannot be taken back, which is why the watcher
  // reports the conflict and the contract is "consult `conflict()`".
  let s = sr_schema("{!a:integer}")
  let evs = match sr_feed_one_by_one("{\"a\":1,\"a\":2}", s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a,root_ready:")
  let w = match sr_watch("{\"a\":1,\"a\":2}", s, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.conflict(), true)
  assert_eq(w.concluded(), true)
  // The snapshot the watcher decided from still satisfies the skeleton, which
  // is exactly why the flag exists: a caller that acts on `RootReady` must
  // re-read the finished document (`analyze` reports the duplicate as `R018`).
  assert_eq(w.verdict().ok, true)
  // The stronger form: a second required member still unsettled means the root
  // is never decided from the stale snapshot, and `finish()` must refuse.
  let t = sr_schema("{!a:integer,!b:integer}")
  let evs2 = match sr_feed_one_by_one("{\"a\":1,\"a\":2,\"b\":3}", t) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs2), "field_ready:a,field_ready:b,root_invalid:")
  assert_eq(sr_count(evs2, "root_ready"), 0)
  assert_eq(sr_at(evs2, "root_invalid"), -1)
  let w2 = match sr_watch("{\"a\":1,\"a\":2,\"b\":3}", t, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w2.conflict(), true)
  assert_eq(w2.concluded(), true)
}

///|
test "a string duplicate is a conflict too" {
  let s = sr_schema("{!a:string}")
  let w = match sr_watch("{\"a\":\"x\",\"a\":\"y\"}", s, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.conflict(), true)
  // The events were emitted for the first value and are not repeated for the
  // second: a conflict is a flag, not a second verdict.
  let evs = match sr_feed_one_by_one("{\"a\":\"x\",\"a\":\"y\"}", s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a,root_ready:")
}

///|
test "an invalid but settled document is refused far below its length" {
  // The product story: the second argument is already typed wrong while the
  // model is still writing a long field nobody asked for. Waiting for the end
  // would pay for the whole generation.
  let text = "{\"limit\":\"ten\",\"note\":\"" + "x".repeat(200) + "\"}"
  let s = sr_schema("{!limit:integer}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_invalid:limit,root_invalid:")
  let off = sr_root_offset(evs)
  assert_true(off > 0, msg=off.to_string())
  assert_true(
    off * 2 < text.length(),
    msg="offset " + off.to_string() + " of " + text.length().to_string(),
  )
  // The same moment as a fraction of the input.
  let decided = decided_at_permille(text, s, chunk=1) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_true(decided > 0 && decided < 500, msg=decided.to_string())
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(r.verdict.ok, false)
  // `schema_permille` answers "may I execute" and never fires on a document
  // that is invalid; `settled_permille` answers "do I know yet" and does.
  assert_eq(r.schema_permille, 1000)
  assert_eq(r.settled_permille, decided)
  assert_true(r.settled_permille < 500, msg=r.settled_permille.to_string())
}

///|
test "an absent member is settled by the closer of the object that holds it" {
  // A member that never arrives inside a container is settled by that
  // container's own closer: once `a` is closed, no further input can add `a.c`,
  // so the refusal is final there and the `pad` behind it is not paid for.
  let text = "{\"a\":{\"b\":1},\"pad\":\"" + "y".repeat(200) + "\"}"
  let s = sr_schema("{!a:{!b:integer,!c:string}}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a.b,field_invalid:a.c,root_invalid:")
  // The closer of `a` is the 12th code unit of a 224 code unit document.
  assert_eq(evs[1].bytes, 12)
  assert_true(
    evs[1].event is FieldInvalid(_, _),
    msg="the absent member is a field_invalid",
  )
  assert_eq(evs[1].event.path(), "a.c")
  assert_eq(evs[1].event.is_verdict(), true)
  assert_true(
    evs[2].bytes * 2 < text.length(),
    msg="decided at " +
      evs[2].bytes.to_string() +
      "/" +
      text.length().to_string(),
  )
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(r.schema_permille, 1000)
  assert_true(r.settled_permille < 100, msg=r.settled_permille.to_string())
  assert_eq(r.verdict.ok, false)
  let decided = decided_at_permille(text, s, chunk=1) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_true(decided > 0 && decided < 100, msg=decided.to_string())
  assert_eq(r.settled_permille, decided)
  // The same document without the pad: the closer is still what decides.
  let w = match sr_watch(text, s, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.settled_at(), 12)
  assert_eq(w.concluded(), true)
  let v = w.verdict()
  assert_eq(v.ok, false)
  assert_eq(v.missing, ["a.c"])
}

///|
test "an absent member at the root is settled by the root's closer" {
  let text = "{\"a\":1}"
  let s = sr_schema("{!a:integer,!b:string}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a,field_invalid:b,root_invalid:")
  // `b` never arrives, and the closer of the root is the last code unit here,
  // so the decision is at the end of this document: `1000`.
  assert_eq(evs[1].bytes, text.length())
  assert_eq(evs[2].bytes, text.length())
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(r.settled_permille, 1000)
  assert_eq(r.schema_permille, 1000)
  assert_eq(r.verdict.ok, false)
  // It is the *closer* and not the end of the stream that decides: the same
  // value with whitespace behind it is refused at the closer, seven code units
  // in, because an object that has closed cannot gain a member. (This is the
  // one place the 0.6.0 brief and the code disagree; the code is the stronger
  // rule and is what is asserted here.)
  let padded = "{\"a\":1}   "
  let early = semantic_readiness(padded, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(early.settled_permille, 700)
  assert_eq(early.schema_permille, 1000)
  assert_eq(early.verdict.ok, false)
  let w = match sr_watch(text, s, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.concluded(), true)
  assert_eq(w.verdict().missing, ["b"])
}

///|
test "finish completes a truncated document and still decides" {
  // The closing quote and the closing brace never arrive; `finish` closes the
  // string, settles the member and decides the root.
  let text = "{\"a\":1,\"b\":\"xy"
  let s = sr_schema("{!a:integer,!b:string}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:a,field_ready:b,root_ready:")
  assert_eq(sr_at(evs, "field_ready"), 7)
  assert_eq(evs[1].bytes, -1)
  assert_eq(evs[2].bytes, -1)
  let w = match sr_watch(text, s, 1) {
    Some(w) => w
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.concluded(), true)
  assert_eq(w.verdict().ok, true)
  assert_eq(w.settled_at(), text.length())
  // A document truncated before the member even starts is refused, not lost.
  let cut = sr_schema("{!a:integer}")
  let evs2 = match sr_feed_one_by_one("{\"a\":", cut) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs2), "field_invalid:a,root_invalid:")
}

// ---------------------------------------------------------------------------
// Final-but-not-valid containers, and the watcher's bookkeeping.
// ---------------------------------------------------------------------------

///|
test "a container that is final but not valid names the member that is wrong" {
  // The message is about the member that is wrong, not about the container that
  // holds it. The path is relative to the container that was declared.
  let obj = sr_schema("{!a:{?x:integer}}")
  let evs = match sr_feed_one_by_one("{\"a\":{\"x\":\"s\"}}", obj) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_incomplete:x,root_invalid:")
  assert_true(
    evs[0].event is FieldIncomplete(_, _),
    msg="a final container with a wrong member is field_incomplete",
  )
  assert_eq(evs[0].event.path(), "x")
  // A `field_incomplete` is a progress note, not a verdict: the container's
  // value is final, the payload the caller asked for is not.
  assert_eq(evs[0].event.is_verdict(), false)
  assert_eq(evs[1].event.is_verdict(), true)
  let arr = sr_schema("{!a:[integer]}")
  let evs2 = match sr_feed_one_by_one("{\"a\":[1,\"x\"]}", arr) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs2), "field_incomplete:1,root_invalid:")
  assert_true(evs2[0].event is FieldIncomplete(_, _), msg="array element")
}

///|
test "the watcher follows only the paths it can decide itself" {
  // `c` is an object with a required member, so it is decided by `c.d`; `?b`
  // is optional and holds up nothing. Declaration order is preserved.
  let s = sr_schema("{!a:integer,?b:string,!c:{!d:integer}}")
  let w = SemanticWatcher::new(s) catch {
    _ => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.watched_paths(), ["a", "c.d"])
  assert_eq(w.total_required(), 2)
  assert_eq(w.all_settled(), false)
  assert_eq(w.ready_count(), 0)
  let doc = "{\"a\":1,\"c\":{\"d\":2}}"
  w.feed(doc) catch {
    _ => return assert_true(false, msg="feed failed")
  }
  let _ = w.drain_events()
  assert_eq(w.all_settled(), true)
  assert_eq(w.ready_count(), 2)
  assert_eq(w.bytes(), doc.length())
  assert_eq(w.settled_at() > 0, true)
  assert_eq(w.syntax_at() > 0, true)
  ignore(w.finish()) catch {
    _ => ()
  }
  assert_eq(w.concluded(), true)
  assert_eq(w.verdict().ok, true)
  // `duplicate_keys KeepFirst` is a documented composition, not a refusal
  // (Q-36): the measurement runs under `KeepLast` because a delta stream cannot
  // carry a value that was dropped, and the caller's own verdict is theirs to
  // take from `parse` under the options they asked for.
  let keep_first : Options = {
    ..Options::default(),
    duplicate_keys: KeepFirst,
  }
  let w2 = SemanticWatcher::new(s, options=keep_first) catch {
    _ => return assert_true(false, msg="KeepFirst must not be refused")
  }
  w2.feed("{\"a\":1,\"c\":{\"d\":2}}") catch {
    _ => return assert_true(false, msg="feed failed")
  }
  let _ = w2.drain_events()
  ignore(w2.finish()) catch {
    _ => ()
  }
  // No duplicate arrived, so the two policies agree and nothing is in conflict.
  assert_eq(w2.conflict(), false)
  assert_eq(w2.verdict().ok, true)
}

///|
test "a fresh watcher judges the empty value, not a missing one" {
  let s = sr_schema("{!a:integer}")
  let w = SemanticWatcher::new(s) catch {
    _ => return assert_true(false, msg="watcher did not build")
  }
  // Before a single code unit arrives the snapshot has no value at all, and the
  // verdict is still total: `a` is missing.
  assert_eq(w.bytes(), 0)
  assert_eq(w.settled_at(), -1)
  assert_eq(w.syntax_at(), -1)
  let v = w.verdict()
  assert_eq(v.ok, false)
  assert_eq(v.missing, ["a"])
  assert_eq(w.ready_count(), 0)
  assert_eq(w.all_settled(), false)
}

///|
test "a dotted member name is split into path segments" {
  // The declaration language cannot write a member whose name contains a dot,
  // and this is why: the path language splits it. A declaration with both `a`
  // and `a.b` puts two watched paths under the same first segment, which is the
  // case the watcher's index exists for.
  let s = sr_schema("{!a:any,!a.b:integer}")
  assert_eq(s.required_paths(), ["a", "a.b"])
  let w = SemanticWatcher::new(s) catch {
    _ => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.watched_paths(), ["a", "a.b"])
  assert_eq(w.total_required(), 2)
  // `Schema::at_path` splits the path the same way, and the step `a` resolves
  // to the declaration `any` and stops: a member literally named `a.b` is
  // unreachable. The path language is the flattened one and a member name may
  // not contain a dot, which is what `required_paths` documents.
  assert_eq(s.at_path("a.b").map(fn(x) { x.name() }), None)
  assert_eq(s.at_path("a").map(fn(x) { x.name() }), Some("any"))
}

// ---------------------------------------------------------------------------
// The one-shot form and the JSON form.
// ---------------------------------------------------------------------------

///|
test "the incremental and the batch form agree on every document" {
  let corpus : Array[(String, String)] = [
    ("{\"a\":1,\"b\":2}", "{!a:integer,!b:integer}"),
    ("{\"q\":\"MoonBit\"}", "{!q:string}"),
    ("{\"a\":{}, \"b\":[1,2]}", "{!a:any,!b:any}"),
    ("{\"city\":\"Osaka\",\"pop\":120000}", "{!city:string,!pop:number}"),
    ("{\"a\":{\"b\":{\"c\":true}}}", "{!a:{!b:{!c:boolean}}}"),
    ("{\"list\":[1,2,3]}", "{!list:[integer]}"),
    ("{\"a\":1,\"b\":\"x\",\"c\":null}", "{!a:integer,!b:string,!c:null}"),
    ("{\"n\":3.5}", "{!n:number}"),
    ("{\"a\":1}", "{}"),
    ("{\"a\":\"x\",\"b\":1}", "{!a:string,?b:integer}"),
    (
      "{\"limit\":\"ten\",\"note\":\"" + "x".repeat(60) + "\"}",
      "{!limit:integer}",
    ),
    // Absent inside a container: settled by that container's closer, early.
    (
      "{\"a\":{\"b\":1},\"pad\":\"" + "y".repeat(200) + "\"}",
      "{!a:{!b:integer,!c:string}}",
    ),
    // Absent at the root: the root's closer is the end of this document.
    ("{\"a\":1}", "{!a:integer,!b:string}"),
  ]
  for (text, decl) in corpus {
    let s = sr_schema(decl)
    let r = semantic_readiness(text, s, step=1) catch {
      _ =>
        return assert_true(false, msg="semantic_readiness failed for " + text)
    }
    let events = watch_readiness(text, s, chunk=1) catch {
      _ => return assert_true(false, msg="watch_readiness failed for " + text)
    }
    let required = s.required_paths()
    // `schema_permille` is the permille of `RootReady`, or 1000 when no
    // `RootReady` ever fired; a skeleton that requires nothing is 0.
    let root = sr_event_permille(events, "root_ready")
    let want_schema = if required.length() == 0 {
      0
    } else if root < 0 {
      1000
    } else {
      root
    }
    assert_eq(
      text + " schema_permille " + r.schema_permille.to_string(),
      text + " schema_permille " + want_schema.to_string(),
    )
    // `settled_permille` is the permille of the last required path becoming
    // final, whether or not it had the declared kind; a path that only
    // `finish()` can settle is the end of the input.
    let last = sr_last_settle(events)
    let want_settled = if required.length() == 0 {
      0
    } else if last < 0 {
      1000
    } else {
      last
    }
    assert_eq(
      text + " settled_permille " + r.settled_permille.to_string(),
      text + " settled_permille " + want_settled.to_string(),
    )
    // Splitting the input differently may not change the events.
    let named = match sr_feed_one_by_one(text, s) {
      Some(e) => sr_names(e)
      None =>
        return assert_true(false, msg="byte-wise stream failed for " + text)
    }
    let whole = match sr_name_sequence(text, s, text.length()) {
      Some(n) => n
      None => return assert_true(false, msg="whole-input watch failed")
    }
    assert_eq(text + " chunked " + named, text + " chunked " + whole)
  }
}

///|
test "the timeline is a property of the input, not of the chunking (Q-35)" {
  // Longer than 1 000 code units, so `auto_step` would have sampled it and every
  // reported fraction would have quantised to a sample boundary.
  let s = sr_schema("{!query:string,!limit:integer}")
  let text = "{\"query\":\"MoonBit\",\"limit\":10,\"tail\":\"" +
    "x".repeat(4000) +
    "\"}"
  let one = watch_readiness(text, s, chunk=1) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  let big = watch_readiness(text, s, chunk=997) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  let whole = watch_readiness(text, s, chunk=text.length()) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  assert_eq(one.length(), big.length())
  assert_eq(one.length(), whole.length())
  for i = 0; i < one.length(); i = i + 1 {
    let label = text.length().to_string() + " event " + i.to_string()
    assert_eq(
      label + " kind " + one[i].event.kind(),
      label + " kind " + big[i].event.kind(),
    )
    assert_eq(
      label + " permille " + one[i].permille.to_string(),
      label + " permille " + big[i].permille.to_string(),
    )
    assert_eq(
      label + " permille whole " + one[i].permille.to_string(),
      label + " permille whole " + whole[i].permille.to_string(),
    )
  }
  // The event the old quantum moved: `limit` is final at its own offset, not at
  // the end of the 997-code-unit chunk that happened to contain it.
  let limit_perm = sr_event_permille(one, "field_ready")
  assert_true(limit_perm > 0 && limit_perm < 100, msg=limit_perm.to_string())
  // Feeding once and sampling per code unit are the same measurement now, so the
  // published numbers cannot depend on the `step` the caller asks for.
  let sampled = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  let batched = semantic_readiness(text, s) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  let coarse = semantic_readiness(text, s, step=997) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(sampled.settled_permille, batched.settled_permille)
  assert_eq(sampled.settled_permille, coarse.settled_permille)
  assert_eq(sampled.syntax_permille, batched.syntax_permille)
  assert_eq(sampled.syntax_permille, coarse.syntax_permille)
  assert_eq(sampled.schema_permille, batched.schema_permille)
  // `syntax_at` and `settled_at` themselves, not only their fractions.
  let w1 = match sr_watch(text, s, 1) {
    Some(x) => x
    None => return assert_true(false, msg="watcher did not build")
  }
  let w2 = match sr_watch(text, s, 997) {
    Some(x) => x
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w1.syntax_at(), w2.syntax_at())
  assert_eq(w1.settled_at(), w2.settled_at())
  // The verdict, too: the answer is the same however the input arrived.
  assert_eq(w1.verdict().ok, true)
  assert_eq(w2.verdict().ok, true)
  assert_eq(
    decided_at_permille(text, s, chunk=1),
    decided_at_permille(text, s, chunk=997),
  )
}

///|
test "deciding early and deciding late are different numbers" {
  let s = sr_schema("{!limit:integer}")
  // Refused as soon as the wrong value is final: a small fraction of the input.
  let early = decided_at_permille(
    "{\"limit\":\"ten\",\"note\":\"" + "x".repeat(200) + "\"}",
    s,
    chunk=1,
  ) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_true(early > 0 && early < 500, msg=early.to_string())
  // The last member is a number that is only final when the root closes: the
  // only decision point is `finish`, which the report spells `1000`.
  let late = decided_at_permille("{\"limit\":10}", s, chunk=1) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_eq(late, 1000)
  // There is nothing to decide in an empty input.
  assert_eq(decided_at_permille("", s, chunk=1), -1)
}

///|
test "the event stream has a JSON form with escaped paths" {
  assert_eq(
    readiness_events_json([FieldReady("a")]),
    "[{\"kind\":\"field_ready\",\"path\":\"a\"}]",
  )
  assert_eq(
    readiness_events_json([FieldInvalid("b", "string"), RootInvalid(7)]),
    "[{\"kind\":\"field_invalid\",\"path\":\"b\",\"expected\":\"string\"},{\"kind\":\"root_invalid\",\"path\":\"\",\"offset\":7}]",
  )
  // A member name that needs escaping is escaped: the JSON form is what a
  // runtime reads, and `"` inside a path would otherwise end the string.
  assert_eq(
    readiness_events_json([FieldIncomplete("a\"b", "string")]),
    "[{\"kind\":\"field_incomplete\",\"path\":\"a\\\"b\",\"expected\":\"string\"}]",
  )
  // The same path, this time read off a real document: the member is written
  // `a"b`, declared `a"b`, and both sides survive the escape.
  let text = "{\"a\\\"b\":1}"
  let events = watch_readiness(text, sr_schema("{!a\"b:integer}"), chunk=1) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  let raw : Array[ReadinessEvent] = []
  for e in events {
    raw.push(e.event)
  }
  assert_eq(
    readiness_events_json(raw),
    "[{\"kind\":\"field_ready\",\"path\":\"a\\\"b\"},{\"kind\":\"root_ready\",\"path\":\"\"}]",
  )
}

// ---------------------------------------------------------------------------
// Option interactions.
// ---------------------------------------------------------------------------

///|
test "KeepFirst is a documented composition: numbers from the stream, verdict from the policy" {
  // The 0.5.0 sampling implementation is gone (Q-36). `KeepFirst` now means:
  // the three numbers come from the watcher, which measures under `KeepLast`
  // because a delta stream cannot carry a value that was dropped; the verdict
  // comes from `parse` under the options the caller asked for. A duplicate
  // whose two values have different kinds is the case where the two differ.
  let s = sr_schema("{!a:integer}")
  let keep_first : Options = {
    ..Options::default(),
    duplicate_keys: KeepFirst,
  }
  let doc = "{\"a\":1,\"a\":\"x\"}"
  let r = semantic_readiness(doc, s, step=1, options=keep_first) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  // `KeepFirst` keeps the first value, which is an integer: the caller's verdict
  // is the `KeepFirst` truth.
  assert_eq(r.verdict.ok, true)
  assert_eq(r.verdict.satisfied, 1)
  // The path is final when `1` ends (7 code units of 15), which is the same
  // offset the sampling loop reported, so `settled` does not move.
  assert_eq(r.settled_permille, permille(7, doc.length()))
  assert_eq(r.settled_permille, 466)
  // `syntax_permille` is the moment the value tree stopped changing, and under
  // the measurement policy the second value does touch it: this is the one
  // number the composition moves, and only for a repeated name.
  assert_eq(r.syntax_permille, permille(14, doc.length()))
  // The same document under `KeepLast` disagrees about the verdict and agrees
  // about when the path was final, which is the split the composition documents.
  let keep_last = semantic_readiness(doc, s, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  assert_eq(keep_last.verdict.ok, false)
  assert_eq(keep_last.settled_permille, r.settled_permille)
  // Byte by byte, the watcher announces the first value (which is the one
  // `KeepFirst` keeps) and concludes `RootReady` on it. It cannot retract that
  // when the duplicate arrives, so the duplicate is reported as a conflict
  // instead: an early conclusion is a lower bound, never a wrong event.
  let events = watch_readiness(doc, s, chunk=1, options=keep_first) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  assert_eq(
    sr_names_of(events.map(fn(e) { e.event })),
    "field_ready:a,root_ready:",
  )
  let w = match sr_watch_opts(doc, s, 1, keep_first) {
    Some(x) => x
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.conflict(), true)
  // The watcher's own verdict is the `KeepLast` one, as documented; the caller
  // who asked for `KeepFirst` takes theirs from `parse`, which is what
  // `semantic_readiness` does above.
  assert_eq(w.verdict().ok, false)
  // A document without duplicates is unaffected: the two policies agree.
  let clean = "{\"a\":1}"
  let c1 = semantic_readiness(clean, s, step=1, options=keep_first) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  let c2 = semantic_readiness(clean, s, step=1) catch {
    _ => return assert_true(false, msg="readiness failed")
  }
  assert_eq(c1.verdict.ok, c2.verdict.ok)
  assert_eq(c1.settled_permille, c2.settled_permille)
  assert_eq(c1.syntax_permille, c2.syntax_permille)
  assert_eq(c1.schema_permille, c2.schema_permille)
}

///|
test "an empty input has no events, and asking is not an error" {
  let s = sr_schema("{!a:integer}")
  let events = watch_readiness("", s, chunk=1) catch {
    _ => return assert_true(false, msg="watch_readiness raised on empty input")
  }
  assert_eq(events.length(), 0)
  // `finish()` cannot close a document that never started, which is why the
  // byte-wise helper has no events to report rather than an empty verdict.
  assert_true(sr_feed_one_by_one("", s) is None, msg="finish on empty input")
}

// ---------------------------------------------------------------------------
// The one-shot helpers, including the step they choose themselves.
// ---------------------------------------------------------------------------

///|
test "the one-shot helpers pick their own step and decide at the end" {
  let s = sr_schema("{!a:integer,!b:string}")
  // No `chunk` argument: the step is automatic. A document whose closing
  // brace never arrives cannot be decided while it is being fed, so the two
  // events that close the case carry `-1` rather than a fraction.
  let evs = watch_readiness("{\"a\":1", s) catch {
    _ => return assert_true(false, msg="watch_readiness failed")
  }
  let raw : Array[ReadinessEvent] = []
  for e in evs {
    raw.push(e.event)
  }
  assert_eq(sr_names_of(raw), "field_ready:a,field_invalid:b,root_invalid:")
  // Even `a`, whose value is complete in the text, is not *final* until a
  // delimiter or the end: a trailing digit could still grow. So every event
  // here is produced by `finish()`.
  assert_eq(sr_event_permille(evs, "field_ready"), -1)
  assert_eq(sr_event_permille(evs, "field_invalid"), -1)
  assert_eq(sr_event_permille(evs, "root_invalid"), -1)
  assert_eq(sr_last_settle(evs), -1)
  // The same for `decided_at_permille`: nothing is final during the feed, so
  // the answer can only be "not before the end".
  let decided = decided_at_permille("{\"a\":1", s) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_eq(decided, 1000)
  // An empty input is never decided at all.
  let empty = decided_at_permille("", s) catch { _ => -2 }
  assert_eq(empty, -1)
  // A document that closes early is decided at the fraction, not at the end.
  let early = decided_at_permille("{\"a\":1}   ", s) catch { _ => -2 }
  assert_eq(early, 700)
  let late = decided_at_permille("{\"a\":1}", s) catch { _ => -2 }
  assert_eq(late, 1000)
  // Text with no JSON in it is refused at the end, so the answer is "only when
  // the stream ends" (`1000`), not "never".
  let prose = decided_at_permille("no json here", s) catch { _ => -2 }
  assert_eq(prose, 1000)
  // Whitespace alone produces no value at all, so there is no decision to
  // report and the answer is `-1`.
  let blank = decided_at_permille("   ", s) catch { _ => -2 }
  assert_eq(blank, -1)
  // Input the delta parser rejects outright propagates the refusal instead,
  // which is why the caller of `decided_at_permille` must still handle an
  // error; `@@@` is the smallest example.
  let bad = decided_at_permille("@@@", s) catch { _ => -2 }
  assert_eq(bad, -2)
}

// ---------------------------------------------------------------------------
// 0.7.0 — a value-level declaration is enforced when the value is final.
//
// A kind is decided by the shape of a value; a constraint is decided by the
// value itself. Both are decided on the delta that makes the value final, so a
// refusal is published at the offset where the model stopped being able to fix
// it — which is the whole point of refusing a number before the document ends.
// ---------------------------------------------------------------------------

///|
test "a value the constraint refuses is refused the moment it is final" {
  // The product story with a value-level answer: `-1` is out of range the
  // moment it is final, and the 200 code units behind it are never paid for.
  let text = "{\"limit\":-1,\"note\":\"" + "x".repeat(200) + "\"}"
  let s = sr_schema("{!limit:integer(minimum:0)}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_rejected:limit,root_invalid:")
  // The value is final when its delimiter arrives, not at the end of the
  // document: 12 code units of 216 here.
  let off = sr_at(evs, "field_rejected")
  assert_eq(off, 12)
  assert_eq(sr_root_offset(evs), 12)
  assert_true(off * 2 < text.length(), msg="refused after half the document")
  // The refusal names the constraint, not the kind it shares.
  assert_eq(sr_rejected(evs), Some(("integer >= 0", "number")))
  assert_eq(evs[0].event.is_verdict(), true)
  // The same moment as a fraction, from the one-shot helpers.
  let decided = decided_at_permille(text, s, chunk=1) catch {
    _ => return assert_true(false, msg="decided_at_permille failed")
  }
  assert_eq(decided, 12 * 1000 / text.length())
  let r = semantic_readiness(text, s, step=1) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(r.verdict.ok, false)
  // `settled_permille` is the fraction at which every followed path was final,
  // and the refusal is exactly that moment: the value settled *and* was refused
  // on the same delta.
  assert_eq(r.settled_permille, decided)
  // `schema_permille` answers "may I execute" and never fires on a document
  // that is invalid; that meaning does not change.
  assert_eq(r.schema_permille, 1000)
}

///|
test "a wrong kind under a constraint still reports the whole declaration" {
  // A kind mismatch is not a constraint violation, and the payload says which
  // declaration was not met rather than pretending the value was in range.
  let s = sr_schema("{!limit:integer(minimum:0)}")
  let evs = match sr_feed_one_by_one("{\"limit\":\"ten\"}", s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_invalid:limit,root_invalid:")
  let payload = match evs[0].event {
    FieldInvalid(p, e) => p + "|" + e
    _ => "not a field_invalid"
  }
  assert_eq(payload, "limit|integer(minimum:0)")
}

///|
test "string constraints are refused on the closing quote" {
  // `maxLength` is decided when the string ends, so the tail behind it is not
  // paid for; and the message names the length rather than the kind.
  let text = "{\"code\":\"ABCD\",\"pad\":\"" + "z".repeat(150) + "\"}"
  let s = sr_schema("{!code:string(maxLength:3)}")
  let evs = match sr_feed_one_by_one(text, s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_rejected:code,root_invalid:")
  assert_eq(sr_rejected(evs), Some(("string with length <= 3", "string")))
  // `"ABCD"` ends at code unit 14 (the closing quote of the value).
  assert_eq(sr_at(evs, "field_rejected"), 14)
  // `enum` and `pattern` refuse the same way.
  let e = sr_schema("{!kind:string(enum:[\"low\",\"high\"])}")
  let ev = match sr_feed_one_by_one("{\"kind\":\"nope\",\"t\":1}", e) {
    Some(x) => x
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_rejected(ev), Some(("one of [\"low\",\"high\"]", "string")))
  let pt = sr_schema("{!code:string(pattern:[A-Z])}")
  let pv = match sr_feed_one_by_one("{\"code\":\"ab\",\"t\":1}", pt) {
    Some(x) => x
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_rejected(pv), Some(("string of characters in [A-Z]", "string")))
}

///|
test "a value that satisfies its constraint is ready, not refused" {
  let s = sr_schema("{!limit:integer(minimum:0),!name:string(maxLength:4)}")
  let evs = match sr_feed_one_by_one("{\"limit\":5,\"name\":\"abcd\"}", s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(sr_names(evs), "field_ready:limit,field_ready:name,root_ready:")
  let w = match sr_watch("{\"limit\":5,\"name\":\"abcd\"}", s, 1) {
    Some(x) => x
    None => return assert_true(false, msg="watcher did not build")
  }
  assert_eq(w.concluded(), true)
  assert_eq(w.all_settled(), true)
  assert_eq(w.ready_count(), 2)
  assert_eq(w.verdict().ok, true)
}

///|
test "the three readiness numbers do not move because constraints exist" {
  // The 0.7.0 rule: constraints add refusals, they do not redefine the numbers.
  // A document that satisfies the constrained declaration is measured exactly
  // as the same document against the bare kind.
  let text = "{\"limit\":5,\"note\":\"" + "x".repeat(120) + "\"}"
  for step in [1, 7, 64] {
    let bare = semantic_readiness(text, sr_schema("{!limit:integer}"), step~) catch {
      _ => return assert_true(false, msg="semantic_readiness failed")
    }
    let constrained = semantic_readiness(
      text,
      sr_schema("{!limit:integer(minimum:0)}"),
      step~,
    ) catch {
      _ => return assert_true(false, msg="semantic_readiness failed")
    }
    assert_eq(constrained.syntax_permille, bare.syntax_permille)
    assert_eq(constrained.settled_permille, bare.settled_permille)
    assert_eq(constrained.schema_permille, bare.schema_permille)
    assert_eq(constrained.verdict.ok, bare.verdict.ok)
  }
  // A constraint violated by the last member is decided at the end, which is
  // where it was decided before constraints existed.
  let late = semantic_readiness(
    "{\"note\":\"" + "x".repeat(120) + "\",\"limit\":-1}",
    sr_schema("{!note:string,!limit:integer(minimum:0)}"),
    step=1,
  ) catch {
    _ => return assert_true(false, msg="semantic_readiness failed")
  }
  assert_eq(late.verdict.ok, false)
  assert_eq(late.settled_permille, 1000)
}

///|
test "field_rejected has a JSON form like every other event" {
  let s = sr_schema("{!n:number(exclusiveMinimum:1.5)}")
  let evs = match sr_feed_one_by_one("{\"n\":1}", s) {
    Some(e) => e
    None => return assert_true(false, msg="byte-wise stream failed")
  }
  assert_eq(
    evs[0].event.to_json(),
    "{\"kind\":\"field_rejected\",\"path\":\"n\",\"expected\":\"number > 1.5\",\"got\":\"number\"}",
  )
  // The value 1 is an integer, and `number` admits it: the constraint is what
  // refuses it, and the number is spelled the way JSON spells it.
  assert_eq(evs[0].event.kind(), "field_rejected")
  assert_eq(
    evs[1].event.to_json(),
    "{\"kind\":\"root_invalid\",\"path\":\"\",\"offset\":7}",
  )
}
