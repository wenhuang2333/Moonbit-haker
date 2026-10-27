// An end-to-end `agent_gate` example: what an application does when the model
// emits arguments that could be read two ways.
//
// The loop is the whole point of the execution gate:
//
//   1. the model streams a tool call whose argument list is missing a comma;
//   2. the application parses it with `Options::for_execution()`, which refuses
//      the repair with `E011` instead of silently picking one reading;
//   3. the refusal becomes a prompt (`RetryHint::to_prompt()`);
//   4. the model re-emits, and the second answer passes the gate;
//   5. only then does the application execute anything.
//
// Step 4 is a literal string here because this example has no network access;
// everything else is the real library. Run it with:
//
//   moon run examples/agent_gate --target native --release

///|
/// The gate decision for one model answer.
enum Decision {
  Execute(String)
  Retry(String)
}

///|
/// Why the gate refused, in one line, for the transcript.
fn reason(hint : @interjson.RetryHint) -> String {
  if hint.error_code == "E011" {
    "E011 " + hint.ambiguity.name() + " - the gate cannot pick a reading"
  } else {
    hint.error_code + " " + hint.reason
  }
}

///|
/// Parse a model answer as tool arguments under the execution profile.
fn decide(answer : String) -> Decision {
  try {
    let result = @interjson.repair(
      answer,
      options=@interjson.Options::for_execution(),
    )
    Execute(result.text)
  } catch {
    // `for_execution()` refuses an ambiguous repair before it refuses a lossy
    // one, so a refusal here is either `E011` (two readings) or `E010` (the
    // value changed). Both are worth sending back to the model.
    e => {
      let prompt = match e.retry_hint() {
        Some(h) => {
          println("gate    : " + reason(h))
          h.to_prompt()
        }
        None => "the input could not be repaired: " + e.to_string()
      }
      Retry(prompt)
    }
  }
}

///|
fn show(label : String, answer : String) -> Unit {
  println("== " + label)
  println("model   : " + answer)
  match decide(answer) {
    Execute(text) => println("execute : " + text)
    Retry(prompt) => {
      println("refused : the gate refused to pick a reading")
      println("prompt  :")
      for line in prompt.split("\n") {
        println("  " + line.to_owned())
      }
    }
  }
  println("")
}

///|
fn main {
  // 1. Two strings with no comma: `["Paris" "London"]` is either one string
  //    with a space or two elements. The gate refuses to guess.
  show("first attempt", "{\"city\":[\"Paris\" \"London\"]}")

  // 2. The model re-emits with the comma restored: the same value is now the
  //    only reading, so the application may execute it.
  show("re-emitted", "{\"city\":[\"Paris\",\"London\"]}")

  // 3. A different ambiguity: a truncation that would invent content.
  show("truncated", "{\"city\":\"Par")

  // 4. Concatenation: `"a" + "b"` is one string or two elements.
  show("concatenated", "{\"city\":\"Par\" + \"is\"}")

  // 5. The same document read leniently still repairs: the gate is opt-in, and
  //    a caller that only displays the text keeps the old behaviour.
  println("== lenient (no gate)")
  try {
    let lenient = @interjson.repair("{\"city\":[\"Paris\" \"London\"]}")
    println("execute  : " + lenient.text)
    println("ambiguous: " + lenient.ambiguous.to_string())
    println("exactness: " + lenient.exactness.name())
  } catch {
    e => println("error    : " + e.to_string())
  }
}
