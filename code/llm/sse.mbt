// A minimal server-sent-events reader (FR-22). It exists because an LLM stream
// is normally an SSE stream, and every caller otherwise rewrites this loop.
//
// The rules implemented are the ones that matter for event payloads:
//   * a line is terminated by LF, CRLF or CR;
//   * `data:` accumulates, `event:`, `id:` and `retry:` are kept out of the
//     payload, a line starting with `:` is a comment;
//   * a blank line dispatches the accumulated `data` lines joined by LF;
//   * the parser is fed arbitrary chunks, so a cut inside a line or inside a
//     multi-byte character is handled.

///|
/// Incremental SSE reader.
pub struct SseBuffer {
  /// Bytes of the current line that are not a complete line yet.
  pending : StringBuilder
  /// Payload lines of the event being assembled.
  data : Array[String]
  /// Whether any `data:` line was seen for the event being assembled.
  mut has_data : Bool
}

///|
/// An empty reader.
pub fn SseBuffer::new() -> SseBuffer {
  { pending: StringBuilder(), data: [], has_data: false, }
}

///|
/// Push a chunk of text, returning the payloads of the events it completed.
pub fn SseBuffer::push(self : SseBuffer, chunk : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  let n = chunk.length()
  while i < n {
    let u = chunk.at(i).to_int()
    if u == 0x0A || u == 0x0D {
      let line = self.pending.to_string()
      self.pending.reset()
      self.dispatch_line(line, out)
      // CRLF is one terminator, not two.
      if u == 0x0D && i + 1 < n && chunk.at(i + 1).to_int() == 0x0A {
        i = i + 1
      }
    } else {
      self.pending.write_char(Int32::unsafe_to_char(u))
    }
    i = i + 1
  }
  out
}

///|
/// End of input: dispatch a last line and the event being assembled.
pub fn SseBuffer::flush(self : SseBuffer) -> Array[String] {
  let out : Array[String] = []
  let line = self.pending.to_string()
  self.pending.reset()
  if line.length() > 0 {
    self.dispatch_line(line, out)
  }
  self.dispatch_event(out)
  out
}

///|
/// Interpret one complete line.
fn SseBuffer::dispatch_line(
  self : SseBuffer,
  line : String,
  out : Array[String],
) -> Unit {
  if line.length() == 0 {
    self.dispatch_event(out)
    return
  }
  if line.at(0).to_int() == 0x3A {
    return
  }
  let cut = line.find(":")
  let (name, value) = match cut {
    Some(i) => (line[0:i].to_owned(), line[i + 1:].to_owned())
    None => (line, "")
  }
  // A single leading space after the colon is part of the framing, not data.
  let text = if value.has_prefix(" ") { value[1:].to_owned() } else { value }
  if name == "data" {
    self.data.push(text)
    self.has_data = true
  }
}

///|
/// Dispatch the event being assembled, if any.
fn SseBuffer::dispatch_event(self : SseBuffer, out : Array[String]) -> Unit {
  if self.has_data {
    out.push(self.data.join("\n"))
  }
  self.data.clear()
  self.has_data = false
}

///|
/// Payload of a single `data:` line, for callers that read lines themselves.
pub fn sse_data(line : String) -> String? {
  if !line.has_prefix("data:") {
    return None
  }
  let v = line[5:].to_owned()
  if v.has_prefix(" ") {
    Some(v[1:].to_owned())
  } else {
    Some(v)
  }
}
