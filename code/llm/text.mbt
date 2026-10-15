// FR-30 — the text half of the adapter.
//
// Tool-call arguments are not the only place a model writes JSON. A structured
// output request is answered as ordinary text:
//
//   Anthropic  content_block_delta, delta.type == "text_delta", delta.text
//   OpenAI     choices[].delta.content
//
// The event shapes above are taken from the official type definitions of both
// SDKs (`text_delta.py`, `chat_completion_chunk.py`); `docs/LLM_EVENTS.md`
// records the exact sources. `TextStream` turns that text into the same partial
// parse the tool-call path produces, so a caller can render either kind of
// response with one renderer.
//
// The parser starts with `skip_prose`, because a text answer usually begins
// with "Here is the JSON:" before the value. Anything the parser cannot use as
// JSON yet is simply not in the snapshot; nothing is guessed.

///|
/// Reads the JSON a model writes as plain text (FR-30).
pub struct TextStream {
  provider : Provider
  parser : @mend.PartialParser
  buf : StringBuilder
  mut end : CallEnd
  mut stop_reason : String
  mut error_message : String
  mut ignored : Int32
  mut seen_text : Bool
}

///|
/// Create a text stream.
///
/// The default options are `Options::for_llm()`, the same as the tool-call
/// path, so the value read here is the value the rest of the library would
/// read. Pass `skip_prose: true` when the answer is a sentence that contains a
/// JSON document: that strip only starts a value at `{` or `[`, so it must not
/// be the default — a scalar root (`0`, `"x"`) would be skipped as prose.
pub fn TextStream::new(
  provider : Provider,
  options? : @mend.Options,
) -> TextStream raise @mend.MendError {
  let opts = match options {
    Some(o) => o
    None => @mend.Options::for_llm()
  }
  opts.validate()
  {
    provider,
    parser: @mend.PartialParser::new(options=opts),
    buf: StringBuilder(),
    end: Open,
    stop_reason: "",
    error_message: "",
    ignored: 0,
    seen_text: false,
  }
}

///|
/// The text deltas received so far, concatenated.
pub fn TextStream::text(self : TextStream) -> String {
  self.buf.to_string()
}

///|
/// How the stream ended (FR-30).
pub fn TextStream::end(self : TextStream) -> CallEnd {
  self.end
}

///|
/// The provider's own word for why it ended, "" when it did not say.
pub fn TextStream::stop_reason(self : TextStream) -> String {
  self.stop_reason
}

///|
/// The provider error message, "" when no error event arrived.
pub fn TextStream::error(self : TextStream) -> String {
  self.error_message
}

///|
/// How many payloads carried no text and were ignored.
pub fn TextStream::ignored_events(self : TextStream) -> Int32 {
  self.ignored
}

///|
/// Feed one event payload; the snapshot of the JSON found in the text so far is
/// returned when the event carried text, and `None` otherwise.
pub fn TextStream::push_event(
  self : TextStream,
  event_json : String,
) -> @mend.Snapshot? raise @mend.MendError {
  let v = @json.parse(event_json) catch {
    _ => raise @mend.InvalidEvent("event payload is not valid JSON")
  }
  let fragment = match self.provider {
    Anthropic => self.text_of_anthropic(v)
    OpenAICompat => self.text_of_openai(v)
  }
  match fragment {
    Some(s) => {
      if s == "" {
        self.ignored = self.ignored + 1
        return None
      }
      self.seen_text = true
      self.buf.write_string(s)
      self.parser.feed(s)
      Some(self.parser.snapshot())
    }
    None => {
      self.ignored = self.ignored + 1
      None
    }
  }
}

///|
/// The text fragment of one Anthropic event, if it carries one.
fn TextStream::text_of_anthropic(self : TextStream, v : Json) -> String? {
  let kind = match field_string(v, "type") {
    Some(t) => t
    None => return None
  }
  if kind == "content_block_delta" {
    return match field(v, "delta") {
      Some(d) =>
        if field_string(d, "type") == Some("text_delta") {
          field_string(d, "text")
        } else {
          None
        }
      None => None
    }
  }
  if kind == "message_delta" {
    match field(v, "delta") {
      Some(d) =>
        match field_string(d, "stop_reason") {
          Some(r) => self.stop_reason = r
          None => ()
        }
      None => ()
    }
    self.end = stop_end(self.stop_reason)
    return None
  }
  if kind == "message_stop" {
    if self.end is Open {
      self.end = Complete
    }
    return None
  }
  if kind == "error" {
    let message = match field(v, "error") {
      Some(e) =>
        match field_string(e, "message") {
          Some(m) => m
          None => "provider error"
        }
      None => "provider error"
    }
    self.error_message = message
    self.end = ProviderError
    return None
  }
  None
}

///|
/// The text fragment of one OpenAI compatible chunk, if it carries one.
fn TextStream::text_of_openai(self : TextStream, v : Json) -> String? {
  match field(v, "error") {
    Some(e) => {
      self.error_message = match field_string(e, "message") {
        Some(m) => m
        None => "provider error"
      }
      self.end = ProviderError
      return None
    }
    None => ()
  }
  let choices = match field(v, "choices") {
    Some(c) => as_array(c)
    None => None
  }
  let list = match choices {
    Some(a) => a
    None => return None
  }
  let mut found : String? = None
  for choice in list {
    match field(choice, "delta") {
      Some(delta) =>
        match field_string(delta, "content") {
          Some(s) => if s != "" { found = Some(s) }
          None => ()
        }
      None => ()
    }
    match field_string(choice, "finish_reason") {
      Some(reason) =>
        if reason != "" {
          self.stop_reason = reason
          self.end = stop_end(reason)
        }
      None => ()
    }
  }
  found
}

///|
/// Map a provider stop word to a `CallEnd`.
pub fn stop_end(reason : String) -> CallEnd {
  match reason {
    "max_tokens" | "length" | "model_context_window_exceeded" => MaxTokens
    "" => Open
    _ => Complete
  }
}

///|
/// The final parse of the text received so far.
///
/// Returns `None` when no text ever arrived, or when the text held no JSON at
/// all: a caller that asked for JSON but got prose should see "nothing", not an
/// empty object. A stream that was still open when this is called is reported
/// as `Interrupted`, because the provider never said it had finished.
pub fn TextStream::finish(self : TextStream) -> @mend.FinalResult? {
  if self.end is Open {
    self.end = Interrupted
  }
  if !self.seen_text {
    return None
  }
  let r = self.parser.finish() catch { _ => return None }
  Some(r)
}
