// OpenAI compatible chat completion chunks.
//
// Field paths follow the published streaming shape:
//   choices[].delta.tool_calls[].index
//   choices[].delta.tool_calls[].id
//   choices[].delta.tool_calls[].function.name
//   choices[].delta.tool_calls[].function.arguments
// The name usually arrives in the first fragment of a call and the arguments
// are then split arbitrarily. A `finish_reason` of `tool_calls` closes every
// open call.

///|
/// Handle one OpenAI compatible chunk, returning the calls it changed.
fn ToolStream::push_openai(
  self : ToolStream,
  v : Json,
) -> Array[ToolCall] raise @mend.MendError {
  let out : Array[ToolCall] = []
  let choices = match field(v, "choices") {
    Some(c) => as_array(c)
    None => None
  }
  let list = match choices {
    Some(a) => a
    None => return out
  }
  for choice in list {
    let delta = match field(choice, "delta") {
      Some(d) => d
      None => continue
    }
    match field(delta, "tool_calls") {
      Some(tc) =>
        match as_array(tc) {
          Some(calls) =>
            for call in calls {
              let index = match field_int(call, "index") {
                Some(i) => i
                None => 0
              }
              let c = self.call_at(index)
              match field_string(call, "id") {
                Some(i) => if c.id == "" { c.id = i }
                None => ()
              }
              match field(call, "function") {
                Some(f) => {
                  // The name arrives with the first fragment of a call and is
                  // never repeated; a later fragment must not rename it.
                  match field_string(f, "name") {
                    Some(n) => if n != "" && c.name == "" { c.name = n }
                    None => ()
                  }
                  match field_string(f, "arguments") {
                    Some(a) => self.push_arguments(c, a)
                    None => ()
                  }
                }
                None => ()
              }
              out.push(c)
            }
          None => ()
        }
      None => ()
    }
    // `finish_reason` closes the call: the provider will not send more
    // argument fragments for this choice.
    match field_string(choice, "finish_reason") {
      Some(reason) =>
        if reason != "" {
          for c in self.calls {
            if !c.done {
              self.close_call(c)
              out.push(c)
            }
          }
        }
      None => ()
    }
  }
  out
}
