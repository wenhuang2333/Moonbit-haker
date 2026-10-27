// `interjson mcp` — InterJSON as a local Model Context Protocol server over
// stdio (JSON-RPC 2.0).
//
// The positioning is the protocol: InterJSON is the *execution gate* between a
// model's output and the tool call the host is about to run. The gate tool is
// therefore named `interjson_gate` and its description tells the model to call
// it before executing arguments; `repair`, `validate` and `readiness` are the
// supporting tools. Every tool is pure (same input, same output, no files, no
// network), so all four are annotated read-only.
//
// stdout carries JSON-RPC messages only; every diagnostic goes to stderr. A
// notification (a message with no `id`) is never answered. The process is
// local by construction: it serves stdin/stdout and opens no socket.

///|
/// The MCP protocol revision this server implements. The client's requested
/// revision is echoed when the server supports it; an unsupported revision is
/// answered with this one, which is what MCP negotiation requires.
const MCP_PROTOCOL_VERSION : String = "2025-06-18"

///|
/// The older revision this server still accepts verbatim. Clients that asked
/// for it keep working without being upgraded behind their back.
const MCP_PROTOCOL_LEGACY : String = "2024-11-05"

///|
/// A JSON Schema for the shared tool arguments.
fn mcp_text_schema() -> Json {
  jobj([
    ("type", Json::string("string")),
    (
      "description",
      Json::string(
        "The raw text to inspect: the model's tool arguments, or any JSON document.",
      ),
    ),
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
        "Safety profile. `agent` (default here) refuses a lossy or ambiguous repair instead of guessing; `permissive` repairs for display; `strict` refuses any repair.",
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
        "The tool's declared inputSchema, passed through unchanged (type/properties/required/items/enum/const/minimum/maximum/exclusiveMinimum/exclusiveMaximum/minLength/maxLength/pattern). Unsupported keywords are refused, not ignored.",
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
/// The output schema of every tool. The payload is the same object the text
/// content carries; clients that understand MCP 2025-06-18 can read it as
/// `structuredContent` instead of parsing the text channel.
fn mcp_output_schema() -> Json {
  jobj([
    ("type", Json::string("object")),
    ("additionalProperties", Json::boolean(true)),
  ])
}

///|
/// Tool annotations: these tools are pure readers. A host may cache, retry or
/// call them concurrently without side effects, which is what every field here
/// says.
fn mcp_annotations() -> Json {
  jobj([
    ("title", Json::string("InterJSON")),
    ("readOnlyHint", Json::boolean(true)),
    ("destructiveHint", Json::boolean(false)),
    ("idempotentHint", Json::boolean(true)),
    ("openWorldHint", Json::boolean(false)),
  ])
}

///|
/// One tool declaration.
fn mcp_tool(
  name : String,
  title : String,
  description : String,
  members : Array[(String, Json)],
  required : Array[String],
) -> Json {
  let annotations = match mcp_annotations() {
    Json::Object(m) => {
      m["title"] = Json::string(title)
      Json::object(m)
    }
    other => other
  }
  jobj([
    ("name", Json::string(name)),
    ("title", Json::string(title)),
    ("description", Json::string(description)),
    ("inputSchema", mcp_object(members, required)),
    ("outputSchema", mcp_output_schema()),
    ("annotations", annotations),
  ])
}

///|
/// The tool list. The first tool is the product.
fn mcp_tools() -> Json {
  let tools : Array[Json] = [
    mcp_tool(
      "interjson_gate",
      "Gate: may I execute this?",
      "The execution gate for LLM output. Call this before executing tool arguments or trusting structured output. Returns decision (safe/cosmetic_repair/lossy_repair/ambiguous/invalid), executable, exactness, ambiguity, schema satisfaction, the parsed value, and a retry hint. If `executable` is false, do not execute: send `retry.prompt` back to the model and re-emit the arguments.",
      [
        ("text", mcp_text_schema()),
        ("profile", mcp_profile_schema()),
        ("schema", mcp_schema_schema()),
        ("schema_json", mcp_schema_json_schema()),
      ],
      ["text"],
    ),
    mcp_tool(
      "interjson_repair",
      "Repair malformed JSON",
      "Repair malformed JSON (markdown fences, single quotes, comments, trailing commas, Python literals, truncated values) and return the repaired text with the exactness label and the repair records. Use this when you need the document, not a decision.",
      [
        ("text", mcp_text_schema()),
        ("profile", mcp_profile_schema()),
        ("schema", mcp_schema_schema()),
        ("schema_json", mcp_schema_json_schema()),
      ],
      ["text"],
    ),
    mcp_tool(
      "interjson_validate",
      "Validate without repairing",
      "Report whether text is legal JSON and, when a declaration is given, whether it satisfies it. This never repairs: a document that could be fixed is still reported as invalid, with the repair the lenient profile would make.",
      [
        ("text", mcp_text_schema()),
        ("schema", mcp_schema_schema()),
        ("schema_json", mcp_schema_json_schema()),
      ],
      ["text"],
    ),
    mcp_tool(
      "interjson_readiness",
      "When do fields become final?",
      "Given a declaration, report when each required field becomes final in the stream: syntax/schema/settled fractions and the missing members. Use this to stop a generation early when the arguments are already settled.",
      [
        ("text", mcp_text_schema()),
        ("schema", mcp_schema_schema()),
        ("schema_json", mcp_schema_json_schema()),
      ],
      ["text"],
    ),
  ]
  jobj([("tools", Json::array(tools))])
}

///|
/// The server instructions MCP clients may surface to the model. Kept short:
/// an instruction the model cannot act on in one step is noise.
fn mcp_instructions() -> String {
  let lines : Array[String] = [
    "InterJSON is a local execution gate for model output. It runs on this machine over stdio and performs no network requests.",
    "", "Before executing tool arguments or trusting structured output, call `interjson_gate` with the raw argument text and the tool's inputSchema as `schema_json`.",
    "- `executable: true` means the arguments are safe to execute; `value` is the parsed object.",
    "- `executable: false` means do not execute: send `retry.prompt` back to the model and use the re-emitted arguments.",
    "", "`interjson_repair` returns repaired text, `interjson_validate` reports legality without repairing, and `interjson_readiness` reports when streaming fields become final.",
  ]
  let sb = StringBuilder()
  for i = 0; i < lines.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('\n')
    }
    sb.write_string(lines[i])
  }
  sb.to_string()
}

///|
/// Negotiate the protocol revision: echo a revision this server implements,
/// otherwise offer the newest one. Never echo an arbitrary string back: a
/// client that asked for `1999-01-01` and got it would believe the server
/// speaks a revision that does not exist.
fn mcp_negotiate(params : Map[String, Json]) -> String {
  match params.get("protocolVersion") {
    Some(Json::String(v)) =>
      if v == MCP_PROTOCOL_VERSION || v == MCP_PROTOCOL_LEGACY {
        v
      } else {
        MCP_PROTOCOL_VERSION
      }
    _ => MCP_PROTOCOL_VERSION
  }
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
/// A `tools/call` result: the tool output as text, plus the same object on the
/// structured channel when the call succeeded. A failure is a `content` text
/// the model can read and `isError: true`; the JSON-RPC request itself
/// succeeded, which is what the protocol asks for a tool execution error.
fn tool_result(text : String, is_error : Bool, structured? : Json) -> Json {
  let m : Map[String, Json] = Map([])
  m["content"] = Json::array([
    jobj([("type", Json::string("text")), ("text", Json::string(text))]),
  ])
  m["isError"] = Json::boolean(is_error)
  match structured {
    Some(value) => m["structuredContent"] = value
    None => ()
  }
  Json::object(m)
}

///|
/// Run one tool. The mapping is one-to-one with `serve` methods, so the two
/// entry points cannot drift.
fn mcp_call_tool(
  state : ServeState,
  base : @ij.Options,
  name : String,
  args : Map[String, Json],
) -> Json {
  let meth = if name == "interjson_gate" {
    "analyze"
  } else if name == "interjson_repair" {
    "repair"
  } else if name == "interjson_validate" {
    "validate"
  } else if name == "interjson_readiness" {
    "readiness"
  } else {
    ""
  }
  if meth == "" {
    return tool_result("unknown tool `" + name + "`", true)
  }
  // The gate is safe by default: a host that calls it without a profile gets
  // the execution profile, never the permissive one. `permissive` is still one
  // explicit argument away for a caller that wants display repair.
  let args = if meth == "analyze" && !args.contains("profile") {
    let with_default = args.copy()
    with_default["profile"] = Json::string("agent")
    with_default
  } else {
    args
  }
  try {
    let result = handle_request(state, base, meth, args)
    tool_result(result.stringify(), false, structured=result)
  } catch {
    e => tool_result(e.to_string(), true)
  }
}

///|
/// Handle one JSON-RPC message. `None` means "a notification, answer nothing".
fn mcp_handle(
  state : ServeState,
  base : @ij.Options,
  message : Json,
) -> String? {
  let id = request_id(message)
  let has_id = match message {
    Json::Object(m) => m.contains("id")
    _ => false
  }
  let meth = request_method(message)
  let params = request_params(message)
  // JSON-RPC: a message without `id` is a notification and is never answered.
  // `initialize`, `tools/list` and `tools/call` are requests, so a client that
  // forgets the id gets silence rather than a response it cannot correlate.
  if !has_id && meth != "" && !meth.has_prefix("notifications/") {
    return None
  }
  let result : String? = if meth == "initialize" {
    Some(
      rpc_ok(
        id,
        jobj([
          ("protocolVersion", Json::string(mcp_negotiate(params))),
          (
            "capabilities",
            jobj([("tools", jobj([("listChanged", Json::boolean(false))]))]),
          ),
          (
            "serverInfo",
            jobj([
              ("name", Json::string("interjson")),
              ("title", Json::string("InterJSON — the execution gate")),
              ("version", Json::string(ENGINE_VERSION)),
            ]),
          ),
          ("instructions", Json::string(mcp_instructions())),
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
/// The mcp-specific help text.
fn mcp_help_text() -> String {
  let lines : Array[String] = [
    "interjson mcp [选项]", "", "  以 MCP stdio server 运行：stdin/stdout 上是 JSON-RPC 2.0，诊断只走 stderr。",
    "  进程只读写自己的管道，不监听端口、不发起网络请求。",
    "", "工具：", "  interjson_gate       执行门：能不能执行、为什么不能、回灌模型的话（首选）",
    "  interjson_repair     修复并返回文本", "  interjson_validate   只校验，不修复",
    "  interjson_readiness  流式字段何时定稿", "", "  --print-config[=CLIENT]  打印客户端配置后退出；CLIENT 为 claude、cursor、",
    "                           vscode、codex、windsurf、zed 或 json（默认）",
    "  -h, --help               显示本帮助", "", "配置示例（Claude Code）：",
    "  claude mcp add interjson -- interjson mcp",
  ]
  let sb = StringBuilder()
  for i = 0; i < lines.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('\n')
    }
    sb.write_string(lines[i])
  }
  sb.to_string()
}

///|
/// The client configuration `--print-config` prints. Pure JSON for the clients
/// that read a JSON file, a command line for Claude Code, TOML for Codex.
fn mcp_config_text(client : String) -> String {
  if client == "claude" {
    "claude mcp add interjson -- interjson mcp"
  } else if client == "cursor" {
    "{\"mcpServers\":{\"interjson\":{\"command\":\"interjson\",\"args\":[\"mcp\"]}}}"
  } else if client == "vscode" {
    "{\"servers\":{\"interjson\":{\"type\":\"stdio\",\"command\":\"interjson\",\"args\":[\"mcp\"]}}}"
  } else if client == "codex" {
    "[mcp_servers.interjson]\ncommand = \"interjson\"\nargs = [\"mcp\"]"
  } else if client == "windsurf" {
    "{\"mcpServers\":{\"interjson\":{\"command\":\"interjson\",\"args\":[\"mcp\"]}}}"
  } else if client == "zed" {
    "{\"context_servers\":{\"interjson\":{\"command\":{\"path\":\"interjson\",\"args\":[\"mcp\"]}}}}"
  } else {
    "{\"mcpServers\":{\"interjson\":{\"command\":\"interjson\",\"args\":[\"mcp\"]}}}"
  }
}

///|
/// Run the MCP server until EOF.
fn run_mcp(o : CliOpts) -> Unit {
  if o.mcp_config != "" {
    println(mcp_config_text(o.mcp_config))
    return quit(0)
  }
  if o.mcp_help {
    println(mcp_help_text())
    return quit(0)
  }
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
