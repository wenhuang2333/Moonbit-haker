// The self-healing loop: a model emits tool arguments, the gate refuses, the
// refusal is handed back as a prompt, and the loop tries again.
//
//   LLM ─▶ JSONMend ─▶ Reject ─▶ Hint ─▶ LLM ─▶ JSONMend ─▶ Execute
//
// The loop is the product: `analyze` never raises, so the same call site
// decides whether to execute or to retry, and the retry text comes from the
// library rather than from the integration. Everything except the model is
// real; `Script` stands in for the network because this example has none, and
// the script is exactly the sequence of answers the transcript shows.
//
//   moon run examples/agent_loop --target native --release

///|
/// The tool the model is asked to call: a name and the arguments it must
/// provide. The skeleton is what makes "ready" mean something before the JSON
/// is closed (FR-34).
struct Tool {
  name : String
  schema : @mend.Schema
}

///|
/// What the model answers, one entry per attempt. A real integration reads this
/// from a provider stream; the loop below does not care which.
struct Script {
  attempts : Array[String]
}

///|
/// Where the loop stopped.
enum Outcome {
  /// Executed after this many attempts.
  Executed(Int32)
  GaveUp(Int32)
}

///|
/// Run one self-healing episode: at most `max_attempts` model answers, each
/// analysed under the agent policy against the tool's skeleton.
fn heal(tool : Tool, script : Script, max_attempts : Int32) -> Outcome {
  println("tool    : " + tool.name + " " + tool.schema.stringify())
  for i = 0; i < script.attempts.length(); i = i + 1 {
    if i >= max_attempts {
      break
    }
    let answer = script.attempts[i]
    println("")
    println("attempt : #" + (i + 1).to_string())
    println("model   : " + answer)
    // The one call an integration makes. No `try`: a refusal is a plan.
    let plan = @mend.analyze(
      answer,
      options=@mend.Options::for_agent(),
      schema=tool.schema,
    )
    println("gate    : " + plan.summary())
    if plan.is_executable() {
      if plan.value is Some(_) {
        println("execute : " + plan.text)
        return Executed(i + 1)
      }
    }
    println("refused : " + plan.decision.label())
    println("retry   :")
    for line in plan.prompt().split("\n") {
      println("  " + line.to_owned())
    }
  }
  println("")
  println(
    "give up : the model did not produce executable arguments in " +
    max_attempts.to_string() +
    " attempts",
  )
  GaveUp(max_attempts)
}

///|
/// One episode, with a heading.
fn episode(
  title : String,
  tool : Tool,
  script : Script,
  max_attempts : Int32,
) -> Unit {
  println("================================================================")
  println("== " + title)
  println("================================================================")
  match heal(tool, script, max_attempts) {
    Executed(n) =>
      println("\nresult  : executed after " + n.to_string() + " attempt(s)")
    GaveUp(n) =>
      println(
        "\nresult  : no value executed after " + n.to_string() + " attempt(s)",
      )
  }
  println("")
}

///|
fn main {
  let schema_of = fn(text : String) -> @mend.Schema {
    @mend.Schema::parse(text) catch {
      _ => @mend.Schema::Any
    }
  }
  let search : Tool = {
    name: "search",
    schema: schema_of("{!query:string,!limit:integer}"),
  }
  let spell : Tool = {
    name: "spell_check",
    schema: schema_of("{!words:[string]}"),
  }
  // 1. Two strings with no comma inside an array: the gate refuses rather than
  //    guessing whether the model meant two elements or one concatenated
  //    string. Note what is *not* refused: `{"query":"a" "limit":10}` has only
  //    one reading, because `"limit"` is followed by `:` and can only be a key.
  //    The gate refuses exactly the sites that admit two readings, no more.
  episode(
    "adjacent strings (E011)",
    spell,
    {
      attempts: [
        "{\"words\":[\"colour\" \"color\"]}", "{\"words\":[\"colour\",\"color\"]}",
      ],
    },
    3,
  )

  // 2. A truncated argument: the repair would invent the rest of the number.
  episode(
    "truncated value (E010)",
    search,
    {
      attempts: [
        "{\"query\":\"MoonBit\",\"limit\":", "{\"query\":\"MoonBit\",\"limit\":10}",
      ],
    },
    3,
  )

  // 3. Valid JSON, wrong type for a declared member: the skeleton, not the
  //    parser, is what refuses here.
  episode(
    "schema mismatch (E070)",
    search,
    {
      attempts: [
        "{\"query\":42,\"limit\":10}", "{\"query\":\"MoonBit\",\"limit\":10}",
      ],
    },
    3,
  )

  // 4. A model that never learns: the loop must stop on a budget rather than
  //    wait forever.
  episode(
    "no improvement",
    search,
    { attempts: ["{\"query\":\"Moon", "{\"query\":\"Moon"], },
    2,
  )
}
