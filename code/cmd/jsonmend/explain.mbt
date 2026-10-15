// `jsonmend explain` — the whole analysis in one block (FR-32, FR-33).
//
// The three pieces the library already had (repair records, exactness, retry
// hints) were only useful to a caller who knew how to read all three at once.
// `explain` prints them as one decision, which is also the shortest way to show
// a reviewer what the gate actually does:
//
//   JSONMend Analysis
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
    eprintln("jsonmend: 无法读取 " + name)
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
fn schema_of(o : CliOpts) -> @mend.Schema? {
  if o.schema == "" {
    None
  } else {
    Some(@mend.Schema::parse(o.schema) catch { _ => @mend.Schema::Any })
  }
}

///|
/// The syntax and schema readiness numbers `--schema` adds (FR-34): two
/// fractions of the input, plus the members that never arrived.
fn print_readiness_lines(
  text : String,
  schema : @mend.Schema,
  step : Int32,
  options : @mend.Options,
) -> Unit {
  let mut err = ""
  // The curve is a property of the input and the declaration, not of how strict
  // the caller is: it says *when* the declared members are final, and the gate
  // says *whether* the value may be used. So the reader keeps the protocol the
  // plan was built with (a prefixed sentence must not break the measurement)
  // and drops the gate's safety knobs, which would otherwise turn an unfinished
  // document into "no measurement at all".
  let measure : @mend.Options = {
    ..options,
    mode: @mend.Lenient,
    max_loss: @mend.Lossy,
    reject_ambiguous: false,
  }
  let r = @mend.semantic_readiness(text, schema, step~, options=measure) catch {
    e => {
      err = e.to_string()
      {
        syntax_permille: 0,
        schema_permille: 0,
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
    eprintln("jsonmend: " + err)
    return
  }
  let sb = StringBuilder()
  sb.write_string("jsonmend: syntax-ready ")
  sb.write_string(r.syntax_permille.to_string())
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
/// `jsonmend explain`: analyse the input and print the decision (FR-32).
fn run_explain(o : CliOpts) -> Unit {
  let text = read_stdin_or_file(o.path)
  let schema = schema_of(o)
  let opts = options_of(o, agent_protocol=true)
  let plan = match schema {
    Some(s) => @mend.analyze(text, options=opts, schema=s)
    None => @mend.analyze(text, options=opts)
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
