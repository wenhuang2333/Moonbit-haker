// Browser demo entry points: plain String in, plain String out, so the
// generated JavaScript can be called from `static/demo/index.html`.

///|
/// Repair `input` and return the repaired text, or `ERROR: …` on a fatal error.
pub fn repair_text(input : String) -> String {
  @mend.repair(input).text catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// Repair `input` and return the repair records, one `R005 3:14 message` per
/// line, or `-` when nothing had to be repaired.
pub fn report_text(input : String) -> String {
  try {
    let repairs = @mend.repair(input).repairs
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
    let parser = @mend.PartialParser::new()
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
  try {
    // Two channels, on purpose. The display channel is permissive and follows
    // the value as it is written (`for_llm` turns on the delta stream); the
    // execution channel is the gate (`for_agent`), which refuses a truncated
    // prefix because closing it would invent the rest. A page that showed only
    // one of the two would either hide the risk or block on every frame.
    let stream_opts = @mend.Options::for_llm()
    let gate_opts = @mend.Options::for_agent()
    let parser = @mend.PartialParser::new(options=stream_opts)
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
    let tracker = @mend.FieldTracker::new(keys)
    for d in parser.drain_deltas() {
      tracker.feed(d)
    }
    let plan = @mend.analyze(prefix, options=gate_opts)
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
    if schema != "" {
      let sk = @mend.Schema::parse(schema) catch { _ => @mend.Schema::Any }
      let plan2 = @mend.analyze(prefix, options=gate_opts, schema=sk)
      sb.write_string(",\"schema\":")
      sb.write_string(plan2.to_json())
      // The document level readiness: two fractions of the *whole* stream. The
      // page uses them to answer the interesting question, which is not
      // "has the JSON ended" but "do I already have what I asked for".
      let full = @mend.semantic_readiness(input, sk, step=1) catch {
        _ =>
          {
            syntax_permille: -1,
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
      sb.write_string(",\"declared\":")
      sb.write_string(full.verdict.satisfied.to_string())
      sb.write_string(",\"declared_total\":")
      sb.write_string(full.verdict.total.to_string())
      // Execution readiness: every member the caller declared is already final,
      // and nothing seen so far had two readings. That is the moment the caller
      // may stop the generation, which is usually long before the end.
      let reached = n == 0 || cap * 1000 / n >= full.schema_permille
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
    sb.write_string("}")
    sb.to_string()
  } catch {
    e => "{\"error\":\"" + escape(e.to_string()) + "\"}"
  }
}

///|
/// `open_path` as `a/0/b`.
fn path_text(snap : @mend.Snapshot) -> String {
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
extern "js" fn js_register1(name : String, f : (String) -> String) -> Unit = "globalThis.jsonmendRegister1"

///|
extern "js" fn js_register3(
  name : String,
  f : (String, Int32, String) -> String,
) -> Unit = "globalThis.jsonmendRegister3"

///|
extern "js" fn js_register2(
  name : String,
  f : (String, Int32) -> String,
) -> Unit = "globalThis.jsonmendRegister2"

///|
/// Hand the demo entry points to the host page and print a banner.
fn main {
  js_register1("repair", repair_text)
  js_register1("report", report_text)
  js_register2("snapshot", snapshot_text)
  js_register3("live", live_text)
  println("jsonmend demo bundle ready")
}
