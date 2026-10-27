// Anthropic fine grained tool streaming.
//
// Event names and fields follow the published streaming reference:
//   content_block_start  -> content_block.type == "tool_use", with name/id
//   content_block_delta  -> delta.type == "input_json_delta", partial_json
//   content_block_stop   -> the arguments of that index are complete
//   message_delta        -> delta.stop_reason, the provider's own verdict
//   ping                 -> {"type":"ping"}, any number of them, ignored
//   error                -> {"type":"error","error":{"type",  "message"}}
//
// `message_start`, `message_stop` and any event type added later are ignored as
// well: the documentation requires a client to handle unknown event types
// gracefully, so this reader never fails on one. Everything ignored is counted
// by `ToolStream::ignored_events`.

///|
/// Handle one Anthropic event, returning the calls it changed.
fn ToolStream::push_anthropic(
  self : ToolStream,
  v : Json,
) -> Array[ToolCall] raise @interjson.InterJSONError {
  let out : Array[ToolCall] = []
  let kind = match field_string(v, "type") {
    Some(t) => t
    None => return out
  }
  if kind == "content_block_start" {
    let block = match field(v, "content_block") {
      Some(b) => b
      None => return out
    }
    let block_type = match field_string(block, "type") {
      Some(t) => t
      None => ""
    }
    if block_type != "tool_use" {
      return out
    }
    let index = match field_int(v, "index") {
      Some(i) => i
      None => 0
    }
    let c = self.call_at(index)
    match field_string(block, "name") {
      Some(n) => c.name = n
      None => ()
    }
    match field_string(block, "id") {
      Some(i) => c.id = i
      None => ()
    }
    // A provider may put a non-empty `input` here (Anthropic sends `{}` when
    // streaming the arguments). Feed whatever is there as the first fragment.
    match field(block, "input") {
      Some(input) => {
        let text = input.stringify()
        if text != "{}" && text != "" {
          self.push_arguments(c, text)
        }
      }
      None => ()
    }
    out.push(c)
    return out
  }
  if kind == "content_block_delta" {
    let delta = match field(v, "delta") {
      Some(d) => d
      None => return out
    }
    let delta_type = match field_string(delta, "type") {
      Some(t) => t
      None => ""
    }
    if delta_type != "input_json_delta" {
      return out
    }
    let index = match field_int(v, "index") {
      Some(i) => i
      None => 0
    }
    let fragment = match field_string(delta, "partial_json") {
      Some(s) => s
      None => return out
    }
    let c = self.call_at(index)
    self.push_arguments(c, fragment)
    out.push(c)
    return out
  }
  if kind == "content_block_stop" {
    let index = match field_int(v, "index") {
      Some(i) => i
      None => 0
    }
    for c in self.calls {
      if c.index == index {
        self.close_call(c, Complete)
        out.push(c)
      }
    }
    return out
  }
  if kind == "message_delta" {
    // The provider's verdict on the whole message: `end_turn`, `tool_use`,
    // `max_tokens`, `stop_sequence`, `pause_turn`, `refusal`, or something
    // added later. It arrives after the blocks, so it is recorded on every
    // call rather than used to close one.
    match field(v, "delta") {
      Some(d) =>
        match field_string(d, "stop_reason") {
          Some(r) => self.note_stop(r)
          None => ()
        }
      None => ()
    }
    return out
  }
  if kind == "error" {
    // An error event (for example `overloaded_error`) ends the stream: no
    // further argument fragments will arrive.
    let message = match field(v, "error") {
      Some(e) =>
        match field_string(e, "message") {
          Some(m) => m
          None => "provider error"
        }
      None => "provider error"
    }
    self.note_error(message)
    return out
  }
  out
}
