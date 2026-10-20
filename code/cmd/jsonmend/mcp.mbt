// `jsonmend mcp` — the same engine as a Model Context Protocol server over
// stdio (JSON-RPC 2.0).
//
// MCP is how an agent *discovers* the tool; the host application is still the
// one that decides to execute a tool call. The four tools below are therefore
// written so that the model can use them deliberately, and so that a host that
// wants the gate can reuse the identical `analyze` semantics through `serve`.
//
// stdout carries JSON-RPC messages only; every diagnostic goes to stderr. A
// notification (a message with no `id`) is never answered.

///|
/// The MCP protocol revision this server implements. The client's requested
/// revision is echoed when it sent one, because MCP negotiates downward and a
/// client that asked for an older revision must not be told a newer one.
const MCP_PROTOCOL_VERSION : String = "2025-06-18"

///|
/// A JSON Schema for the shared tool arguments.
fn mcp_text_schema() -> Json {
  jobj([
    ("type", Json::string("string")),
    ("description", Json::string("The text to inspect.")),
  ])
}

///|
/// The `profile` argument, shared by the tools.
fn mcp_profile_schema() -> Json {
  jobj([
    ("type", Json::string("string")),
    (
      "description",
      Json::string(
        "Safety profile. `agent` (default for execution) refuses a lossy or ambiguous repair instead of guessing.",
      ),
    ),
    (
      "enum",
      Json::array([
        Json::string("permissive"),
        Json::string("interactive"),
        Json::string("execution"),
        Json::string("agent"),
        Json::string("strict"),
      ]),
    ),
  ])
}

///|
/// The `schema` argument (the library's declaration language).
fn mcp_schema_schema() -> Json {
  jobj([
    ("type", Json::string("string")),
    (
      "description",
      Json::string(
        "Skeleton declaration, e.g. `{!query:string,!limit:integer}`.",
      ),
    ),
  ])
}

///|
/// The `schema_json` argument (a JSON Schema subset).
fn mcp_schema_json_schema() -> Json {
  jobj([
    ("type", Json::string("object")),
    (
      "description",
      Json::string(
        "A JSON Schema subset (type/properties/required/items/enum/const/minimum/maximum/exclusiveMinimum/exclusiveMaximum/minLength/maxLength/pattern). Unsupported keywords are refused, not ignored.",
      ),
    ),
  ])
}

///|
/// An object schema from named members.
fn mcp_object(
  members : Array[(String, Json)],
  required : Array[String],
) -> Json {
  let props : Map[String, Json] = Map([])
  for pair in members {
    props[pair.0] = pair.1
  }
  jobj([
    ("type", Json::string("object")),
    ("properties", Json::object(props)),
    ("required", Json::array(required.map(Json::string))),
    ("additionalProperties", Json::boolean(false)),
  ])
}

///|
/// The tool list.
fn mcp_tools() -> Json {
  let tools : Array[Json] = []
  tools.push(
    jobj([
      ("name", Json::string("jsonmend_repair")),
      (
        "description",
        Json::string(
          "Repair malformed JSON: markdown fences, single quotes, comments, trailing commas, Python literals, truncated values. Returns the repaired text, the exactness label and the repair records.",
        ),
      ),
      (
        "inputSchema",
        mcp_object(
          [
            ("text", mcp_text_schema()),
            ("profile", mcp_profile_schema()),
            ("schema", mcp_schema_schema()),
            ("schema_json", mcp_schema_json_schema()),
          ],
          ["text"],
        ),
      ),
    ]),
  )
  tools.push(
    jobj([
      ("name", Json::string("jsonmend_analyze")),
      (
        "description",
        Json::string(
          "Decide whether a model's JSON can be executed. Returns decision (safe/cosmetic_repair/lossy_repair/ambiguous/invalid), exactness, ambiguity, schema satisfaction and a retry hint. Call this before executing tool arguments; if executable is false, re-emit the arguments using the retry_hint.",
        ),
      ),
      (
        "inputSchema",
        mcp_object(
          [
            ("text", mcp_text_schema()),
            ("profile", mcp_profile_schema()),
            ("schema", mcp_schema_schema()),
            ("schema_json", mcp_schema_json_schema()),
          ],
          ["text"],
        ),
      ),
    ]),
  )
  tools.push(
    jobj([
      ("name", Json::string("jsonmend_validate")),
      (
        "description",
        Json::string(
          "Check whether text is legal JSON and, when a declaration is given, whether it satisfies it. Reports what is there; it does not repair.",
        ),
      ),
      (
        "inputSchema",
        mcp_object(
          [
            ("text", mcp_text_schema()),
            ("schema", mcp_schema_schema()),
            ("schema_json", mcp_schema_json_schema()),
          ],
          ["text"],
        ),
      ),
    ]),
  )
  tools.push(
    jobj([
      ("name", Json::string("jsonmend_readiness")),
      (
        "description",
        Json::string(
          "Given a declaration, report when each required field becomes final in the stream: syntax/schema/settled fractions and the missing members.",
        ),
      ),
      (
        "inputSchema",
        mcp_object(
          [
            ("text", mcp_text_schema()),
            ("schema", mcp_schema_schema()),
            ("schema_json", mcp_schema_json_schema()),
          ],
          ["text"],
        ),
      ),
    ]),
  )
  jobj([("tools", Json::array(tools))])
}

///|
/// A JSON-RPC success envelope.
fn rpc_ok(id : Json, result : Json) -> String {
  jobj([("jsonrpc", Json::string("2.0")), ("id", id), ("result", result)]).stringify()
}

///|
/// A JSON-RPC error envelope.
fn rpc_err(id : Json, code : Int32, message : String) -> String {
  jobj([
    ("jsonrpc", Json::string("2.0")),
    ("id", id),
    (
      "error",
      jobj([
        ("code", Json::number(code.to_double())),
        ("message", Json::string(message)),
      ]),
    ),
  ]).stringify()
}

///|
/// A `tools/call` result: the tool output as text, or an error the model can
/// read.
fn tool_result(text : String, is_error : Bool) -> Json {
  jobj([
    (
      "content",
      Json::array([
        jobj([("type", Json::string("text")), ("text", Json::string(text))]),
      ]),
    ),
    ("isError", Json::boolean(is_error)),
  ])
}

///|
/// Run one tool. The mapping is one-to-one with `serve` methods, so the two
/// entry points cannot drift.
fn mcp_call_tool(
  state : ServeState,
  base : @mend.Options,
  name : String,
  args : Map[String, Json],
) -> Json {
  let meth = if name == "jsonmend_repair" {
    "repair"
  } else if name == "jsonmend_analyze" {
    "analyze"
  } else if name == "jsonmend_validate" {
    "validate"
  } else if name == "jsonmend_readiness" {
    "readiness"
  } else {
    ""
  }
  if meth == "" {
    return tool_result("unknown tool `" + name + "`", true)
  }
  let out = try {
    let result = handle_request(state, base, meth, args)
    tool_result(result.stringify(), false)
  } catch {
    e => tool_result(e.to_string(), true)
  }
  out
}

///|
/// Handle one JSON-RPC message. `None` means "a notification, answer nothing".
fn mcp_handle(
  state : ServeState,
  base : @mend.Options,
  message : Json,
) -> String? {
  let id = request_id(message)
  let has_id = match message {
    Json::Object(m) => m.contains("id")
    _ => false
  }
  let meth = request_method(message)
  let params = request_params(message)
  let result : String? = if meth == "initialize" {
    let requested = match params.get("protocolVersion") {
      Some(Json::String(v)) => v
      _ => MCP_PROTOCOL_VERSION
    }
    Some(
      rpc_ok(
        id,
        jobj([
          ("protocolVersion", Json::string(requested)),
          (
            "capabilities",
            jobj([("tools", jobj([("listChanged", Json::boolean(false))]))]),
          ),
          (
            "serverInfo",
            jobj([
              ("name", Json::string("jsonmend")),
              ("version", Json::string(ENGINE_VERSION)),
            ]),
          ),
        ]),
      ),
    )
  } else if meth == "notifications/initialized" ||
    meth == "notifications/cancelled" {
    None
  } else if meth == "ping" {
    Some(rpc_ok(id, jobj([])))
  } else if meth == "tools/list" {
    Some(rpc_ok(id, mcp_tools()))
  } else if meth == "tools/call" {
    let name = match params.get("name") {
      Some(Json::String(s)) => s
      _ => ""
    }
    if name == "" {
      Some(rpc_err(id, -32602, "`tools/call` requires `name`"))
    } else {
      let args = match params.get("arguments") {
        Some(Json::Object(a)) => a
        _ => Map([])
      }
      Some(rpc_ok(id, mcp_call_tool(state, base, name, args)))
    }
  } else if meth == "" {
    Some(rpc_err(id, -32600, "invalid request: missing `method`"))
  } else if has_id {
    Some(rpc_err(id, -32601, "method not found: " + meth))
  } else {
    None
  }
  result
}

///|
/// Run the MCP server until EOF.
fn run_mcp(o : CliOpts) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("jsonmend: 无法读取 <stdin>")
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
            rpc_err(Json::null(), -32700, "message exceeds MAX_LINE"),
          )
          continue
        }
        let trimmed = line.trim()
        if trimmed.length() == 0 {
          continue
        }
        let message = @json.parse(trimmed) catch {
          _ => {
            write_line(proto, rpc_err(Json::null(), -32700, "parse error"))
            continue
          }
        }
        match mcp_handle(state, base, message) {
          Some(out) => write_line(proto, out)
          None => ()
        }
      }
    }
  }
  close_input(stream)
  quit(0)
}
