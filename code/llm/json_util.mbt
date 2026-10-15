// Small JSON readers used by the event adapters. The event envelope is a
// complete JSON document, so it is parsed with the strict core parser; only the
// field access needs helpers.

///|
/// Object value of `v`, if it is an object.
pub fn as_object(v : Json) -> Map[String, Json]? {
  match v {
    Json::Object(m) => Some(m)
    _ => None
  }
}

///|
/// Array value of `v`, if it is an array.
pub fn as_array(v : Json) -> Array[Json]? {
  match v {
    Json::Array(a) => Some(a)
    _ => None
  }
}

///|
/// String value of `v`, if it is a string.
pub fn as_string(v : Json) -> String? {
  match v {
    Json::String(s) => Some(s)
    _ => None
  }
}

///|
/// Integer value of `v`, if it is a number that fits an `Int32`.
pub fn as_int(v : Json) -> Int32? {
  match v {
    Json::Number(n, ..) =>
      if n.is_nan() || n.is_inf() {
        None
      } else {
        Some(n.to_int())
      }
    _ => None
  }
}

///|
/// Member `k` of `v` when `v` is an object.
pub fn field(v : Json, k : String) -> Json? {
  match v {
    Json::Object(m) => m.get(k)
    _ => None
  }
}

///|
/// Member `k` of `v` when `v` is an object, or `None`.
pub fn field_string(v : Json, k : String) -> String? {
  match field(v, k) {
    Some(x) => as_string(x)
    None => None
  }
}

///|
/// Member `k` of `v` as an integer, or `None`.
pub fn field_int(v : Json, k : String) -> Int32? {
  match field(v, k) {
    Some(x) => as_int(x)
    None => None
  }
}
