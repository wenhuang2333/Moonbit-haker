// FR-23 tests: the provider adapters must route fragments to the right call and
// the streamed result must be byte identical to repairing the accumulated
// argument text in one shot.

///|
/// Feed every line of an embedded fixture, then finish.
fn fx_play(
  provider : Provider,
  fixture : String,
) -> ToolStream raise @interjson.InterJSONError {
  let s = ToolStream::new(provider)
  for line in fx_lines(fixture) {
    ignore(s.push_event(line))
  }
  ignore(s.finish())
  s
}

///|
/// Check every expected call of a fixture against the finished stream.
fn fx_expect(
  s : ToolStream,
  calls : Array[(Int32, String, String)],
) -> Unit raise {
  let views = s.finish()
  assert_eq(views.length(), calls.length())
  for i = 0; i < calls.length(); i = i + 1 {
    let (index, name, args) = calls[i]
    let v = views[i]
    assert_eq(v.index, index)
    assert_eq(v.name, name)
    assert_eq(v.done, true)
    assert_eq(s.arguments(index), args)
    if args.length() == 0 {
      assert_eq(v.snapshot.value is None, true)
      assert_eq(v.exactness.name(), "exact")
    } else {
      // The streamed value equals repairing the accumulated text in one shot.
      let once = @interjson.parse(args)
      assert_eq(v.snapshot.value.unwrap().stringify(), once.value.stringify())
      assert_eq(v.exactness.name(), once.exactness.name())
      assert_eq(v.snapshot.completeness is @interjson.Complete, true)
    }
  }
}

///|
/// Run a fixture and check it, reporting a raised error as a failure message.
fn fx_case(
  provider : Provider,
  fixture : String,
  calls : Array[(Int32, String, String)],
) -> Unit raise {
  let err = try {
    fx_expect(fx_play(provider, fixture), calls)
    ""
  } catch {
    e => e.to_string()
  }
  assert_eq(err, "")
}

///|
test "anthropic: a single tool call split into fragments" {
  fx_case(Anthropic, fx_anthropic_single, fx_anthropic_single_calls)
}

///|
test "anthropic: a split inside an escape and inside a surrogate pair" {
  fx_case(Anthropic, fx_anthropic_escape_split, fx_anthropic_escape_split_calls)
  // The decoded value must be the emoji, not a replacement character.
  let s = Some(fx_play(Anthropic, fx_anthropic_escape_split)) catch {
    _ => None
  }
  match s {
    Some(stream) =>
      assert_eq(
        stream.finish()[0].snapshot.value.unwrap().stringify(),
        "{\"note\":\"caf\u00e9 \u{1F600} done\"}",
      )
    None => assert_true(false, msg="fixture raised")
  }
}

///|
test "anthropic: three interleaved tool calls" {
  fx_case(Anthropic, fx_anthropic_parallel, fx_anthropic_parallel_calls)
}

///|
test "anthropic: a mixed stream ignores text and message events" {
  fx_case(Anthropic, fx_anthropic_mixed, fx_anthropic_mixed_calls)
}

///|
test "anthropic: a truncated call is closed and marked lossy" {
  fx_case(Anthropic, fx_anthropic_truncated, fx_anthropic_truncated_calls)
  let s = fx_play(Anthropic, fx_anthropic_truncated)
  // The arguments never finished, so the repair invented the closing brace.
  assert_eq(s.views()[0].exactness.name(), "lossy")
}

///|
test "openai: a single tool call split into fragments" {
  fx_case(OpenAICompat, fx_openai_single, fx_openai_single_calls)
}

///|
test "openai: two interleaved tool calls" {
  fx_case(OpenAICompat, fx_openai_parallel, fx_openai_parallel_calls)
}

///|
test "openai: a length limited call is closed and marked lossy" {
  fx_case(OpenAICompat, fx_openai_truncated, fx_openai_truncated_calls)
  let s = fx_play(OpenAICompat, fx_openai_truncated)
  assert_eq(s.views()[0].exactness.name(), "lossy")
}

///|
test "openai: a call whose arguments never arrive" {
  fx_case(OpenAICompat, fx_openai_name_only, fx_openai_name_only_calls)
}

///|
test "views are available while the call is still being written" {
  let s = ToolStream::new(Anthropic)
  ignore(
    s.push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"f\",\"input\":{}}}",
    ),
  )
  let mid = s.push_event(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\\\"x\"}}",
  )
  assert_eq(mid.length(), 1)
  assert_eq(mid[0].done, false)
  // The value is visible while it is still being written ...
  assert_eq(mid[0].snapshot.value.unwrap().stringify(), "{\"a\":\"x\"}")
  assert_eq(mid[0].snapshot.completeness is @interjson.Partial, true)
  // ... and the exactness only moves once a repair has actually happened.
  assert_eq(mid[0].exactness.name(), "exact")
  let mid2 = s.push_event(
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\",}\"}}",
  )
  assert_eq(mid2[0].snapshot.value.unwrap().stringify(), "{\"a\":\"x\"}")
  assert_eq(mid2[0].exactness.name(), "cosmetic")
  // Before any fragment the call is known by name only.
  let only = s.views()
  assert_eq(only.length(), 1)
  assert_eq(only[0].name, "f")
}

///|
test "a malformed event payload raises E060" {
  let s = ToolStream::new(Anthropic)
  let msg = try {
    ignore(s.push_event("{\"type\":"))
    ""
  } catch {
    e => e.to_string()
  }
  assert_true(msg.contains("E060"), msg~)
  // An event that is valid JSON but not an event of the provider is ignored.
  let views = s.push_event("{\"type\":\"ping\"}")
  assert_eq(views.length(), 0)
  // So is a chunk with no choices.
  let s2 = ToolStream::new(OpenAICompat)
  assert_eq(s2.push_event("{\"id\":\"x\"}").length(), 0)
}

///|
test "the adapters never require the network" {
  // A stream is usable from a string alone, which is what makes it testable.
  let s = ToolStream::new(OpenAICompat)
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"f\",\"arguments\":\"[1,\"}}]}}]}",
    ),
  )
  let views = s.finish()
  assert_eq(views[0].snapshot.value.unwrap().stringify(), "[1]")
}

///|
test "sse reader splits a stream into event payloads" {
  let b = SseBuffer::new()
  let out : Array[String] = []
  for
    piece in [
      "event: content_block_delta\ndata: {\"a\":", "1}\n\ndata: [2]\n\n: comment\n",
    ] {
    for e in b.push(piece) {
      out.push(e)
    }
  }
  assert_eq(out.length(), 2)
  assert_eq(out[0], "{\"a\":1}")
  assert_eq(out[1], "[2]")
}

///|
test "sse reader handles CRLF, multi line data and a cut inside a line" {
  let b = SseBuffer::new()
  let out : Array[String] = []
  for e in b.push("data: one\r\ndata: two\r\n\r\n") {
    out.push(e)
  }
  for e in b.push("data: thr") {
    out.push(e)
  }
  for e in b.push("ee\n") {
    out.push(e)
  }
  for e in b.flush() {
    out.push(e)
  }
  assert_eq(out.length(), 2)
  assert_eq(out[0], "one\ntwo")
  assert_eq(out[1], "three")
  assert_eq(sse_data("data: x"), Some("x"))
  assert_eq(sse_data("data:x"), Some("x"))
  assert_eq(sse_data("event: x"), None)
}

///|
test "an sse wrapped fixture drives the adapter" {
  let s = ToolStream::new(Anthropic)
  let b = SseBuffer::new()
  let lines = fx_lines(fx_anthropic_parallel)
  for line in lines {
    for payload in b.push("event: message\ndata: " + line + "\n\n") {
      ignore(s.push_event(payload))
    }
  }
  fx_expect(s, fx_anthropic_parallel_calls)
}

///|
test "json helpers read the event envelope" {
  let v = @json.parse("{\"i\":3,\"s\":\"x\",\"a\":[1],\"o\":{\"k\":true}}")
  assert_eq(as_int(field(v, "i").unwrap()), Some(3))
  assert_eq(as_string(field(v, "s").unwrap()), Some("x"))
  assert_eq(as_array(field(v, "a").unwrap()).unwrap().length(), 1)
  assert_eq(as_object(field(v, "o").unwrap()).unwrap().length(), 1)
  assert_eq(field_string(v, "s"), Some("x"))
  assert_eq(field_int(v, "i"), Some(3))
  assert_eq(field_int(v, "s"), None)
  assert_eq(field(v, "missing"), None)
  assert_eq(as_int(Json::string("x")), None)
  assert_eq(as_string(Json::number(1.0)), None)
  assert_eq(as_array(Json::null()), None)
  assert_eq(as_object(Json::null()), None)
  assert_eq(field(Json::null(), "k"), None)
}

///|
test "anthropic edge cases" {
  // A block that is not a tool call is ignored.
  let s = ToolStream::new(Anthropic)
  assert_eq(
    s
    .push_event(
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    )
    .length(),
    0,
  )
  // A delta of the wrong kind is ignored.
  assert_eq(
    s
    .push_event(
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}",
    )
    .length(),
    0,
  )
  // A stop for an index that was never seen is ignored.
  assert_eq(
    s.push_event("{\"type\":\"content_block_stop\",\"index\":7}").length(),
    0,
  )
  // A start whose `input` is already populated feeds it as the first fragment.
  let v = s.push_event(
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"f\",\"input\":{\"a\":1}}}",
  )
  assert_eq(v.length(), 1)
  assert_eq(v[0].snapshot.value.unwrap().stringify(), "{\"a\":1}")
  // An event with no type at all is ignored.
  assert_eq(s.push_event("{}").length(), 0)
}

///|
test "openai edge cases" {
  let s = ToolStream::new(OpenAICompat)
  // A choice without a delta is ignored.
  assert_eq(s.push_event("{\"choices\":[{\"index\":0}]}").length(), 0)
  // `arguments: null` is ignored, the name is still recorded.
  let v = s.push_event(
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"f\",\"arguments\":null}}]}}]}",
  )
  assert_eq(v.length(), 1)
  assert_eq(v[0].name, "f")
  // A later name never overwrites the first one.
  ignore(
    s.push_event(
      "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"x\",\"function\":{\"name\":\"g\"}}]}}]}",
    ),
  )
  assert_eq(s.views()[0].name, "f")
  assert_eq(s.views()[0].id, "x")
}

///|
test "sse flush dispatches a final line without a terminator" {
  let b = SseBuffer::new()
  let out = b.push("data: tail")
  assert_eq(out.length(), 0)
  assert_eq(b.flush(), ["tail"])
  assert_eq(b.flush().length(), 0)
}
