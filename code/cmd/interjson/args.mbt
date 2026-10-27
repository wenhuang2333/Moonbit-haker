// Command line parsing and help text (D12 12.4, D09 9.8).

///|
/// What the process should do once the arguments are parsed.
enum CliAction {
  Run
  Help
  Version
  Llm
  Readiness
  Explain
  Serve
  Mcp
}

///|
/// Parsed command line.
struct CliOpts {
  mut strict : Bool
  mut check : Bool
  mut report : Bool
  mut indent : Int32
  mut multi_root : @ij.MultiRoot
  mut skip_prose : Bool
  mut quote_lookahead : Bool
  mut max_repairs : Int32
  mut max_prose_buffer : Int32
  mut max_input_len : Int32
  mut max_depth : Int32
  mut max_token_len : Int32
  mut with_text : Bool
  mut max_loss : @ij.Exactness
  mut reject_ambiguous : Bool
  mut retry_hint : Bool
  mut step : Int32
  mut chunk : Int32
  mut explain : Bool
  mut batch : Bool
  mut provider : String
  mut sse : Bool
  mut text : Bool
  mut follow : Bool
  mut path : String?
  mut schema : String
  mut policy : String
  mut json_out : Bool
  mut mcp_help : Bool
  mut mcp_config : String
  mut action : CliAction
}

///|
/// Help text of the command.
fn help_text() -> String {
  let lines : Array[String] = [
    "interjson [选项] [文件]", "", "读取文件或标准输入，把修复后的 JSON 写到标准输出。",
    "", "  --strict            严格模式：需要修复就报错（退出码 5）",
    "  --check             只检查，不输出；需要修复时退出码 1", "  --report            把修复记录写到标准错误",
    "  --indent N          输出缩进空格数，默认紧凑输出", "  --multi-root MODE   first、array 或 error，默认 first",
    "  --skip-prose        跳过 JSON 之前的说明文字", "  --quote-lookahead   启用引号歧义前瞻",
    "  --max-repairs N     最多记录多少条修复记录，默认 10000", "  --max-prose-buffer N",
    "                      跳过前言时最多缓存多少码元供结束回放（默认 65536），超过则按原样拒绝",
    "  --max-input-len N   最多接受多少码元，超过报 E021 资源限制（默认 67108864）",
    "  --max-depth N       容器最大嵌套深度，超过报 E020（默认 512）",
    "  --max-token-len N   单个 token 的最大码元数，超过报 E022（默认 16777216）",
    "                      这三个上限默认与库一致；调用方可以自己收紧或放宽",
    "  --with-text         与 explain --json 同用时在计划里带上修复后的全文",
    "                      （默认不带：机器可读的计划已有 value，全文是重复的一份）",
    "  --max-loss LEVEL    精确度上限：exact、cosmetic 或 lossy，默认 lossy",
    "  --for-execution     执行档：等价于 --max-loss cosmetic --reject-ambiguous",
    "  --reject-ambiguous  拒绝有第二种读法的修复，报 E011（退出码 5）",
    "  --retry-hint        拒绝时在标准错误上打印可直接回灌模型的提示",
    "  --chunk N           分块喂入：每次喂 N 个码元（≤1048576），用来验证流式路径（默认一次喂完）",
    "  --explain           在标准错误上逐条解释修复，并打印精确度小结",
    "  --policy NAME       安全档位：permissive、interactive、execution、agent 或 strict",
    "  --schema DECL       骨架声明，例如 `{!query:string,!limit:integer}`；检查必需字段与类型",
    "                      与 explain 同用时打印语法就绪与骨架就绪两层数字",
    "  --json              与 explain 同用时打印机器可读的 JSON 计划，而不是文本块",
    "  --batch             逐行读取 {\"id\",\"input\"} JSON，逐行输出结果 JSON",
    "                      与 --chunk N 同用可把每条输入按 N 字节分块喂入",
    "", "interjson explain [选项] [文件]", "  打印完整分析：修复了什么、为什么、风险多大、能不能执行；拒绝时给可直接回灌模型的提示。",
    "  退出码与 interjson 相同（可执行 0，拒绝 5）。", "", "interjson repair [选项] [文件]",
    "  修复并输出：省略子命令时的默认动作。写出这个子命令名，只为让命令与文档一致。",
    "", "interjson readiness [选项] [文件]", "  打印字段就绪曲线：每个顶级字段在输入消耗到多少时已定稿。",
    "  --step N            每 N 个码元观察一次，默认按长度自适应",
    "", "interjson llm [选项] [文件]", "  把模型的事件流喂给 provider 适配器，每个工具调用输出一行结果 JSON。",
    "  --provider NAME     anthropic（默认）或 openai", "  --sse               输入是 SSE 文本（默认按每行一个事件 JSON 读取）",
    "  --text              读取文本增量（delta.content / text_delta）而不是工具调用参数（配 --skip-prose 可跳过前言）",
    "  --follow            每次增量都输出一行，而不是只在结束时输出",
    "", "interjson serve [选项]", "  长驻 stdio 协议（PROTOCOL.md）：每行一个请求 JSON，每行一个响应 JSON。",
    "  方法：hello、repair、analyze、validate、readiness、watch.*、llm.*、shutdown。",
    "  进程级选项（--policy 等）作为默认值，请求里的 profile/schema 逐条覆盖。",
    "", "interjson mcp [选项]", "  MCP stdio server（JSON-RPC 2.0）：interjson_gate（执行门）、interjson_repair、",
    "  interjson_validate、interjson_readiness 四个工具，供 agent 直接调用。",
    "  --print-config[=CLIENT] 打印客户端配置后退出；CLIENT 为 claude、cursor、vscode、",
    "                      codex、windsurf、zed 或 json（默认）", "  -h, --help          显示 mcp 帮助",
    "  --version           显示版本", "", "文件为 `-` 或缺省时读取标准输入。",
    "", "退出码：0 成功（可能有修复）；1 --check 发现需要修复；2 用法错误；",
    "        3 输入无效；4 资源限制；5 严格模式违规；70 内部错误。",
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
/// `s` from index `from` on.
fn slice_tail(s : String, from : Int32) -> String {
  let sb = StringBuilder()
  for i = from; i < s.length(); i = i + 1 {
    sb.write_char(Int32::unsafe_to_char(s.at(i).to_int()))
  }
  sb.to_string()
}

///|
/// Decimal non-negative integer with an upper bound of 64: for the flags whose
/// value is a small enumeration or indentation width.
fn parse_uint(s : String) -> Int32? {
  parse_uint_up_to(s, 64)
}

///|
/// Decimal non-negative integer with an explicit upper bound. `--chunk` and
/// `--step` count code units, so their bound is far above 64.
///
/// The accumulator is checked against `limit` *before* each multiply, so a long
/// digit string cannot wrap the accumulator and be accepted as a negative
/// number.
fn parse_uint_up_to(s : String, limit : Int32) -> Int32? {
  if s.length() == 0 {
    return None
  }
  let mut n = 0
  for i = 0; i < s.length(); i = i + 1 {
    let c = s.at(i).to_int()
    if c < 0x30 || c > 0x39 {
      return None
    }
    let digit = c - 0x30
    if n > (limit - digit) / 10 {
      return None
    }
    n = n * 10 + digit
  }
  Some(n)
}

///|
/// `--multi-root` payload.
fn parse_multi_root(s : String) -> @ij.MultiRoot? {
  match s {
    "first" => Some(@ij.KeepFirst)
    "array" => Some(@ij.AsArray)
    "error" => Some(@ij.AsError)
    _ => None
  }
}

///|
/// `--policy` payload (FR-30): the named safety profiles.
fn parse_policy_name(s : String) -> @ij.SafetyPolicy? {
  match s {
    "permissive" => Some(@ij.SafetyPolicy::permissive())
    "interactive" => Some(@ij.SafetyPolicy::interactive())
    "execution" => Some(@ij.SafetyPolicy::for_execution())
    "agent" => Some(@ij.SafetyPolicy::for_agent())
    "strict" => Some(@ij.SafetyPolicy::strict())
    _ => None
  }
}

///|
/// `--max-loss` payload.
fn parse_max_loss(s : String) -> @ij.Exactness? {
  match s {
    "exact" => Some(@ij.Exact)
    "cosmetic" => Some(@ij.Cosmetic)
    "lossy" => Some(@ij.Lossy)
    _ => None
  }
}

///|
/// Payload of `--name value` or `--name=value`: the value and how many extra
/// arguments it consumed. `name_len` is the length of the bare flag name.
fn flag_value(
  a : String,
  name_len : Int32,
  args : Array[String],
  i : Int32,
) -> (String, Int32) {
  if a.length() == name_len {
    if i + 1 < args.length() {
      (args[i + 1], 1)
    } else {
      ("", 1)
    }
  } else {
    (slice_tail(a, name_len + 1), 0)
  }
}

///|
/// Parse a payload as a positive code-unit limit.
fn limit_of(value : String, limit : Int32) -> Int32? {
  match parse_uint_up_to(value, limit) {
    Some(n) => if n <= 0 { None } else { Some(n) }
    None => None
  }
}

///|
/// Parse `args` (including argv[0]). The second element is a usage error, or
/// the empty string.
fn parse_args(args : Array[String]) -> (CliOpts, String) {
  let d = @ij.Options::default()
  let o : CliOpts = {
    strict: false,
    check: false,
    report: false,
    indent: 0,
    multi_root: @ij.KeepFirst,
    skip_prose: false,
    quote_lookahead: false,
    max_repairs: 10000,
    max_prose_buffer: 65536,
    max_input_len: d.max_input_len,
    max_depth: d.max_depth,
    max_token_len: d.max_token_len,
    with_text: false,
    max_loss: @ij.Lossy,
    reject_ambiguous: false,
    retry_hint: false,
    step: 0,
    chunk: 0,
    explain: false,
    batch: false,
    provider: "anthropic",
    sse: false,
    text: false,
    follow: false,
    path: None,
    schema: "",
    policy: "",
    json_out: false,
    mcp_help: false,
    mcp_config: "",
    action: Run,
  }
  let mut err = ""
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    let mut consumed = 0
    if i == 1 && a == "llm" {
      o.action = Llm
    } else if i == 1 && a == "readiness" {
      o.action = Readiness
    } else if i == 1 && a == "explain" {
      o.action = Explain
    } else if i == 1 && a == "repair" {
      // `repair` is what the CLI does when no subcommand is given; naming it
      // makes the command the documents already use (`interjson repair`) real
      // instead of a filename lookup that fails with "cannot read repair".
      o.action = Run
    } else if i == 1 && a == "serve" {
      o.action = Serve
    } else if i == 1 && a == "mcp" {
      o.action = Mcp
    } else if a == "--stdio" {
      // `serve` speaks stdio and nothing else. `--stdio` is accepted so that
      // the command line printed in the documentation works verbatim: it
      // selects nothing, because there is no other transport to switch to.
      // It is only meaningful together with `serve`.
      match o.action {
        Serve => ()
        _ => err = "`--stdio` 只对 `interjson serve` 有意义"
      }
    } else if a == "--print-config" || a.has_prefix("--print-config=") {
      let value = if a == "--print-config" { "json" } else { slice_tail(a, 15) }
      o.mcp_config = if value == "" { "json" } else { value }
      o.action = Mcp
    } else if a == "-h" || a == "--help" {
      match o.action {
        Mcp => o.mcp_help = true
        _ => o.action = Help
      }
    } else if a == "--version" {
      o.action = Version
    } else if a == "--strict" {
      o.strict = true
    } else if a == "--check" {
      o.check = true
    } else if a == "--report" {
      o.report = true
    } else if a == "--skip-prose" {
      o.skip_prose = true
    } else if a == "--quote-lookahead" {
      o.quote_lookahead = true
    } else if a == "--for-execution" {
      o.max_loss = @ij.Cosmetic
      o.reject_ambiguous = true
    } else if a == "--reject-ambiguous" {
      o.reject_ambiguous = true
    } else if a == "--retry-hint" {
      o.retry_hint = true
    } else if a == "--chunk" || a.has_prefix("--chunk=") {
      let value = if a == "--chunk" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 8)
      }
      if value == "" && a == "--chunk" {
        err = "--chunk 缺少参数"
      } else {
        match parse_uint_up_to(value, 1048576) {
          Some(n) => o.chunk = n
          None =>
            err = "--chunk 需要 0 到 1048576 之间的整数，收到 `" +
              value +
              "`"
        }
      }
    } else if a == "--step" || a.has_prefix("--step=") {
      let value = if a == "--step" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 7)
      }
      if value == "" && a == "--step" {
        err = "--step 缺少参数"
      } else {
        match parse_uint_up_to(value, 1048576) {
          Some(n) => o.step = n
          None =>
            err = "--step 需要 0 到 1048576 之间的整数，收到 `" +
              value +
              "`"
        }
      }
    } else if a == "--explain" {
      o.explain = true
    } else if a == "--json" {
      o.json_out = true
    } else if a == "--policy" || a.has_prefix("--policy=") {
      let value = if a == "--policy" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 9)
      }
      if parse_policy_name(value) is Some(_) {
        o.policy = value
      } else {
        err = "--policy 需要 permissive、interactive、execution、agent 或 strict，收到 `" +
          value +
          "`"
      }
    } else if a == "--schema" || a.has_prefix("--schema=") {
      let value = if a == "--schema" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 9)
      }
      if value == "" {
        err = "--schema 缺少声明"
      } else {
        let mut ok = true
        ignore(
          @ij.Schema::parse(value) catch {
            e => {
              ok = false
              err = e.to_string()
              @ij.Schema::Any
            }
          },
        )
        if ok {
          o.schema = value
        }
      }
    } else if a == "--batch" {
      o.batch = true
    } else if a == "--sse" {
      o.sse = true
    } else if a == "--text" {
      o.text = true
    } else if a == "--follow" {
      o.follow = true
    } else if a == "--provider" || a.has_prefix("--provider=") {
      let value = if a == "--provider" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 11)
      }
      if value == "anthropic" || value == "openai" {
        o.provider = value
      } else {
        err = "--provider 需要 anthropic 或 openai，收到 `" + value + "`"
      }
    } else if a == "--max-loss" || a.has_prefix("--max-loss=") {
      let value = if a == "--max-loss" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 11)
      }
      match parse_max_loss(value) {
        Some(l) => o.max_loss = l
        None =>
          err = "--max-loss 需要 exact、cosmetic 或 lossy，收到 `" +
            value +
            "`"
      }
    } else if a == "--max-repairs" || a.has_prefix("--max-repairs=") {
      let value = if a == "--max-repairs" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 14)
      }
      if value == "" && a == "--max-repairs" {
        err = "--max-repairs 缺少参数"
      } else {
        match parse_uint(value) {
          Some(n) =>
            if n <= 0 {
              err = "--max-repairs 需要正整数，收到 `" + value + "`"
            } else {
              o.max_repairs = n
            }
          None => err = "--max-repairs 需要正整数，收到 `" + value + "`"
        }
      }
    } else if a == "--max-prose-buffer" || a.has_prefix("--max-prose-buffer=") {
      let value = if a == "--max-prose-buffer" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 20)
      }
      if value == "" && a == "--max-prose-buffer" {
        err = "--max-prose-buffer 缺少参数"
      } else {
        match parse_uint_up_to(value, 67108864) {
          Some(n) =>
            if n <= 0 {
              err = "--max-prose-buffer 需要正整数，收到 `" +
                value +
                "`"
            } else {
              o.max_prose_buffer = n
            }
          None =>
            err = "--max-prose-buffer 需要 1 到 67108864 之间的整数，收到 `" +
              value +
              "`"
        }
      }
    } else if a == "--max-input-len" || a.has_prefix("--max-input-len=") {
      let (value, extra) = flag_value(a, 15, args, i)
      consumed = extra
      match limit_of(value, 2147483647) {
        Some(n) => o.max_input_len = n
        None =>
          err = "--max-input-len 需要正整数字面量，收到 `" +
            value +
            "`"
      }
    } else if a == "--max-depth" || a.has_prefix("--max-depth=") {
      let (value, extra) = flag_value(a, 11, args, i)
      consumed = extra
      match limit_of(value, 1048576) {
        Some(n) => o.max_depth = n
        None =>
          err = "--max-depth 需要 1 到 1048576 之间的整数，收到 `" +
            value +
            "`"
      }
    } else if a == "--max-token-len" || a.has_prefix("--max-token-len=") {
      let (value, extra) = flag_value(a, 15, args, i)
      consumed = extra
      match limit_of(value, 2147483647) {
        Some(n) => o.max_token_len = n
        None =>
          err = "--max-token-len 需要正整数字面量，收到 `" +
            value +
            "`"
      }
    } else if a == "--with-text" {
      o.with_text = true
    } else if a == "--indent" || a.has_prefix("--indent=") {
      let value = if a == "--indent" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 9)
      }
      if value == "" && a == "--indent" {
        err = "--indent 缺少参数"
      } else {
        match parse_uint(value) {
          Some(n) => o.indent = n
          None =>
            err = "--indent 需要 0 到 64 之间的整数，收到 `" +
              value +
              "`"
        }
      }
    } else if a == "--multi-root" || a.has_prefix("--multi-root=") {
      let value = if a == "--multi-root" {
        consumed = 1
        if i + 1 < args.length() {
          args[i + 1]
        } else {
          ""
        }
      } else {
        slice_tail(a, 13)
      }
      match parse_multi_root(value) {
        Some(m) => o.multi_root = m
        None =>
          err = "--multi-root 需要 first、array 或 error，收到 `" +
            value +
            "`"
      }
    } else if a == "-" {
      if o.path is Some(_) {
        err = "只能指定一个文件"
      } else {
        o.path = None
      }
    } else if a.length() > 0 && a.at(0).to_int() == 0x2D {
      err = "未知选项 `" + a + "`"
    } else if o.path is Some(_) {
      err = "只能指定一个文件"
    } else {
      o.path = Some(a)
    }
    if err != "" {
      break
    }
    i = i + 1 + consumed
  }
  (o, err)
}
