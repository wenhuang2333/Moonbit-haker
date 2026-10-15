// FR-29 — the field readiness curve and field level early stop.
//
// The "95% coverage" figure of the first evaluation round was structurally
// insensitive (an object is either visible or it is not), and "the first
// visible value arrives after 0.7% of the document" says nothing about *which*
// field becomes usable when. Both are replaced by one measurement:
//
//   for every top-level member, the first input fraction at which the value it
//   holds is already equal to the value it ends up with.
//
// A consumer that waits for the whole document has every field ready at 1.000,
// so the curve of that baseline is flat at 0 until the end. A consumer that
// only needs the fields it saw so far can cancel the generation as soon as the
// last one it needs is ready, which is the saving this file reports.

///|
/// Readiness point of one top-level member.
pub(all) struct FieldReady {
  /// Member name.
  key : String
  /// First input fraction, in per mille of the whole document, at which the
  /// member's value was already finmap. `1000` means "not before the end".
  permille : Int32
}

///|
/// Explicit `Eq` implementation for `FieldReady`.
pub impl Eq for FieldReady with fn equal(self : FieldReady, other : FieldReady) -> Bool {
  self.key == other.key && self.permille == other.permille
}

///|
/// Explicit `Eq` extension for `FieldReady`.
pub extend FieldReady with Eq::{not_equal, equal}

///|
/// Readiness curve of one document (FR-29).
///
/// `step` is the number of code units fed between two observations; `0` (the
/// default) picks a step that samples the document about a thousand times, so
/// the result does not depend on the document length.
///
/// Since 0.6.0 this listens to the delta stream instead of re-reading the
/// document: a top-level member is ready at the offset of its own final delta,
/// which is one pass with one drain per step rather than one partial parse *and
/// one snapshot* per step (FR-39). On a 100 KiB payload that is ~30x.
///
/// A document whose root is not an object has no fields and yields `[]`.
pub fn field_readiness(
  input : String,
  step? : Int32,
  options? : Options,
) -> Array[FieldReady] raise MendError {
  let n = input.length()
  let fin = parse(input, options?)
  let finmap = match fin.value {
    Json::Object(m) => m
    _ => return []
  }
  let st = auto_step(
    n,
    match step {
      Some(v) => v
      None => 0
    },
  )
  // The final member list is what the report is about; each one is followed
  // with an `any` declaration, because FR-29 asks *when the value was final*,
  // not whether it had the declared kind.
  let members : Array[String] = []
  let specs : Array[SchemaMember] = []
  for k, _v in finmap {
    members.push(k)
    specs.push({ key: k, required: true, schema: Any, })
  }
  let skeleton = Obj(specs)
  let events = watch_readiness(input, skeleton, chunk=st, options?)
  let seen : Map[String, Int32] = Map([])
  for e in events {
    let key = e.event.path()
    if key == "" || seen.contains(key) {
      continue
    }
    match e.event {
      FieldReady(_) | FieldInvalid(_, _) =>
        // `-1` means the member was only settled by `finish()`: "not before the
        // end".
        seen[key] = if e.permille < 0 { 1000 } else { e.permille }
      _ => ()
    }
  }
  let out : Array[FieldReady] = []
  for k in members {
    match seen.get(k) {
      Some(p) => out.push({ key: k, permille: p, })
      None => out.push({ key: k, permille: 1000, })
    }
  }
  out
}

///|
/// Median readiness point, in per mille, over every field of every document
/// (FR-29). Documents without fields are ignored.
pub fn readiness_median(
  docs : Array[String],
  step? : Int32,
) -> Int32 raise MendError {
  let all : Array[Int32] = []
  for text in docs {
    for f in field_readiness(text, step?) {
      all.push(f.permille)
    }
  }
  if all.length() == 0 {
    return 1000
  }
  all.sort()
  all[all.length() / 2]
}

///|
/// The readiness curve over `docs`, as eleven percentages: entry `d` is the
/// share (0…100) of fields whose value was already finmap when `d` tenths of
/// the input had been consumed (FR-29). Entry 0 is 0 by construction, entry 10
/// is 100.
pub fn readiness_deciles(
  docs : Array[String],
  step? : Int32,
) -> Array[Int32] raise MendError {
  let points : Array[Int32] = []
  for text in docs {
    for f in field_readiness(text, step?) {
      points.push(f.permille)
    }
  }
  let out : Array[Int32] = []
  for d = 0; d <= 10; d = d + 1 {
    let limit = d * 100
    let mut hit = 0
    for p in points {
      if p <= limit {
        hit = hit + 1
      }
    }
    if points.length() == 0 {
      out.push(0)
    } else {
      out.push(hit * 100 / points.length())
    }
  }
  out
}

///|
/// Average share of the input, in per mille, that a consumer never has to read
/// if it stops the generation as soon as every field of a document is ready
/// (FR-29).
///
/// The baseline is 0 by definition: waiting for the end of the document reads
/// all of it. A document whose root is not an object contributes 0.
pub fn early_stop_saving(
  docs : Array[String],
  step? : Int32,
) -> Int32 raise MendError {
  if docs.length() == 0 {
    return 0
  }
  let mut total = 0
  for text in docs {
    let fields = field_readiness(text, step?)
    let mut last = 0
    for f in fields {
      if f.permille > last {
        last = f.permille
      }
    }
    if fields.length() > 0 {
      total = total + (1000 - last)
    }
  }
  total / docs.length()
}

// ---------------------------------------------------------------------------
// The runtime half of the same idea: watch a delta stream instead of a text.
// ---------------------------------------------------------------------------

///|
/// Watches a set of top-level members of the object a model is writing and
/// reports when each one can no longer change, so the caller can cancel the
/// generation (FR-29).
///
/// The rule is read off the delta contract rather than guessed:
///
/// * `Close` on `/<key>` — a container member is finmap;
/// * `Set` on `/<key>` with a completed scalar — a number, literal, or a
///   non-empty string is finmap (an empty string is the placeholder that
///   announces a string slot, followed by `AppendText`);
/// * any later delta about a different first-level member — the member before
///   it cannot change any more.
pub struct FieldTracker {
  priv watched : Array[String]
  priv seen : Array[Bool]
  priv ready : Array[Bool]
}

///|
/// A tracker for `keys`.
pub fn FieldTracker::new(keys : Array[String]) -> FieldTracker {
  let seen : Array[Bool] = []
  let ready : Array[Bool] = []
  for _k in keys {
    seen.push(false)
    ready.push(false)
  }
  { watched: keys.copy(), seen, ready, }
}

///|
/// First-level member a delta talks about, or "".
fn delta_top_key(d : Delta) -> String {
  if d.path.length() == 0 {
    ""
  } else {
    match d.path[0] {
      Key(k) => k
      Index(_) => ""
    }
  }
}

///|
/// Whether a `Set` carries a scalar that is already finmap.
fn settled_scalar(d : Delta) -> Bool {
  match d.value {
    Some(Json::String(s)) => s != ""
    Some(Json::Array(_)) | Some(Json::Object(_)) => false
    Some(_) => true
    None => false
  }
}

///|
/// Feed one delta.
pub fn FieldTracker::feed(self : FieldTracker, d : Delta) -> Unit {
  let top = delta_top_key(d)
  for i = 0; i < self.watched.length(); i = i + 1 {
    if self.seen[i] && !self.ready[i] && top != "" && top != self.watched[i] { // another member started
      self.ready[i] = true
    }
    if top == self.watched[i] && top != "" {
      self.seen[i] = true
      if d.path.length() == 1 {
        let settled = match d.op {
          Close => true
          Set => settled_scalar(d)
          AppendText => false
        }
        if settled {
          self.ready[i] = true
        }
      }
    }
  }
}

///|
/// Whether every watched member is finmap.
pub fn FieldTracker::all_ready(self : FieldTracker) -> Bool {
  for i = 0; i < self.watched.length(); i = i + 1 {
    if !self.ready[i] {
      return false
    }
  }
  true
}

///|
/// Whether the named member is finmap.
pub fn FieldTracker::ready(self : FieldTracker, key : String) -> Bool {
  for i = 0; i < self.watched.length(); i = i + 1 {
    if self.watched[i] == key {
      return self.ready[i]
    }
  }
  false
}

///|
/// How many watched members are finmap.
pub fn FieldTracker::ready_count(self : FieldTracker) -> Int32 {
  let mut n = 0
  for i = 0; i < self.watched.length(); i = i + 1 {
    if self.ready[i] {
      n = n + 1
    }
  }
  n
}

///|
/// Names of the watched members that are finmap, in the order they were ready.
pub fn FieldTracker::ready_keys(self : FieldTracker) -> Array[String] {
  let out : Array[String] = []
  for i = 0; i < self.watched.length(); i = i + 1 {
    if self.ready[i] {
      out.push(self.watched[i])
    }
  }
  out
}
