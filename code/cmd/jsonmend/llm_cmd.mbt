// `jsonmend llm` — drive the provider adapters from a recorded event stream.
//
//   jsonmend llm --provider anthropic < events.jsonl
//   jsonmend llm --provider openai --sse < response.txt
//   jsonmend llm --follow ...        # one line per update instead of per call
//
// This is the command line face of FR-22: it makes the adapters usable on a
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
  sb.write_string(",\"value\":")
  match v.snapshot.value {
    Some(x) => sb.write_string(x.stringify())
    None => sb.write_string("null")
  }
  sb.write_string("}")
  sb.to_string()
}

///|
/// Run the `llm` subcommand.
fn run_llm(o : CliOpts) -> Unit {
  let stream = open_input(o.path)
  if stream == 0L {
    eprintln("jsonmend: 无法读取输入")
    return quit(3)
  }
  let text = read_all(stream)
  close_input(stream)
  let provider = if o.provider == "openai" {
    @llm.OpenAICompat
  } else if o.provider == "anthropic" {
    @llm.Anthropic
  } else {
    eprintln("jsonmend: --provider 需要 anthropic 或 openai")
    return quit(2)
  }
  let payloads = llm_payloads(text, o.sse)
  try {
    let s = @llm.ToolStream::new(provider)
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
      eprintln("jsonmend: " + e.to_string())
      quit(3)
    }
  }
}
