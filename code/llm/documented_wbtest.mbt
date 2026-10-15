// FR-23 / FR-30 — the event shapes that a real stream contains and the synthetic
// fixtures do not: `ping`, `error`, `message_delta`, unknown event types, a
// response cut off by the token limit, and the text half of the adapter.
//
// Every event payload below is *transcribed* from the shape in the official
// provider documentation or in the official SDK type definitions; the exact
// sources are listed in `code/docs/LLM_EVENTS.md`. No live call was recorded
// (the build environment has no credentials and no route to the provider APIs),
// so these are documented shapes rather than captured bytes. `record_stream.py`
// in `code/tests/` records real ones when a key and a network are available.

///|
/// Build a stream result string: `end/stop_reason/value` per call.
fn ev_str(v : ToolCallView) -> String {
  v.index.to_string() +
  ":" +
  v.end.name() +
  "/" +
  v.stop_reason +
  "/" +
  (match v.snapshot.value {
    Some(x) => x.stringify()
    None => "<none>"
  })
}

///|
/// Feed every payload of a `|` joined stream and render the finished views.
fn ev_run(provider : Provider, payloads : String) -> String {
  let s = ToolStream::new(provider) catch {
    e => return "setup failed: " + e.to_string()
  }
  let parts : Array[String] = []
  for p in payloads.split("|") {
    if p.length() == 0 {
      continue
    }
    ignore(s.push_event(p.to_owned())) catch {
      e => parts.push("raised:" + e.code())
    }
  }
  try {
    for v in s.finish() {
      parts.push(ev_str(v))
    }
  } catch {
    e => parts.push("finish raised:" + e.code())
  }
  parts.push("ignored=" + s.ignored_events().to_string())
  let err = s.error()
  if err != "" {
    parts.push("error=" + err)
  }
  let sb = StringBuilder()
  for i = 0; i < parts.length(); i = i + 1 {
    if i > 0 {
      sb.write_string(" ")
    }
    sb.write_string(parts[i])
  }
  sb.to_string()
}

///|
test "ping and unknown event types are ignored, not rejected" {
  // Anthropic sends `{"type":"ping"}` between blocks, and the documentation
  // requires a client to handle event types added in the future gracefully.
  let stream = "{" +
    "\"type\":\"ping\"}" +
    "|{" +
    "\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\"}}" +
    "|{" +
    "\"type\":\"future_event_type\",\"whatever\":[1,2,3]}" +
    "|{" +
    "\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"f\",\"input\":{}}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}" +
    "|{" +
    "\"type\":\"content_block_stop\",\"index\":0}" +
    "|{" +
    "\"type\":\"message_stop\"}"
  // Four payloads carried no tool-call work (`ping`, `message_start`,
  // `future_event_type`, `message_stop`) for a stream of one call.
  assert_eq(ev_run(Anthropic, stream), "0:complete//{\"a\":1} ignored=4")
}

///|
test "the three ways a stream can end are told apart" {
  // 1. The provider says it finished: `stop_reason: tool_use`.
  let normal = "{" +
    "\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"name\":\"f\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}" +
    "|{" +
    "\"type\":\"content_block_stop\",\"index\":0}" +
    "|{" +
    "\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":15}}"
  assert_eq(ev_run(Anthropic, normal), "0:complete/tool_use/{} ignored=1")
  // 2. The provider says it ran out of tokens: `stop_reason: max_tokens`.
  let cut = "{" +
    "\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"name\":\"f\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1,\\\"b\\\":\\\"x\"}}" +
    "|{" +
    "\"type\":\"content_block_stop\",\"index\":0}" +
    "|{" +
    "\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":4096}}"
  assert_eq(
    ev_run(Anthropic, cut),
    "0:max_tokens/max_tokens/{\"a\":1,\"b\":\"x\"} ignored=1",
  )
  // 3. The stream stops with no verdict at all: a dropped connection.
  let dropped = "{" +
    "\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"name\":\"f\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\"}}"
  assert_eq(ev_run(Anthropic, dropped), "0:interrupted//{\"a\":null} ignored=0")
  // The same three cases on the OpenAI compatible path, where the verdict is
  // `finish_reason` and the truncating value is `length`.
  let oai_ok = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}" +
    "|{" +
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
  assert_eq(ev_run(OpenAICompat, oai_ok), "0:complete/tool_calls/{} ignored=0")
  let oai_cut = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"f\",\"arguments\":\"{}x\"}}]}}]}" +
    "|{" +
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}"
  assert_eq(ev_run(OpenAICompat, oai_cut), "0:max_tokens/length/{} ignored=0")
  let oai_dropped = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]}}]}"
  assert_eq(ev_run(OpenAICompat, oai_dropped), "0:interrupted//{} ignored=0")
}

///|
test "an error event ends the stream and is reported" {
  // `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`
  let anthropic_error = "{" +
    "\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"name\":\"f\"}}" +
    "|{" +
    "\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
  assert_eq(
    ev_run(Anthropic, anthropic_error),
    "0:provider_error//<none> ignored=1 error=Overloaded",
  )
  // `{"error":{"message":…,"type":…,"param":…,"code":…}}` on the OpenAI path.
  let openai_error = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"a\\\":\"}}]}}]}" +
    "|{" +
    "\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\",\"param\":null,\"code\":\"rate_limit\"}}"
  assert_eq(
    ev_run(OpenAICompat, openai_error),
    "0:provider_error//{\"a\":null} ignored=1 error=Rate limit reached",
  )
}

///|
test "a payload that is not an event of the provider is still an error" {
  assert_eq(ev_run(Anthropic, "not json at all"), "raised:E060 ignored=0")
}

// ---------------------------------------------------------------------------
// Text mode
// ---------------------------------------------------------------------------

///|
/// `end/stop_reason/value` of a finished text stream. `prose` selects the
/// `skip_prose` option, which is what a chat answer that introduces its JSON
/// with a sentence needs; it is off by default because it would skip a scalar
/// root (`0`, `"x"`) as if it were prose.
fn tx_run(provider : Provider, payloads : String, prose : Bool) -> String {
  let opts = if prose {
    { ..@mend.Options::for_llm(), skip_prose: true, }
  } else {
    @mend.Options::for_llm()
  }
  let s = TextStream::new(provider, options=opts) catch {
    e => return "setup failed: " + e.to_string()
  }
  for p in payloads.split("|") {
    if p.length() == 0 {
      continue
    }
    ignore(s.push_event(p.to_owned())) catch {
      e => return "raised:" + e.code()
    }
  }
  let fin = s.finish()
  let end = s.end()
  let reason = s.stop_reason()
  let value = match fin {
    Some(f) => f.value.stringify()
    None => "<none>"
  }
  end.name() + "/" + reason + "/" + value
}

///|
test "text deltas are parsed as JSON, prose and all" {
  // Anthropic: `{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}`
  let anthropic = "{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Here is the JSON:\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\n```json\\n{\\\"city\\\":\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\\"Paris\\\",\\\"c\\\":21}\"}}" +
    "|{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\n```\"}}" +
    "|{" +
    "\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}" +
    "|{" +
    "\"type\":\"message_stop\"}"
  assert_eq(
    tx_run(Anthropic, anthropic, true),
    "complete/end_turn/{\"city\":\"Paris\",\"c\":21}",
  )
  // OpenAI compatible: `choices[].delta.content`
  let openai = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Sure. \"}}]}" +
    "|{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"[1,2,\"}}]}" +
    "|{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"3]\"},\"finish_reason\":\"stop\"}]}"
  assert_eq(tx_run(OpenAICompat, openai, true), "complete/stop/[1,2,3]")
}

///|
test "a text answer cut off by the token limit is labelled" {
  let openai = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"{\\\"a\\\":\"}}]}" +
    "|{" +
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}"
  assert_eq(
    tx_run(OpenAICompat, openai, false),
    "max_tokens/length/{\"a\":null}",
  )
  let anthropic = "{" +
    "\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"[1,2\"}}" +
    "|{" +
    "\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"
  assert_eq(tx_run(Anthropic, anthropic, false), "max_tokens/max_tokens/[1,2]")
}

///|
test "a text answer with no JSON is an error, or nothing with prose skipping" {
  // With the default options, a chat answer that is only a sentence is not a
  // JSON document: the parser says so instead of inventing an empty value.
  let prose = "{" +
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"I cannot help with that.\"}}]}"
  assert_eq(tx_run(OpenAICompat, prose, false), "raised:E002")
  // With `skip_prose` the sentence is skipped, no value is ever seen, and the
  // stream is reported as interrupted: the provider never said it had finished.
  assert_eq(tx_run(OpenAICompat, prose, true), "interrupted//<none>")
  // A stream that never carried text at all.
  assert_eq(
    tx_run(OpenAICompat, "{\"choices\":[{\"index\":0,\"delta\":{}}]}", false),
    "interrupted//<none>",
  )
  // A text error frame.
  assert_eq(
    tx_run(
      OpenAICompat,
      "{" +
      "\"error\":{\"message\":\"Overloaded\",\"type\":\"overloaded_error\"}}",
      false,
    ),
    "provider_error//<none>",
  )
}

///|
test "a scalar root survives the text path when prose skipping is off" {
  // `--skip-prose` starts a value only at `{` or `[`, so a scalar root must be
  // read with it off; this is the case that made it off by default.
  // No `finish_reason` at all is a stream that stopped without a verdict.
  assert_eq(
    tx_run(
      OpenAICompat,
      "{" + "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"0\"}}]}",
      false,
    ),
    "interrupted//0",
  )
  assert_eq(
    tx_run(
      OpenAICompat,
      "{" +
      "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"42\"},\"finish_reason\":\"stop\"}]}",
      false,
    ),
    "complete/stop/42",
  )
}
