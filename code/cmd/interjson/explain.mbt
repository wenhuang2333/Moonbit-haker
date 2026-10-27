// `interjson explain` — the whole analysis in one block (FR-32, FR-33).
//
// The three pieces the library already had (repair records, exactness, retry
// hints) were only useful to a caller who knew how to read all three at once.
// `explain` prints them as one decision, which is also the shortest way to show
// a reviewer what the gate actually does:
//
//   InterJSON Analysis
//   ────────────────────────────────
//   Input:
//     {"name":"Alice","age":18,}
//
//   Repair:
//     R005 RemoveExtraComma (remove at 1:21)
//
//   Risk:
//     exactness = cosmetic
//     ambiguity = none
//     information_loss = false
//
//   Decision:
//     SAFE TO EXECUTE

///|
/// Read the whole input, exiting 3 when it cannot be opened.
fn read_stdin_or_file(path : String?) -> String {
  let stream = open_input(path)
  if stream == 0L {
    let name = match path {
      Some(p) => p
      None => "<stdin>"
    }
    eprintln("interjson: 无法读取 " + name)
    quit(3)
    return ""
  }
  let text = read_all(stream)
  close_input(stream)
  text
}

///|
/// The skeleton declaration for this run, or `None` when `--schema` was not
/// given.
///
/// `parse_args` has already read the declaration once, so the fallback branch
/// is unreachable; it exists because a `catch` arm must produce a value.
fn schema_of(o : CliOpts) -> @ij.Schema? {
  if o.schema == "" {
    None
  } else {
    Some(@ij.Schema::parse(o.schema) catch { _ => @ij.Schema::Any })
  }
}

///|
/// The syntax and schema readiness numbers `--schema` adds (FR-34): two
/// fractions of the input, plus the members that never arrived.
fn print_readiness_lines(
  text : String,
  schema : @ij.Schema,
  step : Int32,
  options : @ij.Options,
) -> Unit {
  let mut err = ""
  // The curve is a property of the input and the declaration, not of how strict
  // the caller is: it says *when* the declared members are final, and the gate
  // says *whether* the value may be used. So the reader keeps the protocol the
  // plan was built with (a prefixed sentence must not break the measurement)
  // and drops the gate's safety knobs, which would otherwise turn an unfinished
  // document into "no measurement at all".
  let measure : @ij.Options = {
    ..options,
    mode: @ij.Lenient,
    max_loss: @ij.Lossy,
    reject_ambiguous: false,
  }
  let r = @ij.semantic_readiness(text, schema, step~, options=measure) catch {
    e => {
      err = e.to_string()
      {
        syntax_permille: 0,
        schema_permille: 0,
        settled_permille: 0,
        step: 0,
        verdict: {
          total: 0,
          satisfied: 0,
          missing: [],
          mismatched: [],
          ok: false,
        },
      }
    }
  }
  if err != "" {
    eprintln("interjson: " + err)
    return
  }
  let sb = StringBuilder()
  sb.write_string("interjson: syntax-ready ")
  sb.write_string(r.syntax_permille.to_string())
  sb.write_string("/1000 settled ")
  // `settled` is the runtime number: every declared member is final, whether or
  // not it had the declared kind. `schema-ready` additionally requires the
  // skeleton to be satisfied, so a decidable-and-invalid document reports it as
  // `1000` — "not before the end" — while `settled` says when the answer
  // actually arrived (FR-39).
  sb.write_string(r.settled_permille.to_string())
  sb.write_string("/1000 schema-ready ")
  sb.write_string(r.schema_permille.to_string())
  sb.write_string("/1000 declared ")
  sb.write_string(r.verdict.satisfied.to_string())
  sb.write_string("/")
  sb.write_string(r.verdict.total.to_string())
  sb.write_string(" ok=")
  sb.write_string(r.verdict.ok.to_string())
  sb.write_string(" step ")
  sb.write_string(r.step.to_string())
  println(sb.to_string())
  for m in r.verdict.missing {
    println("schema missing " + m)
  }
  for m in r.verdict.mismatched {
    println(
      "schema mismatch " + m.path + " expected " + m.expected + " got " + m.got,
    )
  }
}

///|
/// `interjson explain`: analyse the input and print the decision (FR-32).
fn run_explain(o : CliOpts) -> Unit {
  let text = read_stdin_or_file(o.path)
  let schema = schema_of(o)
  let opts = options_of(o, agent_protocol=true)
  // `--json` already carries the value, so the rendered text is a second copy
  // of the whole document that a machine consumer does not need. It is dropped
  // unless `--with-text` asks for it; the text block below always renders it,
  // because `Repaired:` is the point of that format.
  let plan_opts = if o.json_out && !o.with_text {
    { ..opts, want_text: false, }
  } else {
    opts
  }
  let plan = match schema {
    Some(s) => @ij.analyze(text, options=plan_opts, schema=s)
    None => @ij.analyze(text, options=plan_opts)
  }
  if o.json_out {
    println(plan.to_json())
  } else {
    println(plan.explain_text(input=text))
    match schema {
      Some(s) => print_readiness_lines(text, s, 0, opts)
      None => ()
    }
  }
  if !plan.is_executable() {
    quit(5)
  }
  quit(0)
}
