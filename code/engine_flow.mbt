// M2 engine (continued) — structure state machine, token scanners, finish and
// snapshot assembly. Same package as engine.mbt.

///|
/// Whether `u` may start a value.
fn is_value_start_char(u : UInt16) -> Bool {
  let n = u.to_int()
  n == 0x7B || n == 0x5B || is_quote_open(u) || is_ident_char(u)
}

///|
/// Dispatch on the document phase.
fn Engine::step_idle(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  match self.phase {
    PPrelude => self.step_prelude(u, p)
    PBody => self.step_body(u, p)
    PEpilogue => self.step_epilogue(u, p)
    PFinished | PFailed =>
      raise InvalidState("no input may be processed after finish")
  }
}

///|
/// Prelude: skip whitespace and BOM, optionally strip one code fence and
/// optionally skip prose before the first `{` or `[` (D08 8.4).
fn Engine::step_prelude(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  if is_ws(u) {
    return
  }
  if !self.saw_content {
    self.saw_content = true
    self.nojson_pos = p
  }
  if self.opts.skip_prose {
    let n = u.to_int()
    if n == 0x7B || n == 0x5B {
      if self.prose_skipped > 0 {
        self.report(SkipProse, Warning, self.prose_start)
      }
      self.phase = PBody
      self.step_body(u, p)
      return
    }
    if self.prose_skipped == 0 {
      self.prose_start = p
    }
    self.prose_skipped = self.prose_skipped + 1
    return
  }
  if self.opts.strip_fence && u.to_int() == 0x60 {
    self.tok = TFence(1)
    self.fence_start = p
    self.fence_body = true
    return
  }
  self.phase = PBody
  self.step_body(u, p)
}

///|
/// Trailing-junk policy after the first root value (D08 8.5).
fn Engine::epilogue_drop(self : Engine, p : Position) -> Unit raise MendError {
  match self.opts.multi_root {
    KeepFirst =>
      if !self.epilogue_reported {
        self.report(DropUnexpected, Warning, p)
        self.epilogue_reported = true
      }
    AsError =>
      raise StrictViolation(
        DropUnexpected,
        p,
        RepairCode::DropUnexpected.message(),
      )
    AsArray => ()
  }
}

///|
/// Epilogue: whitespace, code fence, extra closers, otherwise the multi-root
/// policy decides.
fn Engine::step_epilogue(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  if is_ws(u) {
    return
  }
  if self.epilogue_reported {
    return
  }
  let n = u.to_int()
  if self.opts.strip_fence && n == 0x60 {
    self.tok = TFence(1)
    self.fence_start = p
    self.fence_body = false
    return
  }
  if n == 0x2F {
    self.tok = TSlash
    self.tok_start = p
    return
  }
  if self.opts.multi_root is AsError {
    self.epilogue_drop(p)
    return
  }
  if n == 0x7D || n == 0x5D {
    self.report(DropExtraCloser, Info, p)
    return
  }
  self.epilogue_drop(p)
}

///|
/// Start whatever value `u` begins.
fn Engine::start_value_char(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  let n = u.to_int()
  if n == 0x7B {
    self.enter(FObj, p)
  } else if n == 0x5B {
    self.enter(FArr, p)
  } else if is_quote_open(u) {
    self.start_string(u, p, false)
  } else {
    self.start_bare(u, p, BareValue)
  }
}

///|
/// Start whatever key `u` begins.
fn Engine::start_key_char(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  if is_quote_open(u) {
    self.start_string(u, p, true)
  } else {
    self.start_bare(u, p, BareKey)
  }
}

///|
/// Push a container frame, enforcing `max_depth` (E020).
fn Engine::enter(
  self : Engine,
  kind : FrameKind,
  p : Position,
) -> Unit raise MendError {
  if self.stack.length() >= self.opts.max_depth {
    raise DepthLimit(self.opts.max_depth, p.offset)
  }
  self.stack.push(new_frame(kind, p, false))
}

///|
/// Body dispatch: root, array and object positions.
fn Engine::step_body(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  if is_ws(u) {
    return
  }
  let n = u.to_int()
  if self.stack.length() == 0 {
    if n == 0x7B {
      self.enter(FObj, p)
      return
    }
    if n == 0x5B {
      self.enter(FArr, p)
      return
    }
    if n == 0x2F {
      self.tok = TSlash
      self.tok_start = p
      return
    }
    if is_quote_open(u) {
      self.start_string(u, p, false)
      return
    }
    if is_ident_char(u) {
      self.start_bare(u, p, BareValue)
      return
    }
    // Anything else at a still-empty root (`}`, `]`, `@`, a fence, prose …)
    // means the document carries no JSON at all: E002 at the first
    // non-whitespace code unit (G-113, G-250, G-290).
    raise NoJsonFound(self.nojson_pos.offset)
  }
  let idx = self.stack.length() - 1
  let kind = self.stack[idx].kind
  let ctx = self.stack[idx].ctx
  match kind {
    FArr => self.step_in_array(idx, ctx, u, p)
    FObj => self.step_in_object(idx, ctx, u, p)
  }
}

///|
/// Structure transitions inside an array.
fn Engine::step_in_array(
  self : Engine,
  idx : Int32,
  ctx : Ctx,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  let n = u.to_int()
  if n == 0x2F {
    self.tok = TSlash
    self.tok_start = p
    return
  }
  match ctx {
    CArrValueOrEnd => {
      if n == 0x5D {
        self.close_container(p, false)
        return
      }
      if n == 0x7D {
        self.close_container(p, true)
        return
      }
      if n == 0x2C {
        self.report(RemoveExtraComma, Info, p)
        return
      }
      if is_value_start_char(u) {
        self.start_value_char(u, p)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    CArrCommaOrEnd => {
      if n == 0x2C {
        self.stack[idx].ctx = CArrValueOrEnd
        self.stack[idx].after_comma = true
        self.stack[idx].last_comma = p
        return
      }
      if n == 0x5D {
        self.close_container(p, false)
        return
      }
      if n == 0x7D {
        self.close_container(p, true)
        return
      }
      if is_value_start_char(u) {
        if !self.stack[idx].synthetic {
          self.report(InsertComma, Info, p)
        }
        self.start_value_char(u, p)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    _ => self.report(DropUnexpected, Warning, p)
  }
}

///|
/// Structure transitions inside an object.
fn Engine::step_in_object(
  self : Engine,
  idx : Int32,
  ctx : Ctx,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  let n = u.to_int()
  if n == 0x2F {
    self.tok = TSlash
    self.tok_start = p
    return
  }
  match ctx {
    CObjKeyOrEnd => {
      if is_quote_open(u) {
        self.start_string(u, p, true)
        return
      }
      if is_ident_char(u) {
        self.start_bare(u, p, BareKey)
        return
      }
      if n == 0x7D {
        self.close_container(p, false)
        return
      }
      if n == 0x5D {
        self.close_container(p, true)
        return
      }
      if n == 0x2C {
        self.report(RemoveExtraComma, Info, p)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    CObjColon => {
      if n == 0x3A {
        self.stack[idx].ctx = CObjValue
        return
      }
      if n == 0x7D || n == 0x5D || n == 0x2C {
        self.fill_null_and_replay(idx, p, u)
        return
      }
      if is_value_start_char(u) {
        self.report(InsertColon, Info, p)
        self.start_value_char(u, p)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    CObjValue => {
      if is_value_start_char(u) {
        self.start_value_char(u, p)
        return
      }
      if n == 0x7D || n == 0x5D || n == 0x2C {
        self.fill_null_and_replay(idx, p, u)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    CObjCommaOrEnd => {
      if n == 0x2C {
        self.stack[idx].ctx = CObjKeyOrEnd
        self.stack[idx].after_comma = true
        self.stack[idx].last_comma = p
        return
      }
      if n == 0x7D {
        self.close_container(p, false)
        return
      }
      if n == 0x5D {
        self.close_container(p, true)
        return
      }
      if is_quote_open(u) || is_ident_char(u) {
        self.report(InsertComma, Info, p)
        self.start_key_char(u, p)
        return
      }
      self.report(DropUnexpected, Warning, p)
    }
    _ => self.report(DropUnexpected, Warning, p)
  }
}

///|
/// Fill `null` for a key that never got a value (R008), then replay `u`.
fn Engine::fill_null_and_replay(
  self : Engine,
  idx : Int32,
  p : Position,
  u : UInt16,
) -> Unit raise MendError {
  self.report(FillNull, Warning, p)
  match self.stack[idx].last_key {
    Some(k) => self.assign(idx, k, Json::null())
    None => ()
  }
  self.stack[idx].last_key = None
  self.stack[idx].ctx = CObjCommaOrEnd
  self.step_body(u, p)
}

///|
/// Close the top container normally, reporting a mismatched closer and a
/// trailing comma when present.
fn Engine::close_container(
  self : Engine,
  p : Position,
  mismatch : Bool,
) -> Unit raise MendError {
  if mismatch {
    self.report(MismatchedCloser, Warning, p)
  }
  let idx = self.stack.length() - 1
  if self.stack[idx].after_comma {
    self.report(RemoveExtraComma, Info, self.stack[idx].last_comma)
  }
  let frame = self.stack.pop().unwrap()
  let v = match frame.kind {
    FObj => Json::object(frame.map)
    FArr => Json::array(frame.items)
  }
  self.value_done(v)
}

///|
/// Attach a completed value to the enclosing container, or finish the
/// document when there is none.
fn Engine::value_done(self : Engine, v : Json) -> Unit raise MendError {
  if self.stack.length() == 0 {
    match self.root {
      Some(_old) => ()
      None => {
        self.root = Some(v)
        self.phase = PEpilogue
      }
    }
    return
  }
  let idx = self.stack.length() - 1
  self.stack[idx].dirty = true
  if self.stack[idx].synthetic {
    self.stack[idx].items.push(v)
    self.stack[idx].ctx = CArrCommaOrEnd
    return
  }
  match self.stack[idx].kind {
    FArr => {
      self.stack[idx].items.push(v)
      self.stack[idx].ctx = CArrCommaOrEnd
      self.stack[idx].after_comma = false
    }
    FObj =>
      match self.stack[idx].last_key {
        Some(k) => {
          self.assign(idx, k, v)
          self.stack[idx].ctx = CObjCommaOrEnd
          self.stack[idx].after_comma = false
          self.stack[idx].last_key = None
        }
        None => self.stack[idx].ctx = CObjCommaOrEnd
      }
  }
}

///|
/// Insert a value under `k`, applying the duplicate-key policy (BR-19).
fn Engine::assign(
  self : Engine,
  idx : Int32,
  k : String,
  v : Json,
) -> Unit raise MendError {
  if self.stack[idx].map.contains(k) {
    match self.opts.duplicate_keys {
      KeepLast => {
        self.report(MergeDuplicateKey, Warning, self.stack[idx].key_pos)
        self.stack[idx].map[k] = v
      }
      KeepFirst =>
        self.report(MergeDuplicateKey, Warning, self.stack[idx].key_pos)
      AsError =>
        raise StrictViolation(
          MergeDuplicateKey,
          self.stack[idx].key_pos,
          RepairCode::MergeDuplicateKey.message(),
        )
    }
  } else {
    self.stack[idx].map[k] = v
  }
}

///|
/// Mark the current value slot as complete without producing a value (used
/// when an ellipsis placeholder is dropped).
fn Engine::mark_value_done_no_value(self : Engine) -> Unit {
  if self.stack.length() == 0 {
    return
  }
  let idx = self.stack.length() - 1
  match self.stack[idx].kind {
    FArr => self.stack[idx].ctx = CArrCommaOrEnd
    FObj => {
      self.stack[idx].ctx = CObjCommaOrEnd
      self.stack[idx].last_key = None
    }
  }
  self.stack[idx].after_comma = false
}

///|
/// Open a string token.
fn Engine::start_string(
  self : Engine,
  u : UInt16,
  p : Position,
  is_key : Bool,
) -> Unit raise MendError {
  if u.to_int() != 0x22 {
    self.report(NormalizeQuote, Info, p)
  }
  self.tok = TStr(str_kind_of(u), is_key)
  self.tok_start = p
  self.parts.clear()
  self.parts_len = 0
  self.esc = 0
  self.pending_high = 0
}

///|
/// Append one code unit of string content, enforcing `max_token_len`.
fn Engine::push_cu(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  if is_high_surrogate(u) {
    if self.pending_high != 0 {
      self.flush_lone_surrogate()
    }
    self.pending_high = u.to_int()
    self.pending_high_pos = p
    return
  }
  if is_low_surrogate(u) {
    if self.pending_high != 0 {
      let hi = self.pending_high
      self.pending_high = 0
      self.push_code_point(
        0x10000 + ((hi - 0xD800) << 10) + (u.to_int() - 0xDC00),
      )
    } else {
      self.report(FixEscape, Warning, p)
      self.push_code_point(0xFFFD)
    }
    return
  }
  self.push_plain(u.to_int())
}

///|
/// Append one code unit produced by a `\uXXXX` escape. Diagnostics point at
/// the backslash that opened the escape (G-224).
fn Engine::push_escaped_cu(
  self : Engine,
  v : Int32,
  p : Position,
) -> Unit raise MendError {
  if v >= 0xD800 && v <= 0xDBFF {
    if self.pending_high != 0 {
      self.flush_lone_surrogate()
    }
    self.pending_high = v
    self.pending_high_pos = p
    return
  }
  if v >= 0xDC00 && v <= 0xDFFF {
    if self.pending_high != 0 {
      let hi = self.pending_high
      self.pending_high = 0
      self.push_code_point(0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00))
    } else {
      self.report(FixEscape, Warning, p)
      self.push_code_point(0xFFFD)
    }
    return
  }
  self.push_plain(v)
}

///|
/// Append a scalar value.
fn Engine::push_code_point(self : Engine, cp : Int32) -> Unit raise MendError {
  match cp.to_char() {
    Some(c) => self.push_char(c)
    None => ()
  }
}

///|
/// Append an ASCII code unit.
fn Engine::push_char_code(self : Engine, code : Int32) -> Unit raise MendError {
  match code.to_char() {
    Some(c) => self.push_char(c)
    None => ()
  }
}

///|
/// Append plain (non-surrogate) content, flushing a pending half pair first.
fn Engine::push_plain(self : Engine, code : Int32) -> Unit raise MendError {
  if self.pending_high != 0 {
    self.flush_lone_surrogate()
  }
  self.push_char_code(code)
}

///|
/// Append a character and check the token length limit (E022).
fn Engine::push_char(self : Engine, c : Char) -> Unit raise MendError {
  self.parts.push(c.to_string())
  self.parts_len = self.parts_len + c.utf16_len()
  if self.parts_len > self.opts.max_token_len {
    raise TokenLimit(self.opts.max_token_len, self.tok_start.offset)
  }
}

///|
/// A half surrogate pair never completed: replace it with U+FFFD (R014).
fn Engine::flush_lone_surrogate(self : Engine) -> Unit raise MendError {
  let p = self.pending_high_pos
  self.pending_high = 0
  self.report(FixEscape, Warning, p)
  self.push_code_point(0xFFFD)
}

///|
/// String scanning (D08 8.6).
fn Engine::step_str(
  self : Engine,
  u : UInt16,
  p : Position,
  kind : StrKind,
  is_key : Bool,
) -> Unit raise MendError {
  if self.esc == 1 {
    self.esc = 0
    let n = u.to_int()
    if n == 0x75 {
      self.esc = 2
      self.esc_val = 0
      self.esc_digits = 0
      return
    }
    if n == 0x62 {
      self.push_plain(0x08)
      return
    }
    if n == 0x66 {
      self.push_plain(0x0C)
      return
    }
    if n == 0x6E {
      self.push_plain(0x0A)
      return
    }
    if n == 0x72 {
      self.push_plain(0x0D)
      return
    }
    if n == 0x74 {
      self.push_plain(0x09)
      return
    }
    if n == 0x22 {
      self.push_plain(0x22)
      return
    }
    if n == 0x2F {
      self.push_plain(0x2F)
      return
    }
    if n == 0x5C {
      self.push_plain(0x5C)
      return
    }
    self.report(FixEscape, Warning, self.esc_pos)
    self.push_cu(u, p)
    return
  }
  if self.esc >= 2 {
    if is_hex_digit(u) {
      self.esc_val = self.esc_val * 16 + hex_value(u)
      self.esc_digits = self.esc_digits + 1
      if self.esc_digits == 4 {
        self.esc = 0
        self.push_escaped_cu(self.esc_val, self.esc_pos)
      }
      return
    }
    self.esc = 0
    self.report(FixEscape, Warning, self.esc_pos)
    self.push_cu(u, p)
    return
  }
  if closes_str(kind, u) {
    if self.opts.quote_lookahead {
      self.tok = TStrPending(kind, is_key)
      self.pending_quote = u.to_int()
      self.pending_quote_pos = p
      self.pending_ws.reset()
      return
    }
    // The closing quote is consumed by the string scanner; the next code unit
    // is dispatched by the container state machine on the following step.
    self.tok = TIdle
    self.finish_string(is_key)
    return
  }
  if u.to_int() == 0x5C {
    self.esc = 1
    self.esc_pos = p
    return
  }
  if u.to_int() < 0x20 {
    self.report(EscapeControl, Warning, p)
  }
  self.push_cu(u, p)
}

///|
/// Quote lookahead: a candidate closing quote is only confirmed when the next
/// non-whitespace character can follow a value (D08 8.6, FR-14).
fn Engine::step_str_pending(
  self : Engine,
  u : UInt16,
  p : Position,
  kind : StrKind,
  is_key : Bool,
) -> Unit raise MendError {
  if is_ws(u) {
    match u.to_char() {
      Some(c) => self.pending_ws.write_char(c)
      None => ()
    }
    return
  }
  let n = u.to_int()
  if n == 0x2C || n == 0x7D || n == 0x5D || n == 0x3A || n == 0x2F {
    self.pending_ws.reset()
    self.tok = TIdle
    self.finish_string(is_key)
    self.step_idle(u, p)
    return
  }
  self.report(NormalizeQuote, Warning, self.pending_quote_pos)
  match self.pending_quote.to_char() {
    Some(q) => self.push_char(q)
    None => ()
  }
  let ws = self.pending_ws.to_string()
  self.pending_ws.reset()
  if ws.length() > 0 {
    self.parts.push(ws)
    self.parts_len = self.parts_len + ws.length()
  }
  self.tok = TStr(kind, is_key)
  self.step_str(u, p, kind, is_key)
}

///|
/// Complete the current string token, delivering it as a key or a value.
fn Engine::finish_string(self : Engine, is_key : Bool) -> Unit raise MendError {
  if self.pending_high != 0 {
    self.flush_lone_surrogate()
  }
  if self.esc != 0 {
    self.report(FixEscape, Warning, self.esc_pos)
    self.esc = 0
  }
  let text = self.parts_text()
  self.parts.clear()
  self.parts_len = 0
  if is_key {
    let idx = self.stack.length() - 1
    self.stack[idx].last_key = Some(text)
    self.stack[idx].key_pos = self.tok_start
    self.stack[idx].ctx = CObjColon
  } else {
    self.value_done(Json::string(text))
  }
}

///|
/// Open a bare token.
fn Engine::start_bare(
  self : Engine,
  u : UInt16,
  p : Position,
  kind : BareKind,
) -> Unit raise MendError {
  self.tok = TBare(kind)
  self.tok_start = p
  self.bare.reset()
  self.bare_len = 0
  self.push_bare_cu(u)
}

///|
/// Append a code unit to the bare token, enforcing `max_token_len`.
fn Engine::push_bare_cu(self : Engine, u : UInt16) -> Unit raise MendError {
  match u.to_char() {
    Some(c) => self.bare.write_char(c)
    None => ()
  }
  self.bare_len = self.bare_len + 1
  if self.bare_len > self.opts.max_token_len {
    raise TokenLimit(self.opts.max_token_len, self.tok_start.offset)
  }
}

///|
/// Bare token scanning.
fn Engine::step_bare(
  self : Engine,
  u : UInt16,
  p : Position,
  kind : BareKind,
) -> Unit raise MendError {
  if is_ident_char(u) {
    self.push_bare_cu(u)
    return
  }
  self.tok = TIdle
  self.classify_bare(kind)
  self.step_idle(u, p)
}

///|
/// Classify a finished bare token (D08 8.7).
fn Engine::classify_bare(
  self : Engine,
  kind : BareKind,
) -> Unit raise MendError {
  let text = self.bare.to_string()
  let start = self.tok_start
  self.bare.reset()
  self.bare_len = 0
  if text.length() == 0 {
    return
  }
  if text == "..." {
    self.report(DropEllipsis, Info, start)
    self.mark_value_done_no_value()
    return
  }
  if kind is BareKey {
    self.emit_bare_word(text, start, kind)
    return
  }
  let lower = ascii_lower(text)
  let lk = literal_kind(lower)
  if !(lk is LNone) {
    let canon = literal_canonical(lk)
    let v = match lk {
      LTrue => Json::boolean(true)
      LFalse => Json::boolean(false)
      LNull => Json::null()
      LNone => Json::null()
    }
    self.emit_literal(v, text == canon, start)
    return
  }
  if is_non_finite(lower) {
    self.emit_non_finite(text, start)
    return
  }
  if is_number_start(text.at(0)) && is_number_shaped(text) {
    match normalize_number(text) {
      Some(txt) => {
        if txt != text {
          self.report(FixNumber, Info, start)
        }
        self.value_done(build_number(txt))
      }
      None => self.emit_numberless(start)
    }
    return
  }
  self.emit_bare_word(text, start, kind)
}

///|
/// Literal or literal-prefix conversion (R012).
fn Engine::emit_literal(
  self : Engine,
  v : Json,
  exact : Bool,
  start : Position,
) -> Unit raise MendError {
  if !exact {
    self.report(ConvertLiteral, Warning, start)
  }
  self.value_done(v)
}

///|
/// `NaN` / `Infinity` handling (BR-12).
fn Engine::emit_non_finite(
  self : Engine,
  text : String,
  start : Position,
) -> Unit raise MendError {
  match self.opts.non_finite {
    AsNull => {
      self.report(ConvertLiteral, Warning, start)
      self.value_done(Json::null())
    }
    AsString => {
      self.report(ConvertLiteral, Warning, start)
      self.value_done(Json::string(text))
    }
    AsError =>
      raise StrictViolation(
        ConvertLiteral,
        start,
        RepairCode::ConvertLiteral.message(),
      )
  }
}

///|
/// A number-shaped token with no usable prefix: `null` in an object, dropped
/// in an array, `E002` at the root (G-076, G-077, G-133).
fn Engine::emit_numberless(
  self : Engine,
  start : Position,
) -> Unit raise MendError {
  if self.stack.length() == 0 {
    raise NoJsonFound(start.offset)
  }
  let idx = self.stack.length() - 1
  match self.stack[idx].kind {
    FArr => {
      self.report(FixNumber, Info, start)
      self.mark_value_done_no_value()
    }
    FObj => {
      self.report(FillNull, Warning, start)
      match self.stack[idx].last_key {
        Some(k) => self.assign(idx, k, Json::null())
        None => ()
      }
      self.stack[idx].last_key = None
      self.stack[idx].ctx = CObjCommaOrEnd
    }
  }
}

///|
/// A word that is neither literal nor number: quoted as a key (R004, Info) or
/// as a string value (R004, Warning); `E002` at the root (BR-07).
fn Engine::emit_bare_word(
  self : Engine,
  text : String,
  start : Position,
  kind : BareKind,
) -> Unit raise MendError {
  match kind {
    BareKey => {
      self.report(QuoteBareWord, Info, start)
      let idx = self.stack.length() - 1
      self.stack[idx].last_key = Some(text)
      self.stack[idx].key_pos = start
      self.stack[idx].ctx = CObjColon
    }
    BareValue => {
      if self.stack.length() == 0 {
        raise NoJsonFound(start.offset)
      }
      self.report(QuoteBareWord, Warning, start)
      self.value_done(Json::string(text))
    }
  }
}

///|
/// `/` seen: decide between line comment, block comment and a dropped slash.
fn Engine::step_slash(
  self : Engine,
  u : UInt16,
  p : Position,
) -> Unit raise MendError {
  let n = u.to_int()
  if n == 0x2F {
    self.tok = TLineComment
    self.report(StripComment, Info, self.tok_start)
    return
  }
  if n == 0x2A {
    self.tok = TBlockComment
    self.block_star = false
    self.report(StripComment, Info, self.tok_start)
    return
  }
  self.tok = TIdle
  self.report(DropUnexpected, Warning, self.tok_start)
  self.step_idle(u, p)
}

///|
/// Block comment scanning, including the `*` / `/` pair.
fn Engine::step_block(self : Engine, u : UInt16, _p : Position) -> Unit {
  let n = u.to_int()
  if n == 0x2A {
    self.block_star = true
    return
  }
  if self.block_star && n == 0x2F {
    self.block_star = false
    self.tok = TIdle
    return
  }
  self.block_star = false
}

///|
/// Code fence scanning: three backticks then the rest of the line.
fn Engine::step_fence(
  self : Engine,
  u : UInt16,
  p : Position,
  count : Int32,
) -> Unit raise MendError {
  if u.to_int() == 0x60 {
    if count + 1 >= 3 {
      self.report(StripFence, Info, self.fence_start)
      self.tok = TFenceLine
    } else {
      self.tok = TFence(count + 1)
    }
    return
  }
  match self.phase {
    PPrelude => raise NoJsonFound(self.fence_start.offset)
    _ => {
      self.tok = TIdle
      self.epilogue_drop(p)
    }
  }
}

///|
/// End of a fence line.
fn Engine::finish_fence_line(self : Engine) -> Unit {
  self.tok = TIdle
  if self.fence_body {
    self.fence_body = false
    self.phase = PBody
  }
}

///|
/// Flush the last unfinished token when the input ends (D08 8.11).
fn Engine::finalize_token(self : Engine) -> Unit raise MendError {
  match self.tok {
    TIdle => ()
    TStr(_kind, is_key) => {
      self.tok = TIdle
      if self.pending_high != 0 {
        self.flush_lone_surrogate()
      }
      if self.esc != 0 {
        self.report(FixEscape, Warning, self.esc_pos)
        self.esc = 0
      }
      self.report(CloseString, Warning, self.pos)
      self.finish_string(is_key)
    }
    TStrPending(_kind, is_key) => {
      self.tok = TIdle
      self.finish_string(is_key)
    }
    TBare(kind) => {
      self.tok = TIdle
      self.classify_bare(kind)
    }
    TSlash => {
      self.tok = TIdle
      self.report(DropUnexpected, Warning, self.tok_start)
    }
    TLineComment | TBlockComment | TFence(_) | TFenceLine => self.tok = TIdle
  }
}

///|
/// Close one still-open container at end of input (D08 8.11).
fn Engine::unwind_top(self : Engine) -> Bool raise MendError {
  let idx = self.stack.length() - 1
  let f = self.stack[idx]
  if f.synthetic {
    self.stack.pop() |> ignore
    if f.dirty {
      self.root = Some(Json::array(f.items))
      self.phase = PEpilogue
      return true
    }
    return false
  }
  match f.kind {
    FObj => {
      if f.ctx is CObjColon || f.ctx is CObjValue {
        match f.last_key {
          Some(k) => {
            self.report(FillNull, Warning, self.pos)
            self.assign(idx, k, Json::null())
          }
          None => ()
        }
      } else if f.after_comma {
        self.report(RemoveExtraComma, Info, f.last_comma)
      }
      self.report(CloseContainer, Warning, self.pos)
      self.stack.pop() |> ignore
      self.value_done(Json::object(f.map))
      true
    }
    FArr => {
      if f.after_comma {
        self.report(RemoveExtraComma, Info, f.last_comma)
      }
      self.report(CloseContainer, Warning, self.pos)
      self.stack.pop() |> ignore
      self.value_done(Json::array(f.items))
      true
    }
  }
}

///|
/// Finish the document: flush the token, close open containers, produce text.
fn Engine::finish_engine(self : Engine) -> FinalResult raise MendError {
  match self.phase {
    PFinished | PFailed =>
      raise InvalidState("finish called on a finished parser")
    _ => ()
  }
  if self.utf8_need != 0 {
    self.utf8_need = 0
    raise InvalidUtf8(0)
  }
  self.finalize_token()
  let mut unwound = false
  while self.stack.length() > 0 {
    if self.unwind_top() {
      unwound = true
    }
  }
  match self.root {
    Some(value) => {
      self.phase = PFinished
      let text = if self.opts.want_text {
        render(value, self.opts.indent)
      } else {
        ""
      }
      { text, value, repairs: self.reps, completeness: Complete, }
    }
    None => {
      self.phase = PFailed
      if !self.saw_content && !unwound {
        raise EmptyInput
      }
      raise NoJsonFound(self.nojson_pos.offset)
    }
  }
}

///|
/// Current string content as text.
fn Engine::parts_text(self : Engine) -> String {
  let sb = StringBuilder()
  for part in self.parts {
    sb.write_string(part)
  }
  sb.to_string()
}

///|
/// Value of the unfinished scalar token, if it may appear in a snapshot.
fn Engine::pending_element(self : Engine) -> Json? {
  match self.tok {
    TStr(_kind, is_key) =>
      if is_key {
        None
      } else {
        Some(Json::string(self.parts_text()))
      }
    TStrPending(_kind, is_key) =>
      if is_key {
        None
      } else {
        Some(Json::string(self.parts_text()))
      }
    TBare(kind) =>
      match kind {
        BareKey => None
        BareValue => self.pending_bare()
      }
    _ => None
  }
}

///|
/// Whether an unfinished bare token can be shown as a number (FR-11).
fn Engine::pending_bare(self : Engine) -> Json? {
  if self.opts.incomplete_number is Drop {
    return None
  }
  let text = self.bare.to_string()
  if text.length() == 0 {
    return None
  }
  let lower = ascii_lower(text)
  if !(literal_kind(lower) is LNone) || is_non_finite(lower) {
    return None
  }
  if !is_number_shaped(text) {
    return None
  }
  match normalize_number(text) {
    Some(txt) => Some(build_number(txt))
    None => None
  }
}

///|
/// Partial value of the frame at `i`, with `elem` standing in for the value
/// currently being built inside it.
fn Engine::partial_frame(self : Engine, i : Int32, elem : Json?) -> Json {
  let f = self.stack[i]
  match f.kind {
    FArr => {
      let items = f.items.copy()
      match elem {
        Some(v) => items.push(v)
        None => ()
      }
      Json::array(items)
    }
    FObj => {
      let map = f.map.copy()
      match f.last_key {
        Some(k) =>
          if f.ctx is CObjColon || f.ctx is CObjValue {
            match elem {
              Some(v) => map[k] = v
              None =>
                if self.opts.pending_key is NullKey {
                  map[k] = Json::null()
                }
            }
          }
        None => ()
      }
      Json::object(map)
    }
  }
}

///|
/// Assemble the partial value from the container stack.
fn Engine::snapshot_value(self : Engine) -> Json? {
  if self.stack.length() == 0 {
    match self.root {
      Some(v) => Some(v)
      None => self.pending_element()
    }
  } else {
    let n = self.stack.length()
    let mut acc : Json? = None
    let mut i = n - 1
    while i >= 0 {
      let elem = if i == n - 1 { self.pending_element() } else { acc }
      acc = Some(self.partial_frame(i, elem))
      i = i - 1
    }
    acc
  }
}

///|
/// Snapshot completeness (FR-09).
fn Engine::completeness(self : Engine) -> Completeness {
  if self.stack.length() > 0 {
    return Partial
  }
  match self.root {
    Some(_v) => Complete
    None =>
      match self.pending_element() {
        Some(_v) => Partial
        None => Empty
      }
  }
}

///|
/// Path of the value currently being built.
fn Engine::open_path(self : Engine) -> Array[PathSegment] {
  let out : Array[PathSegment] = []
  for i = 0; i < self.stack.length(); i = i + 1 {
    let f = self.stack[i]
    if f.synthetic {
      continue
    }
    match f.kind {
      FObj =>
        match f.last_key {
          Some(k) => out.push(Key(k))
          None => ()
        }
      FArr => out.push(Index(f.items.length()))
    }
  }
  out
}

///|
/// Take a snapshot without mutating engine state (FR-10).
fn Engine::snapshot(self : Engine) -> Snapshot {
  {
    value: self.snapshot_value(),
    completeness: self.completeness(),
    open_path: self.open_path(),
  }
}
