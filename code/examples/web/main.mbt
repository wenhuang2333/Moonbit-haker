// Browser demo entry points: plain String in, plain String out, so the
// generated JavaScript can be called from `static/demo/index.html`.

///|
/// Repair `input` and return the repaired text, or `ERROR: …` on a fatal error.
pub fn repair_text(input : String) -> String {
  @interjson.repair(input).text catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// Repair `input` and return the repair records, one `R005 3:14 message` per
/// line, or `-` when nothing had to be repaired.
pub fn report_text(input : String) -> String {
  try {
    let repairs = @interjson.repair(input).repairs
    if repairs.length() == 0 {
      return "-"
    }
    let sb = StringBuilder()
    for i = 0; i < repairs.length(); i = i + 1 {
      let r = repairs[i]
      if i > 0 {
        sb.write_char('\n')
      }
      sb.write_string(r.code.code())
      sb.write_char(' ')
      sb.write_string(r.position.line.to_string())
      sb.write_char(':')
      sb.write_string(r.position.column.to_string())
      sb.write_char(' ')
      sb.write_string(r.message)
    }
    sb.to_string()
  } catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// Feed the first `upto` code units of `input` and return the partial snapshot
/// as `value | completeness | open path`.
pub fn snapshot_text(input : String, upto : Int32) -> String {
  try {
    let n = if upto < 0 {
      0
    } else if upto > input.length() {
      input.length()
    } else {
      upto
    }
    let parser = @interjson.PartialParser::new()
    parser.feed(input[:n].to_owned())
    let snap = parser.snapshot()
    let value = match snap.value {
      Some(v) => v.stringify()
      None => "-"
    }
    let state = match snap.completeness {
      Empty => "Empty"
      Partial => "Partial"
      Complete => "Complete"
    }
    let sb = StringBuilder()
    sb.write_string(value)
    sb.write_string(" | ")
    sb.write_string(state)
    sb.write_string(" | ")
    for i = 0; i < snap.open_path.length(); i = i + 1 {
      if i > 0 {
        sb.write_char('/')
      }
      match snap.open_path[i] {
        Key(k) => sb.write_string(k)
        Index(x) => sb.write_string(x.to_string())
      }
    }
    sb.to_string()
  } catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// The safety profile named by a string, or `None` when it is unknown/empty.
fn web_policy(name : String) -> @interjson.SafetyPolicy? {
  match name {
    "permissive" => Some(@interjson.SafetyPolicy::permissive())
    "interactive" => Some(@interjson.SafetyPolicy::interactive())
    "execution" => Some(@interjson.SafetyPolicy::for_execution())
    "agent" => Some(@interjson.SafetyPolicy::for_agent())
    "strict" => Some(@interjson.SafetyPolicy::strict())
    _ => None
  }
}

///|
/// Options for a profile name; the default profile when the name is empty or
/// unknown.
fn web_options(policy : String) -> @interjson.Options {
  match web_policy(policy) {
    Some(p) => @interjson.Options::default().with_policy(p)
    None => @interjson.Options::default()
  }
}

///|
/// Repair under a named safety profile.
pub fn repair_opts_text(input : String, policy : String) -> String {
  @interjson.repair(input, options=web_options(policy)).text catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// The decision for a document under a caller-chosen `max_depth`, as JSON:
/// `{"decision": …, "executable": …, "max_depth": …, "error": …}`.
///
/// The value walks became iterative in 1.5.0, so the depth a document may
/// have is bounded by the heap rather than by the native stack: the limit that
/// used to be a stack depth is now a caller-chosen budget. The demo page
/// raises it to show a hundred-thousand-level document parsed in the browser,
/// so the entry point takes the budget as an argument instead of hard-coding
/// one: the default stays where the library puts it.
pub fn analyze_depth_text(input : String, max_depth : Int32) -> String {
  let opts = { ..@interjson.Options::default(), max_depth, }
  let plan = @interjson.analyze(input, options=opts)
  let sb = StringBuilder()
  sb.write_string("{\"decision\":")
  sb.write_string("\"" + escape(plan.decision.name()) + "\"")
  sb.write_string(",\"executable\":")
  sb.write_string(plan.is_executable().to_string())
  sb.write_string(",\"max_depth\":")
  sb.write_string(max_depth.to_string())
  sb.write_string(",\"error\":")
  match plan.error_code {
    "" => sb.write_string("null")
    code => {
      sb.write_string("{\"code\":")
      sb.write_string("\"" + escape(code) + "\"")
      sb.write_string(",\"message\":")
      sb.write_string("\"" + escape(plan.error_message) + "\"")
      sb.write_string("}")
    }
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// The full decision plan as JSON, with the library's declaration language.
///
/// A declaration that cannot be parsed is reported as `{"error": …}` instead of
/// being silently replaced by `Schema::Any`: a page that showed "no skeleton"
/// for a typo would be claiming the document passed a check that never ran.
pub fn analyze_text(input : String, policy : String, schema : String) -> String {
  let opts = web_options(policy)
  if schema == "" {
    return @interjson.analyze(input, options=opts).to_json()
  }
  let s = @interjson.Schema::parse(schema) catch {
    e => return "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
  @interjson.analyze(input, options=opts, schema=s).to_json()
}

///|
/// The full decision plan as JSON, taking the JSON Schema subset a tool
/// declaration already carries. An unsupported keyword is reported, never
/// silently dropped.
pub fn analyze_json_schema_text(
  input : String,
  policy : String,
  schema_json : String,
) -> String {
  let mut err = ""
  let parsed = Some(@interjson.Schema::parse_json_schema(schema_json)) catch {
    e => {
      err = e.to_string()
      None
    }
  }
  match parsed {
    Some(s) => {
      let plan = @interjson.analyze(
        input,
        options=web_options(policy),
        schema=s,
      )
      plan.to_json()
    }
    None => "{\"error\":\"" + escape(err) + "\"}"
  }
}

///|
/// The same analysis with `skip_prose` on, for the chat-channel case where a
/// model prefixes the arguments with a sentence. A malformed declaration is
/// reported, not replaced by `Schema::Any` (see `analyze_text`).
pub fn analyze_prose_text(
  input : String,
  policy : String,
  schema : String,
) -> String {
  let opts = { ..web_options(policy), skip_prose: true, }
  if schema == "" {
    return @interjson.analyze(input, options=opts).to_json()
  }
  let s = @interjson.Schema::parse(schema) catch {
    e => return "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
  @interjson.analyze(input, options=opts, schema=s).to_json()
}

///|
/// `analyze_json_schema` with `skip_prose` on.
pub fn analyze_json_schema_prose_text(
  input : String,
  policy : String,
  schema_json : String,
) -> String {
  let opts = { ..web_options(policy), skip_prose: true, }
  let parsed = Some(@interjson.Schema::parse_json_schema(schema_json)) catch {
    e => return "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
  match parsed {
    Some(s) => {
      let plan = @interjson.analyze(input, options=opts, schema=s)
      plan.to_json()
    }
    None => "{\"error\":\"schema\"}"
  }
}

///|
/// The readiness curve as JSON: the three document-level numbers, every
/// field-ready event with the input fraction it happened at, and the final
/// verdict. One pass of the engine; the page only draws what came back.
pub fn readiness_text(input : String, schema : String) -> String {
  let s = @interjson.Schema::parse(schema) catch {
    e => return "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
  try {
    let full = @interjson.semantic_readiness(input, s)
    let events = @interjson.watch_readiness(input, s)
    let fields = @interjson.field_readiness(input)
    let sb = StringBuilder()
    sb.write_string("{\"syntax_permille\":")
    sb.write_string(full.syntax_permille.to_string())
    sb.write_string(",\"schema_permille\":")
    sb.write_string(full.schema_permille.to_string())
    sb.write_string(",\"settled_permille\":")
    sb.write_string(full.settled_permille.to_string())
    sb.write_string(",\"verdict\":{\"ok\":")
    sb.write_string(full.verdict.ok.to_string())
    sb.write_string(",\"total\":")
    sb.write_string(full.verdict.total.to_string())
    sb.write_string(",\"satisfied\":")
    sb.write_string(full.verdict.satisfied.to_string())
    sb.write_string(",\"missing\":[")
    for i = 0; i < full.verdict.missing.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string("\"" + escape(full.verdict.missing[i]) + "\"")
    }
    sb.write_string("],\"mismatched\":[")
    for i = 0; i < full.verdict.mismatched.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      let m = full.verdict.mismatched[i]
      sb.write_string("{\"path\":\"")
      sb.write_string(escape(m.path))
      sb.write_string("\",\"expected\":\"")
      sb.write_string(escape(m.expected))
      sb.write_string("\",\"got\":\"")
      sb.write_string(escape(m.got))
      sb.write_string("\"}")
    }
    sb.write_string("]},\"events\":[")
    for i = 0; i < events.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string("{\"permille\":")
      sb.write_string(events[i].permille.to_string())
      sb.write_string(",\"event\":")
      sb.write_string(events[i].event.to_json())
      sb.write_string("}")
    }
    sb.write_string("],\"fields\":[")
    for i = 0; i < fields.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string("{\"key\":\"")
      sb.write_string(escape(fields[i].key))
      sb.write_string("\",\"permille\":")
      sb.write_string(fields[i].permille.to_string())
      sb.write_string("}")
    }
    sb.write_string("]}")
    sb.to_string()
  } catch {
    e => "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
}

///|
/// The delta stream for the first `upto` code units: the protocol a consumer
/// subscribes to instead of re-reading the document on every frame.
pub fn deltas_text(input : String, upto : Int32) -> String {
  let n = input.length()
  let cap = if upto < 0 { 0 } else if upto > n { n } else { upto }
  try {
    let parser = @interjson.PartialParser::new(
      options=@interjson.Options::for_llm(),
    )
    parser.feed(input[:cap].to_owned())
    let ds = parser.drain_deltas()
    let sb = StringBuilder()
    sb.write_string("{\"consumed\":")
    sb.write_string(cap.to_string())
    sb.write_string(",\"total\":")
    sb.write_string(n.to_string())
    sb.write_string(",\"deltas\":[")
    for i = 0; i < ds.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      let d = ds[i]
      sb.write_string("{\"op\":\"")
      sb.write_string(d.op.name())
      sb.write_string("\",\"pointer\":\"")
      sb.write_string(escape(d.pointer()))
      sb.write_string("\",\"at\":")
      sb.write_string(d.at.to_string())
      sb.write_string(",\"value\":")
      match d.value {
        Some(v) => sb.write_string("\"" + escape(v.stringify()) + "\"")
        None => sb.write_string("null")
      }
      sb.write_string(",\"text\":\"")
      sb.write_string(escape(d.text))
      sb.write_string("\"}")
    }
    sb.write_string("]}")
    sb.to_string()
  } catch {
    e => "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
}

///|
/// The live streaming view: everything the browser page needs to render one
/// frame of a model's output, as one JSON object (FR-35).
///
/// `upto` is how many code units of `input` the model has emitted so far. The
/// page calls this once per animation frame, so the function is written to be
/// called a few hundred times per second on inputs of a few kilobytes: the
/// parser is fed from scratch each time (a stream is cheap to replay and
/// stateless in the page), and the readiness measurement is the only
/// `O(n / step)` part.
pub fn live_text(input : String, upto : Int32, schema : String) -> String {
  let n = input.length()
  let cap = if upto < 0 { 0 } else if upto > n { n } else { upto }
  let prefix = input[:cap].to_owned()
  // A declaration that cannot be parsed is reported before any frame is built:
  // the streaming page must not show "no skeleton" for a typo.
  let declared : @interjson.Schema? = if schema == "" {
    None
  } else {
    Some(@interjson.Schema::parse(schema)) catch {
      e => return "{\"error\":\"" + escape(e.to_string()) + "\"}"
    }
  }
  try {
    // Two channels, on purpose. The display channel is permissive and follows
    // the value as it is written (`for_llm` turns on the delta stream); the
    // execution channel is the gate (`for_agent`), which refuses a truncated
    // prefix because closing it would invent the rest. A page that showed only
    // one of the two would either hide the risk or block on every frame.
    let stream_opts = @interjson.Options::for_llm()
    let gate_opts = @interjson.Options::for_agent()
    let parser = @interjson.PartialParser::new(options=stream_opts)
    parser.feed(prefix)
    // The members seen so far, and which of them can no longer change. This is
    // the delta protocol being used as intended: a consumer subscribes to the
    // state changes instead of re-reading the document.
    let snap = parser.snapshot()
    let keys : Array[String] = match snap.value {
      Some(Json::Object(m)) => {
        let out : Array[String] = []
        for k, _v in m {
          out.push(k)
        }
        out
      }
      _ => []
    }
    let tracker = @interjson.FieldTracker::new(keys)
    for d in parser.drain_deltas() {
      tracker.feed(d)
    }
    let plan = @interjson.analyze(prefix, options=gate_opts)
    let sb = StringBuilder()
    sb.write_string("{\"consumed\":")
    sb.write_string(cap.to_string())
    sb.write_string(",\"total\":")
    sb.write_string(n.to_string())
    sb.write_string(",\"completeness\":\"")
    sb.write_string(
      match snap.completeness {
        Empty => "Empty"
        Partial => "Partial"
        Complete => "Complete"
      },
    )
    sb.write_string("\",\"snapshot\":\"")
    sb.write_string(
      escape(
        match snap.value {
          Some(v) => v.stringify()
          None => ""
        },
      ),
    )
    sb.write_string("\",\"open_path\":\"")
    sb.write_string(escape(path_text(snap)))
    sb.write_string("\",\"members\":[")
    for i = 0; i < keys.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string("{\"key\":\"")
      sb.write_string(escape(keys[i]))
      sb.write_string("\",\"ready\":")
      sb.write_string(tracker.ready(keys[i]).to_string())
      sb.write_string("}")
    }
    sb.write_string("],\"ready\":")
    sb.write_string(tracker.ready_count().to_string())
    sb.write_string(",\"seen\":")
    sb.write_string(keys.length().to_string())
    sb.write_string(",\"plan\":")
    sb.write_string(plan.to_json())
    match declared {
      Some(sk) => {
        let plan2 = @interjson.analyze(prefix, options=gate_opts, schema=sk)
        sb.write_string(",\"schema\":")
        sb.write_string(plan2.to_json())
        // The document level readiness: two fractions of the *whole* stream. The
        // page uses them to answer the interesting question, which is not
        // "has the JSON ended" but "do I already have what I asked for".
        let full = @interjson.semantic_readiness(input, sk, step=1) catch {
          _ =>
            {
              syntax_permille: -1,
              settled_permille: -1,
              schema_permille: -1,
              step: 1,
              verdict: {
                total: 0,
                satisfied: 0,
                missing: [],
                mismatched: [],
                ok: false,
              },
            }
        }
        sb.write_string(",\"syntax_ready\":")
        sb.write_string(full.syntax_permille.to_string())
        sb.write_string(",\"schema_ready\":")
        sb.write_string(full.schema_permille.to_string())
        // `settled` is when every declared member became final, whether or not it
        // had the declared kind. It is the number a streaming caller acts on: a
        // wrong-typed argument settles early and the page can say "decided at
        // N%, the answer is no" instead of "not ready until the end".
        sb.write_string(",\"settled_ready\":")
        sb.write_string(full.settled_permille.to_string())
        sb.write_string(",\"declared\":")
        sb.write_string(full.verdict.satisfied.to_string())
        sb.write_string(",\"declared_total\":")
        sb.write_string(full.verdict.total.to_string())
        // Execution readiness: every member the caller declared is already final,
        // and nothing seen so far had two readings. That is the moment the caller
        // may stop the generation, which is usually long before the end. The
        // arrival is `settled_permille`, not `schema_permille`: for an argument
        // of the wrong kind the arrival is early and the answer is no, and the
        // page should be able to stop there.
        let reached = n == 0 || cap * 1000 / n >= full.settled_permille
        sb.write_string(",\"execution_ready\":")
        sb.write_string(
          (reached && full.verdict.ok && !snap.ambiguous).to_string(),
        )
        sb.write_string(",\"missing\":[")
        for i = 0; i < full.verdict.missing.length(); i = i + 1 {
          if i > 0 {
            sb.write_string(",")
          }
          sb.write_string("\"" + escape(full.verdict.missing[i]) + "\"")
        }
        sb.write_string("]")
      }
      None => ()
    }
    sb.write_string("}")
    sb.to_string()
  } catch {
    e => "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
}

///|
/// `open_path` as `a/0/b`.
fn path_text(snap : @interjson.Snapshot) -> String {
  let sb = StringBuilder()
  for i = 0; i < snap.open_path.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('/')
    }
    match snap.open_path[i] {
      Key(k) => sb.write_string(k)
      Index(x) => sb.write_string(x.to_string())
    }
  }
  sb.to_string()
}

///|
/// Minimal JSON string escaping for the demo's own output.
fn escape(s : String) -> String {
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
      sb.write_string("?")
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
extern "js" fn js_register1(name : String, f : (String) -> String) -> Unit = "globalThis.interjsonRegister1"

///|
extern "js" fn js_register3(
  name : String,
  f : (String, Int32, String) -> String,
) -> Unit = "globalThis.interjsonRegister3"

///|
extern "js" fn js_register2(
  name : String,
  f : (String, Int32) -> String,
) -> Unit = "globalThis.interjsonRegister2"

///|
/// The same host hook, for a two-string entry point (`repair_opts`). The host
/// function is untyped JavaScript, so one global hook serves both signatures.
extern "js" fn js_register2s(
  name : String,
  f : (String, String) -> String,
) -> Unit = "globalThis.interjsonRegister2"

///|
/// The three-string form of the same hook (`analyze`).
extern "js" fn js_register3s(
  name : String,
  f : (String, String, String) -> String,
) -> Unit = "globalThis.interjsonRegister3"

///|
/// Hand the entry points to the host page. No banner: the bundle is also
/// imported as a library (npm, MCP hosts, tests), and a library that writes to
/// stdout on import breaks line-oriented protocols.
fn main {
  js_register1("repair", repair_text)
  js_register1("report", report_text)
  js_register2("snapshot", snapshot_text)
  js_register3("live", live_text)
  js_register2s("repair_opts", repair_opts_text)
  js_register3s("analyze", analyze_text)
  js_register3s("analyze_json_schema", analyze_json_schema_text)
  js_register3s("analyze_prose", analyze_prose_text)
  js_register2("analyze_depth", analyze_depth_text)
  js_register3s("analyze_json_schema_prose", analyze_json_schema_prose_text)
  js_register2s("readiness", readiness_text)
  js_register2("deltas", deltas_text)
}
