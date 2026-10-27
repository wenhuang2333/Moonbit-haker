// interjson — repair and partial-parse JSON from the command line.
// Usage and exit codes: see D12 12.4 and D09 9.8.

///|
/// Slice of `s` by code unit.
fn slice(s : String, from : Int32, to : Int32) -> String {
  let sb = StringBuilder()
  for i = from; i < to; i = i + 1 {
    sb.write_char(Int32::unsafe_to_char(s.at(i).to_int()))
  }
  sb.to_string()
}

///|
/// Two line excerpt around `offset` with a caret under the column (D09 9.7).
fn snippet(text : String, offset : Int32) -> String {
  let n = text.length()
  let off = if offset < 0 { 0 } else if offset > n { n } else { offset }
  let mut start = 0
  let mut i = 0
  while i < off {
    if text.at(i).to_int() == 0x0A {
      start = i + 1
    }
    i = i + 1
  }
  let mut end = off
  while end < n {
    if text.at(end).to_int() == 0x0A {
      break
    }
    end = end + 1
  }
  let sb = StringBuilder()
  sb.write_string("  ")
  sb.write_string(slice(text, start, end))
  sb.write_string("\n  ")
  let mut k = start
  while k < off {
    sb.write_char(' ')
    k = k + 1
  }
  sb.write_char('^')
  sb.to_string()
}

///|
/// Offset a fatal error points at, when it has one.
fn error_offset(e : @ij.InterJSONError) -> Int32? {
  match e {
    @ij.NoJsonFound(o) => Some(o)
    @ij.InvalidUtf8(o) => Some(o)
    @ij.StrictViolation(_, p, _) => Some(p.offset)
    @ij.AmbiguousRepair(_, p, _) => Some(p.offset)
    _ => None
  }
}

///|
/// Exit code of a fatal error (D09 9.8).
fn error_exit_code(e : @ij.InterJSONError) -> Int32 {
  match e {
    @ij.EmptyInput
    | @ij.NoJsonFound(_)
    | @ij.InvalidUtf8(_)
    | @ij.InvalidEvent(_) => 3
    @ij.DepthLimit(_, _) | @ij.SizeLimit(_, _) | @ij.TokenLimit(_, _) => 4
    @ij.StrictViolation(_, _, _) | @ij.AmbiguousRepair(_, _, _) => 5
    @ij.InvalidState(_) => 70
    @ij.InvalidOption(_) => 2
    // A skeleton that is not satisfied is a refusal of the execution channel,
    // so it shares exit code 5 with E010 and E011.
    @ij.SchemaError(_) => 5
  }
}

///|
/// One `R005 3:14 trailing comma removed` line per record, on stderr.
fn report(repairs : Array[@ij.Repair]) -> Unit {
  for r in repairs {
    eprintln(
      r.code.code() +
      " " +
      r.position.line.to_string() +
      ":" +
      r.position.column.to_string() +
      " " +
      r.message,
    )
  }
}

///|
/// Suffix `--explain` adds when a record admits a second reading (FR-27).
fn ambiguity_note(a : @ij.Ambiguity) -> String {
  if a is @ij.Unambiguous {
    ""
  } else {
    " [ambiguous: " + a.name() + "]"
  }
}

///|
/// `--explain`: one repair per block, with severity and a caret under the
/// input position, then the exactness summary (FR-17, FR-20).
fn explain(repairs : Array[@ij.Repair], text : String) -> Unit {
  for r in repairs {
    eprintln(
      r.code.code() +
      " " +
      (match r.severity {
        @ij.Info => "info"
        @ij.Warning => "warning"
      }) +
      " " +
      r.position.line.to_string() +
      ":" +
      r.position.column.to_string() +
      " " +
      r.message +
      ambiguity_note(r.ambiguity),
    )
    eprintln(snippet(text, r.position.offset))
  }
}

///|
/// The library options a parsed command line asks for.
///
/// `agent_protocol` is set by `explain` and by nothing else: the caller of
/// `explain` is an agent looking at a model's answer, so the answer may come
/// wrapped in a sentence and a code fence. Every other subcommand is a filter
/// over bytes the caller already has, and a filter does not get to ignore the
/// bytes in front of the value without being asked (`--skip-prose`).
fn options_of(o : CliOpts, agent_protocol? : Bool) -> @ij.Options {
  let base : @ij.Options = {
    ..@ij.Options::default(),
    mode: if o.strict {
      @ij.Strict
    } else {
      @ij.Lenient
    },
    indent: o.indent,
    multi_root: o.multi_root,
    skip_prose: o.skip_prose || agent_protocol.unwrap_or(false),
    quote_lookahead: o.quote_lookahead,
    max_repairs: o.max_repairs,
    max_prose_buffer: o.max_prose_buffer,
    max_input_len: o.max_input_len,
    max_depth: o.max_depth,
    max_token_len: o.max_token_len,
    max_loss: o.max_loss,
    reject_ambiguous: o.reject_ambiguous,
    // `--check` answers with the records and the exit code; rendering the
    // repaired text would copy the whole document for nothing.
    want_text: !o.check,
  }
  if o.policy == "" {
    base
  } else {
    match parse_policy_name(o.policy) {
      Some(p) => base.with_policy(p)
      None => base
    }
  }
}

///|
/// Distinguish the two `E002` refusals when `skip_prose` is on: "where the
/// prose ends is undecidable" versus "the prelude outgrew the replay buffer".
/// The first is a documented boundary, the second is a tunable limit, and
/// without this line the user cannot tell which one they hit.
fn prose_overflow_hint(
  parser : @ij.PartialParser,
  options : @ij.Options,
) -> Unit {
  if options.skip_prose && parser.prose_overflow() {
    eprintln(
      "interjson: hint: the skipped prelude exceeded max_prose_buffer (" +
      options.max_prose_buffer.to_string() +
      "); raise --max-prose-buffer or drop --skip-prose",
    )
  }
}

///|
/// The executable name without its directory, for the `interjson-mcp` alias.
/// A copy or symlink under that name starts the MCP server, which is how a
/// package manager (or a Docker entrypoint) can expose the gate directly.
fn program_name(argv : Array[String]) -> String {
  let path = if argv.length() > 0 { argv[0] } else { "" }
  let mut start = 0
  for i = 0; i < path.length(); i = i + 1 {
    let c = path.at(i).to_int()
    if c == 0x2F || c == 0x5C {
      start = i + 1
    }
  }
  let name = slice(path, start, path.length())
  if name.length() > 4 && name.has_suffix(".exe") {
    slice(name, 0, name.length() - 4)
  } else {
    name
  }
}

///|
/// Run the command.
fn run() -> Unit {
  let (o, usage_error) = parse_args(@env.args())
  if program_name(@env.args()) == "interjson-mcp" {
    match o.action {
      Run => o.action = Mcp
      Help => {
        o.action = Mcp
        o.mcp_help = true
      }
      _ => ()
    }
  }
  if usage_error != "" {
    eprintln("interjson: " + usage_error)
    eprintln(
      "用法：interjson [选项] [文件]；用 `interjson --help` 查看帮助。",
    )
    quit(2)
  }
  match o.action {
    Help => {
      println(help_text())
      quit(0)
    }
    Version => {
      // Keep in sync with `version` in moon.mod; cli_smoke.sh checks it.
      println("interjson 1.4.0")
      quit(0)
    }
    Llm => {
      run_llm(o)
      quit(0)
    }
    Readiness => {
      run_readiness(o)
      quit(0)
    }
    Explain => {
      run_explain(o)
      quit(0)
    }
    Serve => {
      run_serve(o)
      quit(0)
    }
    Mcp => {
      run_mcp(o)
      quit(0)
    }
    Run => ()
  }
  if o.batch {
    run_batch(options_of(o), o.chunk)
    quit(0)
  }
  let stream = open_input(o.path)
  if stream == 0L {
    let name = match o.path {
      Some(p) => p
      None => "<stdin>"
    }
    eprintln("interjson: 无法读取 " + name)
    return quit(3)
  }
  let options = options_of(o)
  // The input is streamed in fixed chunks, so the whole document is never
  // held in memory twice; the first `PREFIX_MAX` bytes are kept only to draw
  // the error snippet.
  let prefix_max = 1048576
  let prefix : Array[Byte] = []
  let chunk_cap = 65536
  try {
    let parser = @ij.PartialParser::new(options~)
    let mut piece = read_chunk(stream, chunk_cap)
    while piece.length() > 0 {
      if prefix.length() < prefix_max {
        for i = 0; i < piece.length(); i = i + 1 {
          prefix.push(piece[i])
        }
      }
      parser.feed_bytes(piece)
      piece = read_chunk(stream, chunk_cap)
    }
    close_input(stream)
    let fin = parser.finish() catch {
      e =>
        // `skip_prose` looks for the first `{` or `[`, because that is where a
        // chatty model puts the arguments. A document whose root is a scalar
        // — `true`, `42`, `"ok"`, which RFC 8259 allows — has no such
        // character, so the whole input is skipped as prose and a valid
        // document is refused. When the buffered prefix holds the whole input
        // and that input is valid JSON as written, the skip was wrong: parse it
        // again with the skip undone. The retry is gated on a strict parser
        // accepting the input, so prose is never read as a value; it is
        // skipped when the prefix is incomplete, which is the only case where
        // the buffered text is not the whole document.
        match e {
          @ij.NoJsonFound(_) =>
            if options.skip_prose && prefix.length() < prefix_max {
              let text = @utf8.decode_lossy(Bytes::from_array(prefix[:])[:])
              if @ij.is_valid_json(text) {
                let again : @ij.Options = { ..options, skip_prose: false, }
                let retry = @ij.PartialParser::new(options=again)
                retry.feed(text)
                retry.finish()
              } else {
                prose_overflow_hint(parser, options)
                raise e
              }
            } else {
              prose_overflow_hint(parser, options)
              raise e
            }
          _ => raise e
        }
    }
    // A skeleton on the default path is a gate, not a decoration: `--check`
    // and `repair` both refuse a value that does not satisfy it. `explain` and
    // `readiness` add the two readiness fractions on top of this check.
    if o.schema != "" {
      match schema_of(o) {
        Some(s) => {
          let verdict = s.evaluate(fin.value)
          if !verdict.ok {
            eprintln(
              "interjson: schema not satisfied (" +
              verdict.satisfied.to_string() +
              "/" +
              verdict.total.to_string() +
              ")",
            )
            for m in verdict.missing {
              eprintln("  missing " + m)
            }
            for m in verdict.mismatched {
              eprintln(
                "  mismatch " +
                m.path +
                " expected " +
                m.expected +
                " got " +
                m.got,
              )
            }
            quit(5)
          }
        }
        None => ()
      }
    }
    if o.explain {
      explain(fin.repairs, @utf8.decode_lossy(Bytes::from_array(prefix[:])[:]))
      eprintln("interjson: exactness " + fin.exactness.name())
    } else if o.report {
      report(fin.repairs)
      if fin.repairs_truncated {
        eprintln(
          "interjson: repair records truncated at " +
          fin.repairs.length().to_string() +
          " (raise max_repairs to record more)",
        )
      }
    }
    if o.check {
      if fin.repairs.length() > 0 {
        quit(1)
      }
    } else {
      println(fin.text)
    }
    quit(0)
  } catch {
    e => {
      eprintln("interjson: " + e.to_string())
      if o.retry_hint {
        let text = @utf8.decode_lossy(Bytes::from_array(prefix[:])[:])
        match e.retry_hint(input=text) {
          Some(h) => eprintln(h.to_prompt())
          None => ()
        }
      }
      match error_offset(e) {
        // Every offset carried by an error is absolute, measured from the start
        // of the input, and therefore independent of the chunking used here.
        Some(off) =>
          if off < prefix.length() {
            eprintln(
              snippet(@utf8.decode_lossy(Bytes::from_array(prefix[:])[:]), off),
            )
          }
        None => ()
      }
      quit(error_exit_code(e))
    }
  }
}

///|
/// Order two readiness points by position, then by name.
fn cmp_ready(a : @ij.FieldReady, b : @ij.FieldReady) -> Int32 {
  if a.permille < b.permille {
    -1
  } else if a.permille > b.permille {
    1
  } else {
    a.key.compare(b.key)
  }
}

///|
/// `interjson readiness`: the field readiness curve of one document (FR-29).
fn run_readiness(o : CliOpts) -> Unit {
  let stream = open_input(o.path)
  if stream == 0L {
    let name = match o.path {
      Some(p) => p
      None => "<stdin>"
    }
    eprintln("interjson: 无法读取 " + name)
    return quit(3)
  }
  let text = read_all(stream)
  close_input(stream)
  let fields = @ij.field_readiness(text, step=o.step) catch {
    e => {
      eprintln("interjson: " + e.to_string())
      return quit(error_exit_code(e))
    }
  }
  if fields.length() == 0 {
    println("interjson: readiness 0 fields (root is not an object)")
    return quit(0)
  }
  let curve = @ij.readiness_deciles([text], step=o.step) catch { _ => [] }
  let saving = @ij.early_stop_saving([text], step=o.step) catch { _ => 0 }
  let median = @ij.readiness_median([text], step=o.step) catch { _ => 0 }
  let sorted = fields.copy()
  sorted.sort_by(cmp_ready)
  let sb = StringBuilder()
  sb.write_string("interjson: readiness median ")
  sb.write_string(median.to_string())
  sb.write_string("/1000 fields ")
  sb.write_string(fields.length().to_string())
  sb.write_string(" early-stop-saving ")
  sb.write_string(saving.to_string())
  sb.write_string("/1000 curve")
  for c in curve {
    sb.write_string(" ")
    sb.write_string(c.to_string())
  }
  println(sb.to_string())
  for f in sorted {
    println("field " + f.key + " " + f.permille.to_string())
  }
  match schema_of(o) {
    Some(s) => print_readiness_lines(text, s, o.step, options_of(o))
    None => ()
  }
  quit(0)
}

///|
/// Entry point.
fn main {
  run()
}
