// `interjson llm` — drive the provider adapters from a recorded event stream.
//
//   interjson llm --provider anthropic < events.jsonl
//   interjson llm --provider openai --sse < response.txt
//   interjson llm --follow ...        # one line per update instead of per call
//
// This is the command line face of FR-23: it makes the adapters usable on a
// captured stream without writing any code, and it is what the demo page and
// the fixtures are checked against.

///|
/// Split a recorded stream into event payloads.
fn llm_payloads(text : String, sse : Bool) -> Array[String] {
  let out : Array[String] = []
  if sse {
    let b = @llm.SseBuffer::new()
    for e in b.push(text) {
      out.push(e)
    }
    for e in b.flush() {
      out.push(e)
    }
  } else {
    for line in text.split("\n") {
      if line.length() > 0 {
        out.push(line.to_owned())
      }
    }
  }
  out
}

///|
/// One result line, in the same shape as `--batch`.
fn llm_line(v : @llm.ToolCallView) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"index\":")
  sb.write_string(v.index.to_string())
  sb.write_string(",\"id\":")
  sb.write_string(Json::string(v.id).stringify())
  sb.write_string(",\"name\":")
  sb.write_string(Json::string(v.name).stringify())
  sb.write_string(",\"done\":")
  sb.write_string(if v.done { "true" } else { "false" })
  sb.write_string(",\"exactness\":")
  sb.write_string(Json::string(v.exactness.name()).stringify())
  sb.write_string(",\"end\":")
  sb.write_string(Json::string(v.end.name()).stringify())
  sb.write_string(",\"stop_reason\":")
  sb.write_string(Json::string(v.stop_reason).stringify())
  sb.write_string(",\"value\":")
  match v.snapshot.value {
    Some(x) => sb.write_string(x.stringify())
    None => sb.write_string("null")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// Provider named on the command line.
fn provider_of(name : String) -> @llm.Provider? {
  if name == "openai" {
    Some(@llm.OpenAICompat)
  } else if name == "anthropic" {
    Some(@llm.Anthropic)
  } else {
    None
  }
}

///|
/// One `{"id", "events"}` batch line: feed every event payload of `events` and
/// render the finished calls. Used by the evaluation harness to run the same
/// corpus through the adapter path.
fn llm_batch_line(
  id : String,
  events : Array[String],
  provider : @llm.Provider,
  options : @ij.Options,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":")
  sb.write_string(Json::string(id).stringify())
  sb.write_string(",\"rc\":")
  let mut rc = 0
  let calls : Array[String] = []
  try {
    let s = @llm.ToolStream::new(provider, options~)
    for e in events {
      ignore(s.push_event(e))
    }
    for v in s.finish() {
      calls.push(llm_line(v))
    }
  } catch {
    e => {
      rc = error_exit_code(e)
      calls.push("{\"error\":" + Json::string(e.to_string()).stringify() + "}")
    }
  }
  sb.write_string(rc.to_string())
  sb.write_string(",\"calls\":[")
  for i = 0; i < calls.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(",")
    }
    sb.write_string(calls[i])
  }
  sb.write_string("]}")
  sb.to_string()
}

///|
/// Run the `llm` subcommand in `--batch` mode: one `{"id","events"}` object per
/// input line, one result line per input.
fn run_llm_batch(provider : @llm.Provider, options : @ij.Options) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("interjson: 无法读取 <stdin>")
    return quit(3)
  }
  let text = read_all(stream)
  close_input(stream)
  let mut n = 0
  for line in text.split("\n") {
    if line.length() == 0 {
      continue
    }
    let fallback = "line-" + n.to_string()
    n = n + 1
    let v = @json.parse(line) catch {
      _ => {
        println(
          "{\"id\":" +
          Json::string(fallback).stringify() +
          ",\"rc\":2,\"calls\":[]}",
        )
        continue
      }
    }
    let (id, events) = llm_batch_fields(v, fallback)
    println(llm_batch_line(id, events, provider, options))
  }
  quit(0)
}

///|
/// One line for the text path: the same shape as one tool call, so a harness
/// can read either with the same code.
fn text_line(
  snapshot : Json?,
  exactness : @ij.Exactness,
  end : @llm.CallEnd,
  stop_reason : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"index\":0,\"id\":\"\",\"name\":\"\",\"done\":")
  sb.write_string(if end is @llm.Open { "false" } else { "true" })
  sb.write_string(",\"exactness\":")
  sb.write_string(Json::string(exactness.name()).stringify())
  sb.write_string(",\"end\":")
  sb.write_string(Json::string(end.name()).stringify())
  sb.write_string(",\"stop_reason\":")
  sb.write_string(Json::string(stop_reason).stringify())
  sb.write_string(",\"value\":")
  match snapshot {
    Some(x) => sb.write_string(x.stringify())
    None => sb.write_string("null")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// The `id` and `events` of one `llm --batch` input line.
///
/// An event may be given either as an embedded JSON object or as a string that
/// holds one; both forms are accepted, because a caller who builds the line by
/// hand writes the first and a caller who pipes through `json.dumps` writes the
/// second.
fn llm_batch_fields(v : Json, fallback : String) -> (String, Array[String]) {
  match v {
    Json::Object(m) => {
      let id = match m.get("id") {
        Some(Json::String(s)) => s
        _ => fallback
      }
      let out : Array[String] = []
      match m.get("events") {
        Some(Json::Array(a)) =>
          for item in a {
            match item {
              Json::String(s) => out.push(s)
              other => out.push(other.stringify())
            }
          }
        _ => ()
      }
      (id, out)
    }
    _ => (fallback, [])
  }
}

///|
/// Run the text path over a batch of `{"id","events"}` lines.
fn run_llm_text_batch(provider : @llm.Provider, options : @ij.Options) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("interjson: 无法读取 <stdin>")
    return quit(3)
  }
  let body = read_all(stream)
  close_input(stream)
  let mut n = 0
  for line in body.split("\n") {
    if line.length() == 0 {
      continue
    }
    let fallback = "line-" + n.to_string()
    n = n + 1
    let v = @json.parse(line) catch {
      _ => {
        println(
          "{\"id\":" +
          Json::string(fallback).stringify() +
          ",\"rc\":2,\"calls\":[]}",
        )
        continue
      }
    }
    let (id, events) = llm_batch_fields(v, fallback)
    let sb = StringBuilder()
    sb.write_string("{\"id\":")
    sb.write_string(Json::string(id).stringify())
    sb.write_string(",\"rc\":")
    let mut rc = 0
    let mut line_body = text_line(None, @ij.Exact, @llm.Interrupted, "")
    try {
      // The text path uses the command line as given. `--skip-prose` is what
      // makes it read a chat answer that introduces its JSON with a sentence;
      // it is not the default because a scalar root (`0`, `"x"`) would then be
      // mistaken for prose and skipped.
      let s = @llm.TextStream::new(provider, options~)
      for e in events {
        ignore(s.push_event(e))
      }
      let end = s.end()
      let reason = s.stop_reason()
      match s.finish() {
        Some(f) =>
          line_body = text_line(Some(f.value), f.exactness, end, reason)
        None => line_body = text_line(None, @ij.Exact, end, reason)
      }
    } catch {
      e => {
        rc = error_exit_code(e)
        line_body = "{\"error\":" +
          Json::string(e.to_string()).stringify() +
          "}"
      }
    }
    sb.write_string(rc.to_string())
    sb.write_string(",\"calls\":[")
    sb.write_string(line_body)
    sb.write_string("]}")
    println(sb.to_string())
  }
  quit(0)
}

///|
/// Run the `llm` subcommand.
fn run_llm(o : CliOpts) -> Unit {
  let provider = match provider_of(o.provider) {
    Some(p) => p
    None => {
      eprintln("interjson: --provider 需要 anthropic 或 openai")
      return quit(2)
    }
  }
  // `--batch` reads standard input itself, so it must run before the stream
  // below is opened: a second `fdopen` of the same descriptor fails.
  // The adapter defaults to `Options::for_llm()`; the rest of the command line
  // still applies, so the same document behaves the same way on every path.
  let options : @ij.Options = {
    ..@ij.Options::for_llm(),
    skip_prose: o.skip_prose,
    max_loss: o.max_loss,
    reject_ambiguous: o.reject_ambiguous,
  }
  if o.batch {
    if o.text {
      run_llm_text_batch(provider, options)
    }
    run_llm_batch(provider, options)
  }
  if o.text {
    // The single stream form: the whole input is one stream of text deltas.
    let stream = open_input(o.path)
    if stream == 0L {
      eprintln("interjson: 无法读取输入")
      return quit(3)
    }
    let body = read_all(stream)
    close_input(stream)
    let payloads = llm_payloads(body, o.sse)
    try {
      // The text path uses the command line as given. `--skip-prose` is what
      // makes it read a chat answer that introduces its JSON with a sentence;
      // it is not the default because a scalar root (`0`, `"x"`) would then be
      // mistaken for prose and skipped.
      let s = @llm.TextStream::new(provider, options~)
      for p in payloads {
        ignore(s.push_event(p))
      }
      let end = s.end()
      let reason = s.stop_reason()
      match s.finish() {
        Some(f) => println(text_line(Some(f.value), f.exactness, end, reason))
        None => println(text_line(None, @ij.Exact, end, reason))
      }
      quit(0)
    } catch {
      e => {
        eprintln("interjson: " + e.to_string())
        quit(3)
      }
    }
  }
  let stream = open_input(o.path)
  if stream == 0L {
    eprintln("interjson: 无法读取输入")
    return quit(3)
  }
  let text = read_all(stream)
  close_input(stream)
  let payloads = llm_payloads(text, o.sse)
  try {
    let s = @llm.ToolStream::new(provider, options~)
    for p in payloads {
      for v in s.push_event(p) {
        if o.follow {
          println(llm_line(v))
        }
      }
    }
    for v in s.finish() {
      if !o.follow {
        println(llm_line(v))
      }
    }
    quit(0)
  } catch {
    e => {
      eprintln("interjson: " + e.to_string())
      quit(3)
    }
  }
}
