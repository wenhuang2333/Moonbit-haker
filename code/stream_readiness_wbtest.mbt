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
/// Permille of the last settle event (`field_ready` / `field_invalid`), or
/// `-1` when only `finish()` settled a path.
fn sr_last_settle(events : Array[ReadinessEventAt]) -> Int32 {
  let mut last = -1
  for e in events {
    match e.event {
      FieldReady(_) | FieldInvalid(_, _) => last = e.permille
      _ => ()
    }
  }
  last
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
  // A delta stream cannot retract a container it already announced, so the one
  // option combination a watcher cannot work with is refused up front.
  let code = try {
    ignore(
      SemanticWatcher::new(s, options={
        ..Options::default(),
        duplicate_keys: KeepFirst,
      }),
    )
    "no error"
  } catch {
    e => e.code()
  }
  assert_eq(code, "E050")
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
test "the watcher keeps working when the delta stream cannot be used" {
  // `duplicate_keys KeepFirst` needs a value the delta stream cannot express,
  // so `semantic_readiness` falls back to the 0.5.0 sampling implementation
  // instead of raising. The result is the same kind of measurement.
  let s = sr_schema("{!a:integer}")
  let keep_first : Options = {
    ..Options::default(),
    duplicate_keys: KeepFirst,
  }
  let r = semantic_readiness("{\"a\":1,\"a\":2}", s, step=1, options=keep_first) catch {
    _ => return assert_true(false, msg="sampled readiness failed")
  }
  // `KeepFirst` keeps the first value, so the document satisfies the skeleton.
  assert_eq(r.verdict.ok, true)
  assert_true(r.settled_permille > 0, msg=r.settled_permille.to_string())
  assert_true(r.settled_permille <= 1000, msg=r.settled_permille.to_string())
  assert_eq(r.verdict.satisfied, 1)
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
