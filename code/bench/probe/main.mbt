///|
/// Minimal wasm-gc consumer of the library: used to measure the size of a
/// real artifact (TC-B-05) instead of an empty package's baseline. It calls
/// one entry point of every public family so the linker keeps the whole
/// engine reachable.
fn main {
  try {
    let r = @interjson.repair("{'a':1,}")
    println(r.text)
    let p = @interjson.PartialParser::new()
    p.feed("{\"b\":[1,2")
    println(p.snapshot().value.unwrap().stringify())
    let fin = Some(p.finish()) catch { _ => None }
    match fin {
      Some(r) => println(r.text)
      None => println("error")
    }
    println(@interjson.is_valid_json("{}").to_string())
  } catch {
    _ => println("error")
  }
}
