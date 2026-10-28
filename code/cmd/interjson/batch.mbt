// `interjson --batch` — a machine readable driver for evaluation harnesses.
//
// One JSON object per input line on standard input:
//
//   {"id": "m-0001", "input": "<text to repair>"}
//
// and one JSON object per result line on standard output:
//
//   {"id": "m-0001", "rc": 0, "exactness": "lossy",
//    "codes": ["R009", "R010"], "value": {...}, "text": "..."}
//
// `value` is the parsed value, or `null` when the run failed. This exists so
// that a harness can measure thousands of cases without paying one process per
// case; it is the only reason the command line knows about JSON input.

///|
/// Read all of standard input as text.
///
/// The stream is decoded once, not chunk by chunk. Decoding each 64 KiB piece
/// on its own looks equivalent and is not: a multi-byte character that
/// straddles a chunk boundary is a malformed sequence in *both* pieces, so a
/// lossy decode turns it into two U+FFFD replacement characters. For Chinese
/// text and emoji that is a silent wrong result — the command reports success
/// and the document it read is not the document that was written. Reading the
/// bytes first and decoding once removes the boundary entirely.
fn read_all(stream : Int64) -> String {
  // `stream` is a stdio `FILE *`, the same handle the single document path
  // reads from.
  let all : Array[Byte] = []
  let mut piece = read_chunk(stream, 65536)
  while piece.length() > 0 {
    for i = 0; i < piece.length(); i = i + 1 {
      all.push(piece[i])
    }
    piece = read_chunk(stream, 65536)
  }
  @utf8.decode_lossy(Bytes::from_array(all[:])[:])
}

///|
/// Feed `input` as one piece, or in `chunk` byte pieces. Byte boundaries are
/// honoured literally, so a chunk may split a UTF-8 sequence or a surrogate
/// pair; that is the point of the streaming check.
fn feed_in_chunks(
  p : @ij.PartialParser,
  input : String,
  chunk : Int32,
) -> Unit raise @ij.InterJSONError {
  let bs = @utf8.encode(input)
  let n = bs.length()
  if chunk <= 0 {
    p.feed_bytes(bs)
    return
  }
  let mut i = 0
  while i < n {
    let to = if i + chunk > n { n } else { i + chunk }
    p.feed_bytes(Bytes::makei(to - i, j => bs[i + j]))
    i = to
  }
}

///|
/// Outcome of one batch input, rendered as one JSON object.
fn batch_line(
  id : String,
  input : String,
  opts : @ij.Options,
  chunk : Int32,
) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"id\":")
  sb.write_string(Json::string(id).stringify())
  sb.write_string(",\"rc\":")
  let rc = try {
    let p = @ij.PartialParser::new(options=opts)
    feed_in_chunks(p, input, chunk)
    let r = p.finish()
    sb.write_string("0,\"exactness\":")
    sb.write_string(Json::string(r.exactness.name()).stringify())
    sb.write_string(",\"ambiguous\":")
    sb.write_string(if r.ambiguous { "true" } else { "false" })
    sb.write_string(",\"codes\":[")
    for i = 0; i < r.repairs.length(); i = i + 1 {
      if i > 0 {
        sb.write_string(",")
      }
      sb.write_string(Json::string(r.repairs[i].code.code()).stringify())
    }
    sb.write_string("],\"value\":")
    sb.write_string(r.value.stringify())
    sb.write_string(",\"text\":")
    sb.write_string(Json::string(r.text).stringify())
    0
  } catch {
    e => {
      sb.write_string(
        error_exit_code(e).to_string() +
        ",\"exactness\":\"none\",\"ambiguous\":false,\"codes\":[],\"value\":null,\"text\":\"\",\"error_code\":" +
        Json::string(e.code()).stringify(),
      )
      error_exit_code(e)
    }
  }
  ignore(rc)
  sb.write_string("}")
  sb.to_string()
}

///|
/// Run the batch driver over standard input.
fn run_batch(opts : @ij.Options, chunk : Int32) -> Unit {
  let stream = open_input(None)
  if stream == 0L {
    eprintln("interjson: 无法读取 <stdin>")
    return
  }
  let text = read_all(stream)
  close_input(stream)
  let mut n = 0
  for line in text.split("\n") {
    if line.length() == 0 {
      continue
    }
    let id = "line-" + n.to_string()
    n = n + 1
    let v = @json.parse(line) catch {
      _ => {
        println(
          "{\"id\":" +
          Json::string(id).stringify() +
          ",\"rc\":2,\"exactness\":\"none\",\"ambiguous\":false,\"codes\":[],\"value\":null,\"text\":\"\",\"error\":\"input line is not valid JSON\"}",
        )
        continue
      }
    }
    let real_id = match v {
      Json::Object(m) =>
        match m.get("id") {
          Some(Json::String(s)) => s
          _ => id
        }
      _ => id
    }
    let input = match v {
      Json::Object(m) =>
        match m.get("input") {
          Some(Json::String(s)) => s
          _ => ""
        }
      _ => ""
    }
    println(batch_line(real_id, input, opts, chunk))
  }
}
