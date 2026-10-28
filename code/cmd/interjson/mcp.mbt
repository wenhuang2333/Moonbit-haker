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
/// The older revisions this server still accepts verbatim. Clients that asked
/// for one of them keep working without being upgraded behind their back.
const MCP_PROTOCOL_LEGACY : String = "2024-11-05"

///|
/// The revision between the two above. It changed the tool *result* shape
/// (`structuredContent` alongside `content`), which this server already does,
/// so a client that asks for it is answered in the revision it asked for.
const MCP_PROTOCOL_MID : String = "2025-03-26"

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
/// A JSON Schema fragment for a string.
fn mcp_string() -> Json {
  jobj([("type", Json::string("string"))])
}

///|
/// A JSON Schema fragment for a boolean.
fn mcp_boolean() -> Json {
  jobj([("type", Json::string("boolean"))])
}

///|
/// A JSON Schema fragment for a number.
fn mcp_number() -> Json {
  jobj([("type", Json::string("number"))])
}

///|
/// A JSON Schema fragment for an array of strings.
fn mcp_string_array() -> Json {
  jobj([("type", Json::string("array")), ("items", mcp_string())])
}

///|
/// A JSON Schema fragment for a value of any JSON type.
fn mcp_any_value() -> Json {
  jobj([
    (
      "type",
      Json::array([
        Json::string("object"),
        Json::string("array"),
        Json::string("string"),
        Json::string("number"),
        Json::string("boolean"),
        Json::string("null"),
      ]),
    ),
  ])
}

///|
/// A JSON Schema fragment for an object or `null`.
fn mcp_object_or_null() -> Json {
  jobj([("type", Json::array([Json::string("object"), Json::string("null")]))])
}

///|
/// A JSON Schema fragment for one repair record.
fn mcp_repair_schema() -> Json {
  mcp_object(
    [
      ("rule", mcp_string()),
      ("name", mcp_string()),
      ("action", mcp_string()),
      ("offset", mcp_number()),
      ("line", mcp_number()),
      ("column", mcp_number()),
      ("severity", mcp_string()),
      ("ambiguity", mcp_string()),
      ("confidence_class", mcp_string()),
      ("confidence", mcp_number()),
      ("information_loss", mcp_boolean()),
    ],
    [
      "rule", "name", "action", "offset", "line", "column", "severity", "ambiguity",
      "confidence_class", "confidence", "information_loss",
    ],
  )
}

///|
/// The output schema of the gate.
///
/// It used to be `{type: object, additionalProperties: true}`, which says
/// nothing: a client that validates the structured channel against it learns
/// no more than it would from the absence of a schema, and a client that
/// generates code from it gets `object`. The schema now names every field the
/// gate actually returns, so a host can read `executable` and `retry.prompt`
/// as typed members.
fn mcp_gate_output_schema() -> Json {
  mcp_object(
    [
      ("decision", mcp_string()),
      ("label", mcp_string()),
      ("exactness", mcp_string()),
      ("ambiguous", mcp_boolean()),
      ("information_loss", mcp_boolean()),
      ("valid_json", mcp_boolean()),
      ("normalized", mcp_boolean()),
      ("ambiguity", mcp_string()),
      ("execution", mcp_string()),
      ("executable", mcp_boolean()),
      ("syntax_ready_permille", mcp_number()),
      ("schema_total", mcp_number()),
      ("schema_satisfied", mcp_number()),
      ("schema_missing", mcp_string_array()),
      ("error", mcp_object_or_null()),
      (
        "repairs",
        jobj([("type", Json::string("array")), ("items", mcp_repair_schema())]),
      ),
      ("retry", mcp_object_or_null()),
      ("repairs_truncated", mcp_boolean()),
      ("value", mcp_any_value()),
      ("text", mcp_string()),
    ],
    [
      "decision", "label", "exactness", "ambiguous", "information_loss", "valid_json",
      "normalized", "ambiguity", "execution", "executable", "syntax_ready_permille",
      "schema_total", "schema_satisfied", "schema_missing", "error", "repairs", "retry",
      "repairs_truncated", "value", "text",
    ],
  )
}

///|
/// The output schema of the repair tool.
fn mcp_repair_output_schema() -> Json {
  mcp_object(
    [
      ("text", mcp_string()),
      ("exactness", mcp_string()),
      ("ambiguous", mcp_boolean()),
      ("completeness", mcp_string()),
      (
        "repairs",
        jobj([("type", Json::string("array")), ("items", mcp_repair_schema())]),
      ),
      ("repairs_truncated", mcp_boolean()),
    ],
    [
      "text", "exactness", "ambiguous", "completeness", "repairs", "repairs_truncated",
    ],
  )
}

///|
/// The output schema of the validation tool.
fn mcp_validate_output_schema() -> Json {
  mcp_object(
    [
      ("valid", mcp_boolean()),
      ("schema", mcp_object_or_null()),
      ("error", mcp_object_or_null()),
      ("repaired", mcp_string()),
      ("exactness", mcp_string()),
      ("ambiguous", mcp_boolean()),
      (
        "repairs",
        jobj([("type", Json::string("array")), ("items", mcp_repair_schema())]),
      ),
    ],
    ["valid"],
  )
}

///|
/// The output schema of the readiness tool.
fn mcp_readiness_output_schema() -> Json {
  mcp_object(
    [
      ("syntax_permille", mcp_number()),
      ("schema_permille", mcp_number()),
      ("settled_permille", mcp_number()),
      ("step", mcp_number()),
      ("verdict", mcp_object_or_null()),
    ],
    ["syntax_permille", "schema_permille", "settled_permille", "step"],
  )
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
  output : Json,
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
    ("outputSchema", output),
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
      mcp_gate_output_schema(),
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
      mcp_repair_output_schema(),
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
      mcp_validate_output_schema(),
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
      mcp_readiness_output_schema(),
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
      if v == MCP_PROTOCOL_VERSION ||
        v == MCP_PROTOCOL_MID ||
        v == MCP_PROTOCOL_LEGACY {
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
/// The text channel of a tool result: a summary a model can act on, not a
/// second copy of the payload.
///
/// The two channels used to carry the same object, so a gate response was two
/// complete copies of the same JSON on the wire — the payload twice, plus the
/// repaired document inside each copy. A host pays for every byte of it, and
/// the model reads the text channel, so the text channel now says what the
/// model needs: the decision, whether it may execute, and the sentence to
/// send back when it may not. The machine-readable payload stays in
/// `structuredContent`, once.
fn mcp_summary(meth : String, result : Json) -> String {
  let sb = StringBuilder()
  match result {
    Json::Object(m) =>
      if meth == "analyze" {
        sb.write_string("decision=")
        sb.write_string(json_field(m, "decision"))
        sb.write_string(" executable=")
        sb.write_string(json_field(m, "executable"))
        sb.write_string(" exactness=")
        sb.write_string(json_field(m, "exactness"))
        match m.get("error") {
          Some(Json::Object(e)) => {
            sb.write_string("\nerror=")
            sb.write_string(json_field(e, "code"))
            sb.write_string(" ")
            sb.write_string(json_field(e, "message"))
          }
          _ => ()
        }
        match m.get("retry") {
          Some(Json::Object(r)) => {
            sb.write_string("\nretry (send this back to the model): ")
            sb.write_string(json_field(r, "prompt"))
          }
          _ => ()
        }
      } else if meth == "repair" {
        sb.write_string("exactness=")
        sb.write_string(json_field(m, "exactness"))
        sb.write_string(" ambiguous=")
        sb.write_string(json_field(m, "ambiguous"))
        sb.write_string("\n")
        sb.write_string(json_field(m, "text"))
      } else if meth == "validate" {
        sb.write_string("valid=")
        sb.write_string(json_field(m, "valid"))
        match m.get("error") {
          Some(Json::Object(e)) => {
            sb.write_string("\nerror=")
            sb.write_string(json_field(e, "code"))
            sb.write_string(" ")
            sb.write_string(json_field(e, "message"))
          }
          _ => ()
        }
        match m.get("repaired") {
          Some(Json::String(t)) => {
            sb.write_string("\nrepaired: ")
            sb.write_string(t)
          }
          _ => ()
        }
      } else if meth == "readiness" {
        sb.write_string("syntax=")
        sb.write_string(json_field(m, "syntax_permille"))
        sb.write_string(" schema=")
        sb.write_string(json_field(m, "schema_permille"))
        sb.write_string(" settled=")
        sb.write_string(json_field(m, "settled_permille"))
        // The per-field answer is the reason the tool exists, so the summary
        // names the fields and when each became final.
        match m.get("events") {
          Some(Json::Array(events)) =>
            for e in events {
              match e {
                Json::Object(ev) =>
                  if json_field(ev, "event") == "field_ready" {
                    sb.write_string("\n  ")
                    sb.write_string(json_field(ev, "path"))
                    sb.write_string(" ready at ")
                    sb.write_string(json_field(ev, "permille"))
                    sb.write_string("/1000")
                  }
                _ => ()
              }
            }
          _ => ()
        }
      } else {
        sb.write_string(result.stringify())
      }
    _ => sb.write_string(result.stringify())
  }
  sb.to_string()
}

///|
/// One field of an object as text, or `""` when the field is absent.
fn json_field(m : Map[String, Json], key : String) -> String {
  match m.get(key) {
    Some(Json::String(s)) => s
    Some(Json::Number(d, ..)) => d.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    Some(Json::Null) => "null"
    _ => ""
  }
}

///|
/// Run one tool. The mapping is one-to-one with `serve` methods, so the two
/// entry points cannot drift.
fn mcp_tool_method(name : String) -> String {
  if name == "interjson_gate" {
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
  let meth = mcp_tool_method(name)
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
    tool_result(mcp_summary(meth, result), false, structured=result)
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
  // The handshake comes first. `initialize` and `ping` are the only requests
  // answered before it (notifications are never answered at all); anything
  // else is `-32002`, the code MCP reserves for "not initialized". Answering
  // `tools/list` before the handshake used to succeed, which meant a client
  // that had skipped `initialize` got a tool list and then found that its
  // captured `instructions` and negotiated revision were missing -- a failure
  // several steps away from its cause.
  if meth != "initialize" &&
    meth != "ping" &&
    meth != "notifications/initialized" &&
    meth != "notifications/cancelled" &&
    !state.initialized {
    return Some(
      rpc_err(id, -32002, "server not initialized; send `initialize` first"),
    )
  }
  let result : String? = if meth == "initialize" {
    state.initialized = true
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
    } else if mcp_tool_method(name) == "" {
      // An unknown tool is a bad request, not a tool that failed: the
      // JSON-RPC answer is `-32602`. It used to come back as a tool result
      // with `isError: true`, which told the host "the tool ran and
      // refused" — a distinction the host could not make, and which hid a
      // typo in the tool name behind a tool-level failure.
      Some(rpc_err(id, -32602, "unknown tool `" + name + "`"))
    } else {
      let args = match params.get("arguments") {
        Some(Json::Object(a)) => a
        // A non-object `arguments` used to be read as "no arguments", so a
        // malformed call became a call with no text and a confusing error
        // about a missing parameter.
        Some(other) =>
          return Some(
            rpc_err(
              id,
              -32602,
              "`arguments` must be an object, not " + other.stringify(),
            ),
          )
        None => Map([])
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
fn mcp_config_text(client : String) -> String? {
  let generic = "{\"mcpServers\":{\"interjson\":{\"command\":\"interjson\",\"args\":[\"mcp\"]}}}"
  if client == "claude" {
    Some("claude mcp add interjson -- interjson mcp")
  } else if client == "cursor" {
    Some(generic)
  } else if client == "vscode" {
    Some(
      "{\"servers\":{\"interjson\":{\"type\":\"stdio\",\"command\":\"interjson\",\"args\":[\"mcp\"]}}}",
    )
  } else if client == "codex" {
    Some("[mcp_servers.interjson]\ncommand = \"interjson\"\nargs = [\"mcp\"]")
  } else if client == "windsurf" {
    Some(generic)
  } else if client == "zed" {
    Some(
      "{\"context_servers\":{\"interjson\":{\"command\":{\"path\":\"interjson\",\"args\":[\"mcp\"]}}}}",
    )
  } else if client == "json" {
    Some(generic)
  } else {
    // An unknown client name used to fall back to the generic JSON silently,
    // so a typo (`--print-config claud`) printed a config for a client the
    // user had not asked about and said nothing.
    None
  }
}

///|
/// Run the MCP server until EOF.
fn run_mcp(o : CliOpts) -> Unit {
  if o.mcp_config != "" {
    match mcp_config_text(o.mcp_config) {
      Some(text) => {
        println(text)
        return quit(0)
      }
      None => {
        eprintln(
          "interjson: 未知客户端 `" +
          o.mcp_config +
          "`；可用：claude、cursor、vscode、codex、windsurf、zed、json",
        )
        return quit(2)
      }
    }
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
