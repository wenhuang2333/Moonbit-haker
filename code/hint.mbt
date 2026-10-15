// FR-28 — reject as feedback.
//
// `for_execution()` refuses a result instead of returning a wrong value. That
// refusal is only useful to an agent loop if it can be handed back to the model
// that produced the input, so this file turns the fatal error into a short,
// structured instruction. Nothing here calls a model: `to_prompt()` returns
// text, and the caller decides where to send it.

///|
/// One actionable refusal, ready to be fed back to the model that produced the
/// arguments (FR-28).
pub(all) struct RetryHint {
  /// The `E` code that was raised, e.g. `E011`.
  error_code : String
  /// The `R` code of the refused repair, e.g. `R006`.
  repair_code : String
  /// Stable name of that repair, e.g. `InsertComma`.
  repair_name : String
  /// Where the refused repair sits in the input.
  position : Position
  /// The second reading, when the refusal was an ambiguity (FR-27).
  ambiguity : Ambiguity
  /// Why the repair could not be accepted.
  reason : String
  /// The code units around `position`, when the caller passed the input.
  context : String
  /// Index of `position` inside `context`.
  caret : Int32
}

///|
/// Explicit `Eq` implementation for `RetryHint` (structural, for tests).
pub impl Eq for RetryHint with fn equal(self : RetryHint, other : RetryHint) -> Bool {
  self.error_code == other.error_code &&
  self.repair_code == other.repair_code &&
  self.position.offset == other.position.offset
}

///|
/// Explicit `Eq` extension for `RetryHint`.
pub extend RetryHint with Eq::{not_equal, equal}

///|
/// Window of `text` around `offset`: `radius` code units on each side, with
/// the offset itself always inside (FR-28). Never embeds the input in a
/// structured field, so the caller chooses what to show.
pub fn hint_context(
  text : String,
  offset : Int32,
  radius : Int32,
) -> (String, Int32) {
  let n = text.length()
  let off = if offset < 0 { 0 } else if offset > n { n } else { offset }
  let r = if radius < 0 { 0 } else { radius }
  let start = if off - r < 0 { 0 } else { off - r }
  let end = if off + r + 1 > n { n } else { off + r + 1 }
  let sb = StringBuilder()
  for i = start; i < end; i = i + 1 {
    sb.write_char(Int32::unsafe_to_char(text.at(i).to_int()))
  }
  (sb.to_string(), off - start)
}

///|
/// Build the hint for a refusal. Returns `None` for every error that is not a
/// refusal of a repair (`EmptyInput`, `SizeLimit`, …), because those are not
/// something the model can fix by re-emitting its arguments.
///
/// `input` is optional: without it the hint still names the position, but it
/// cannot quote the surrounding text.
pub fn RetryHint::of_error(
  e : MendError,
  input? : String,
  radius? : Int32,
) -> RetryHint? {
  let r = if radius is Some(v) { v } else { 24 }
  let (code, pos, ambiguity, reason) = match e {
    StrictViolation(c, p, msg) => (c, p, Unambiguous, msg)
    AmbiguousRepair(c, p, a) => (c, p, a, a.message())
    _ => return None
  }
  let (context, caret) = match input {
    Some(text) => hint_context(text, pos.offset, r)
    None => ("", 0)
  }
  Some({
    error_code: e.code(),
    repair_code: code.code(),
    repair_name: code.name(),
    position: pos,
    ambiguity,
    reason,
    context,
    caret,
  })
}

///|
/// Render the hint as a prompt fragment (FR-28). Stable across releases; the
/// wording is part of the contract, so it is covered by a test.
///
/// The rendering never contains the whole input, only the window around the
/// refused position, so a caller can put it in a retry message as is.
pub fn RetryHint::to_prompt(self : RetryHint) -> String {
  let sb = StringBuilder()
  sb.write_string("JSONMend refused the arguments: ")
  sb.write_string(self.error_code)
  sb.write_string(" ")
  sb.write_string(self.repair_code)
  sb.write_string(" ")
  sb.write_string(self.repair_name)
  sb.write_string(" at line ")
  sb.write_string(self.position.line.to_string())
  sb.write_string(" column ")
  sb.write_string(self.position.column.to_string())
  sb.write_string(" (offset ")
  sb.write_string(self.position.offset.to_string())
  sb.write_string(").\nReason: ")
  sb.write_string(self.reason)
  if self.ambiguity.is_ambiguous() {
    sb.write_string("\nAmbiguity: ")
    sb.write_string(self.ambiguity.name())
  }
  if self.context != "" {
    sb.write_string("\nContext: ")
    sb.write_string(self.context)
    sb.write_string("\n")
    let mut i = 0
    while i < self.caret + 9 {
      sb.write_char(' ')
      i = i + 1
    }
    sb.write_char('^')
  }
  sb.write_string(
    "\nRe-emit the arguments as valid JSON with exactly one reading.",
  )
  sb.to_string()
}

///|
/// One line form, for `--report` and logs.
pub fn RetryHint::to_string(self : RetryHint) -> String {
  self.error_code +
  " " +
  self.repair_code +
  " " +
  self.repair_name +
  " at " +
  self.position.line.to_string() +
  ":" +
  self.position.column.to_string() +
  " " +
  self.reason
}

///|
/// Convenience: the hint of a refusal, or `None`.
pub fn MendError::retry_hint(
  self : MendError,
  input? : String,
  radius? : Int32,
) -> RetryHint? {
  match (input, radius) {
    (Some(text), Some(r)) => RetryHint::of_error(self, input=text, radius=r)
    (Some(text), None) => RetryHint::of_error(self, input=text)
    (None, Some(r)) => RetryHint::of_error(self, radius=r)
    (None, None) => RetryHint::of_error(self)
  }
}
