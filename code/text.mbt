// M6 text — character classification, UTF-16 helpers and number normalisation.
//
// The engine works on UTF-16 code units, never on `Char`, so that surrogate
// pairs split across chunk boundaries behave exactly like unsplit ones.

///|
/// Code unit at `i`, as an `Int` for convenience.
fn cu(s : String, i : Int32) -> Int32 {
  s.at(i).to_int()
}

///|
/// Whitespace recognised by the engine. BOM counts as whitespace (D08 8.4).
fn is_ws(u : UInt16) -> Bool {
  let n = u.to_int()
  if n == 0x20 ||
    n == 0x09 ||
    n == 0x0A ||
    n == 0x0D ||
    n == 0xFEFF ||
    n == 0x00A0 {
    return true
  }
  if n >= 0x2000 && n <= 0x200A {
    return true
  }
  n == 0x1680 ||
  n == 0x2028 ||
  n == 0x2029 ||
  n == 0x202F ||
  n == 0x205F ||
  n == 0x3000
}

///|
/// ASCII decimal digit.
fn is_digit(u : UInt16) -> Bool {
  let n = u.to_int()
  n >= 0x30 && n <= 0x39
}

///|
/// Hexadecimal digit.
fn is_hex_digit(u : UInt16) -> Bool {
  let n = u.to_int()
  (n >= 0x30 && n <= 0x39) ||
  (n >= 0x41 && n <= 0x46) ||
  (n >= 0x61 && n <= 0x66)
}

///|
/// Value of a hexadecimal digit (input must satisfy `is_hex_digit`).
fn hex_value(u : UInt16) -> Int32 {
  let n = u.to_int()
  if n >= 0x30 && n <= 0x39 {
    n - 0x30
  } else if n >= 0x41 && n <= 0x46 {
    n - 0x41 + 10
  } else {
    n - 0x61 + 10
  }
}

///|
/// Characters that may appear inside a bare word (identifier, number or
/// literal). `@`, `#`, `*` and friends are deliberately excluded so that they
/// are dropped as unrecognised content (G-230).
fn is_ident_char(u : UInt16) -> Bool {
  let n = u.to_int()
  if n < 0x80 {
    return (n >= 0x30 && n <= 0x39) ||
      (n >= 0x41 && n <= 0x5A) ||
      (n >= 0x61 && n <= 0x7A) ||
      n == 0x5F ||
      n == 0x24 ||
      n == 0x2B ||
      n == 0x2D ||
      n == 0x2E
  }
  if n >= 0xD800 && n <= 0xDFFF {
    return false
  }
  if is_ws(u) {
    return false
  }
  match n {
    0x2018 | 0x2019 | 0x201C | 0x201D => false
    _ => true
  }
}

///|
/// Opening quote kinds accepted by BR-06.
priv enum StrKind {
  QuoteD
  QuoteS
  QuoteCurlyD
  QuoteCurlyS
}

///|
/// Whether a code unit opens a string.
fn is_quote_open(u : UInt16) -> Bool {
  let n = u.to_int()
  n == 0x22 || n == 0x27 || n == 0x201C || n == 0x2018
}

///|
/// Quote kind of an opening code unit.
fn str_kind_of(u : UInt16) -> StrKind {
  let n = u.to_int()
  if n == 0x22 {
    QuoteD
  } else if n == 0x27 {
    QuoteS
  } else if n == 0x201C {
    QuoteCurlyD
  } else {
    QuoteCurlyS
  }
}

///|
/// Whether `u` closes a string opened with `kind`.
fn closes_str(kind : StrKind, u : UInt16) -> Bool {
  let n = u.to_int()
  match kind {
    QuoteD => n == 0x22
    QuoteS => n == 0x27
    QuoteCurlyD => n == 0x201D || n == 0x22
    QuoteCurlyS => n == 0x2019 || n == 0x27
  }
}

///|
/// UTF-16 leading (high) surrogate.
fn is_high_surrogate(u : UInt16) -> Bool {
  let n = u.to_int()
  n >= 0xD800 && n <= 0xDBFF
}

///|
/// UTF-16 trailing (low) surrogate.
fn is_low_surrogate(u : UInt16) -> Bool {
  let n = u.to_int()
  n >= 0xDC00 && n <= 0xDFFF
}

///|
/// ASCII lowercase copy of `s` (used for case-insensitive literal matching).
fn ascii_lower(s : String) -> String {
  let sb = StringBuilder()
  for i = 0; i < s.length(); i = i + 1 {
    let n = s.at(i).to_int()
    if n >= 0x41 && n <= 0x5A {
      match (n + 32).to_char() {
        Some(c) => sb.write_char(c)
        None => ()
      }
    } else {
      match s.at(i).to_char() {
        Some(c) => sb.write_char(c)
        None => ()
      }
    }
  }
  sb.to_string()
}

///|
/// Whether the text is shaped like a number, i.e. uses only number characters
/// in a plausible arrangement. `2024-01-01` and `12abc` are *not* number
/// shaped, while `-`, `007`, `.5` and `1e` are (D08 8.7).
fn is_number_shaped(text : String) -> Bool {
  let n = text.length()
  if n == 0 {
    return false
  }
  let first = cu(text, 0)
  if !(first == 0x2B ||
    first == 0x2D ||
    first == 0x2E ||
    (first >= 0x30 && first <= 0x39)) {
    return false
  }
  let mut i = 0
  if cu(text, i) == 0x2B || cu(text, i) == 0x2D {
    i = i + 1
  }
  while i < n && is_digit(text.at(i)) {
    i = i + 1
  }
  if i < n && cu(text, i) == 0x2E {
    i = i + 1
    while i < n && is_digit(text.at(i)) {
      i = i + 1
    }
  }
  if i < n && (cu(text, i) == 0x65 || cu(text, i) == 0x45) {
    i = i + 1
    if i < n && (cu(text, i) == 0x2B || cu(text, i) == 0x2D) {
      i = i + 1
    }
    while i < n && is_digit(text.at(i)) {
      i = i + 1
    }
  }
  i == n
}

///|
/// Normalise a number lexeme per BR-11: drop a leading `+`, drop leading
/// zeros, pad `.5` to `0.5`, drop a bare trailing dot, drop an incomplete
/// exponent. Returns `None` when the text carries no valid numeric prefix at
/// all (for example `-` or `.`).
///
/// The effective digits are never changed, so large integers keep their exact
/// source text (ADR-004).
fn normalize_number(text : String) -> String? {
  let n = text.length()
  if n == 0 {
    return None
  }
  let sb = StringBuilder()
  let mut i = 0
  let mut neg = false
  if cu(text, i) == 0x2B {
    i = i + 1
  } else if cu(text, i) == 0x2D {
    neg = true
    i = i + 1
  }
  let int_start = i
  while i < n && is_digit(text.at(i)) {
    i = i + 1
  }
  let int_end = i
  let int_len = int_end - int_start
  let mut j = int_start
  while j < int_end - 1 && cu(text, j) == 0x30 {
    j = j + 1
  }
  let mut has_frac = false
  let mut frac_start = 0
  let mut frac_end = 0
  if i < n && cu(text, i) == 0x2E {
    let fs = i + 1
    let mut k = fs
    while k < n && is_digit(text.at(k)) {
      k = k + 1
    }
    if k > fs {
      has_frac = true
      frac_start = fs
      frac_end = k
      i = k
    } else {
      i = i + 1
    }
  }
  let mut has_exp = false
  let mut exp_start = 0
  let mut exp_end = 0
  if i < n && (cu(text, i) == 0x65 || cu(text, i) == 0x45) {
    let es = i
    let mut k = i + 1
    if k < n && (cu(text, k) == 0x2B || cu(text, k) == 0x2D) {
      k = k + 1
    }
    let ds = k
    while k < n && is_digit(text.at(k)) {
      k = k + 1
    }
    if k > ds {
      has_exp = true
      exp_start = es
      exp_end = k
      i = k
    } else {
      i = k
    }
  }
  if i < n {
    return None
  }
  if int_len == 0 && !has_frac {
    return None
  }
  if neg {
    sb.write_char('-')
  }
  if int_len == 0 {
    sb.write_char('0')
  } else {
    sb.write_substring(text, j, int_end - j)
  }
  if has_frac {
    sb.write_char('.')
    sb.write_substring(text, frac_start, frac_end - frac_start)
  }
  if has_exp {
    sb.write_substring(text, exp_start, exp_end - exp_start)
  }
  Some(sb.to_string())
}
