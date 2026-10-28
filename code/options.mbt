// M5 options — the option dictionary of D04 4.6, with defaults and validation.

///|
/// The deepest a parsed value may nest, and the ceiling on
/// `Options::max_depth`.
///
/// Every walk over a value is iterative -- `copy_json`, `json_equal`,
/// `Schema::evaluate` and the renderer all carry an explicit work list -- so
/// the depth a caller may configure is bounded by the heap, not by the native
/// stack. That is what lets this number be a *sanity bound* rather than a
/// stack bound: it exists so that a typo cannot ask for an allocation the
/// machine cannot make, not to stop a caller going deeper than the engine can.
///
/// The history matters, because the ceiling used to be 512 and the reason was
/// different. `copy_json`, `json_equal` and `walk_schema` were recursive, and
/// the wasm backend's stack overflows somewhere between 896 and 1024 frames;
/// capping `max_depth` at 512 was the only way to keep "a refusal, never a
/// crash" true, and it had the side effect that a caller could tighten the
/// limit but never loosen it. Making the walks iterative removed the reason,
/// so the ceiling is now one million: far above any document, and still a
/// number rather than infinity.
pub const MAX_VALUE_DEPTH : Int32 = 1048576

///|
/// The deepest a *declaration* may nest (JSON Schema or the library's skeleton
/// language), and the ceiling on `Options::max_depth` when reading one.
///
/// Declarations are still parsed recursively by the two schema parsers, so this
/// one really is a stack bound and is deliberately much lower than
/// `MAX_VALUE_DEPTH`. A declaration 256 levels deep is already far past what
/// any real tool schema needs; a value 512 levels deep is a document.
pub const MAX_SCHEMA_DEPTH : Int32 = 256

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
///
/// The size is derived from `RepairCode::count()` rather than written as a
/// literal. It used to be the literal `22`, which was wrong the moment it was
/// written: `RepairCode::number()` is 1-based, so a 22-slot array covers
/// `R001` … `R021` and leaves `R022 NormalizeLiteral` — the code added in the
/// same release — outside the table. `is_enabled` then fell into its
/// out-of-range branch, which returned `true`, so `R022` looked enabled while
/// `disable(R022)` was a silent no-op: a caller could not switch the rule off,
/// and nothing said so. Sizing the table from the enum removes the class of
/// bug rather than the instance.
pub fn RuleSet::all() -> RuleSet {
  let flags : Array[Bool] = []
  // Slot 0 is unused: `number()` is 1-based so that `R001` reads as 1.
  for _i = 0; _i <= RepairCode::count(); _i = _i + 1 {
    flags.push(true)
  }
  { flags, }
}

///|
/// A copy of this rule set with one rule disabled.
///
/// Disabling a rule that is outside the table is refused loudly rather than
/// ignored: a silent no-op here means the caller believes a repair is
/// switched off when it is not, which is a fail-open configuration bug. The
/// table is sized from the enum, so the only way to reach this branch is a
/// programming error, and it should be reported as one.
pub fn RuleSet::disable(self : RuleSet, code : RepairCode) -> RuleSet {
  let flags : Array[Bool] = []
  for i = 0; i < self.flags.length(); i = i + 1 {
    flags.push(self.flags[i])
  }
  let n = code.number()
  if n < 0 || n >= flags.length() {
    abort(
      "RuleSet::disable: " +
      code.code() +
      " has no slot in the rule table (" +
      flags.length().to_string() +
      " slots)",
    )
  }
  flags[n] = false
  { flags, }
}

///|
/// A copy of this rule set with one rule enabled. Out of range aborts, for the
/// same reason `disable` does.
pub fn RuleSet::enable(self : RuleSet, code : RepairCode) -> RuleSet {
  let flags : Array[Bool] = []
  for i = 0; i < self.flags.length(); i = i + 1 {
    flags.push(self.flags[i])
  }
  let n = code.number()
  if n < 0 || n >= flags.length() {
    abort(
      "RuleSet::enable: " +
      code.code() +
      " has no slot in the rule table (" +
      flags.length().to_string() +
      " slots)",
    )
  }
  flags[n] = true
  { flags, }
}

///|
/// Whether a repair code may be reported without raising `E010`.
///
/// A code with no slot is NOT enabled: the answer must fail closed. The
/// previous `true` meant a rule the table did not know about ran anyway, and
/// a rule that runs is a rule the caller cannot refuse.
pub fn RuleSet::is_enabled(self : RuleSet, code : RepairCode) -> Bool {
  let n = code.number()
  if n >= 0 && n < self.flags.length() {
    self.flags[n]
  } else {
    false
  }
}

///|
/// Whether two rule sets enable exactly the same rules (FR-30). Used to decide
/// whether an options value still matches a named safety profile.
pub fn RuleSet::same_as(self : RuleSet, other : RuleSet) -> Bool {
  if self.flags.length() != other.flags.length() {
    return false
  }
  for i = 0; i < self.flags.length(); i = i + 1 {
    if self.flags[i] != other.flags[i] {
      return false
    }
  }
  true
}

///|
/// All options. Defaults are the ones documented in D04 4.6.
pub(all) struct Options {
  mode : Mode
  max_depth : Int32
  max_input_len : Int32
  max_token_len : Int32
  /// How much skipped prelude is kept so that `finish` can retry it as JSON.
  /// `skip_prose` only recognises `{` or `[`, so a scalar root looks exactly
  /// like prose while it is being read; keeping the text is what lets the
  /// retry recover it. Beyond this bound the skipped text is dropped and the
  /// document is refused as before, which keeps the memory cost of a
  /// pathological input bounded.
  max_prose_buffer : Int32
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
  /// Highest exactness a result may have (FR-17). `Lossy` accepts anything and
  /// therefore never changes behaviour.
  max_loss : Exactness
  /// Record incremental deltas so that `PartialParser::drain_deltas` can return
  /// them (FR-18). Off by default: tracking costs work and memory.
  collect_deltas : Bool
  /// Refuse a repair that admits a second reading (FR-27): the first ambiguous
  /// record raises `E011` instead of being recorded. Off by default.
  reject_ambiguous : Bool
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
    max_prose_buffer: 65536,
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
    max_loss: Lossy,
    collect_deltas: false,
    reject_ambiguous: false,
  }
}

// ---------------------------------------------------------------------------
// Presets (FR-19). `Options` has eighteen fields; most callers only need one
// of three profiles.
// ---------------------------------------------------------------------------

///|
/// The documented defaults: lenient, every rule on, no exactness gate, no
/// delta tracking. Equivalent to `Options::default()`.
pub fn Options::lenient() -> Options {
  Options::default()
}

///|
/// Reject any input that needs a repair: the first recorded repair becomes
/// `E010`. Equivalent to `{ ..Options::default(), mode: Strict }`.
pub fn Options::strict() -> Options {
  { ..Options::default(), mode: Strict, }
}

///|
/// Profile for consuming a large language model's tool-call arguments
/// (FR-18, FR-19): the documented defaults plus `collect_deltas`, so that
/// `PartialParser::drain_deltas` is available. `duplicate_keys` stays
/// `KeepLast` and `incomplete_number` stays `Drop`, which are the two settings
/// a delta stream can express.
pub fn Options::for_llm() -> Options {
  { ..Options::default(), collect_deltas: true, }
}

///|
/// Profile for a caller that will execute the parsed value (FR-17, FR-27):
/// notation repairs are accepted, but a repair that admits a second reading
/// raises `E011` and anything that invented, dropped or truncated a value
/// raises `E010`. Distinct from `strict()`, which rejects even a normalised
/// quote, and from `lenient()`, which accepts both.
pub fn Options::for_execution() -> Options {
  { ..Options::default(), max_loss: Cosmetic, reject_ambiguous: true, }
}

///|
/// Profile for an agent loop that streams a tool call and hands a refusal back
/// to the model (FR-28, FR-30): the execution policy's safety knobs plus the
/// protocol an agent channel needs — the delta stream
/// (`collect_deltas: true`, from `for_llm()`) so a consumer can follow the
/// value as it is written, and `skip_prose: true` because a model that answers
/// in a chat channel often prefixes the arguments with a sentence and the
/// prefix is not part of the arguments.
///
/// The safety knobs are the agent profile's; what a *streaming* agent adds is
/// protocol, so this is `SafetyPolicy::for_agent()` with the delta stream and
/// prose handling turned on. There is exactly one definition of the agent
/// profile, and `SafetyPolicy::of_options` reads it back.
pub fn Options::for_agent() -> Options {
  {
    ..SafetyPolicy::for_agent().to_options(),
    collect_deltas: true,
    skip_prose: true,
  }
}

///|
/// The options a named profile denotes when applied to `self`, protocol
/// included. This is what a caller that selects a profile *by name* — the
/// MCP tools, `--policy`, `serve` — must use, so that the profile it selects
/// and the library preset of the same name agree.
pub fn Options::for_profile(self : Options, name : String) -> Options? {
  match name {
    "permissive" => Some(self.with_profile(SafetyPolicy::permissive()))
    "interactive" => Some(self.with_profile(SafetyPolicy::interactive()))
    "execution" => Some(self.with_profile(SafetyPolicy::for_execution()))
    "agent" => Some(self.with_profile(SafetyPolicy::for_agent()))
    "strict" => Some(self.with_profile(SafetyPolicy::strict()))
    _ => None
  }
}

///|
/// Profile for a caller whose only output is the repaired text — a pipe, a log
/// line, a file rewrite (FR-30). The value is what is wanted and nothing else
/// is: no repair records are kept (they cost an allocation per repair and an
/// array that grows with the input) and the text is compact.
///
/// This is a preset, not a separate engine mode: the tree is still built
/// internally, because the duplicate-key policy, `+` concatenation and the
/// `fill_null` replay all read the value that was already accepted (see
/// `docs/RULES.md` §2.4 for why the value cannot simply be dropped).
pub fn Options::for_text() -> Options {
  { ..Options::default(), collect_repairs: false, indent: 0, want_text: true, }
}

///|
/// Validate option values, raising `E050` for anything out of range.
pub fn Options::validate(self : Options) -> Unit raise InterJSONError {
  if self.max_depth <= 0 {
    raise InvalidOption("max_depth must be a positive integer")
  }
  // The ceiling is not a policy choice: three recursive walks (`copy_json`,
  // `json_equal`, `walk_schema`) and the engine's own frame stack are bounded
  // by it, and a caller that asks for a deeper limit would get a stack
  // overflow where it asked for an `E020`. Refusing the option turns a crash
  // into a documented `E050`.
  if self.max_depth > MAX_VALUE_DEPTH {
    raise InvalidOption(
      "max_depth must not exceed " +
      MAX_VALUE_DEPTH.to_string() +
      "; deeper values are refused rather than parsed",
    )
  }
  if self.max_input_len <= 0 {
    raise InvalidOption("max_input_len must be a positive integer")
  }
  if self.max_token_len <= 0 {
    raise InvalidOption("max_token_len must be a positive integer")
  }
  if self.max_prose_buffer <= 0 {
    raise InvalidOption("max_prose_buffer must be a positive integer")
  }
  if self.indent < 0 {
    raise InvalidOption("indent must not be negative")
  }
  if self.max_repairs <= 0 {
    raise InvalidOption("max_repairs must be a positive integer")
  }
  if self.collect_deltas {
    // A delta stream cannot take back a container it already announced, so a
    // duplicate key whose new value is a container cannot be ignored.
    if self.duplicate_keys is KeepFirst {
      raise InvalidOption(
        "collect_deltas requires duplicate_keys KeepLast or AsError: KeepFirst drops a value whose container was already announced",
      )
    }
    if self.incomplete_number is TrimToValid {
      raise InvalidOption(
        "collect_deltas requires incomplete_number Drop: an unfinished number cannot be streamed as a delta",
      )
    }
  }
}
