// FR-32 — SafetyPolicy: the named safety profiles.

///|
/// A result or the code of the error that stopped it.
enum PolicyOutcome {
  Accepted(RepairResult)
  Refused(String)
}

///|
/// `repair` under `o`, as an outcome, so that an assertion can never be
/// swallowed by the `catch` that is being tested.
fn repair_with(text : String, o : Options) -> PolicyOutcome {
  Accepted(repair(text, options=o)) catch {
    e => Refused(e.code())
  }
}

///|
test "the five profiles map onto documented options" {
  assert_eq(SafetyPolicy::permissive().max_loss.name(), "lossy")
  assert_eq(SafetyPolicy::permissive().reject_ambiguous, false)
  assert_eq(SafetyPolicy::interactive().max_loss.name(), "cosmetic")
  assert_eq(SafetyPolicy::interactive().reject_ambiguous, false)
  assert_eq(SafetyPolicy::for_execution().max_loss.name(), "cosmetic")
  assert_eq(SafetyPolicy::for_execution().reject_ambiguous, true)
  // `for_agent` is `for_execution` in safety terms; what an agent adds is the
  // protocol, which lives in `Options::for_agent`, not in the policy.
  assert_eq(SafetyPolicy::for_agent().max_loss.name(), "cosmetic")
  assert_eq(SafetyPolicy::for_agent().reject_ambiguous, true)
  // The agent profile additionally bounds the resources, because an agent
  // cannot look at the whole input before deciding to accept it.
  assert_true(SafetyPolicy::for_agent().max_depth == 64)
  assert_true(SafetyPolicy::for_agent().max_input_len == 1048576)
  assert_true(SafetyPolicy::strict().mode == Strict)
  // `max_loss` is not consulted under `Strict`: the first repair is refused
  // before the exactness gate sees it.
  assert_eq(SafetyPolicy::strict().max_loss.name(), "lossy")
}

///|
test "permissive repairs what execution refuses" {
  // Two adjacent strings in an array have two readings, so the execution
  // profile refuses instead of choosing one.
  let text = "{\"words\":[\"colour\" \"color\"]}"
  match repair_with(text, SafetyPolicy::permissive().to_options()) {
    Accepted(r) => {
      assert_eq(r.ambiguous, true)
      assert_eq(r.text, "{\"words\":[\"colour\",\"color\"]}")
    }
    Refused(code) => assert_true(false, msg="permissive refused: " + code)
  }
  match repair_with(text, SafetyPolicy::for_execution().to_options()) {
    Accepted(_) =>
      assert_true(false, msg="execution accepted an ambiguous repair")
    Refused(code) => assert_eq(code, "E011")
  }
}

///|
test "interactive accepts a cosmetic repair and refuses a lossy one" {
  match repair_with("{'a':1}", SafetyPolicy::interactive().to_options()) {
    Accepted(r) => {
      assert_eq(r.text, "{\"a\":1}")
      assert_eq(r.exactness.name(), "cosmetic")
    }
    Refused(code) =>
      assert_true(false, msg="interactive refused a quote: " + code)
  }
  // Closing a truncated string invents its tail, which a human would read as
  // if the model had said it.
  match repair_with("{\"a\":\"x", SafetyPolicy::interactive().to_options()) {
    Accepted(_) => assert_true(false, msg="interactive accepted a lossy repair")
    Refused(code) => assert_eq(code, "E010")
  }
}

///|
test "strict refuses even a normalised quote" {
  match repair_with("{\"a\":'x'}", SafetyPolicy::strict().to_options()) {
    Accepted(_) => assert_true(false, msg="strict accepted a normalised quote")
    Refused(code) => assert_eq(code, "E010")
  }
}

///|
test "with_policy replaces the safety knobs and keeps the protocol ones" {
  let agent = Options::for_agent()
  assert_eq(agent.collect_deltas, true)
  assert_eq(agent.skip_prose, true)
  // Overlaying the execution policy must not switch the delta stream off: that
  // is the whole reason the policy does not own the protocol.
  let overlaid = agent.with_policy(SafetyPolicy::for_execution())
  assert_eq(overlaid.collect_deltas, true)
  assert_eq(overlaid.skip_prose, true)
  assert_eq(overlaid.reject_ambiguous, true)
  assert_eq(overlaid.max_loss.name(), "cosmetic")
}

///|
test "of_options names the profile the options actually are" {
  assert_eq(SafetyPolicy::of_options(Options::default()), Some("permissive"))
  assert_eq(SafetyPolicy::of_options(Options::for_llm()), Some("permissive"))
  assert_eq(
    SafetyPolicy::of_options(Options::for_execution()),
    Some("execution"),
  )
  assert_eq(SafetyPolicy::of_options(Options::for_agent()), Some("agent"))
  assert_eq(SafetyPolicy::of_options(Options::strict()), Some("strict"))
  // A hand written combination is not one of the profiles, and the library says
  // so instead of rounding it to the nearest name. (`max_loss: Cosmetic` alone
  // *is* the interactive profile; the duplicate-key policy is what makes this
  // one different.)
  let mixed = {
    ..Options::default(),
    max_loss: Cosmetic,
    duplicate_keys: KeepFirst,
  }
  assert_eq(SafetyPolicy::of_options(mixed), None)
}

///|
test "options built from a policy validate" {
  let policies : Array[SafetyPolicy] = [
    SafetyPolicy::permissive(),
    SafetyPolicy::interactive(),
    SafetyPolicy::for_execution(),
    SafetyPolicy::for_agent(),
    SafetyPolicy::strict(),
  ]
  for p in policies {
    let o = p.to_options()
    o.validate() catch {
      e => assert_true(false, msg=p.name() + ": " + e.to_string())
    }
  }
}

///|
test "for_text keeps the text and drops the repair log" {
  let o = Options::for_text()
  assert_eq(o.collect_repairs, false)
  assert_eq(o.want_text, true)
  assert_eq(o.indent, 0)
  match repair_with("{'a':1,}", o) {
    Accepted(r) => {
      // The text is still repaired; only the records are not kept. A caller
      // that wants both asks for the default profile.
      assert_eq(r.text, "{\"a\":1}")
      assert_eq(r.repairs.length(), 0)
      assert_eq(r.exactness.name(), "cosmetic")
    }
    Refused(code) => assert_true(false, msg="for_text refused: " + code)
  }
}
