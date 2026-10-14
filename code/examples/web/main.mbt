// Browser demo entry points: plain String in, plain String out, so the
// generated JavaScript can be called from `static/demo/index.html`.

///|
/// Repair `input` and return the repaired text, or `ERROR: …` on a fatal error.
pub fn repair_text(input : String) -> String {
  @mend.repair(input).text catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// Repair `input` and return the repair records, one `R005 3:14 message` per
/// line, or `-` when nothing had to be repaired.
pub fn report_text(input : String) -> String {
  try {
    let repairs = @mend.repair(input).repairs
    if repairs.length() == 0 {
      return "-"
    }
    let sb = StringBuilder()
    for i = 0; i < repairs.length(); i = i + 1 {
      let r = repairs[i]
      if i > 0 {
        sb.write_char('\n')
      }
      sb.write_string(r.code.code())
      sb.write_char(' ')
      sb.write_string(r.position.line.to_string())
      sb.write_char(':')
      sb.write_string(r.position.column.to_string())
      sb.write_char(' ')
      sb.write_string(r.message)
    }
    sb.to_string()
  } catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
/// Feed the first `upto` code units of `input` and return the partial snapshot
/// as `value | completeness | open path`.
pub fn snapshot_text(input : String, upto : Int32) -> String {
  try {
    let n = if upto < 0 {
      0
    } else if upto > input.length() {
      input.length()
    } else {
      upto
    }
    let parser = @mend.PartialParser::new()
    parser.feed(input[:n].to_owned())
    let snap = parser.snapshot()
    let value = match snap.value {
      Some(v) => v.stringify()
      None => "-"
    }
    let state = match snap.completeness {
      Empty => "Empty"
      Partial => "Partial"
      Complete => "Complete"
    }
    let sb = StringBuilder()
    sb.write_string(value)
    sb.write_string(" | ")
    sb.write_string(state)
    sb.write_string(" | ")
    for i = 0; i < snap.open_path.length(); i = i + 1 {
      if i > 0 {
        sb.write_char('/')
      }
      match snap.open_path[i] {
        Key(k) => sb.write_string(k)
        Index(x) => sb.write_string(x.to_string())
      }
    }
    sb.to_string()
  } catch {
    e => "ERROR: " + e.to_string()
  }
}

///|
extern "js" fn js_register1(name : String, f : (String) -> String) -> Unit = "globalThis.jsonmendRegister1"

///|
extern "js" fn js_register2(
  name : String,
  f : (String, Int32) -> String,
) -> Unit = "globalThis.jsonmendRegister2"

///|
/// Hand the demo entry points to the host page and print a banner.
fn main {
  js_register1("repair", repair_text)
  js_register1("report", report_text)
  js_register2("snapshot", snapshot_text)
  println("jsonmend demo bundle ready")
}
