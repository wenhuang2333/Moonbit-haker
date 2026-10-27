// M4 diag — positions, repair codes, repair records and fatal errors.
//
// Two signal families are kept strictly apart (ADR-006):
//   * repair records (R codes) are informational and travel with the result;
//   * fatal errors (E codes) abort processing and are raised as `InterJSONError`.

///|
/// Severity of a repair record.
///
/// `Info` means the value is unchanged (only the notation was normalised);
/// `Warning` means content may have been invented, dropped or altered.
pub(all) enum Severity {
  Info
  Warning
}

///|
/// Explicit `Eq` implementation for `Severity`.
pub impl Eq for Severity with fn equal(self : Severity, other : Severity) -> Bool {
  (self is Info && other is Info) || (self is Warning && other is Warning)
}

///|
/// Explicit `Eq` extension for `Severity`.
pub extend Severity with Eq::{not_equal, equal}

///|
/// Repair codes. The string form (`R001` … `R022`) is stable: a code never
/// changes meaning once released, and codes are only ever appended.
pub(all) enum RepairCode {
  StripFence
  StripComment
  NormalizeQuote
  QuoteBareWord
  RemoveExtraComma
  InsertComma
  InsertColon
  FillNull
  CloseContainer
  CloseString
  FixNumber
  ConvertLiteral
  EscapeControl
  FixEscape
  MismatchedCloser
  DropUnexpected
  DropExtraCloser
  MergeDuplicateKey
  ConcatStrings
  DropEllipsis
  SkipProse
  /// A literal was only re-cased (`True` -> `true`). Nothing was invented, so
  /// this is `Info`; a literal that had to be *completed* stays
  /// `ConvertLiteral`, which is `Warning`.
  NormalizeLiteral
}

///|
/// Explicit `Eq` implementation for `RepairCode`.
pub impl Eq for RepairCode with fn equal(self : RepairCode, other : RepairCode) -> Bool {
  self.number() == other.number()
}

///|
/// Explicit `Eq` extension for `RepairCode`.
pub extend RepairCode with Eq::{not_equal, equal}

///|
/// Stable numeric index of a repair code (1 … 21), used by rule switches.
pub fn RepairCode::number(self : RepairCode) -> Int32 {
  match self {
    StripFence => 1
    StripComment => 2
    NormalizeQuote => 3
    QuoteBareWord => 4
    RemoveExtraComma => 5
    InsertComma => 6
    InsertColon => 7
    FillNull => 8
    CloseContainer => 9
    CloseString => 10
    FixNumber => 11
    ConvertLiteral => 12
    EscapeControl => 13
    FixEscape => 14
    MismatchedCloser => 15
    DropUnexpected => 16
    DropExtraCloser => 17
    MergeDuplicateKey => 18
    ConcatStrings => 19
    DropEllipsis => 20
    SkipProse => 21
    NormalizeLiteral => 22
  }
}

///|
/// Stable string form of a repair code, e.g. `R005`.
pub fn RepairCode::code(self : RepairCode) -> String {
  let n = self.number()
  if n < 10 {
    "R00" + n.to_string()
  } else {
    "R0" + n.to_string()
  }
}

///|
/// Human readable name of a repair code, e.g. `RemoveExtraComma`.
pub fn RepairCode::name(self : RepairCode) -> String {
  match self {
    StripFence => "StripFence"
    StripComment => "StripComment"
    NormalizeQuote => "NormalizeQuote"
    QuoteBareWord => "QuoteBareWord"
    RemoveExtraComma => "RemoveExtraComma"
    InsertComma => "InsertComma"
    InsertColon => "InsertColon"
    FillNull => "FillNull"
    CloseContainer => "CloseContainer"
    CloseString => "CloseString"
    FixNumber => "FixNumber"
    ConvertLiteral => "ConvertLiteral"
    EscapeControl => "EscapeControl"
    FixEscape => "FixEscape"
    MismatchedCloser => "MismatchedCloser"
    DropUnexpected => "DropUnexpected"
    DropExtraCloser => "DropExtraCloser"
    MergeDuplicateKey => "MergeDuplicateKey"
    ConcatStrings => "ConcatStrings"
    DropEllipsis => "DropEllipsis"
    SkipProse => "SkipProse"
    NormalizeLiteral => "NormalizeLiteral"
  }
}

///|
/// Where a repaired token sits in the grammar (BR-07a).
pub(all) enum Slot {
  /// An object member name.
  KeySlot
  /// Any value position.
  ValueSlot
}

///|
/// Explicit `Eq` implementation for `Slot`.
pub impl Eq for Slot with fn equal(self : Slot, other : Slot) -> Bool {
  (self is KeySlot && other is KeySlot) ||
  (self is ValueSlot && other is ValueSlot)
}

///|
/// Explicit `Eq` extension for `Slot`.
pub extend Slot with Eq::{not_equal, equal}

///|
/// Default severity of a repair code. `QuoteBareWord` is context dependent and
/// is recorded as `Warning` when it quotes a value (see `BR-07a`).
pub fn RepairCode::severity(self : RepairCode) -> Severity {
  match self {
    StripFence
    | StripComment
    | NormalizeQuote
    | QuoteBareWord
    | RemoveExtraComma
    | InsertComma
    | InsertColon
    | EscapeControl
    | ConcatStrings
    | MismatchedCloser
    | DropExtraCloser
    | SkipProse
    | NormalizeLiteral => Info
    _ => Warning
  }
}

///|
/// Severity of a code in a given slot. Only `QuoteBareWord` differs: quoting a
/// member name is a notation fix, quoting a value invents a string (BR-07a).
pub fn RepairCode::severity_in(self : RepairCode, slot : Slot) -> Severity {
  match (self, slot) {
    (QuoteBareWord, ValueSlot) => Warning
    _ => self.severity()
  }
}

///|
/// Whether a repair admits a second, equally self-consistent reading (FR-27).
///
/// `Unambiguous` means the JSON grammar leaves no other reading of the input.
/// Every other variant names the concrete alternative reading, which a consumer
/// that is about to *execute* the value must refuse: `Options::reject_ambiguous`
/// turns a non-`Unambiguous` repair into `E011`.
///
/// The marker is orthogonal to `Severity`: `["a" "b"]` is `Info` (nothing was
/// invented, both characters were already there) yet structurally ambiguous.
pub(all) enum Ambiguity {
  Unambiguous
  /// R004 in value position: the bare word may be a string, a reference to a
  /// value of the host language, or a misspelled literal.
  BareWord
  /// R006 between two string literals: `["a" "b"]` reads equally as two
  /// elements and as the single concatenated string `"ab"`.
  AdjacentStrings
  /// R019: `"a" + "b"` reads equally as one concatenated string and as two
  /// values separated by an operator that JSON does not have.
  ConcatOperator
  /// R016 after a complete root value: what follows may be a second document,
  /// a further element of a list, or prose.
  TrailingContent
}

///|
/// Explicit `Eq` implementation for `Ambiguity`.
pub impl Eq for Ambiguity with fn equal(self : Ambiguity, other : Ambiguity) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `Ambiguity`.
pub extend Ambiguity with Eq::{not_equal, equal}

///|
/// Stable lowercase name of an ambiguity, e.g. `adjacent_strings`.
pub fn Ambiguity::name(self : Ambiguity) -> String {
  match self {
    Unambiguous => "unambiguous"
    BareWord => "bare_word"
    AdjacentStrings => "adjacent_strings"
    ConcatOperator => "concat_operator"
    TrailingContent => "trailing_content"
  }
}

///|
/// Whether the two readings of an ambiguity can be told apart from the input
/// alone. Always false today: that is what makes it an ambiguity.
pub fn Ambiguity::is_ambiguous(self : Ambiguity) -> Bool {
  !(self is Unambiguous)
}

///|
/// Fixed English message of an ambiguity, for `E011` and `RetryHint`.
pub fn Ambiguity::message(self : Ambiguity) -> String {
  match self {
    Unambiguous => ""
    BareWord =>
      "bare word in value position may be a string or a host-language value"
    AdjacentStrings =>
      "two adjacent strings may be two elements or one concatenated string"
    ConcatOperator => "a plus sign between strings may concatenate or separate"
    TrailingContent =>
      "text after the first root value may be a second document or prose"
  }
}

///|
/// Fixed English message template of a repair code. Messages never embed user
/// input, so they cannot be used to inject content into logs (D09 9.7).
pub fn RepairCode::message(self : RepairCode) -> String {
  match self {
    StripFence => "code fence removed"
    StripComment => "comment removed"
    NormalizeQuote => "quote normalized to double quote"
    QuoteBareWord => "bare word quoted"
    RemoveExtraComma => "extra comma removed"
    InsertComma => "missing comma inserted"
    InsertColon => "missing colon inserted"
    FillNull => "null filled for missing value"
    CloseContainer => "unclosed container closed"
    CloseString => "unclosed string closed"
    FixNumber => "number normalized or trimmed"
    ConvertLiteral => "literal converted or completed"
    EscapeControl => "control character escaped"
    FixEscape => "invalid escape repaired"
    MismatchedCloser => "mismatched closer replaced"
    DropUnexpected => "unexpected content dropped"
    DropExtraCloser => "extra closer dropped"
    MergeDuplicateKey => "duplicate key merged"
    ConcatStrings => "string concatenation merged"
    DropEllipsis => "ellipsis placeholder dropped"
    SkipProse => "leading prose skipped"
    NormalizeLiteral => "literal re-cased"
  }
}

///|
/// How much of a result was invented rather than read from the input (FR-17).
///
/// The three levels are ordered: `Exact` is the safest, `Lossy` the riskiest.
/// `Options::max_loss` compares against this order.
///
/// * `Exact` — no repair was recorded, so the value is exactly what the input
///   said (a valid document, possibly with trailing whitespace).
/// * `Cosmetic` — only notation-level repairs (`Info` severity) were recorded:
///   quotes normalised, a comment or a code fence removed, a missing comma or
///   colon inserted, a control character escaped. No value was guessed.
/// * `Lossy` — at least one `Warning` severity repair was recorded: a value was
///   invented, dropped, truncated or replaced.
pub(all) enum Exactness {
  Exact
  Cosmetic
  Lossy
}

///|
/// Explicit `Eq` implementation for `Exactness`.
pub impl Eq for Exactness with fn equal(self : Exactness, other : Exactness) -> Bool {
  (self is Exact && other is Exact) ||
  (self is Cosmetic && other is Cosmetic) ||
  (self is Lossy && other is Lossy)
}

///|
/// Explicit `Eq` extension for `Exactness`.
pub extend Exactness with Eq::{not_equal, equal}

///|
/// Risk rank of an exactness level: `Exact` 0, `Cosmetic` 1, `Lossy` 2.
pub fn Exactness::rank(self : Exactness) -> Int32 {
  match self {
    Exact => 0
    Cosmetic => 1
    Lossy => 2
  }
}

///|
/// Whether `self` is at most as risky as `limit`.
pub fn Exactness::within(self : Exactness, limit : Exactness) -> Bool {
  self.rank() <= limit.rank()
}

///|
/// Stable lowercase name, e.g. `exact`.
pub fn Exactness::name(self : Exactness) -> String {
  match self {
    Exact => "exact"
    Cosmetic => "cosmetic"
    Lossy => "lossy"
  }
}

///|
/// Aggregate the exactness of a result from its repair records (FR-17).
///
/// The level is the highest risk among the records: no records is `Exact`, any
/// `Warning` is `Lossy`, otherwise `Cosmetic`.
pub fn exactness_of(repairs : Array[Repair]) -> Exactness {
  if repairs.length() == 0 {
    return Exact
  }
  for r in repairs {
    if r.severity is Warning {
      return Lossy
    }
  }
  Cosmetic
}

///|
/// A position inside the input. `offset` counts UTF-16 code units from 0,
/// `line` and `column` are 1-based (BR-20).
pub(all) struct Position {
  offset : Int32
  line : Int32
  column : Int32
}

///|
/// Explicit `Eq` implementation for `Position`.
pub impl Eq for Position with fn equal(self : Position, other : Position) -> Bool {
  self.offset == other.offset &&
  self.line == other.line &&
  self.column == other.column
}

///|
/// Explicit `Eq` extension for `Position`.
pub extend Position with Eq::{not_equal, equal}

///|
/// One repair record: what was changed, where, how serious it is, and whether
/// the change admits a second reading.
pub(all) struct Repair {
  code : RepairCode
  position : Position
  severity : Severity
  message : String
  /// `Unambiguous` unless the site could be read more than one way (FR-27).
  ambiguity : Ambiguity
}

///|
/// Whether any record in `repairs` is ambiguous (FR-27).
pub fn has_ambiguity(repairs : Array[Repair]) -> Bool {
  for r in repairs {
    if r.ambiguity.is_ambiguous() {
      return true
    }
  }
  false
}

///|
/// Fatal error. Every variant carries the data needed to diagnose the input
/// without re-running the parser.
pub(all) suberror InterJSONError {
  EmptyInput
  NoJsonFound(Int32)
  StrictViolation(RepairCode, Position, String)
  /// An unambiguous reading was required but the repair admits a second one
  /// (E011, FR-27). Raised before the `max_loss` gate, because the ambiguity is
  /// the more specific diagnosis.
  AmbiguousRepair(RepairCode, Position, Ambiguity)
  DepthLimit(Int32, Int32)
  SizeLimit(Int32, Int32)
  TokenLimit(Int32, Int32)
  InvalidState(String)
  InvalidUtf8(Int32)
  InvalidOption(String)
  /// A provider event payload could not be interpreted (E060). Raised by the
  /// `interjson/llm` adapters; the payload is a fixed explanation.
  InvalidEvent(String)
  /// A skeleton declaration could not be read, or a value does not satisfy it
  /// (E070, FR-34). The payload is a fixed explanation.
  SchemaError(String)
}

///|
/// Stable error code string, e.g. `E010`.
pub fn InterJSONError::code(self : InterJSONError) -> String {
  match self {
    EmptyInput => "E001"
    NoJsonFound(_offset) => "E002"
    StrictViolation(_code, _pos, _msg) => "E010"
    AmbiguousRepair(_code, _pos, _msg) => "E011"
    DepthLimit(_limit, _offset) => "E020"
    SizeLimit(_limit, _offset) => "E021"
    TokenLimit(_limit, _offset) => "E022"
    InvalidState(_) => "E030"
    InvalidUtf8(_) => "E040"
    InvalidOption(_) => "E050"
    InvalidEvent(_) => "E060"
    SchemaError(_) => "E070"
  }
}

///|
/// One-line diagnostic, e.g. `E020 DepthLimit: limit 3 exceeded at offset 3`.
pub fn InterJSONError::to_string(self : InterJSONError) -> String {
  let sb = StringBuilder()
  match self {
    EmptyInput =>
      sb.write_string("E001 EmptyInput: input is empty or whitespace only")
    NoJsonFound(offset) => {
      sb.write_string("E002 NoJsonFound: no JSON value found at offset ")
      sb.write_string(offset.to_string())
    }
    StrictViolation(code, pos, msg) => {
      sb.write_string("E010 StrictViolation at ")
      sb.write_string(pos.line.to_string())
      sb.write_string(":")
      sb.write_string(pos.column.to_string())
      sb.write_string(" (offset ")
      sb.write_string(pos.offset.to_string())
      sb.write_string("): ")
      sb.write_string(code.code())
      sb.write_string(" ")
      sb.write_string(code.name())
      sb.write_string(": ")
      sb.write_string(msg)
    }
    AmbiguousRepair(code, pos, ambiguity) => {
      sb.write_string("E011 AmbiguousRepair at ")
      sb.write_string(pos.line.to_string())
      sb.write_string(":")
      sb.write_string(pos.column.to_string())
      sb.write_string(" (offset ")
      sb.write_string(pos.offset.to_string())
      sb.write_string("): ")
      sb.write_string(code.code())
      sb.write_string(" ")
      sb.write_string(code.name())
      sb.write_string(": ")
      sb.write_string(ambiguity.message())
    }
    DepthLimit(limit, offset) => {
      sb.write_string("E020 DepthLimit: nesting limit ")
      sb.write_string(limit.to_string())
      sb.write_string(" exceeded at offset ")
      sb.write_string(offset.to_string())
    }
    SizeLimit(limit, offset) => {
      sb.write_string("E021 SizeLimit: input limit ")
      sb.write_string(limit.to_string())
      sb.write_string(" exceeded at offset ")
      sb.write_string(offset.to_string())
    }
    TokenLimit(limit, offset) => {
      sb.write_string("E022 TokenLimit: token limit ")
      sb.write_string(limit.to_string())
      sb.write_string(" exceeded at offset ")
      sb.write_string(offset.to_string())
    }
    InvalidState(msg) => {
      sb.write_string("E030 InvalidState: ")
      sb.write_string(msg)
    }
    InvalidUtf8(offset) => {
      sb.write_string("E040 InvalidUtf8: invalid UTF-8 byte at offset ")
      sb.write_string(offset.to_string())
    }
    InvalidOption(msg) => {
      sb.write_string("E050 InvalidOption: ")
      sb.write_string(msg)
    }
    InvalidEvent(msg) => {
      sb.write_string("E060 InvalidEvent: ")
      sb.write_string(msg)
    }
    SchemaError(msg) => {
      sb.write_string("E070 SchemaError: ")
      sb.write_string(msg)
    }
  }
  sb.to_string()
}
