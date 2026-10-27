// interjson/llm — adapt the tool-call fragment streams of large language model
// providers into `interjson` partial parses (FR-23).
//
// The package is pure: it never opens a socket and never owns an HTTP client.
// Its input is the text of one already-extracted event payload; how that text
// was obtained (an SSE `data:` line, a WebSocket frame, a log line) is the
// caller's business. `sse.mbt` offers a minimal reader for the common case.

///|
/// Wire format of the incoming events.
pub(all) enum Provider {
  /// `content_block_start` / `content_block_delta` / `content_block_stop`,
  /// with `delta.type == "input_json_delta"` carrying `partial_json`.
  Anthropic
  /// `choices[].delta.tool_calls[]`, with `function.name` and
  /// `function.arguments` fragments.
  OpenAICompat
}

///|
/// Explicit `Eq` implementation for `Provider`.
pub impl Eq for Provider with fn equal(self : Provider, other : Provider) -> Bool {
  (self is Anthropic && other is Anthropic) ||
  (self is OpenAICompat && other is OpenAICompat)
}

///|
/// Explicit `Eq` extension for `Provider`.
pub extend Provider with Eq::{not_equal, equal}

///|
/// How a stream ended, which is not the same question as "is the value
/// complete" (FR-23 / FR-30).
///
/// `Open` means no end was signalled yet. The distinction between `Complete`,
/// `MaxTokens` and `Interrupted` is the one a caller needs: the first two are
/// the provider's own verdicts (`content_block_stop` / `finish_reason`, and
/// `stop_reason: max_tokens` / `finish_reason: length`), the third means the
/// stream stopped without one — a dropped connection, or a caller that gave up.
pub(all) enum CallEnd {
  Open
  Complete
  MaxTokens
  Interrupted
  ProviderError
}

///|
/// Explicit `Eq` implementation for `CallEnd`.
pub impl Eq for CallEnd with fn equal(self : CallEnd, other : CallEnd) -> Bool {
  self.name() == other.name()
}

///|
/// Explicit `Eq` extension for `CallEnd`.
pub extend CallEnd with Eq::{not_equal, equal}

///|
/// Stable lowercase name of a `CallEnd`.
pub fn CallEnd::name(self : CallEnd) -> String {
  match self {
    Open => "open"
    Complete => "complete"
    MaxTokens => "max_tokens"
    Interrupted => "interrupted"
    ProviderError => "provider_error"
  }
}

///|
/// Whether the call ended because the provider ran out of tokens.
pub fn CallEnd::is_truncated(self : CallEnd) -> Bool {
  self is MaxTokens
}

///|
/// One tool call as seen so far.
///
/// `snapshot` is the partial parse of the argument text received so far, so a
/// caller can render a form while the model is still writing. `exactness` is
/// the exactness of that snapshot: as long as the arguments are incomplete it
/// is normally `Lossy`, and it becomes `Exact` only when the model happened to
/// emit a complete, valid argument object.
pub(all) struct ToolCallView {
  /// Provider index of the call, used to route the result back.
  index : Int32
  /// Provider id of the call, when the provider sent one.
  id : String
  /// Function name, when the provider sent one.
  name : String
  /// Partial parse of the arguments received so far.
  snapshot : @interjson.Snapshot
  /// Exactness of `snapshot`.
  exactness : @interjson.Exactness
  /// Whether the provider signalled the end of this call's arguments.
  done : Bool
  /// How the call ended (FR-30).
  end : CallEnd
  /// The provider's own word for why it ended, verbatim and unparsed:
  /// `"end_turn"`, `"max_tokens"`, `"tool_use"`, `"length"`, `"stop"`, …
  stop_reason : String
}

///|
/// One call being accumulated.
struct ToolCall {
  index : Int32
  mut id : String
  mut name : String
  mut parser : @interjson.PartialParser?
  mut done : Bool
  mut end : CallEnd
  mut stop_reason : String
  /// Text of every fragment received, kept for the equivalence check and for
  /// callers that want the raw text.
  text : StringBuilder
}

///|
/// Accumulates the tool calls of one model response.
pub struct ToolStream {
  provider : Provider
  options : @interjson.Options
  calls : Array[ToolCall]
  /// Explanation of the last `error` event, "" when none arrived.
  mut error_message : String
  /// Event payloads that were not understood: `ping`, `message_start`, future
  /// event types, text deltas in tool mode. The provider may add event types at
  /// any time, so they are counted and ignored rather than rejected.
  mut ignored : Int32
}

///|
/// Create a stream. `options` defaults to `Options::for_llm()`, the profile
/// that enables delta tracking and leaves the exactness gate open.
pub fn ToolStream::new(
  provider : Provider,
  options? : @interjson.Options,
) -> ToolStream raise @interjson.InterJSONError {
  let opts = match options {
    Some(o) => o
    None => @interjson.Options::for_llm()
  }
  opts.validate()
  { provider, options: opts, calls: [], error_message: "", ignored: 0, }
}

///|
/// The call at `index`, created on first use.
fn ToolStream::call_at(self : ToolStream, index : Int32) -> ToolCall {
  for c in self.calls {
    if c.index == index {
      return c
    }
  }
  let c : ToolCall = {
    index,
    id: "",
    name: "",
    parser: None,
    done: false,
    end: Open,
    stop_reason: "",
    text: StringBuilder(),
  }
  self.calls.push(c)
  c
}

///|
/// The parser of a call, created on first use.
fn ToolStream::parser_of(
  self : ToolStream,
  c : ToolCall,
) -> @interjson.PartialParser raise @interjson.InterJSONError {
  match c.parser {
    Some(p) => p
    None => {
      let p = @interjson.PartialParser::new(options=self.options)
      c.parser = Some(p)
      p
    }
  }
}

///|
/// View of one call.
fn ToolStream::view(self : ToolStream, c : ToolCall) -> ToolCallView {
  ignore(self)
  let snap = match c.parser {
    Some(p) => p.snapshot()
    None =>
      {
        value: None,
        completeness: @interjson.Empty,
        open_path: [],
        exactness: @interjson.Exact,
        ambiguous: false,
      }
  }
  {
    index: c.index,
    id: c.id,
    name: c.name,
    snapshot: snap,
    exactness: snap.exactness,
    done: c.done,
    end: c.end,
    stop_reason: c.stop_reason,
  }
}

///|
/// Append one argument fragment to a call.
fn ToolStream::push_arguments(
  self : ToolStream,
  c : ToolCall,
  fragment : String,
) -> Unit raise @interjson.InterJSONError {
  c.text.write_string(fragment)
  let p = self.parser_of(c)
  p.feed(fragment)
}

///|
/// Mark a call's arguments as complete.
fn ToolStream::close_call(
  _self : ToolStream,
  c : ToolCall,
  end : CallEnd,
) -> Unit raise @interjson.InterJSONError {
  match c.parser {
    Some(p) => if !c.done { ignore(p.finish()) }
    // A call whose name arrived but whose arguments never did has no parser:
    // there is nothing to finish and `finish` would raise `E001`.
    None => ()
  }
  c.done = true
  // A verdict that is already known wins: `content_block_stop` says "this block
  // ended normally", it does not overrule a `max_tokens` or a provider error.
  if c.end is Open {
    c.end = end
  }
}

///|
/// Record the provider's own word for why the stream ended, on every call that
/// is not already in an error state.
fn ToolStream::note_stop(self : ToolStream, reason : String) -> Unit {
  let end = match reason {
    "max_tokens" | "length" | "model_context_window_exceeded" => MaxTokens
    _ => Complete
  }
  for c in self.calls {
    if c.end is ProviderError {
      continue
    }
    // The provider's word is recorded even when the block already closed
    // normally: `tool_use` and `end_turn` are both normal ends, and a caller
    // may still want to know which one it was.
    if reason != "" {
      c.stop_reason = reason
    }
    if c.end is Open || end is MaxTokens {
      c.end = end
    }
  }
}

///|
/// Mark every call as ended by a provider error (FR-30).
fn ToolStream::note_error(self : ToolStream, message : String) -> Unit {
  self.error_message = message
  for c in self.calls {
    // The end is decided, but the arguments are left open so that `finish`
    // still finalises whatever fragment arrived: a caller wants the partial
    // value of a call that failed, not an empty one.
    c.end = ProviderError
  }
}

///|
/// Feed one event payload. Returns the views of the calls the event changed.
///
/// The payload must be a complete JSON document. Anything that cannot be read
/// as an event of the configured provider raises `E060 InvalidEvent`.
pub fn ToolStream::push_event(
  self : ToolStream,
  event_json : String,
) -> Array[ToolCallView] raise @interjson.InterJSONError {
  let v = @json.parse(event_json) catch {
    _ => raise @interjson.InvalidEvent("event payload is not valid JSON")
  }
  let touched = match self.provider {
    Anthropic => self.push_anthropic(v)
    OpenAICompat => self.push_openai(v)
  }
  if touched.length() == 0 {
    self.ignored = self.ignored + 1
  }
  let out : Array[ToolCallView] = []
  for c in touched {
    out.push(self.view(c))
  }
  out
}

///|
/// Whether the provider reported an error in the stream, and what it said.
pub fn ToolStream::error(self : ToolStream) -> String {
  self.error_message
}

///|
/// How many payloads were not understood and ignored.
pub fn ToolStream::ignored_events(self : ToolStream) -> Int32 {
  self.ignored
}

///|
/// Finish every call that the provider never closed, and return all views.
///
/// This is the case of a response cut short by `max_tokens`: the arguments are
/// truncated, so `interjson` closes the open containers and the view's
/// exactness is `Lossy`.
pub fn ToolStream::finish(
  self : ToolStream,
) -> Array[ToolCallView] raise @interjson.InterJSONError {
  let out : Array[ToolCallView] = []
  for c in self.calls {
    // A call the provider never closed was cut off: the stream stopped without
    // a verdict, which is not the same as a normal end (FR-30).
    let end = if c.end is Open { Interrupted } else { c.end }
    self.close_call(c, end)
    out.push(self.view(c))
  }
  out
}

///|
/// Every call seen so far, without finishing anything.
pub fn ToolStream::views(self : ToolStream) -> Array[ToolCallView] {
  let out : Array[ToolCallView] = []
  for c in self.calls {
    out.push(self.view(c))
  }
  out
}

///|
/// Raw argument text accumulated for `index`, or the empty string.
pub fn ToolStream::arguments(self : ToolStream, index : Int32) -> String {
  for c in self.calls {
    if c.index == index {
      return c.text.to_string()
    }
  }
  ""
}
