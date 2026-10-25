// M6 delta — the incremental change stream (FR-18).
//
// Delta tracking is off unless `Options::collect_deltas` is set, so every hook
// in this file is guarded by that flag and costs one branch otherwise.
//
// The contract, checked by `delta_wbtest.mbt`:
//
//   applying the deltas returned by `drain_deltas()` to the value obtained
//   from the previous drain yields exactly `snapshot().value`
//
// Four design consequences follow, and all four are enforced or documented:
//
//   * a change is recorded as one entry in a set of parallel arrays, never as a
//     `Delta` object, and a path is an index into an arena, never an array
//     copy. `Delta` values are built only by `drain_deltas`, which stays as a
//     compatibility layer; `DeltaView` and `for_each_delta` are the shapes that
//     do not materialise a path per change at all;
//   * text is flushed at drain time, not per code unit, so a long string costs
//     one path computation per drain rather than one per character;
//   * `duplicate_keys KeepFirst` is rejected by `Options::validate`, because a
//     dropped duplicate still announces its container; the default `KeepLast`
//     needs no retraction — a later `Set` simply overwrites;
//   * `incomplete_number TrimToValid` is rejected as well, because an
//     unfinished number has no delta representation.

///|
/// Arena index of the empty (root) path.
let root_path : Int32 = 0

///|
/// The incremental change log (FR-18).
///
/// Recording appends one entry to each parallel array and at most one node to
/// the arena: no `Delta` and no path array is built while the document is being
/// read. The arena is append-only, so a drain clears the parallel arrays but
/// leaves the paths that `DeltaView`s still point at intact.
///
/// The arena is itself a set of parallel arrays rather than an `Array` of a
/// node struct: a struct holding a reference field is boxed per element, which
/// is exactly the allocation this type exists to avoid. The one-entry cache
/// makes the two or three lookups a single slot receives (its open
/// announcement, the drain-time text flush, its landing) cost three integer
/// comparisons instead of three nodes. It is content-addressed, so a hit is
/// always the same path and never a stale one.
priv struct DeltaLog {
  node_parent : Array[Int32]
  node_key : Array[String?]
  node_index : Array[Int32]
  mut cache_parent : Int32
  mut cache_index : Int32
  mut cache_key : String?
  mut cache_id : Int32
  mut cache_valid : Bool
  ops : Array[Byte]
  ats : Array[Int32]
  path_ids : Array[Int32]
  values : Array[Json?]
  texts : Array[String]
}

///|
/// Which `DeltaOp` a log byte stands for.
fn delta_op_code(op : DeltaOp) -> Byte {
  match op {
    Set => b'\x00'
    AppendText => b'\x01'
    Close => b'\x02'
  }
}

///|
/// The `DeltaOp` a log byte stands for.
fn delta_op_of(code : Byte) -> DeltaOp {
  if code == b'\x00' {
    Set
  } else if code == b'\x01' {
    AppendText
  } else {
    Close
  }
}

///|
/// An empty log, holding only the root path node.
fn DeltaLog::new() -> DeltaLog {
  {
    node_parent: [-1],
    node_key: [None],
    node_index: [0],
    cache_parent: 0,
    cache_index: 0,
    cache_key: None,
    cache_id: -1,
    cache_valid: false,
    ops: [],
    ats: [],
    path_ids: [],
    values: [],
    texts: [],
  }
}

///|
/// Append one change. `pid` is an arena index.
fn DeltaLog::push(
  self : DeltaLog,
  op : DeltaOp,
  at : Int32,
  pid : Int32,
  value : Json?,
  text : String,
) -> Unit {
  self.ops.push(delta_op_code(op))
  self.ats.push(at)
  self.path_ids.push(pid)
  self.values.push(value)
  self.texts.push(text)
}

///|
/// Drop the recorded changes, keeping the arena.
fn DeltaLog::clear(self : DeltaLog) -> Unit {
  self.ops.clear()
  self.ats.clear()
  self.path_ids.clear()
  self.values.clear()
  self.texts.clear()
}

///|
/// Whether two optional segment keys name the same member.
fn option_string_eq(a : String?, b : String?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x == y
    _ => false
  }
}

///|
/// Extend `parent` by one segment, returning the new node's index. `key` is
/// `Some` for a `Key` segment and `None` for an `Index` segment.
fn DeltaLog::intern(
  self : DeltaLog,
  parent : Int32,
  key : String?,
  index : Int32,
) -> Int32 {
  let same_slot = self.cache_valid &&
    self.cache_parent == parent &&
    self.cache_index == index &&
    option_string_eq(self.cache_key, key)
  if same_slot {
    return self.cache_id
  }
  self.node_parent.push(parent)
  self.node_key.push(key)
  self.node_index.push(index)
  let id = self.node_parent.length() - 1
  self.cache_parent = parent
  self.cache_index = index
  self.cache_key = key
  self.cache_id = id
  self.cache_valid = true
  id
}

///|
/// Extend `parent` by a whole segment list, returning its index.
fn DeltaLog::intern_path(self : DeltaLog, segs : Array[PathSegment]) -> Int32 {
  let mut cur = root_path
  for seg in segs {
    cur = match seg {
      Key(k) => self.intern(cur, Some(k), 0)
      Index(i) => self.intern(cur, None, i)
    }
  }
  cur
}

///|
/// Decode an arena path into segments, outermost first.
///
/// One pass counts the depth and one fills the slots from the end, so the only
/// array this allocates is the answer. The naive version walked the chain into a
/// temporary index list first, which doubled the cost of the compatibility
/// `drain_deltas`.
fn DeltaLog::segments(self : DeltaLog, id : Int32) -> Array[PathSegment] {
  let mut depth = 0
  let mut cur = id
  while cur > root_path {
    depth = depth + 1
    cur = self.node_parent[cur]
  }
  let out : Array[PathSegment] = []
  for i = 0; i < depth; i = i + 1 {
    out.push(Index(0))
  }
  let mut cur = id
  let mut i = depth - 1
  while cur > root_path {
    out[i] = match self.node_key[cur] {
      Some(key) => Key(key)
      None => Index(self.node_index[cur])
    }
    cur = self.node_parent[cur]
    i = i - 1
  }
  out
}

///|
/// Decode an arena path as an RFC 6901 JSON Pointer.
fn DeltaLog::pointer_of(self : DeltaLog, id : Int32) -> String {
  pointer_of_path(self.segments(id))
}

///|
/// Record one delta. Only called when `collect_deltas` is on.
fn Engine::push_delta(
  self : Engine,
  op : DeltaOp,
  pid : Int32,
  value : Json?,
  text : String,
) -> Unit {
  // `step` advances the position after the token handler runs, so inside a
  // handler `pos_offset` is the offset of the code unit being processed: one
  // code unit has been consumed once that unit is done. At `finish` everything
  // is consumed already and `pos_offset` is the total length.
  let at = if self.finishing { self.pos_offset } else { self.pos_offset + 1 }
  self.dlog.push(op, at, pid, value, text)
}

///|
/// Record one already-materialised delta, rebuilding its path in this engine's
/// arena. Used only by the `skip_prose` prelude retry, whose second engine owns
/// a different arena.
fn Engine::push_delta_path(self : Engine, d : Delta) -> Unit {
  self.dlog.push(d.op, d.at, self.dlog.intern_path(d.path), d.value, d.text)
}

///|
/// Arena index of the path of the slot the next child of the frame at `idx`
/// would occupy. One arena node is appended per call; the rest of the path is
/// shared with the container, which is what keeps recording from copying a
/// path array per change.
fn Engine::child_path_id(self : Engine, idx : Int32) -> Int32 {
  let parent = self.stack[idx].path_id
  let f = self.stack[idx]
  match f.kind {
    FArr => self.dlog.intern(parent, None, f.items.length())
    FObj =>
      match f.last_key {
        Some(k) => self.dlog.intern(parent, Some(k), 0)
        None => parent
      }
  }
}

///|
/// Arena index of the path of the slot currently being filled: the root, or the
/// next child of the innermost frame.
fn Engine::slot_path_id(self : Engine) -> Int32 {
  if self.stack.length() == 0 {
    root_path
  } else {
    self.child_path_id(self.stack.length() - 1)
  }
}

///|
/// Whether the value currently being built is already visible in a snapshot.
///
/// At the root the pending value is hidden once a root value exists. Inside an
/// array the pending element is always visible. Inside an object it is visible
/// only once a key is known and a colon may follow.
fn Engine::slot_visible(self : Engine) -> Bool {
  if self.stack.length() == 0 {
    return self.root is None
  }
  let f = self.stack[self.stack.length() - 1]
  match f.kind {
    FArr => true
    FObj =>
      match f.last_key {
        Some(_) => f.ctx is CObjColon || f.ctx is CObjValue
        None => false
      }
  }
}

///|
/// Arena index of the path of the string value that a pending `+` would extend
/// (BR-21).
fn Engine::concat_target_path_id(self : Engine) -> Int32 {
  if self.stack.length() == 0 {
    return root_path
  }
  let idx = self.stack.length() - 1
  let parent = self.stack[idx].path_id
  let f = self.stack[idx]
  match f.kind {
    FArr =>
      if f.items.length() > 0 {
        self.dlog.intern(parent, None, f.items.length() - 1)
      } else {
        parent
      }
    FObj =>
      match f.last_assigned_key {
        Some(k) => self.dlog.intern(parent, Some(k), 0)
        None => parent
      }
  }
}

///|
/// Emit the delta that announces a freshly opened container.
fn Engine::delta_enter(self : Engine, pid : Int32, kind : FrameKind) -> Unit {
  let v = match kind {
    FObj => Json::object(Map([]))
    FArr => Json::array([])
  }
  self.push_delta(Set, pid, Some(v), "")
}

///|
/// Emit the delta for a value that just landed in a slot. A container lands as
/// `Close`, which carries its final content; the earlier `Set` from
/// `delta_enter` announced the empty container.
fn Engine::delta_land(self : Engine, pid : Int32, v : Json) -> Unit {
  let op = match v {
    Json::Array(_) | Json::Object(_) => Close
    _ => Set
  }
  self.push_delta(op, pid, Some(v), "")
}

///|
/// Emit the `Set` that opens a string value slot, so that a drain taken while
/// the string is still growing sees the element.
fn Engine::delta_open_string(self : Engine, is_key : Bool) -> Unit {
  if is_key || self.concat_pending || !self.slot_visible() {
    return
  }
  self.push_delta(Set, self.slot_path_id(), Some(Json::string("")), "")
}

///|
/// Emit the `Set` for a key that is visible before its value arrives, which is
/// what `pending_key NullKey` promises (FR-09).
fn Engine::delta_pending_key(self : Engine) -> Unit {
  if self.opts.pending_key is OmitKey || self.stack.length() == 0 {
    return
  }
  let idx = self.stack.length() - 1
  let f = self.stack[idx]
  if f.kind is FArr {
    return
  }
  match f.last_key {
    Some(_) =>
      if f.ctx is CObjColon || f.ctx is CObjValue {
        self.push_delta(Set, self.child_path_id(idx), Some(Json::null()), "")
      }
    None => ()
  }
}

///|
/// Text of the string being scanned that has not been reported yet.
///
/// The cursor (`delta_part_idx` / `delta_part_off`) records where the previous
/// tail stopped, so a drain costs one pass over the newly appended parts and
/// never rescans the prefix. `delta_str_reported` remains the total length and
/// is what `flush_delta_text` compares against.
fn Engine::delta_text_tail(self : Engine) -> String {
  let sb = StringBuilder()
  let mut idx = self.delta_part_idx
  let mut off = self.delta_part_off
  while idx < self.parts.length() {
    let part = self.parts[idx]
    let n = part.length()
    if off >= n {
      idx = idx + 1
      off = 0
      continue
    }
    sb.write_substring(part, off, n - off)
    idx = idx + 1
    off = 0
  }
  self.delta_part_idx = idx
  self.delta_part_off = off
  sb.to_string()
}

///|
/// Flush the growth of the string currently being scanned (FR-18). Called from
/// the drain entry points, so a long string costs one path computation per
/// drain.
fn Engine::flush_delta_text(self : Engine) -> Unit {
  if self.concat_pending || self.parts_len <= self.delta_str_reported {
    return
  }
  match self.tok {
    TStr(_k, is_key) | TStrPending(_k, is_key) => if is_key { return }
    _ => return
  }
  if !self.slot_visible() {
    return
  }
  let tail = self.delta_text_tail()
  self.delta_str_reported = self.parts_len
  if tail.length() > 0 {
    self.push_delta(AppendText, self.slot_path_id(), None, tail)
  }
}

///|
/// Return and clear the deltas recorded since the previous call, including the
/// text of a string that is still growing, as materialised `Delta` values.
///
/// This is the compatibility shape: it builds one `Delta` and one path array
/// per change. `drain_views` and `for_each_delta` are the shapes that do not.
fn Engine::drain_deltas(self : Engine) -> Array[Delta] {
  self.flush_delta_text()
  let out : Array[Delta] = []
  let n = self.dlog.ops.length()
  for i = 0; i < n; i = i + 1 {
    out.push({
      path: self.dlog.segments(self.dlog.path_ids[i]),
      op: delta_op_of(self.dlog.ops[i]),
      value: self.dlog.values[i],
      text: self.dlog.texts[i],
      at: self.dlog.ats[i],
    })
  }
  self.dlog.clear()
  out
}

///|
/// The deltas recorded since the previous drain as `DeltaView`s: same
/// operations, same order, but the path stays in the arena until
/// `PartialParser::delta_path` or `PartialParser::delta_pointer` decodes it.
fn Engine::drain_views(self : Engine) -> Array[DeltaView] {
  self.flush_delta_text()
  let out : Array[DeltaView] = []
  let n = self.dlog.ops.length()
  for i = 0; i < n; i = i + 1 {
    out.push({
      op: delta_op_of(self.dlog.ops[i]),
      at: self.dlog.ats[i],
      value: self.dlog.values[i],
      text: self.dlog.texts[i],
      path_id: self.dlog.path_ids[i],
    })
  }
  self.dlog.clear()
  out
}

///|
/// Hand every recorded delta to `on`, in order, and clear the log.
fn Engine::for_each_delta(self : Engine, on : (DeltaView) -> Unit) -> Unit {
  self.flush_delta_text()
  let n = self.dlog.ops.length()
  for i = 0; i < n; i = i + 1 {
    on({
      op: delta_op_of(self.dlog.ops[i]),
      at: self.dlog.ats[i],
      value: self.dlog.values[i],
      text: self.dlog.texts[i],
      path_id: self.dlog.path_ids[i],
    })
  }
  self.dlog.clear()
}
