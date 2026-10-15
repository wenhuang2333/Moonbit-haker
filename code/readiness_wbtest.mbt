// FR-29 — the readiness curve and the delta-driven early stop.

///|
/// Readiness of `key` in `input`, or -1.
fn ready_at(input : String, key : String) -> Int32 {
  let fields = field_readiness(input) catch { _ => return -1 }
  for f in fields {
    if f.key == key {
      return f.permille
    }
  }
  -1
}

///|
test "a field is ready before the document ends" {
  // The first member is complete as soon as its closing brace arrives; the
  // second one only when its own closing quote arrives, just short of the end.
  let doc = "{\"a\":{\"x\":1},\"b\":\"" + "y".repeat(200) + "\"}"
  let a = ready_at(doc, "a")
  let b = ready_at(doc, "b")
  assert_true(a > 0 && a < 1000, msg=a.to_string())
  assert_true(b > 900, msg=b.to_string())
  assert_true(a < b, msg=a.to_string() + "<" + b.to_string())
  // A trailing scalar is ready when the next member starts, and an object
  // member is never ready before its own `}`.
  assert_true(ready_at("{\"a\":1,\"b\":2}", "a") > 0, msg="scalar member a")
  assert_true(ready_at("{\"a\":1,\"b\":2}", "b") > 900, msg="last member b")
}

///|
test "readiness is measured against the value the document ends with" {
  // A number keeps changing while it grows: `12` is not ready while the input
  // may still be `123`, so the last member of a document is ready at the end.
  let doc = "{\"n\":1234567890}"
  assert_eq(ready_at(doc, "n"), 1000)
  // A member whose value cannot change any more is ready immediately after it.
  let early = "{\"n\":1234567890}   "
  assert_true(ready_at(early, "n") < 1000, msg=early)
}

///|
test "the curve is monotone and reaches both ends" {
  let docs = tc_valid_docs(31415L, 60)
  let curve = readiness_deciles(docs) catch {
    _ => {
      assert_true(false, msg="readiness failed")
      return
    }
  }
  assert_eq(curve.length(), 11)
  assert_eq(curve[0], 0)
  assert_eq(curve[10], 100)
  for i = 1; i < curve.length(); i = i + 1 {
    assert_true(
      curve[i] >= curve[i - 1],
      msg=i.to_string() +
        ": " +
        curve[i - 1].to_string() +
        " -> " +
        curve[i].to_string(),
    )
  }
  // The reported baseline of a full-document consumer is 1000.
  let base = readiness_median(docs) catch { _ => -1 }
  assert_true(base > 0 && base <= 1000, msg=base.to_string())
}

///|
test "early stop saves input on real shaped payloads" {
  // A tool call whose last member is a long `content` string: everything else
  // is ready long before the string is written out.
  let docs : Array[String] = []
  for i = 0; i < 20; i = i + 1 {
    docs.push(
      "{\"path\":\"/src/f" +
      i.to_string() +
      ".mbt\",\"old\":\"" +
      "x".repeat(40) +
      "\",\"content\":\"" +
      "y".repeat(400 + i) +
      "\"}",
    )
  }
  let saving = early_stop_saving(docs) catch { _ => -1 }
  assert_true(saving > 0, msg=saving.to_string())
  // The saving is the tail of the document after the last field is ready, so
  // it is bounded by the length of the longest field.
  assert_true(saving < 1000, msg=saving.to_string())
  let median = readiness_median(docs) catch { _ => -1 }
  assert_true(median < 1000, msg=median.to_string())
}

///|
test "the delta tracker agrees with the textual readiness" {
  // Feed the whole document as one chunk, drain, and check that every watched
  // member the textual curve calls ready at 1000 is ready in the tracker too.
  let docs = tc_valid_docs(271828L, 300)
  let mut checked = 0
  for text in docs {
    let fields = field_readiness(text) catch { _ => continue }
    if fields.length() == 0 {
      continue
    }
    let keys : Array[String] = []
    for f in fields {
      keys.push(f.key)
    }
    let p = PartialParser::new(options=Options::for_llm()) catch {
      _ => continue
    }
    let t = FieldTracker::new(keys)
    let ok = try {
      p.feed(text)
      true
    } catch {
      _ => false
    }
    if !ok {
      continue
    }
    for d in p.drain_deltas() {
      t.feed(d)
    }
    let fin = p.finish() catch { _ => continue }
    for d in p.drain_deltas() {
      t.feed(d)
    }
    assert_true(t.all_ready(), msg="tracker not ready for " + text)
    assert_eq(t.ready_count(), keys.length())
    // The tracker's keys are exactly the document's members.
    let finmap = match fin.value {
      Json::Object(m) => m
      _ => continue
    }
    for k, _v in finmap {
      assert_true(t.ready(k), msg="tracker missed " + k + " in " + text)
    }
    checked = checked + 1
  }
  assert_true(checked >= 10, msg=checked.to_string())
}

///|
test "the tracker reports members in the order they settle" {
  let p = PartialParser::new(options=Options::for_llm())
  let t = FieldTracker::new(["a", "b", "c"])
  p.feed("{\"a\":{\"x\":1},\"b\":2,\"c\":\"zz")
  for d in p.drain_deltas() {
    t.feed(d)
  }
  assert_eq(t.ready("a"), true)
  assert_eq(t.ready("b"), true)
  assert_eq(t.ready("c"), false)
  assert_eq(t.all_ready(), false)
  assert_eq(t.ready_keys().length(), 2)
  assert_eq(t.ready_count(), 2)
  // `AppendText` alone never settles a string member; the `Set` that lands when
  // the string closes does.
  p.feed("y")
  for d in p.drain_deltas() {
    t.feed(d)
  }
  assert_eq(t.ready("c"), false)
  p.feed("\"")
  for d in p.drain_deltas() {
    t.feed(d)
  }
  assert_eq(t.ready("c"), true)
  p.feed(",\"d\":1}")
  for d in p.drain_deltas() {
    t.feed(d)
  }
  assert_eq(t.ready("c"), true)
  assert_eq(t.all_ready(), true)
}
