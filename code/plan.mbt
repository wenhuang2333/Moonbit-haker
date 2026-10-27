// FR-33 — RepairPlan: what was repaired, why, how risky it is, and
// whether the caller may act on it.
//
// FR-33, the *why*: `Repair` says `R005 at 1:21`; that is a diagnosis, not a
// decision, because the caller still has to know what R005 does to the text.
// A `PlanOp` adds the action the rule performed (remove, insert, replace,
// merge, …), whether information was lost, and a *class* of confidence.
//
// FR-33, the self-healing loop: `analyze` never raises. A gate that throws
// forces every caller to write a `try` around it and then re-derive the retry
// message from the error, which is exactly the code that gets written slightly
// differently in every integration. `analyze` returns the refusal inside the
// plan (decision `Invalid`/`LossyRepair`/`Ambiguous` plus `retry_hint`), so the
// loop is:
//
//   let plan = @interjson.analyze(arguments, options=@interjson.Options::for_agent())
//   if plan.is_executable() { execute(plan.value) } else { send(plan.prompt()) }
//
// Confidence is deliberately a class, not a probability: InterJSON has no
// calibration data, and a number that looks like a probability but is not one
// is worse than a label. `certain` means the value is provably unchanged;
// `probable` means the repair is the only one the rules allow but it did
// invent, drop or truncate content; `ambiguous` means two readings exist.

///|
/// What a repair did to the text (FR-33).
pub(all) enum PlanAction {
  /// Nothing was rewritten (`R001`, `R002`: a fence or a comment was dropped).
  Remove
  /// Something was added (`R006`, `R007`, `R008`, `R009`, `R010`).
  Insert
  /// A token was rewritten in place (`R003`, `R011`, `R012`, `R015`).
  Replace
  /// A token was re-spelled without changing what it denotes (`R003`, `R011`,
  /// `R012`, `R013`, `R014`, `R022`).
  Normalize
  /// Two values became one (`R018`, `R019`).
  Merge
  /// A bare word was turned into a string by adding quotes (`R004`).
  Wrap
}

///|
/// Explicit `Eq` implementation for `PlanAction`.
pub impl Eq for PlanAction with fn equal(self : PlanAction, other : PlanAction) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `PlanAction`.
pub extend PlanAction with Eq::{not_equal, equal}

///|
/// Stable lowercase name, e.g. `remove`.
pub fn PlanAction::name(self : PlanAction) -> String {
  match self {
    Remove => "remove"
    Insert => "insert"
    Replace => "replace"
    Normalize => "normalize"
    Merge => "merge"
    Wrap => "wrap"
  }
}

///|
/// The action a rule performs (FR-33). Total by construction: adding a
/// `RepairCode` without a case here is a compile error.
pub fn plan_action(code : RepairCode) -> PlanAction {
  match code {
    StripFence => Remove
    StripComment => Remove
    NormalizeQuote => Normalize
    QuoteBareWord => Wrap
    RemoveExtraComma => Remove
    InsertComma => Insert
    InsertColon => Insert
    FillNull => Insert
    CloseContainer => Insert
    CloseString => Insert
    FixNumber => Normalize
    ConvertLiteral => Replace
    EscapeControl => Normalize
    FixEscape => Normalize
    MismatchedCloser => Replace
    DropUnexpected => Remove
    DropExtraCloser => Remove
    MergeDuplicateKey => Merge
    ConcatStrings => Merge
    DropEllipsis => Remove
    SkipProse => Remove
    NormalizeLiteral => Normalize
  }
}

///|
/// One repair, described as an operation on the input (FR-33).
pub(all) struct PlanOp {
  /// `R` code, e.g. `R005`.
  rule : String
  /// Stable name of the rule, e.g. `RemoveExtraComma`.
  name : String
  /// What the rule did.
  action : PlanAction
  /// Where in the input.
  position : Position
  severity : Severity
  /// The second reading, when there is one.
  ambiguity : Ambiguity
  /// `certain`, `probable` or `ambiguous` (see the file header).
  confidence_class : String
  /// `1.0` for `certain`, `0.75` for `probable`, `0.5` for `ambiguous`. A class
  /// label with a numeric spelling for machine consumers, not a probability.
  confidence : Double
}

///|
/// Explicit `Eq` implementation for `PlanOp`.
pub impl Eq for PlanOp with fn equal(self : PlanOp, other : PlanOp) -> Bool {
  self.rule == other.rule && self.position.offset == other.position.offset
}

///|
/// Explicit `Eq` extension for `PlanOp`.
pub extend PlanOp with Eq::{not_equal, equal}

///|
/// Whether the operation threw information away: true for a `Warning` record.
pub fn PlanOp::information_loss(self : PlanOp) -> Bool {
  self.severity is Warning
}

///|
/// One repair record as a plan operation (FR-33).
pub fn PlanOp::of_repair(r : Repair) -> PlanOp {
  let (class, value) = if r.ambiguity.is_ambiguous() {
    ("ambiguous", 0.5)
  } else if r.severity is Warning {
    ("probable", 0.75)
  } else {
    ("certain", 1.0)
  }
  {
    rule: r.code.code(),
    name: r.code.name(),
    action: plan_action(r.code),
    position: r.position,
    severity: r.severity,
    ambiguity: r.ambiguity,
    confidence_class: class,
    confidence: value,
  }
}

///|
/// The full analysis of one input: the repairs, the risk, the decision and the
/// refusal, if any (FR-33, FR-33).
pub(all) struct RepairPlan {
  /// Repaired text; empty when the input produced no value.
  text : String
  /// The parsed value, when the caller can use it. `None` on a refusal.
  value : Json?
  /// One entry per repair record, in the order they happened.
  repairs : Array[PlanOp]
  /// Whether the repair log was cut short by `max_repairs`.
  repairs_truncated : Bool
  exactness : Exactness
  /// Whether the input was already well-formed JSON and the only thing InterJSON
  /// had to decide was what its repeated member names mean (Q-26).
  valid_json : Bool
  /// Whether any repair admitted a second reading (FR-27).
  ambiguous : Bool
  completeness : Completeness
  /// What the caller may do (FR-34).
  decision : ExecutionDecision
  /// The refusal as feedback for the model, when there was one (FR-28).
  retry_hint : RetryHint?
  /// `E` code of the refusal, or `""`.
  error_code : String
  /// One line about the refusal, or `""`.
  error_message : String
  /// First input fraction, in per mille, at which the document needed no
  /// further closing, or `-1` when it was not measured (`analyze(…, readiness=step)`).
  readiness_permille : Int32
  /// Declared members of the skeleton the value was checked against, or `0`
  /// when no skeleton was given (FR-36).
  schema_total : Int32
  /// Declared members that hold a value of the declared kind.
  schema_satisfied : Int32
  /// Required members that the value does not provide, as dotted paths.
  schema_missing : Array[String]
}

///|
/// Whether the caller may execute the plan (FR-34).
pub fn RepairPlan::is_executable(self : RepairPlan) -> Bool {
  self.decision.is_safe() && self.value is Some(_)
}

///|
/// What a model should do differently, one sentence per rule that fired
/// (FR-33). Ordered by first occurrence and de-duplicated, because a truncated
/// document fires `R010` and `R009` and the two sentences are one instruction.
pub fn RepairPlan::suggestions(self : RepairPlan) -> Array[String] {
  let out : Array[String] = []
  for op in self.repairs {
    let advice = advice_for(op)
    if advice != "" && !out.contains(advice) {
      out.push(advice)
    }
  }
  out
}

///|
/// The instruction one operation implies (FR-33).
///
/// A second reading is more specific than the rule that produced it: `R006`
/// between two elements usually means "you forgot a comma", but when the two
/// strings may equally be one concatenated string the useful sentence is the
/// ambiguity, not the rule.
pub fn advice_for(op : PlanOp) -> String {
  match op.ambiguity {
    AdjacentStrings =>
      "Separate the two adjacent strings with a comma, or merge them into one string."
    ConcatOperator =>
      "Remove the `+`, or merge the two strings into one string."
    BareWord => "Quote the bare word, or spell it as a JSON literal."
    TrailingContent => "Return exactly one JSON value."
    Unambiguous => rule_advice(code_of_name(op.name))
  }
}

///|
/// The rule a stable name refers to; `RepairCode::name` is total, so this
/// inverse is used only to avoid carrying the enum in the plan as well.
fn code_of_name(name : String) -> RepairCode {
  let codes : Array[RepairCode] = [
    StripFence,
    StripComment,
    NormalizeQuote,
    QuoteBareWord,
    RemoveExtraComma,
    InsertComma,
    InsertColon,
    FillNull,
    CloseContainer,
    CloseString,
    FixNumber,
    ConvertLiteral,
    EscapeControl,
    FixEscape,
    MismatchedCloser,
    DropUnexpected,
    DropExtraCloser,
    MergeDuplicateKey,
    ConcatStrings,
    DropEllipsis,
    SkipProse,
    NormalizeLiteral,
  ]
  for c in codes {
    if c.name() == name {
      return c
    }
  }
  CloseContainer
}

///|
/// The instruction a refusal implies for the model that produced the input
/// (FR-28, FR-33). Empty for a rule with nothing specific to say.
fn rule_advice(code : RepairCode) -> String {
  match code {
    CloseString => "Do not truncate string values."
    CloseContainer => "Close every object and array you open."
    MismatchedCloser | DropExtraCloser | DropUnexpected =>
      "Emit well-nested JSON: every `{` needs its `}` and every `[` its `]`."
    InsertComma | RemoveExtraComma =>
      "Fix the commas: one between members and elements, none before a closer."
    InsertColon => "Write every object member as `\"key\": value`."
    FillNull => "Do not leave a value out after `:`."
    QuoteBareWord => "Quote every string, including member names."
    NormalizeQuote => "Use double quotes, not single quotes, around strings."
    FixNumber | NormalizeLiteral | ConvertLiteral =>
      "Use JSON values only: `true`, `false`, `null`, and numbers without a leading `+` or a trailing dot."
    EscapeControl | FixEscape =>
      "Escape control characters and stray backslashes inside strings."
    MergeDuplicateKey => "Do not repeat an object member."
    ConcatStrings => "Do not concatenate strings with `+`."
    StripFence | SkipProse | StripComment | DropEllipsis =>
      "Return JSON only: no code fences, comments, prose or `...`."
  }
}

///|
/// Feedback ready to be sent back to the model that produced the input
/// (FR-28, FR-33).
///
/// A refusal carries a `RetryHint`, which names the position and quotes the
/// window. A plan that was *accepted* but is not executable — a lossy repair
/// under `permissive()` — has no hint, because nothing was refused; the prompt
/// is then derived from the rules that fired, which is the same instruction a
/// refusal would have produced. A plan that was accepted and is executable
/// returns a sentence saying so, so that a caller never has to branch.
pub fn RepairPlan::prompt(self : RepairPlan) -> String {
  match self.retry_hint {
    Some(h) => h.to_prompt()
    None =>
      if self.is_executable() {
        "The output was accepted; no retry is needed."
      } else {
        let sb = StringBuilder()
        sb.write_string("InterJSON refused the output (")
        sb.write_string(self.decision.name())
        if self.error_message != "" {
          sb.write_string(": ")
          sb.write_string(self.error_message)
        }
        sb.write_string(").")
        for line in self.suggestions() {
          sb.write_string("\n")
          sb.write_string(line)
        }
        sb.write_string(
          "\nRe-emit the arguments as valid JSON with exactly one reading.",
        )
        sb.to_string()
      }
  }
}

///|
/// A one line summary for logs: `lossy_repair exactness=lossy repairs=2`.
pub fn RepairPlan::summary(self : RepairPlan) -> String {
  let sb = StringBuilder()
  sb.write_string(self.decision.name())
  sb.write_string(" exactness=")
  sb.write_string(self.exactness.name())
  sb.write_string(" repairs=")
  sb.write_string(self.repairs.length().to_string())
  if self.ambiguous {
    sb.write_string(" ambiguous")
  }
  if self.readiness_permille >= 0 {
    sb.write_string(" syntax-ready=")
    sb.write_string(self.readiness_permille.to_string())
    sb.write_string("/1000")
  }
  if self.schema_total > 0 {
    sb.write_string(" schema=")
    sb.write_string(self.schema_satisfied.to_string())
    sb.write_string("/")
    sb.write_string(self.schema_total.to_string())
  }
  sb.to_string()
}

///|
/// The plan for an accepted result.
fn plan_of_final(
  fin : FinalResult,
  input : String,
  step : Int32,
  schema : Schema?,
) -> RepairPlan {
  let ops : Array[PlanOp] = []
  for r in fin.repairs {
    ops.push(PlanOp::of_repair(r))
  }
  let readiness = if step > 0 {
    syntax_readiness_permille(input, step~)
  } else {
    -1
  }
  let verdict = check_schema(schema, fin.value)
  let decision = decide(ops.length(), fin.exactness, fin.ambiguous)
  {
    text: fin.text,
    value: Some(fin.value),
    repairs: ops,
    repairs_truncated: fin.repairs_truncated,
    exactness: fin.exactness,
    valid_json: input_was_valid_json(ops),
    ambiguous: fin.ambiguous,
    completeness: fin.completeness,
    decision: verdict.decision(decision),
    retry_hint: None,
    error_code: if verdict.ok {
      ""
    } else {
      "E070"
    },
    error_message: verdict.message,
    readiness_permille: readiness,
    schema_total: verdict.total,
    schema_satisfied: verdict.satisfied,
    schema_missing: verdict.missing,
  }
}

///|
/// Whether the input was already well-formed JSON, so that the only thing
/// InterJSON had to decide was what a repeated member name means (Q-26).
///
/// `R018` is the rule that fires on text a strict JSON reader accepts: RFC 8259
/// permits a repeated name and leaves "which one wins" to the consumer. Every
/// other rule fires on text that is not JSON yet. So "no repair at all" and
/// "only duplicate-key normalisation" are exactly the cases in which
/// *syntactically valid* and *safe to execute* come apart, which is the
/// distinction this field exists to report. The claim is checked against the
/// independent corpus by `code/tests/eval/run_independent.py`.
fn input_was_valid_json(ops : Array[PlanOp]) -> Bool {
  for op in ops {
    if op.rule != "R018" {
      return false
    }
  }
  true
}

///|
/// Whether the value InterJSON hands over was produced by rewriting the input:
/// `true` as soon as any repair was recorded, including the ones that only
/// normalise notation.
pub fn RepairPlan::normalized(self : RepairPlan) -> Bool {
  self.repairs.length() > 0
}

///|
/// Which kind of second reading the plan admits (Q-26).
///
/// `semantic` — two values became one (`merge`), so two consumers that disagree
/// about repeated member names would end up with different values; the plan
/// cannot be executed without choosing for them.
/// `syntactic` — the notation could be read two ways, but the value is the same
/// under both readings.
/// `none` — one reading only.
pub fn RepairPlan::ambiguity_kind(self : RepairPlan) -> String {
  let mut syntactic = false
  for op in self.repairs {
    match op.action {
      // A merge is only a second *meaning* when the two values differ. Merging
      // `{"a":1,"a":1}` loses nothing and both readings give the same value, so
      // the record is Info and this is not an ambiguity at all.
      Merge =>
        if op.information_loss() {
          return "semantic"
        } else if op.ambiguity.is_ambiguous() {
          syntactic = true
        }
      _ => if op.ambiguity.is_ambiguous() { syntactic = true }
    }
  }
  if syntactic {
    "syntactic"
  } else {
    "none"
  }
}

///|
/// `allowed` when the plan may be handed to a tool, `blocked` otherwise.
pub fn RepairPlan::execution(self : RepairPlan) -> String {
  if self.is_executable() {
    "allowed"
  } else {
    "blocked"
  }
}

///|
/// What a schema check adds to a plan: the counts, and the reason when the
/// value does not satisfy the skeleton (FR-36).
priv struct SchemaCheck {
  total : Int32
  satisfied : Int32
  missing : Array[String]
  ok : Bool
  message : String
}

///|
/// `SchemaCheck::decision`: the parse decision, downgraded to `Invalid` when the
/// skeleton is not satisfied.
fn SchemaCheck::decision(
  self : SchemaCheck,
  base : ExecutionDecision,
) -> ExecutionDecision {
  if self.ok {
    base
  } else {
    base.worse_of(Invalid)
  }
}

///|
/// Check a value against an optional skeleton, turning the two failure modes
/// (missing required member, wrong kind) into one sentence.
fn check_schema(schema : Schema?, value : Json) -> SchemaCheck {
  match schema {
    None => { total: 0, satisfied: 0, missing: [], ok: true, message: "", }
    Some(s) => {
      let v = s.evaluate(value)
      let sb = StringBuilder()
      if !v.ok {
        sb.write_string(
          "the value does not satisfy the declared skeleton: " +
          v.satisfied.to_string() +
          "/" +
          v.total.to_string() +
          " declared members",
        )
        if v.missing.length() > 0 {
          sb.write_string("; missing ")
          for i = 0; i < v.missing.length(); i = i + 1 {
            if i > 0 {
              sb.write_string(", ")
            }
            sb.write_string(v.missing[i])
          }
        }
        if v.mismatched.length() > 0 {
          // "mismatch", not "wrong kind": since 0.7.0 the declared kind can be
          // right while a constraint on the value is violated, and `expected`
          // then carries the constraint (`integer >= 0`, `one of ["low",
          // "high"]`) rather than a kind. Calling that a wrong kind sends the
          // reader looking for a type error that is not there.
          sb.write_string("; mismatch ")
          for i = 0; i < v.mismatched.length(); i = i + 1 {
            if i > 0 {
              sb.write_string(", ")
            }
            let m = v.mismatched[i]
            sb.write_string(
              m.path + " (expected " + m.expected + ", got " + m.got + ")",
            )
          }
        }
      }
      {
        total: v.total,
        satisfied: v.satisfied,
        missing: v.missing,
        ok: v.ok,
        message: sb.to_string(),
      }
    }
  }
}

///|
/// The plan for a refused input (FR-33). `E010` and `E011` carry the repair that
/// was refused, so the plan keeps it as an operation: the caller can show the
/// same "why" for a refusal as for an accepted repair.
fn plan_of_error(e : InterJSONError, input : String) -> RepairPlan {
  let code = e.code()
  let refused = match e {
    StrictViolation(c, p, m) => Some((c, p, m, Unambiguous))
    AmbiguousRepair(c, p, a) => Some((c, p, a.message(), a))
    _ => None
  }
  let ops : Array[PlanOp] = []
  let mut exactness = Exact
  let mut ambiguous = false
  match refused {
    Some((c, p, m, a)) => {
      exactness = Lossy
      ambiguous = a.is_ambiguous()
      ops.push({
        rule: c.code(),
        name: c.name(),
        action: plan_action(c),
        position: p,
        severity: Warning,
        ambiguity: a,
        confidence_class: "refused",
        confidence: 0.0,
      })
      ignore(m)
    }
    None => ()
  }
  {
    text: "",
    value: None,
    repairs: ops,
    repairs_truncated: false,
    exactness,
    // A refusal is still a statement about the input: when the rule that was
    // refused is the duplicate-key normalisation, the input *was* well-formed
    // JSON and the refusal is about its meaning, not its syntax (Q-26).
    valid_json: match refused {
      Some((c, _, _, _)) => c is MergeDuplicateKey
      None => false
    },
    ambiguous,
    completeness: Empty,
    decision: decide_error(code),
    retry_hint: e.retry_hint(input~),
    error_code: code,
    error_message: e.to_string(),
    readiness_permille: -1,
    schema_total: 0,
    schema_satisfied: 0,
    schema_missing: [],
  }
}

///|
/// Analyse `input` under `options` (FR-33, FR-33).
///
/// Never raises: a refusal is a plan whose `decision` is not executable and
/// whose `retry_hint` carries the feedback. `readiness` is the sampling step of
/// the syntax readiness measurement; `0` (the default) skips it, because it
/// costs `O(n / step)` partial parses and most callers do not need it.
pub fn analyze(
  input : String,
  options? : Options,
  readiness? : Int32,
  schema? : Schema,
) -> RepairPlan {
  let opts = match options {
    Some(o) => o
    None => Options::default()
  }
  let step = match readiness {
    Some(v) => if v > 0 { v } else { 0 }
    None => 0
  }
  try {
    opts.validate()
    analyze_once(input, opts, step, schema)
  } catch {
    e => {
      let mut retried : RepairPlan? = None
      if opts.skip_prose && refused_no_json(e) && is_valid_json(input) {
        // `skip_prose` looks for the first `{` or `[`, because that is what a
        // chatty model puts the arguments in. A document whose root is a scalar
        // — `true`, `42`, `"ok"`, which RFC 8259 allows — has no such
        // character, so the whole input is skipped as prose and a perfectly
        // valid document is refused. When the input is in fact valid JSON, the
        // skip was wrong and is undone. The retry only happens on that refusal
        // and only for input a strict parser accepts, so prose is never
        // reinterpreted as a value.
        let again : Options = { ..opts, skip_prose: false, }
        try {
          retried = Some(analyze_once(input, again, step, schema))
        } catch {
          e2 => retried = Some(plan_of_error(e2, input))
        }
      }
      match retried {
        Some(p) => p
        None => plan_of_error(e, input)
      }
    }
  }
}

///|
/// Whether the refusal is "there is no JSON here", the only one that says
/// anything about `skip_prose`.
fn refused_no_json(e : InterJSONError) -> Bool {
  match e {
    NoJsonFound(_) => true
    _ => false
  }
}

///|
/// One attempt at analysing `input` with `opts`.
fn analyze_once(
  input : String,
  opts : Options,
  step : Int32,
  schema : Schema?,
) -> RepairPlan raise InterJSONError {
  let engine = Engine::make(opts)
  engine.feed_str(input)
  plan_of_final(engine.finish_engine(), input, step, schema)
}

///|
/// The same analysis for a stream that was fed incrementally (FR-33).
///
/// `input` is optional and only used to quote the window around a refused
/// position; the parser does not keep the text it consumed.
pub fn PartialParser::analyze(
  self : PartialParser,
  input? : String,
  schema? : Schema,
) -> RepairPlan {
  let text = match input {
    Some(t) => t
    None => ""
  }
  plan_of_final(self.finish(), text, 0, schema) catch {
    e => plan_of_error(e, text)
  }
}

///|
/// Render `self` as the `interjson explain` block (FR-33).
///
/// `input` is optional; when it is passed it is echoed under `Input:` truncated
/// to one line, so the block is self-contained in a log.
pub fn RepairPlan::explain_text(self : RepairPlan, input? : String) -> String {
  let sb = StringBuilder()
  sb.write_string("InterJSON Analysis\n")
  sb.write_string(
    "────────────────────────────────\n",
  )
  match input {
    Some(text) => {
      sb.write_string("Input:\n  ")
      sb.write_string(one_line(text))
      sb.write_string("\n")
    }
    None => ()
  }
  sb.write_string("\nRepair:\n")
  if self.repairs.length() == 0 {
    if self.error_code == "" {
      sb.write_string("  none (valid JSON)\n")
    } else {
      sb.write_string("  none\n")
    }
  }
  for op in self.repairs {
    sb.write_string("  ")
    sb.write_string(op.rule)
    sb.write_string(" ")
    sb.write_string(op.name)
    sb.write_string(" (")
    sb.write_string(op.action.name())
    sb.write_string(" at ")
    sb.write_string(op.position.line.to_string())
    sb.write_string(":")
    sb.write_string(op.position.column.to_string())
    sb.write_string(")")
    if op.ambiguity.is_ambiguous() {
      sb.write_string(" [ambiguous: ")
      sb.write_string(op.ambiguity.name())
      sb.write_string("]")
    }
    sb.write_string("\n")
  }
  sb.write_string("\nRisk:\n")
  sb.write_string("  exactness = ")
  sb.write_string(self.exactness.name())
  sb.write_string("\n  ambiguity = ")
  sb.write_string(if self.ambiguous { "yes" } else { "none" })
  sb.write_string("\n  information_loss = ")
  sb.write_string(if self.exactness is Lossy { "true" } else { "false" })
  sb.write_string("\n")
  if self.schema_total > 0 {
    sb.write_string("  schema = ")
    sb.write_string(self.schema_satisfied.to_string())
    sb.write_string("/")
    sb.write_string(self.schema_total.to_string())
    if self.schema_missing.length() > 0 {
      sb.write_string(" (missing ")
      for i = 0; i < self.schema_missing.length(); i = i + 1 {
        if i > 0 {
          sb.write_string(", ")
        }
        sb.write_string(self.schema_missing[i])
      }
      sb.write_string(")")
    }
    sb.write_string("\n")
  }
  sb.write_string("\nDecision:\n  ")
  sb.write_string(self.decision.label())
  sb.write_string("\n")
  if self.decision.is_safe() {
    sb.write_string("\nRepaired:\n  ")
    sb.write_string(one_line(self.text))
    sb.write_string("\n")
  } else {
    sb.write_string("\nSuggested retry:\n")
    for line in self.prompt().split("\n") {
      sb.write_string("  ")
      sb.write_string(line.to_owned())
      sb.write_string("\n")
    }
  }
  sb.to_string()
}

///|
/// The first line of `s`, so that a plan can be printed without echoing a whole
/// document into a log file.
fn one_line(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    if c.to_int() == 0x0A {
      sb.write_string("\\n")
    } else {
      sb.write_char(c)
    }
  }
  let out = sb.to_string()
  let max = 200
  if out.length() <= max {
    out
  } else {
    out[:max].to_owned() + "…"
  }
}

///|
/// Escape a string for the JSON documents this file emits.
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    let n = c.to_int()
    if n == 0x22 {
      sb.write_string("\\\"")
    } else if n == 0x5C {
      sb.write_string("\\\\")
    } else if n == 0x0A {
      sb.write_string("\\n")
    } else if n == 0x0D {
      sb.write_string("\\r")
    } else if n == 0x09 {
      sb.write_string("\\t")
    } else if n < 0x20 {
      sb.write_string("\\u00")
      let hi = n >> 4
      let lo = n & 15
      sb.write_char(hex_digit(hi))
      sb.write_char(hex_digit(lo))
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
fn hex_digit(n : Int32) -> Char {
  if n < 10 {
    Int32::unsafe_to_char(0x30 + n)
  } else {
    Int32::unsafe_to_char(0x61 + (n - 10))
  }
}

///|
/// `"key":"value"` for an already escaped value.
fn kv(key : String, value : String) -> String {
  "\"" + key + "\":\"" + value + "\""
}

///|
/// Machine readable form of the plan, for `interjson explain --json` and for the
/// browser demo. Field names are part of the contract.
pub fn RepairPlan::to_json(self : RepairPlan) -> String {
  let sb = StringBuilder()
  sb.write_string("{")
  sb.write_string(kv("decision", self.decision.name()))
  sb.write_string(",")
  sb.write_string(kv("label", self.decision.label()))
  sb.write_string(",")
  sb.write_string(kv("exactness", self.exactness.name()))
  sb.write_string(",\"ambiguous\":")
  sb.write_string(self.ambiguous.to_string())
  sb.write_string(",\"information_loss\":")
  sb.write_string((self.exactness is Lossy).to_string())
  // Q-26: "syntactically valid" is not "safe to execute", and the pair
  // `valid_json` / `normalized` is what says so. A document can be valid JSON
  // and still be blocked, because a repeated member name has no single meaning.
  sb.write_string(",\"valid_json\":")
  sb.write_string(self.valid_json.to_string())
  sb.write_string(",\"normalized\":")
  sb.write_string(self.normalized().to_string())
  sb.write_string(",")
  sb.write_string(kv("ambiguity", self.ambiguity_kind()))
  sb.write_string(",")
  sb.write_string(kv("execution", self.execution()))
  sb.write_string(",\"executable\":")
  sb.write_string(self.is_executable().to_string())
  sb.write_string(",\"syntax_ready_permille\":")
  sb.write_string(self.readiness_permille.to_string())
  sb.write_string(",\"schema_total\":")
  sb.write_string(self.schema_total.to_string())
  sb.write_string(",\"schema_satisfied\":")
  sb.write_string(self.schema_satisfied.to_string())
  sb.write_string(",\"schema_missing\":[")
  for i = 0; i < self.schema_missing.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("\"" + json_escape(self.schema_missing[i]) + "\"")
  }
  sb.write_string("]")
  sb.write_string(",\"error\":")
  if self.error_code == "" {
    sb.write_string("null")
  } else {
    sb.write_string("{")
    sb.write_string(kv("code", self.error_code))
    sb.write_string(",")
    sb.write_string(kv("message", json_escape(self.error_message)))
    sb.write_string("}")
  }
  sb.write_string(",\"repairs\":[")
  for i = 0; i < self.repairs.length(); i = i + 1 {
    let op = self.repairs[i]
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string("{")
    sb.write_string(kv("rule", op.rule))
    sb.write_string(",")
    sb.write_string(kv("name", op.name))
    sb.write_string(",")
    sb.write_string(kv("action", op.action.name()))
    sb.write_string(",\"offset\":")
    sb.write_string(op.position.offset.to_string())
    sb.write_string(",\"line\":")
    sb.write_string(op.position.line.to_string())
    sb.write_string(",\"column\":")
    sb.write_string(op.position.column.to_string())
    sb.write_string(",")
    sb.write_string(
      kv(
        "severity",
        match op.severity {
          Info => "info"
          Warning => "warning"
        },
      ),
    )
    sb.write_string(",")
    sb.write_string(kv("ambiguity", op.ambiguity.name()))
    sb.write_string(",")
    sb.write_string(kv("confidence", op.confidence_class))
    sb.write_string(",\"confidence_value\":")
    sb.write_string(op.confidence.to_string())
    sb.write_string(",\"information_loss\":")
    sb.write_string(op.information_loss().to_string())
    sb.write_string("}")
  }
  sb.write_string("],\"retry\":")
  match self.retry_hint {
    Some(h) =>
      sb.write_string(
        "{" +
        kv("code", h.error_code) +
        "," +
        kv("prompt", json_escape(h.to_prompt())) +
        "}",
      )
    None => sb.write_string("null")
  }
  sb.write_string(",\"repairs_truncated\":")
  sb.write_string(self.repairs_truncated.to_string())
  // The value itself, so a caller that has the right to execute does not have to
  // parse the text again to get it.
  sb.write_string(",\"value\":")
  match self.value {
    Some(v) => sb.write_string(v.stringify())
    None => sb.write_string("null")
  }
  sb.write_string(",\"text\":")
  sb.write_string("\"" + json_escape(self.text) + "\"")
  sb.write_string("}")
  sb.to_string()
}
