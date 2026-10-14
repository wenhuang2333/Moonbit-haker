// M5 options — the option dictionary of D04 4.6, with defaults and validation.

///|
/// Repair mode. `Strict` turns the first repair record into `E010`.
pub(all) enum Mode {
  Lenient
  Strict
}

///|
/// Explicit `Eq` implementation for `Mode`.
pub impl Eq for Mode with fn equal(self : Mode, other : Mode) -> Bool {
  (self is Lenient && other is Lenient) || (self is Strict && other is Strict)
}

///|
/// Explicit `Eq` extension for `Mode`.
pub extend Mode with Eq::{not_equal, equal}

///|
/// Policy for duplicate object keys (BR-19).
pub(all) enum DuplicateKeys {
  KeepLast
  KeepFirst
  AsError
}

///|
/// Explicit `Eq` implementation for `DuplicateKeys`.
pub impl Eq for DuplicateKeys with fn equal(
  self : DuplicateKeys,
  other : DuplicateKeys,
) -> Bool {
  (self is KeepLast && other is KeepLast) ||
  (self is KeepFirst && other is KeepFirst) ||
  (self is AsError && other is AsError)
}

///|
/// Explicit `Eq` extension for `DuplicateKeys`.
pub extend DuplicateKeys with Eq::{not_equal, equal}

///|
/// How an unterminated number appears in a snapshot (FR-11).
pub(all) enum IncompleteNumber {
  Drop
  TrimToValid
}

///|
/// Explicit `Eq` implementation for `IncompleteNumber`.
pub impl Eq for IncompleteNumber with fn equal(
  self : IncompleteNumber,
  other : IncompleteNumber,
) -> Bool {
  (self is Drop && other is Drop) ||
  (self is TrimToValid && other is TrimToValid)
}

///|
/// Explicit `Eq` extension for `IncompleteNumber`.
pub extend IncompleteNumber with Eq::{not_equal, equal}

///|
/// How a dangling key (key with colon but no value) appears in a snapshot.
pub(all) enum PendingKey {
  OmitKey
  NullKey
}

///|
/// Explicit `Eq` implementation for `PendingKey`.
pub impl Eq for PendingKey with fn equal(self : PendingKey, other : PendingKey) -> Bool {
  (self is OmitKey && other is OmitKey) || (self is NullKey && other is NullKey)
}

///|
/// Explicit `Eq` extension for `PendingKey`.
pub extend PendingKey with Eq::{not_equal, equal}

///|
/// How `NaN`, `Infinity` and `-Infinity` are converted (BR-12).
pub(all) enum NonFinite {
  AsNull
  AsError
  AsString
}

///|
/// Explicit `Eq` implementation for `NonFinite`.
pub impl Eq for NonFinite with fn equal(self : NonFinite, other : NonFinite) -> Bool {
  (self is AsNull && other is AsNull) ||
  (self is AsError && other is AsError) ||
  (self is AsString && other is AsString)
}

///|
/// Explicit `Eq` extension for `NonFinite`.
pub extend NonFinite with Eq::{not_equal, equal}

///|
/// Policy for content after the first root value (FR-15).
pub(all) enum MultiRoot {
  KeepFirst
  AsArray
  AsError
}

///|
/// Explicit `Eq` implementation for `MultiRoot`.
pub impl Eq for MultiRoot with fn equal(self : MultiRoot, other : MultiRoot) -> Bool {
  (self is KeepFirst && other is KeepFirst) ||
  (self is AsArray && other is AsArray) ||
  (self is AsError && other is AsError)
}

///|
/// Explicit `Eq` extension for `MultiRoot`.
pub extend MultiRoot with Eq::{not_equal, equal}

///|
/// Per-rule switches. Disabling a rule makes that single code raise `E010`
/// instead of being recorded (D09 9.5).
pub(all) struct RuleSet {
  priv flags : Array[Bool]
}

///|
/// All rules enabled.
pub fn RuleSet::all() -> RuleSet {
  let flags : Array[Bool] = []
  for _i = 0; _i < 22; _i = _i + 1 {
    flags.push(true)
  }
  { flags, }
}

///|
/// A copy of this rule set with one rule disabled.
pub fn RuleSet::disable(self : RuleSet, code : RepairCode) -> RuleSet {
  let flags : Array[Bool] = []
  for i = 0; i < self.flags.length(); i = i + 1 {
    flags.push(self.flags[i])
  }
  let n = code.number()
  if n >= 0 && n < flags.length() {
    flags[n] = false
  }
  { flags, }
}

///|
/// A copy of this rule set with one rule enabled.
pub fn RuleSet::enable(self : RuleSet, code : RepairCode) -> RuleSet {
  let flags : Array[Bool] = []
  for i = 0; i < self.flags.length(); i = i + 1 {
    flags.push(self.flags[i])
  }
  let n = code.number()
  if n >= 0 && n < flags.length() {
    flags[n] = true
  }
  { flags, }
}

///|
/// Whether a repair code may be reported without raising `E010`.
pub fn RuleSet::is_enabled(self : RuleSet, code : RepairCode) -> Bool {
  let n = code.number()
  if n >= 0 && n < self.flags.length() {
    self.flags[n]
  } else {
    true
  }
}

///|
/// All options. Defaults are the ones documented in D04 4.6.
pub(all) struct Options {
  mode : Mode
  max_depth : Int32
  max_input_len : Int32
  max_token_len : Int32
  duplicate_keys : DuplicateKeys
  incomplete_number : IncompleteNumber
  pending_key : PendingKey
  non_finite : NonFinite
  strip_fence : Bool
  collect_repairs : Bool
  want_text : Bool
  skip_prose : Bool
  quote_lookahead : Bool
  multi_root : MultiRoot
  rules : RuleSet
  indent : Int32
  max_repairs : Int32
}

///|
/// Documented defaults: lenient, depth 512, 64 Mi code units, duplicate keys
/// keep the last value, snapshots drop unfinished numbers, all rules on.
pub fn Options::default() -> Options {
  {
    mode: Lenient,
    max_depth: 512,
    max_input_len: 67108864,
    max_token_len: 16777216,
    duplicate_keys: KeepLast,
    incomplete_number: Drop,
    pending_key: OmitKey,
    non_finite: AsNull,
    strip_fence: true,
    collect_repairs: true,
    want_text: true,
    skip_prose: false,
    quote_lookahead: false,
    multi_root: KeepFirst,
    rules: RuleSet::all(),
    indent: 0,
    max_repairs: 10000,
  }
}

///|
/// Validate option values, raising `E050` for anything out of range.
pub fn Options::validate(self : Options) -> Unit raise MendError {
  if self.max_depth <= 0 {
    raise InvalidOption("max_depth must be a positive integer")
  }
  if self.max_input_len <= 0 {
    raise InvalidOption("max_input_len must be a positive integer")
  }
  if self.max_token_len <= 0 {
    raise InvalidOption("max_token_len must be a positive integer")
  }
  if self.indent < 0 {
    raise InvalidOption("indent must not be negative")
  }
  if self.max_repairs <= 0 {
    raise InvalidOption("max_repairs must be a positive integer")
  }
}
