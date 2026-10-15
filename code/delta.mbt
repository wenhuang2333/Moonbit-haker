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
// Three design consequences follow, and all three are enforced or documented:
//
//   * text is flushed at drain time, not per code unit, so a long string costs
//     one path computation per drain rather than one per character;
//   * `duplicate_keys KeepFirst` is rejected by `Options::validate`, because a
//     dropped duplicate still announces its container; the default `KeepLast`
//     needs no retraction — a later `Set` simply overwrites;
//   * `incomplete_number TrimToValid` is rejected as well, because an
//     unfinished number has no delta representation.

///|
/// Record one delta. Only called when `collect_deltas` is on.
fn Engine::push_delta(
  self : Engine,
  op : DeltaOp,
  path : Array[PathSegment],
  value : Json?,
  text : String,
) -> Unit {
  self.deltas.push({ path, op, value, text, })
}

///|
/// Path of the container frame at `idx`.
fn Engine::frame_path(self : Engine, idx : Int32) -> Array[PathSegment] {
  self.stack[idx].path.copy()
}

///|
/// Path of the slot the next child of the frame at `idx` would occupy.
fn Engine::child_path(self : Engine, idx : Int32) -> Array[PathSegment] {
  let out = self.frame_path(idx)
  let f = self.stack[idx]
  match f.kind {
    FArr => out.push(Index(f.items.length()))
    FObj =>
      match f.last_key {
        Some(k) => out.push(Key(k))
        None => ()
      }
  }
  out
}

///|
/// Path of the slot currently being filled: the root, or the next child of the
/// innermost frame.
fn Engine::slot_path(self : Engine) -> Array[PathSegment] {
  if self.stack.length() == 0 {
    []
  } else {
    self.child_path(self.stack.length() - 1)
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
/// Path of the string value that a pending `+` would extend (BR-21).
fn Engine::concat_target_path(self : Engine) -> Array[PathSegment] {
  if self.stack.length() == 0 {
    return []
  }
  let idx = self.stack.length() - 1
  let out = self.frame_path(idx)
  let f = self.stack[idx]
  match f.kind {
    FArr => if f.items.length() > 0 { out.push(Index(f.items.length() - 1)) }
    FObj =>
      match f.last_assigned_key {
        Some(k) => out.push(Key(k))
        None => ()
      }
  }
  out
}

///|
/// Emit the delta that announces a freshly opened container.
fn Engine::delta_enter(
  self : Engine,
  path : Array[PathSegment],
  kind : FrameKind,
) -> Unit {
  let v = match kind {
    FObj => Json::object(Map([]))
    FArr => Json::array([])
  }
  self.push_delta(Set, path, Some(v), "")
}

///|
/// Emit the delta for a value that just landed in a slot. A container lands as
/// `Close`, which carries its final content; the earlier `Set` from
/// `delta_enter` announced the empty container.
fn Engine::delta_land(
  self : Engine,
  path : Array[PathSegment],
  v : Json,
) -> Unit {
  let op = match v {
    Json::Array(_) | Json::Object(_) => Close
    _ => Set
  }
  self.push_delta(op, path, Some(v), "")
}

///|
/// Emit the `Set` that opens a string value slot, so that a drain taken while
/// the string is still growing sees the element.
fn Engine::delta_open_string(self : Engine, is_key : Bool) -> Unit {
  if is_key || self.concat_pending || !self.slot_visible() {
    return
  }
  self.push_delta(Set, self.slot_path(), Some(Json::string("")), "")
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
        self.push_delta(Set, self.child_path(idx), Some(Json::null()), "")
      }
    None => ()
  }
}

///|
/// Text of the string being scanned that has not been reported yet.
fn Engine::delta_text_tail(self : Engine) -> String {
  let sb = StringBuilder()
  let mut acc = 0
  for part in self.parts {
    let n = part.length()
    if acc + n <= self.delta_str_reported {
      acc = acc + n
      continue
    }
    let start = if self.delta_str_reported > acc {
      self.delta_str_reported - acc
    } else {
      0
    }
    sb.write_string(part[start:n].to_owned())
    acc = acc + n
  }
  sb.to_string()
}

///|
/// Flush the growth of the string currently being scanned (FR-18). Called from
/// `drain_deltas`, so a long string costs one path computation per drain.
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
    self.push_delta(AppendText, self.slot_path(), None, tail)
  }
}

///|
/// Return and clear the deltas recorded since the previous call, including the
/// text of a string that is still growing.
fn Engine::drain_deltas(self : Engine) -> Array[Delta] {
  self.flush_delta_text()
  let out = self.deltas
  self.deltas = []
  out
}
