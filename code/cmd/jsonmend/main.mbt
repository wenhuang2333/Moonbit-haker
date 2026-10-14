// jsonmend — repair and partial-parse JSON from the command line.
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
fn error_offset(e : @mend.MendError) -> Int32? {
  match e {
    @mend.NoJsonFound(o) => Some(o)
    @mend.InvalidUtf8(o) => Some(o)
    @mend.StrictViolation(_, p, _) => Some(p.offset)
    _ => None
  }
}

///|
/// Exit code of a fatal error (D09 9.8).
fn error_exit_code(e : @mend.MendError) -> Int32 {
  match e {
    @mend.EmptyInput | @mend.NoJsonFound(_) | @mend.InvalidUtf8(_) => 3
    @mend.DepthLimit(_, _) | @mend.SizeLimit(_, _) | @mend.TokenLimit(_, _) => 4
    @mend.StrictViolation(_, _, _) => 5
    @mend.InvalidState(_) => 70
    @mend.InvalidOption(_) => 2
  }
}

///|
/// One `R005 3:14 trailing comma removed` line per record, on stderr.
fn report(repairs : Array[@mend.Repair]) -> Unit {
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
/// Run the command.
fn run() -> Unit {
  let (o, usage_error) = parse_args(@env.args())
  if usage_error != "" {
    eprintln("jsonmend: " + usage_error)
    eprintln(
      "用法：jsonmend [选项] [文件]；用 `jsonmend --help` 查看帮助。",
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
      println("jsonmend 0.2.0")
      quit(0)
    }
    Run => ()
  }
  let stream = open_input(o.path)
  if stream == 0L {
    let name = match o.path {
      Some(p) => p
      None => "<stdin>"
    }
    eprintln("jsonmend: 无法读取 " + name)
    return quit(3)
  }
  let options : @mend.Options = {
    ..@mend.Options::default(),
    mode: if o.strict {
      @mend.Strict
    } else {
      @mend.Lenient
    },
    indent: o.indent,
    multi_root: o.multi_root,
    skip_prose: o.skip_prose,
    quote_lookahead: o.quote_lookahead,
    max_repairs: o.max_repairs,
  }
  // The input is streamed in fixed chunks, so the whole document is never
  // held in memory twice; the first `PREFIX_MAX` bytes are kept only to draw
  // the error snippet.
  let prefix_max = 1048576
  let prefix : Array[Byte] = []
  let chunk_cap = 65536
  let mut chunk_start : Int32 = 0
  try {
    let parser = @mend.PartialParser::new(options~)
    let mut piece = read_chunk(stream, chunk_cap)
    while piece.length() > 0 {
      if prefix.length() < prefix_max {
        for i = 0; i < piece.length(); i = i + 1 {
          prefix.push(piece[i])
        }
      }
      parser.feed_bytes(piece)
      chunk_start = chunk_start + piece.length()
      piece = read_chunk(stream, chunk_cap)
    }
    close_input(stream)
    let fin = parser.finish()
    if o.report {
      report(fin.repairs)
      if fin.repairs_truncated {
        eprintln(
          "jsonmend: repair records truncated at " +
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
      eprintln("jsonmend: " + e.to_string())
      match error_offset(e) {
        Some(off) =>
          // E040 offsets are relative to the chunk that failed (docs/ERRORS.md)
          match e {
            @mend.InvalidUtf8(within) =>
              if within < chunk_cap {
                eprintln(
                  snippet(
                    @utf8.decode_lossy(Bytes::from_array(prefix[:])[:]),
                    chunk_start + within,
                  ),
                )
              }
            _ =>
              if off < prefix.length() {
                eprintln(
                  snippet(
                    @utf8.decode_lossy(Bytes::from_array(prefix[:])[:]),
                    off,
                  ),
                )
              }
          }
        None => ()
      }
      quit(error_exit_code(e))
    }
  }
}

///|
/// Entry point.
fn main {
  run()
}
