// `interjson serve` — the long-lived, versioned protocol (PROTOCOL.md).
//
// `--stdio` is accepted as an explicit alias: stdio is the only transport,
// so the flag selects nothing. It exists so that the command line printed in
// the documentation works verbatim.
//
// One request per line on stdin, one response per line on stdout, UTF-8. The
// response echoes the client's `id`. stdout carries protocol bytes and nothing
// else; diagnostics go to stderr. The engine is the same one the one-shot CLI
// uses, so `serve` cannot disagree with `interjson repair`.
//
// The protocol is deliberately stateless for `repair`/`analyze`/`validate` and
// single-stream for `watch`/`llm`: one active stream per connection. That is
// enough for a tool-calling loop (one call at a time) and avoids an id map
// whose copy semantics would be the first thing to break. `hello` advertises
// `streams: 1` so a client can see the limit instead of discovering it.

///|
/// Protocol major version. A client that sees a different major version must
/// not assume the same fields.
const PROTOCOL_VERSION : Int32 = 1

///|
/// The engine version this build reports. It is the library's `VERSION`, not
/// a literal: the CLI, the MCP handshake and the library all have to name the
/// same release, and there is exactly one place that says which release this
/// is.
const ENGINE_VERSION : String = @ij.VERSION

///|
/// The mooncakes registry version that corresponds to `ENGINE_VERSION`. Also
/// the library's, for the same reason.
const REGISTRY_VERSION : String = @ij.REGISTRY_VERSION

///|
/// Largest request line accepted. A request larger than this is answered with
/// a structured error and discarded; it is not allowed to grow the process.
const MAX_LINE : Int32 = 8388608

///|
/// Line reader over a stdio stream. `fread` is asked for exactly one byte at a
/// time: a larger read blocks until the whole buffer is full on a pipe, which
/// would make the interactive protocol wait for 64 KiB before answering. The
/// stdio layer still buffers the underlying file descriptor, so this is a
/// function call per byte, not a syscall per byte.
struct LineReader {
  stream : Int64
  one : Bytes
  mut acc : Array[Byte]
  mut overflow : Bool
}

///|
/// A reader over `stream`.
fn LineReader::new(stream : Int64) -> LineReader {
  { stream, one: Bytes::make(1, b'\x00'), acc: [], overflow: false, }
}

///|
/// Decode a byte range as UTF-8, replacing malformed sequences.
fn line_text(bytes : ArrayView[Byte]) -> String {
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
/// The next byte, or `-1` at end of input.
fn LineReader::next_byte(self : LineReader) -> Int32 {
  let n = ffi_fread(self.one, 1, 1, self.stream)
  if n <= 0L {
    -1
  } else {
    self.one[0].to_char().to_int()
  }
}

///|
/// The next line, without the LF, or `None` at end of input. A line longer
/// than `MAX_LINE` sets `overflow` and is discarded up to the next LF; the
/// caller answers with an error instead of trying to parse half a request.
fn LineReader::read_line(self : LineReader) -> String? {
  self.acc = []
  while true {
    let c = self.next_byte()
    if c < 0 {
      if self.acc.length() == 0 {
        return None
      }
      return Some(line_text(self.acc[:]))
    }
    if c == 0x0A {
      return Some(line_text(self.acc[:]))
    }
    if self.acc.length() >= MAX_LINE {
      self.overflow = true
      while true {
        let d = self.next_byte()
        if d < 0 || d == 0x0A {
          break
        }
      } nobreak {
        ()
      }
      self.acc = []
      return Some("")
    }
    self.acc.push(c.to_byte())
  } nobreak {
    None
  }
}

///|
/// Build a JSON object from pairs.
fn jobj(pairs : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for pair in pairs {
    m[pair.0] = pair.1
  }
  Json::object(m)
}

///|
/// A number from a code-unit count.
fn jnum(n : Int32) -> Json {
  Json::number(n.to_double())
}

///|
/// `Completeness` as the stable word the protocol uses.
fn completeness_name(c : @ij.Completeness) -> String {
  match c {
    @ij.Empty => "empty"
    @ij.Partial => "partial"
    @ij.Complete => "complete"
  }
}

///|
/// `Severity` as the stable word the protocol uses.
fn severity_name(s : @ij.Severity) -> String {
  match s {
    @ij.Info => "info"
    @ij.Warning => "warning"
  }
}

///|
/// One repair record.
fn repair_json(r : @ij.Repair) -> Json {
  jobj([
    ("code", Json::string(r.code.code())),
    ("threshold", Json::string(r.code.name())),
    ("line", jnum(r.position.line)),
    ("column", jnum(r.position.column)),
    ("offset", jnum(r.position.offset)),
    ("severity", Json::string(severity_name(r.severity))),
    ("message", Json::string(r.message)),
    ("ambiguity", Json::string(r.ambiguity.name())),
  ])
}

///|
/// One delta.
fn delta_json(d : @ij.Delta) -> Json {
  jobj([
    ("path", Json::string(d.pointer())),
    ("op", Json::string(d.op.name())),
    (
      "value",
      match d.value {
        Some(v) => v
        None => Json::null()
      },
    ),
    ("text", Json::string(d.text)),
    ("at", jnum(d.at)),
  ])
}

///|
/// A snapshot path as `a/0/b`.
fn snapshot_path(s : @ij.Snapshot) -> String {
  let sb = StringBuilder()
  for i = 0; i < s.open_path.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('/')
    }
    match s.open_path[i] {
      @ij.Key(k) => sb.write_string(k)
      @ij.Index(x) => sb.write_string(x.to_string())
    }
  }
  sb.to_string()
}

///|
/// A finished parse.
fn final_json(f : @ij.FinalResult) -> Json {
  jobj([
    ("text", Json::string(f.text)),
    ("value", f.value),
    ("exactness", Json::string(f.exactness.name())),
    ("ambiguous", Json::boolean(f.ambiguous)),
    ("completeness", Json::string(completeness_name(f.completeness))),
    ("repairs", Json::array(f.repairs.map(repair_json))),
    ("repairs_truncated", Json::boolean(f.repairs_truncated)),
  ])
}

///|
/// A one-shot repair result (no `value`; `analyze` carries the value).
fn repair_out_json(r : @ij.RepairResult) -> Json {
  jobj([
    ("text", Json::string(r.text)),
    ("exactness", Json::string(r.exactness.name())),
    ("ambiguous", Json::boolean(r.ambiguous)),
    ("completeness", Json::string(completeness_name(r.completeness))),
    ("repairs", Json::array(r.repairs.map(repair_json))),
    ("repairs_truncated", Json::boolean(r.repairs_truncated)),
  ])
}

///|
/// One readiness event with the offset it fired at.
fn event_json(e : @ij.ReadinessEvent, at : Int32, fed : Int32) -> Json {
  let base = @json.parse(e.to_json()) catch { _ => Json::null() }
  match base {
    Json::Object(m) => {
      m["at"] = jnum(at)
      m["permille"] = jnum(
        if at < 0 || fed == 0 {
          -1
        } else {
          at * 1000 / fed
        },
      )
      Json::object(m)
    }
    _ => base
  }
}

///|
/// A schema verdict.
fn verdict_json(v : @ij.SchemaVerdict) -> Json {
  let mismatched : Array[Json] = []
  for m in v.mismatched {
    mismatched.push(
      jobj([
        ("path", Json::string(m.path)),
        ("expected", Json::string(m.expected)),
        ("got", Json::string(m.got)),
      ]),
    )
  }
  jobj([
    ("total", jnum(v.total)),
    ("satisfied", jnum(v.satisfied)),
    ("missing", Json::array(v.missing.map(Json::string))),
    ("mismatched", Json::array(mismatched)),
    ("ok", Json::boolean(v.ok)),
  ])
}

///|
/// One tool call as the provider stream sees it.
fn tool_call_json(v : @llm.ToolCallView) -> Json {
  jobj([
    ("index", jnum(v.index)),
    ("id", Json::string(v.id)),
    ("name", Json::string(v.name)),
    ("done", Json::boolean(v.done)),
    ("exactness", Json::string(v.exactness.name())),
    ("end", Json::string(v.end.name())),
    ("stop_reason", Json::string(v.stop_reason)),
    (
      "value",
      match v.snapshot.value {
        Some(x) => x
        None => Json::null()
      },
    ),
    ("open_path", Json::string(snapshot_path(v.snapshot))),
  ])
}

///|
/// A fatal error as a structured object, never as stderr text.
fn error_json(e : @ij.InterJSONError) -> Json {
  let m : Map[String, Json] = Map([])
  m["code"] = Json::string(e.code())
  m["message"] = Json::string(e.to_string())
  m["exit"] = Json::number(error_exit_code(e).to_double())
  match e.retry_hint() {
    Some(h) => m["retry_hint"] = Json::string(h.to_prompt())
    None => ()
  }
  match error_offset(e) {
    Some(off) => m["offset"] = jnum(off)
    None => ()
  }
  Json::object(m)
}

///|
/// `{"id":…,"ok":true,"result":…}`.
fn response_ok(id : Json, result : Json) -> String {
  jobj([("id", id), ("ok", Json::boolean(true)), ("result", result)]).stringify()
}

///|
/// `{"id":…,"ok":false,"error":…}`.
fn response_err(id : Json, e : @ij.InterJSONError) -> String {
  jobj([("id", id), ("ok", Json::boolean(false)), ("error", error_json(e))]).stringify()
}

///|
/// The `hello` result: what this process is, what it can do, and which two
/// version numbers it carries.
fn hello_json() -> Json {
  let caps : Array[Json] = [
    Json::string("repair"),
    Json::string("analyze"),
    Json::string("validate"),
    Json::string("readiness"),
    Json::string("watch"),
    Json::string("llm"),
  ]
  jobj([
    ("name", Json::string("interjson")),
    ("engine", Json::string(ENGINE_VERSION)),
    ("registry", Json::string(REGISTRY_VERSION)),
    ("protocol", Json::number(PROTOCOL_VERSION.to_double())),
    ("capabilities", Json::array(caps)),
    ("streams", Json::number(1)),
  ])
}

///|
/// Read `text` from the request.
fn text_param(params : Map[String, Json]) -> String raise @ij.InterJSONError {
  match params.get("text") {
    Some(Json::String(s)) => s
    Some(_) => raise @ij.InvalidOption("`text` must be a string")
    None => raise @ij.InvalidOption("missing `text`")
  }
}

///|
/// Read an integer parameter, or `fallback` when absent.
fn int_param(
  params : Map[String, Json],
  key : String,
  fallback : Int32,
) -> Int32 raise @ij.InterJSONError {
  match params.get(key) {
    Some(Json::Number(d, ..)) => d.to_int()
    Some(Json::Null) => fallback
    Some(_) => raise @ij.InvalidOption("`" + key + "` must be a number")
    None => fallback
  }
}

///|
/// The caller's declaration: `schema_json` (JSON Schema subset) wins over
/// `schema` (the library's DSL).
fn schema_param(
  params : Map[String, Json],
) -> @ij.Schema? raise @ij.InterJSONError {
  match params.get("schema_json") {
    Some(v) => Some(@ij.Schema::of_json_schema(v))
    None =>
      match params.get("schema") {
        Some(Json::String(s)) => Some(@ij.Schema::parse(s))
        Some(_) => raise @ij.InvalidOption("`schema` must be a string")
        None => None
      }
  }
}

///|
/// Merge a request's `profile`/`skip_prose`/`max_loss` into the process
/// options. A profile replaces the safety fields and keeps the protocol fields
/// (`collect_deltas`, `want_text`, …), which is what `with_policy` exists for.
fn options_from_params(
  base : @ij.Options,
  params : Map[String, Json],
) -> @ij.Options raise @ij.InterJSONError {
  let mut opts = base
  match params.get("profile") {
    Some(Json::String(name)) =>
      match parse_policy_name(name) {
        // `with_profile`, not `with_policy`: a profile carries protocol as
        // well as safety, and `agent` implies prose skipping. See
        // `Options::with_profile`.
        Some(p) => opts = opts.with_profile(p)
        None =>
          raise @ij.InvalidOption(
            "unknown profile `" +
            name +
            "`; use permissive, interactive, execution, agent or strict",
          )
      }
    Some(_) => raise @ij.InvalidOption("`profile` must be a string")
    None => ()
  }
  match params.get("skip_prose") {
    Some(Json::True) => opts = { ..opts, skip_prose: true, }
    Some(Json::False) => opts = { ..opts, skip_prose: false, }
    Some(_) => raise @ij.InvalidOption("`skip_prose` must be a boolean")
    None => ()
  }
  match params.get("max_loss") {
    Some(Json::String(name)) =>
      match parse_max_loss(name) {
        Some(x) => opts = { ..opts, max_loss: x, }
        None =>
          raise @ij.InvalidOption(
            "unknown max_loss `" + name + "`; use exact, cosmetic or lossy",
          )
      }
    None => ()
    Some(_) => raise @ij.InvalidOption("`max_loss` must be a string")
  }
  opts
}

///|
/// One open stream per connection.
struct ServeState {
  mut watch_parser : @ij.PartialParser?
  mut watch_watcher : @ij.SemanticWatcher?
  mut llm_stream : @llm.ToolStream?
  /// Whether `initialize` has been answered. MCP is a session protocol: a
  /// request that arrives before the handshake is a bug in the client, and
  /// answering it anyway hides the bug behind a response the client cannot
  /// place. Only `initialize`, `ping` and notifications are answered before
  /// it; anything else gets `-32002`.
  mut initialized : Bool
}

///|
/// A fresh state.
fn ServeState::new() -> ServeState {
  {
    watch_parser: None,
    watch_watcher: None,
    llm_stream: None,
    initialized: false,
  }
}

///|
/// `repair`: one document in, one repaired document out.
fn handle_repair(
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  let text = text_param(params)
  let opts = options_from_params(base, params)
  // The one-shot entry point, not a hand-rolled feed/finish: it also carries
  // the scalar-root retry that `skip_prose` needs, so `serve` cannot disagree
  // with `interjson repair`.
  repair_out_json(@ij.repair(text, options=opts))
}

///|
/// `analyze`: the never-raising decision call, as the full plan object.
fn handle_analyze(
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  let text = text_param(params)
  let opts = options_from_params(base, params)
  let schema = schema_param(params)
  let plan = match schema {
    Some(s) => @ij.analyze(text, options=opts, schema=s)
    None => @ij.analyze(text, options=opts)
  }
  // `value` and `text` are the same document twice. A gate response used to
  // carry both, so a 1 MB tool-call argument produced ~3 MB of
  // `structuredContent` -- the payload, the rendered text, and the text channel.
  // `text` is now opt-in (`with_text`), because a caller that has `value` can
  // render it and the MCP gate never reads `text`.
  let with_text = match params.get("with_text") {
    Some(Json::True) => true
    _ => false
  }
  @json.parse(plan.to_json_with_text(with_text)) catch {
    _ => raise @ij.InvalidState("the plan could not be serialised")
  }
}

///|
/// `validate`: is this text legal JSON, and (optionally) does it satisfy the
/// declaration? A repairable document is still invalid: this method reports
/// what is there, it does not repair.
fn handle_validate(
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  let text = text_param(params)
  let schema = schema_param(params)
  if @ij.is_valid_json(text) {
    let result : Map[String, Json] = Map([])
    result["valid"] = Json::boolean(true)
    match schema {
      Some(s) => {
        let parsed = @ij.parse(text)
        let verdict = s.evaluate(parsed.value)
        result["schema"] = verdict_json(verdict)
      }
      None => ()
    }
    return Json::object(result)
  }
  // Not legal JSON: name the first repair the strict profile would have to
  // make, and the repaired text the lenient profile produces.
  let out : Map[String, Json] = Map([])
  out["valid"] = Json::boolean(false)
  let strict = try {
    ignore(@ij.repair(text, options=@ij.Options::strict()))
    None
  } catch {
    e => Some(e)
  }
  match strict {
    Some(e) => out["error"] = error_json(e)
    None => ()
  }
  let repaired = Some(
    @ij.repair(text, options=options_from_params(base, params)),
  ) catch {
    _ => None
  }
  match repaired {
    Some(r) => {
      out["repaired"] = Json::string(r.text)
      out["exactness"] = Json::string(r.exactness.name())
      out["ambiguous"] = Json::boolean(r.ambiguous)
      out["repairs"] = Json::array(r.repairs.map(repair_json))
    }
    None => ()
  }
  Json::object(out)
}

///|
/// `readiness`: the two fractions and the verdict, without a stream.
fn handle_readiness(
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  let text = text_param(params)
  let step = int_param(params, "step", 0)
  match schema_param(params) {
    Some(s) => {
      let opts = options_from_params(base, params)
      let r = @ij.semantic_readiness(text, s, step~, options=opts)
      // The three aggregate fractions say *when the document as a whole* was
      // ready. The tool's description promises "when each required field
      // becomes final", which is a different question, and until now the
      // answer was not in the response: a caller that wanted to stop a
      // generation as soon as the arguments were settled had to re-derive it.
      // `watch_readiness` already computes exactly that, so the events are
      // returned, each with the input fraction it fired at.
      let events = @ij.watch_readiness(text, s, options=opts)
      let fields : Array[Json] = []
      for e in events {
        fields.push(
          jobj([
            ("event", Json::string(e.event.kind())),
            ("path", Json::string(e.event.path())),
            ("permille", jnum(e.permille)),
          ]),
        )
      }
      jobj([
        ("syntax_permille", jnum(r.syntax_permille)),
        ("schema_permille", jnum(r.schema_permille)),
        ("settled_permille", jnum(r.settled_permille)),
        ("step", jnum(r.step)),
        ("verdict", verdict_json(r.verdict)),
        ("events", Json::array(fields)),
      ])
    }
    None => {
      let p = @ij.syntax_readiness_permille(text, step~)
      jobj([
        ("syntax_permille", jnum(p)),
        ("schema_permille", jnum(-1)),
        ("settled_permille", jnum(-1)),
        ("step", jnum(if step > 0 { step } else { 0 })),
        ("events", Json::array([])),
      ])
    }
  }
}

///|
/// `watch.start`: open the single stream.
fn handle_watch_start(
  state : ServeState,
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  if state.watch_parser is Some(_) {
    raise @ij.InvalidState(
      "a watch stream is already open; call `watch.finish` first",
    )
  }
  let schema = match schema_param(params) {
    Some(s) => s
    None => @ij.Schema::Any
  }
  let opts : @ij.Options = {
    ..options_from_params(base, params),
    collect_deltas: true,
  }
  state.watch_parser = Some(@ij.PartialParser::new(options=opts))
  state.watch_watcher = Some(@ij.SemanticWatcher::new(schema, options=opts))
  jobj([
    ("ok", Json::boolean(true)),
    ("schema", Json::string(schema.stringify())),
  ])
}

///|
/// `watch.feed`: one chunk in, deltas and readiness events out.
fn handle_watch_feed(
  state : ServeState,
  params : Map[String, Json],
) -> Json raise @ij.InterJSONError {
  let chunk = match params.get("chunk") {
    Some(Json::String(s)) => s
    Some(_) => raise @ij.InvalidOption("`chunk` must be a string")
    None => raise @ij.InvalidOption("missing `chunk`")
  }
  match (state.watch_parser, state.watch_watcher) {
    (Some(parser), Some(watcher)) => {
      parser.feed(chunk)
      watcher.feed(chunk)
      let deltas = parser.drain_deltas().map(delta_json)
      let events : Array[Json] = []
      for pair in watcher.drain_events_at() {
        events.push(event_json(pair.0, pair.1, watcher.bytes()))
      }
      jobj([
        ("deltas", Json::array(deltas)),
        ("events", Json::array(events)),
        ("bytes", jnum(watcher.bytes())),
      ])
    }
    _ => raise @ij.InvalidState("no active watch stream")
  }
}

///|
/// `watch.finish`: close the stream and return the final parse.
fn handle_watch_finish(state : ServeState) -> Json raise @ij.InterJSONError {
  match (state.watch_parser, state.watch_watcher) {
    (Some(parser), Some(watcher)) => {
      let mut err = ""
      let fin = Some(parser.finish()) catch {
        e => {
          err = e.to_string()
          None
        }
      }
      let wfin = Some(watcher.finish()) catch { _ => None }
      let events : Array[Json] = []
      let fed = watcher.bytes()
      for pair in watcher.drain_events_at() {
        events.push(event_json(pair.0, pair.1, fed))
      }
      state.watch_parser = None
      state.watch_watcher = None
      match fin {
        Some(f) =>
          jobj([
            ("final", final_json(f)),
            ("events", Json::array(events)),
            (
              "watcher_final",
              match wfin {
                Some(w) => final_json(w)
                None => Json::null()
              },
            ),
          ])
        None => raise @ij.InvalidState(err)
      }
    }
    _ => raise @ij.InvalidState("no active watch stream")
  }
}

///|
/// The provider named by a request.
fn provider_param(
  params : Map[String, Json],
) -> @llm.Provider raise @ij.InterJSONError {
  match params.get("provider") {
    Some(Json::String(s)) =>
      if s == "anthropic" {
        @llm.Anthropic
      } else if s == "openai" || s == "openai_compat" {
        @llm.OpenAICompat
      } else {
        raise @ij.InvalidOption(
          "unknown provider `" + s + "`; use anthropic or openai",
        )
      }
    None => @llm.Anthropic
    Some(_) => raise @ij.InvalidOption("`provider` must be a string")
  }
}

///|
/// `llm.open`: open the single provider stream.
fn handle_llm_open(
  state : ServeState,
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  if state.llm_stream is Some(_) {
    raise @ij.InvalidState(
      "a provider stream is already open; call `llm.close` first",
    )
  }
  let provider = provider_param(params)
  let opts = options_from_params(base, params)
  state.llm_stream = Some(@llm.ToolStream::new(provider, options=opts))
  jobj([
    ("ok", Json::boolean(true)),
    (
      "provider",
      Json::string(
        if provider is @llm.Anthropic {
          "anthropic"
        } else {
          "openai"
        },
      ),
    ),
  ])
}

///|
/// `llm.feed`: one event payload in, the calls it touched out.
fn handle_llm_feed(
  state : ServeState,
  params : Map[String, Json],
) -> Json raise @ij.InterJSONError {
  let event = match params.get("event") {
    Some(Json::String(s)) => s
    Some(_) => raise @ij.InvalidOption("`event` must be a string")
    None => raise @ij.InvalidOption("missing `event`")
  }
  match state.llm_stream {
    Some(stream) => {
      let views = stream.push_event(event)
      // The stream is a struct with mutable arrays; writing it back keeps the
      // state field authoritative even if the compiler copied it.
      state.llm_stream = Some(stream)
      jobj([("calls", Json::array(views.map(tool_call_json)))])
    }
    None => raise @ij.InvalidState("no active provider stream")
  }
}

///|
/// `llm.close`: finish every call and report the provider's verdict.
fn handle_llm_close(state : ServeState) -> Json raise @ij.InterJSONError {
  match state.llm_stream {
    Some(stream) => {
      let views = stream.finish()
      let err = stream.error()
      let ignored = stream.ignored_events()
      state.llm_stream = None
      jobj([
        ("calls", Json::array(views.map(tool_call_json))),
        ("error", Json::string(err)),
        ("ignored_events", jnum(ignored)),
      ])
    }
    None => raise @ij.InvalidState("no active provider stream")
  }
}

///|
/// `llm.run`: the stateless form, for a client that already has the whole
/// event list.
fn handle_llm_run(
  params : Map[String, Json],
  base : @ij.Options,
) -> Json raise @ij.InterJSONError {
  let provider = provider_param(params)
  let stream = @llm.ToolStream::new(
    provider,
    options=options_from_params(base, params),
  )
  match params.get("events") {
    Some(Json::Array(events)) =>
      for event in events {
        match event {
          Json::String(s) => {
            let _ = stream.push_event(s)
          }
          _ => raise @ij.InvalidOption("`events` must be an array of strings")
        }
      }
    Some(_) => raise @ij.InvalidOption("`events` must be an array of strings")
    None => ()
  }
  let views = stream.finish()
  jobj([
    ("calls", Json::array(views.map(tool_call_json))),
    ("error", Json::string(stream.error())),
    ("ignored_events", jnum(stream.ignored_events())),
  ])
}

///|
/// Dispatch one method.
fn handle_request(
  state : ServeState,
  base : @ij.Options,
  meth : String,
  params : Map[String, Json],
) -> Json raise @ij.InterJSONError {
  if meth == "hello" {
    hello_json()
  } else if meth == "repair" {
    handle_repair(params, base)
  } else if meth == "analyze" {
    handle_analyze(params, base)
  } else if meth == "validate" {
    handle_validate(params, base)
  } else if meth == "readiness" {
    handle_readiness(params, base)
  } else if meth == "watch.start" {
    handle_watch_start(state, params, base)
  } else if meth == "watch.feed" {
    handle_watch_feed(state, params)
  } else if meth == "watch.finish" {
    handle_watch_finish(state)
  } else if meth == "llm.open" {
    handle_llm_open(state, params, base)
  } else if meth == "llm.feed" {
    handle_llm_feed(state, params)
  } else if meth == "llm.close" {
    handle_llm_close(state)
  } else if meth == "llm.run" {
    handle_llm_run(params, base)
  } else {
    raise @ij.InvalidOption("unknown method `" + meth + "`")
  }
}

///|
/// The request's `id`, or `null` when it has none.
fn request_id(v : Json) -> Json {
  match v {
    Json::Object(m) =>
      match m.get("id") {
        Some(id) => id
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// The request's `method`, or `""`.
fn request_method(v : Json) -> String {
  match v {
    Json::Object(m) =>
      match m.get("method") {
        Some(Json::String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
/// The request's `params`, or an empty object.
fn request_params(v : Json) -> Map[String, Json] {
  match v {
    Json::Object(m) =>
      match m.get("params") {
        Some(Json::Object(p)) => p
        _ => Map([])
      }
    _ => Map([])
  }
}

///|
/// Run the stdio protocol until EOF or `shutdown`.
fn run_serve(o : CliOpts) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("interjson: 无法读取 <stdin>")
    return quit(3)
  }
  let reader = LineReader::new(stream)
  let base = options_of(o)
  let state = ServeState::new()
  let proto = open_output()
  let mut running = true
  while running {
    match reader.read_line() {
      None => running = false
      Some(line) => {
        if reader.overflow {
          reader.overflow = false
          write_line(
            proto,
            jobj([
              ("id", Json::null()),
              ("ok", Json::boolean(false)),
              (
                "error",
                jobj([
                  ("code", Json::string("E050")),
                  (
                    "message",
                    Json::string(
                      "request line exceeds MAX_LINE (" +
                      MAX_LINE.to_string() +
                      " bytes)",
                    ),
                  ),
                  ("exit", Json::number(2)),
                ]),
              ),
            ]).stringify(),
          )
          continue
        }
        let trimmed = line.trim()
        if trimmed.length() == 0 {
          continue
        }
        let request = @json.parse(trimmed) catch {
          _ => {
            write_line(
              proto,
              jobj([
                ("id", Json::null()),
                ("ok", Json::boolean(false)),
                (
                  "error",
                  jobj([
                    ("code", Json::string("E060")),
                    ("message", Json::string("request is not valid JSON")),
                    ("exit", Json::number(3)),
                  ]),
                ),
              ]).stringify(),
            )
            continue
          }
        }
        let id = request_id(request)
        let meth = request_method(request)
        let params = request_params(request)
        if meth == "shutdown" {
          write_line(
            proto,
            response_ok(
              id,
              jobj([("ok", Json::boolean(true)), ("bye", Json::boolean(true))]),
            ),
          )
          running = false
        } else if meth == "" {
          write_line(
            proto,
            response_err(id, @ij.InvalidOption("missing `method`")),
          )
        } else {
          let out = response_ok(id, handle_request(state, base, meth, params)) catch {
            e => response_err(id, e)
          }
          write_line(proto, out)
        }
      }
    }
  }
  close_input(stream)
  quit(0)
}
