// FR-34 — ExecutionDecision: one word for "may the caller act on this value".
//
// Until now a caller had to read three fields (`exactness`, `ambiguous`, and
// whether `repairs` is empty) and know that `for_execution()` refuses rather
// than repairs. The decision is that reading, made once, in the library, with
// the risk order fixed:
//
//   ambiguous -> lossy -> cosmetic -> safe
//
// The order is not arbitrary. A repair with a second reading is worse than one
// that merely invented content, because the caller cannot even tell what was
// invented: `["a" "b"]` may have become `["a","b"]` or `"ab"`. That is why
// `Ambiguous` outranks `LossyRepair`, and why `Options::for_execution()` raises
// `E011` before it raises `E010` (FR-27).

///|
/// What a caller may do with a result (FR-34).
pub(all) enum ExecutionDecision {
  /// Valid JSON that needed nothing.
  Safe
  /// Only the notation was normalised: the value is byte-for-byte the value the
  /// input already denoted, so the result may be executed.
  CosmeticRepair
  /// A repair invented, dropped, truncated or replaced a value
  /// (`Severity::Warning`). Correct for a display channel, not for an effect.
  LossyRepair
  /// A repair admits a second reading (FR-27).
  Ambiguous
  /// No value was produced: the input could not be repaired under the options,
  /// or the value does not satisfy the schema it was checked against.
  Invalid
}

///|
/// Explicit `Eq` implementation for `ExecutionDecision`.
pub impl Eq for ExecutionDecision with fn equal(
  self : ExecutionDecision,
  other : ExecutionDecision,
) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `ExecutionDecision`.
pub extend ExecutionDecision with Eq::{not_equal, equal}

///|
/// Stable lowercase name, e.g. `lossy_repair`.
pub fn ExecutionDecision::name(self : ExecutionDecision) -> String {
  match self {
    Safe => "safe"
    CosmeticRepair => "cosmetic_repair"
    LossyRepair => "lossy_repair"
    Ambiguous => "ambiguous"
    Invalid => "invalid"
  }
}

///|
/// Whether the caller may execute: `Safe` and `CosmeticRepair` only.
pub fn ExecutionDecision::is_safe(self : ExecutionDecision) -> Bool {
  match self {
    Safe | CosmeticRepair => true
    LossyRepair | Ambiguous | Invalid => false
  }
}

///|
/// Upper-case label for a human, e.g. `SAFE TO EXECUTE`.
pub fn ExecutionDecision::label(self : ExecutionDecision) -> String {
  match self {
    Safe => "SAFE TO EXECUTE"
    CosmeticRepair => "SAFE TO EXECUTE (notation normalised)"
    LossyRepair => "REJECT (a value was changed)"
    Ambiguous => "BLOCKED (two readings)"
    Invalid => "REJECT (not repairable)"
  }
}

///|
/// The decision for a result that was produced: `repairs` is the number of
/// recorded records, because `exactness` alone cannot tell a clean document
/// from one that needed a cosmetic repair (both are `Exact`).
pub fn decide(
  repairs : Int32,
  exactness : Exactness,
  ambiguous : Bool,
) -> ExecutionDecision {
  if ambiguous {
    Ambiguous
  } else if exactness is Lossy {
    LossyRepair
  } else if repairs > 0 || exactness is Cosmetic {
    CosmeticRepair
  } else {
    Safe
  }
}

///|
/// The decision for a value that was refused: `E011` is an ambiguity, every
/// other refusal of a repair (`E010`) is a lossy one, and a fatal error that is
/// not a repair refusal is `Invalid`.
pub fn decide_error(code : String) -> ExecutionDecision {
  match code {
    "E011" => Ambiguous
    "E010" => LossyRepair
    _ => Invalid
  }
}

///|
/// The risk of a decision, used to order two decisions (FR-34): `Safe` 0,
/// `CosmeticRepair` 1, `LossyRepair` 2, `Ambiguous` 3, `Invalid` 4.
pub fn ExecutionDecision::rank(self : ExecutionDecision) -> Int32 {
  match self {
    Safe => 0
    CosmeticRepair => 1
    LossyRepair => 2
    Ambiguous => 3
    Invalid => 4
  }
}

///|
/// The riskier of two decisions. Used to combine the parse decision with the
/// schema verdict without inventing a sixth variant.
pub fn ExecutionDecision::worse_of(
  self : ExecutionDecision,
  other : ExecutionDecision,
) -> ExecutionDecision {
  if other.rank() > self.rank() {
    other
  } else {
    self
  }
}
