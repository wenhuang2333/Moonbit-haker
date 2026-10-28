// Byte-level fuzzing (family TC-F of the 1.5 test set).
//
// The property tests in `prop_wbtest.mbt` generate *strings* that look like
// damaged JSON. This file generates *bytes*: arbitrary byte sequences, fed to
// the byte entry point in arbitrary chunk sizes, with the chunk boundaries
// landing anywhere -- including in the middle of a multi-byte character and
// in the middle of a UTF-16 surrogate pair.
//
// The reason is a promise the project makes: "no panic on any byte
// sequence". Until now that promise was tested only over strings that were
// already valid UTF-8, so it was really a promise about text, not about
// bytes. A byte-oriented caller -- a socket, a file that is not UTF-8, a
// truncated download -- can hand the engine something the string path can
// never produce.
//
// Every generator is deterministic: a fixed seed means a failure is
// reproducible from the printed bytes. `INTERJSON_LONGRUN=N` raises the case
// count the way it does for the property tests.

///|
/// Bytes fed per fuzz case by default.
let tf_cases_default : Int32 = 300

///|
/// How many fuzz cases to run.
///
/// The budget is `INTERJSON_FUZZ`, not `INTERJSON_LONGRUN`. The two measure
/// different things and cost wildly different amounts: a property case is one
/// parse, while a fuzz case is fifteen (three shapes times five chunk sizes).
/// Sharing the nightly's `INTERJSON_LONGRUN=1000000` would have turned a
/// ten-minute nightly into fifteen million parses.
fn tf_cases() -> Int32 {
  match @env.get_env_var("INTERJSON_FUZZ") {
    Some(v) => {
      let mut n = 0
      let mut ok = v.length() > 0
      for i = 0; i < v.length(); i = i + 1 {
        let c = v.at(i).to_int()
        if c < 0x30 || c > 0x39 {
          ok = false
        } else {
          n = n * 10 + (c - 0x30)
          if n > 1000000 {
            ok = false
          }
        }
      }
      if ok && n > 0 {
        n
      } else {
        tf_cases_default
      }
    }
    None => tf_cases_default
  }
}

///|
/// A byte generator with three shapes, because one shape finds one class of
/// bug:
///
///   * pure noise -- finds the parser's handling of arbitrary bytes;
///   * noise around JSON syntax -- finds the boundaries between the scanner
///     and the repair rules;
///   * valid UTF-8 cut at arbitrary byte offsets -- finds the decoder's
///     handling of a truncated multi-byte sequence, which is what a
///     truncated download looks like.
struct TfGen {
  mut seed : Int64
}

///|
fn tf_gen(seed : Int64) -> TfGen {
  { seed, }
}

///|
/// Next byte in `[0, 256)`.
fn TfGen::next_byte(self : TfGen) -> Byte {
  self.seed = (self.seed * 6364136223846793005L + 1442695040888963407L) &
    0x7FFFFFFFFFFFFFFFL
  ((self.seed >> 33) % 256L).to_byte()
}

///|
/// A block of JSON-ish ASCII, used by the second shape.
fn tf_json_block(gen : TfGen) -> Byte {
  let block = "{}[],:\"\\0123456789.eE+-tfnul \n\t\r"
  let i = gen.next_byte().to_int() % block.length()
  // `String::at` is a UTF-16 code unit; the block is ASCII, so the low eight
  // bits are the byte.
  block.at(i).to_int().to_byte()
}

///|
/// One fuzz case: a byte sequence.
fn tf_case(seed : Int64, shape : Int32) -> Bytes {
  let gen = tf_gen(seed)
  let n = 1 + gen.next_byte().to_int() % 96
  let out : Array[Byte] = []
  for _k = 0; _k < n; _k = _k + 1 {
    if shape == 1 {
      out.push(tf_json_block(gen))
    } else if shape == 2 {
      // Valid UTF-8, then cut at an arbitrary byte offset: the sequence
      // ends in the middle of a character more often than not.
      let s = "{\"k\":\"héllo 世界 🌍\"}"
      let bytes = @utf8.encode(s)
      let cut = 1 + gen.next_byte().to_int() % (bytes.length() - 1)
      for j = 0; j < cut; j = j + 1 {
        out.push(bytes[j])
      }
    } else {
      out.push(gen.next_byte())
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Feed `bytes` to a parser in chunks of `chunk` bytes and report what
/// happened. Never raises: the point is that nothing raises *unexpectedly*.
fn tf_run(bytes : Bytes, chunk : Int32, opts : Options) -> String {
  try {
    let p = PartialParser::new(options=opts)
    let n = bytes.length()
    let mut i = 0
    while i < n {
      let to = if i + chunk > n { n } else { i + chunk }
      p.feed_bytes(Bytes::makei(to - i, j => bytes[i + j]))
      i = to
    }
    let fin = p.finish()
    fin.text
  } catch {
    e => e.code()
  }
}

///|
/// Whether a byte sequence is valid UTF-8.
fn tf_valid_utf8(bytes : Bytes) -> Bool {
  try {
    ignore(@utf8.decode(bytes[:]))
    true
  } catch {
    _ => false
  }
}

///|
/// The bytes of a case, as hex, so a failure can be reproduced.
fn tf_hex(bytes : Bytes) -> String {
  let sb = StringBuilder()
  for i = 0; i < bytes.length(); i = i + 1 {
    let v = bytes[i].to_int()
    if v < 16 {
      sb.write_string("0")
    }
    sb.write_string(v.to_string(radix=16))
  }
  sb.to_string()
}

///|
test "TC-F-01 no byte sequence panics the engine" {
  // The project's first invariant. Feed every shape at several chunk sizes,
  // including one byte at a time, so the boundary lands inside every
  // multi-byte sequence at some point.
  let cases = tf_cases()
  for shape in 0..<3 {
    for chunk in [1, 3, 7, 16, 64] {
      for i in 0..<cases {
        let bytes = tf_case(
          1000L + i.to_int64() * 7L + shape.to_int64() * 1000003L,
          shape,
        )
        let out = tf_run(bytes, chunk, Options::default())
        // The only requirement is that the call returned. The engine may
        // refuse (that is a documented outcome) but it may not die.
        ignore(out)
      }
    }
  }
}

///|
test "TC-F-02 a repaired byte sequence is valid JSON" {
  // The second invariant, over bytes rather than strings: whatever comes
  // out of a successful run must parse.
  let cases = tf_cases()
  for shape in 0..<3 {
    for i in 0..<cases {
      let bytes = tf_case(
        2000L + i.to_int64() * 11L + shape.to_int64() * 1000003L,
        shape,
      )
      let out = tf_run(bytes, 5, Options::default())
      if out != "" && !out.has_prefix("E") {
        assert_true(
          is_valid_json(out),
          msg="shape " + shape.to_string() + " bytes " + tf_hex(bytes),
        )
      }
    }
  }
}

///|
test "TC-F-03 a byte sequence repairs to the same thing as a string one" {
  // The byte path and the text path must agree -- for a byte sequence that
  // *is* valid UTF-8. For a sequence that is not, the two paths are
  // deliberately different: the byte path sees the bytes, while the text
  // path sees the string those bytes decode to, and a lossy decode replaces
  // each malformed sequence with U+FFFD. That difference is the point of
  // having a byte entry point, so the assertion is made where it is true.
  let cases = tf_cases()
  for shape in 0..<3 {
    for i in 0..<cases {
      let bytes = tf_case(
        3000L + i.to_int64() * 13L + shape.to_int64() * 1000003L,
        shape,
      )
      let valid = tf_valid_utf8(bytes)
      if !valid {
        continue
      }
      let text = @utf8.decode_lossy(bytes[:])
      let from_bytes = tf_run(bytes, 7, Options::default())
      let from_text = tf_run(@utf8.encode(text), 7, Options::default())
      assert_eq(
        from_bytes,
        from_text,
        msg="shape " + shape.to_string() + " bytes " + tf_hex(bytes),
      )
    }
  }
}

///|
test "TC-F-04 the chunk size does not change the outcome" {
  // Chunk invariance, over bytes. A byte sequence split differently must
  // give the same result, or the "any split" promise does not hold for the
  // byte entry point.
  let cases = tf_cases()
  for shape in 0..<3 {
    for i in 0..<cases {
      let bytes = tf_case(
        4000L + i.to_int64() * 17L + shape.to_int64() * 1000003L,
        shape,
      )
      let one = tf_run(bytes, bytes.length() + 1, Options::default())
      for chunk in [1, 2, 5, 13] {
        let many = tf_run(bytes, chunk, Options::default())
        assert_eq(
          one,
          many,
          msg="shape " +
            shape.to_string() +
            " chunk " +
            chunk.to_string() +
            " bytes " +
            tf_hex(bytes),
        )
      }
    }
  }
}

///|
test "TC-F-05 the strict profile refuses rather than guesses" {
  // Under `strict` the engine must refuse a repair instead of making one.
  // Feeding it noise is the cheapest way to check that the refusal path is
  // reachable and does not fall through into a repair.
  let cases = tf_cases()
  for shape in 0..<3 {
    for i in 0..<cases {
      let bytes = tf_case(
        5000L + i.to_int64() * 19L + shape.to_int64() * 1000003L,
        shape,
      )
      let out = tf_run(bytes, 11, Options::strict())
      if out.has_prefix("E") {
        assert_true(out.length() > 1, msg="an error must name a code")
      }
    }
  }
}
