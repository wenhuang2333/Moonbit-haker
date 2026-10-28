// FR-32 — SafetyPolicy: the safety-relevant half of `Options`, named by the
// situation the caller is in instead of by eleven parameter values.
//
// `Options` describes the protocol (chunking, delta tracking, prose, indent) as
// well as the risk contract. A caller that only wants to say "this value came
// from a model and I am going to execute it" should not have to derive that
// from `max_loss` plus `reject_ambiguous` plus the duplicate-key policy, and a
// reviewer should not have to read the call site to find out what was allowed.
// A policy is that decision, in one value, with a name.
//
// The mapping is deliberately one-way: `SafetyPolicy::to_options` turns a
// policy into library options, and `Options::with_policy` overlays the policy's
// safety knobs on an existing options value so the protocol knobs survive.

///|
/// A named set of safety-relevant settings (FR-32).
///
/// Every field here can also be set on `Options` directly; the policy exists so
/// that the *intent* is part of the value and can be printed in a log line
/// (`SafetyPolicy::name`).
pub(all) struct SafetyPolicy {
  /// Short stable name of the profile, e.g. `execution`.
  profile : String
  /// `Strict` turns the first repair into `E010` whatever it was.
  mode : Mode
  /// Highest exactness the policy accepts (FR-17).
  max_loss : Exactness
  /// Refuse a repair with a second reading (FR-27).
  reject_ambiguous : Bool
  /// Duplicate object key policy (BR-19).
  duplicate_keys : DuplicateKeys
  /// How an unterminated number appears (FR-11).
  incomplete_number : IncompleteNumber
  /// How a dangling key appears.
  pending_key : PendingKey
  /// What happens to content after the first root value (FR-15).
  multi_root : MultiRoot
  /// Nesting limit.
  max_depth : Int32
  /// Input length limit, in code units.
  max_input_len : Int32
  /// Which repair rules may run at all.
  rules : RuleSet
}

///|
/// The three profiles that differ in what they accept, from least to most
/// careful. `permissive` is the documented default; `interactive` refuses a
/// repair that invented content but lets a human judge a second reading;
/// `execution` refuses both.
pub fn SafetyPolicy::permissive() -> SafetyPolicy {
  {
    profile: "permissive",
    mode: Lenient,
    max_loss: Lossy,
    reject_ambiguous: false,
    duplicate_keys: KeepLast,
    incomplete_number: Drop,
    pending_key: OmitKey,
    multi_root: KeepFirst,
    max_depth: 512,
    max_input_len: 67108864,
    rules: RuleSet::all(),
  }
}

///|
/// A human reads the result and can supply the missing judgement: notation
/// repairs pass, a repair that invented, dropped or truncated a value is
/// refused (`max_loss: Cosmetic`), and a second reading is reported through
/// `RepairResult::ambiguous` instead of being refused, because a person is
/// allowed to choose.
pub fn SafetyPolicy::interactive() -> SafetyPolicy {
  { ..SafetyPolicy::permissive(), profile: "interactive", max_loss: Cosmetic, }
}

///|
/// Nothing human sits between the parse and the effect: notation repairs pass,
/// a repair that changed a value raises `E010` and a repair with a second
/// reading raises `E011` (FR-27).
///
/// This is the policy behind `Options::for_execution()`.
pub fn SafetyPolicy::for_execution() -> SafetyPolicy {
  {
    ..SafetyPolicy::interactive(),
    profile: "execution",
    reject_ambiguous: true,
  }
}

///|
/// An agent loop, where a refusal is cheap because the refusal is handed back
/// to the model that produced the input (FR-28).
///
/// In safety terms this is `for_execution()` plus a resource bound: a tool call
/// is a handful of arguments, so nesting is capped at 64 and the input at one
/// million code units, while the general defaults are 512 and 64 MiB. What an
/// agent additionally needs is protocol, not policy, which is why the streaming
/// preset is `Options::for_agent()` — this policy plus `for_llm()`'s delta
/// stream and prose handling.
pub fn SafetyPolicy::for_agent() -> SafetyPolicy {
  {
    ..SafetyPolicy::for_execution(),
    profile: "agent",
    // A tool call is a handful of arguments, not a 64 MiB document. The bound
    // is part of the agent profile because an agent is the one caller that
    // cannot look at the input before deciding to accept it.
    max_depth: 64,
    max_input_len: 1048576,
  }
}

///|
/// Refuse every repair, including a normalised quote: `Mode::Strict` turns the
/// first recorded repair into `E010`, whatever its severity. This is the policy
/// behind `Options::strict()`.
///
/// `max_loss` is left where the permissive profile puts it, because under
/// `Strict` it is never consulted: the refusal happens first. Changing it would
/// make the profile look stricter than it is while changing nothing.
pub fn SafetyPolicy::strict() -> SafetyPolicy {
  { ..SafetyPolicy::permissive(), profile: "strict", mode: Strict, }
}

///|
/// The profile name, e.g. `execution`.
pub fn SafetyPolicy::name(self : SafetyPolicy) -> String {
  self.profile
}

///|
/// The policy as a fresh `Options` value: the documented protocol defaults with
/// this policy's safety knobs.
pub fn SafetyPolicy::to_options(self : SafetyPolicy) -> Options {
  {
    ..Options::default(),
    mode: self.mode,
    max_loss: self.max_loss,
    reject_ambiguous: self.reject_ambiguous,
    duplicate_keys: self.duplicate_keys,
    incomplete_number: self.incomplete_number,
    pending_key: self.pending_key,
    multi_root: self.multi_root,
    max_depth: self.max_depth,
    max_input_len: self.max_input_len,
    rules: self.rules,
  }
}

///|
/// The same policy applied to `self`, keeping every protocol field (deltas,
/// prose, indent, repair log, limits the caller set by hand) and replacing only
/// the safety knobs.
pub fn Options::with_policy(self : Options, policy : SafetyPolicy) -> Options {
  {
    ..self,
    mode: policy.mode,
    max_loss: policy.max_loss,
    reject_ambiguous: policy.reject_ambiguous,
    duplicate_keys: policy.duplicate_keys,
    incomplete_number: policy.incomplete_number,
    pending_key: policy.pending_key,
    multi_root: policy.multi_root,
    max_depth: policy.max_depth,
    max_input_len: policy.max_input_len,
    rules: policy.rules,
  }
}

///|
/// The same profile applied to `self`: the safety knobs of the policy, plus
/// the protocol the profile implies.
///
/// `with_policy` keeps the caller's protocol fields and replaces the safety
/// ones, which is right for a *policy* — a risk contract on its own. A
/// *profile* is more than that. The `agent` profile is the one a chat channel
/// uses, and it implies `skip_prose`, because a model in a chat channel
/// routinely answers with a sentence before the arguments and that sentence
/// is not part of the arguments.
///
/// Applying only the safety half is not a small difference. The MCP gate
/// selects its profile by name, so the gate's `agent` profile was the agent
/// profile's safety knobs without its protocol, and the most common shape of
/// model output — `Here are the args:\n{"a":1}` — was refused with `E002` by
/// the tool whose entire job is to accept it. There is now one place that
/// says what a profile means, and both the library preset and the
/// name-selecting callers go through it.
pub fn Options::with_profile(self : Options, policy : SafetyPolicy) -> Options {
  let out = self.with_policy(policy)
  if policy.name() == "agent" {
    { ..out, skip_prose: true, }
  } else {
    out
  }
}

///|
/// The policy a set of options corresponds to, or `None` when the options are
/// not one of the five documented profiles.
///
/// Two options values match the same profile when every safety knob is equal;
/// protocol knobs are ignored, because that is what makes them protocol. The
/// comparison exists so that `--policy` reporting cannot drift: the CLI prints
/// the profile the options it built actually are, not the word the user typed.
pub fn SafetyPolicy::of_options(options : Options) -> String? {
  let candidates : Array[SafetyPolicy] = [
    SafetyPolicy::permissive(),
    SafetyPolicy::interactive(),
    SafetyPolicy::for_execution(),
    SafetyPolicy::for_agent(),
    SafetyPolicy::strict(),
  ]
  for p in candidates {
    if p.matches(options) {
      return Some(p.profile)
    }
  }
  None
}

///|
/// Whether `options` has exactly this policy's safety knobs.
fn SafetyPolicy::matches(self : SafetyPolicy, options : Options) -> Bool {
  options.mode == self.mode &&
  options.max_loss == self.max_loss &&
  options.reject_ambiguous == self.reject_ambiguous &&
  options.duplicate_keys == self.duplicate_keys &&
  options.incomplete_number == self.incomplete_number &&
  options.pending_key == self.pending_key &&
  options.multi_root == self.multi_root &&
  options.max_depth == self.max_depth &&
  options.max_input_len == self.max_input_len &&
  options.rules.same_as(self.rules)
}
