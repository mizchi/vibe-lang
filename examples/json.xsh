enum Json {
  JNull,
  JBool(Bool),
  JNum(Double),
  JStr(String),
  JArr(Array[Json]),
  JObj(Map[Json])
}

enum Parse { Ok(Json, Int), ErrParse(String) }
enum ParseString { OkStr(String, Int), ErrStr(String) }
enum ParseInt { OkInt(Int, Int), ErrInt(String) }
enum ParseNumber { OkNum(Double, Int), ErrNum(String) }

let is_ws = (c: Int) -> Bool {
  c == ' ' || c == '\n' || c == '\t' || c == '\r'
}

let is_digit = (c: Int) -> Bool {
  c >= '0' && c < ':'
}

let digit_to_double = (c: Int) -> Double {
  if c == '0' { 0.0 }
  else if c == '1' { 1.0 }
  else if c == '2' { 2.0 }
  else if c == '3' { 3.0 }
  else if c == '4' { 4.0 }
  else if c == '5' { 5.0 }
  else if c == '6' { 6.0 }
  else if c == '7' { 7.0 }
  else if c == '8' { 8.0 }
  else if c == '9' { 9.0 }
  else { 0.0 }
}

let rec skip_ws = (s: String, i: Int) -> Int {
  if i < string_length(s) {
    let c = string_char_code_at(s, i)
    if is_ws(c) { skip_ws(s, i + 1) } else { i }
  } else {
    i
  }
}

let starts_with = (s: String, i: Int, word: String) -> Bool {
  let end = i + string_length(word)
  end <= string_length(s) && string_equals(string_substring(s, i, end), word)
}

let parse_string = (s: String, i: Int) -> ParseString with {Error} {
  if i >= string_length(s) {
    ErrStr("unexpected eof")
  } else if string_char_code_at(s, i) != '"' {
    ErrStr("expected string")
  } else {
    let len = string_length(s)
    let rec scan = (
      s: String,
      idx: Int,
      start: Int,
      acc: String,
    ) -> ParseString {
      if idx >= len {
        ErrStr("unterminated string")
      } else {
        let c = string_char_code_at(s, idx)
        if c < ' ' {
          ErrStr("invalid string")
        } else if c == '"' {
          let chunk = string_substring(s, start, idx)
          OkStr(string_concat(acc, chunk), idx + 1)
        } else if c == '\\' {
          let chunk = string_substring(s, start, idx)
          let next = idx + 1
          if next >= len {
            ErrStr("unterminated string")
          } else {
            let esc = string_char_code_at(s, next)
            if esc == '"' {
              scan(s, next + 1, next + 1, string_concat(string_concat(acc, chunk), "\""))
            } else if esc == '\\' {
              scan(s, next + 1, next + 1, string_concat(string_concat(acc, chunk), "\\"))
            } else if esc == '/' {
              scan(s, next + 1, next + 1, string_concat(string_concat(acc, chunk), "/"))
            } else if esc == 'n' {
              scan(s, next + 1, next + 1, string_concat(string_concat(acc, chunk), "\n"))
            } else if esc == 't' {
              scan(s, next + 1, next + 1, string_concat(string_concat(acc, chunk), "\t"))
            } else {
              ErrStr("invalid escape")
            }
          }
        } else {
          scan(s, idx + 1, start, acc)
        }
      }
    }
    scan(s, i + 1, i + 1, "")
  }
}

let rec parse_digits = (s: String, i: Int, acc: Int) -> ParseInt with {Error} {
  if i < string_length(s) {
    let c = string_char_code_at(s, i)
    if is_digit(c) {
      let digit = c - '0'
      parse_digits(s, i + 1, acc * 10 + digit)
    } else {
      OkInt(acc, i)
    }
  } else {
    OkInt(acc, i)
  }
}

let rec parse_digits_double = (
  s: String,
  i: Int,
  acc: Double,
  seen: Bool,
) -> ParseNumber with {Error} {
  if i < string_length(s) {
    let c = string_char_code_at(s, i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      parse_digits_double(s, i + 1, acc * 10.0 + digit, true)
    } else if seen {
      OkNum(acc, i)
    } else {
      ErrNum("expected digit")
    }
  } else if seen {
    OkNum(acc, i)
  } else {
    ErrNum("expected digit")
  }
}

let parse_int_part = (s: String, i: Int) -> ParseNumber with {Error} {
  let len = string_length(s)
  if i < len {
    let c = string_char_code_at(s, i)
    if c == '0' {
      let next = i + 1
      if next < len {
        if is_digit(string_char_code_at(s, next)) {
          ErrNum("leading zero")
        } else {
          OkNum(0.0, next)
        }
      } else {
        OkNum(0.0, next)
      }
    } else if is_digit(c) {
      parse_digits_double(s, i, 0.0, false)
    } else {
      ErrNum("expected digit")
    }
  } else {
    ErrNum("expected digit")
  }
}

let rec parse_fraction = (
  s: String,
  i: Int,
  acc: Double,
  scale: Double,
  seen: Bool,
) -> ParseNumber with {Error} {
  if i < string_length(s) {
    let c = string_char_code_at(s, i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      parse_fraction(s, i + 1, acc + digit / scale, scale * 10.0, true)
    } else if seen {
      OkNum(acc, i)
    } else {
      ErrNum("expected fraction")
    }
  } else if seen {
    OkNum(acc, i)
  } else {
    ErrNum("expected fraction")
  }
}

let rec apply_exponent = (value: Double, exp: Int) -> Double {
  if exp == 0 {
    value
  } else if exp < 0 {
    apply_exponent(value / 10.0, exp + 1)
  } else {
    apply_exponent(value * 10.0, exp - 1)
  }
}

let parse_fraction_if_any = (
  s: String,
  i: Int,
  value: Double,
) -> ParseNumber with {Error} {
  if i < string_length(s) {
    if string_char_code_at(s, i) == '.' {
      match parse_fraction(s, i + 1, 0.0, 10.0, false) {
        OkNum(frac, next) => OkNum(value + frac, next)
        ErrNum(msg) => ErrNum(msg)
      }
    } else {
      OkNum(value, i)
    }
  } else {
    OkNum(value, i)
  }
}

let parse_exponent_if_any = (
  s: String,
  i: Int,
  value: Double,
) -> ParseNumber with {Error} {
  let len = string_length(s)
  let parse_exp = (exp_sign: Int, exp_idx: Int) -> ParseNumber with {Error} {
    if exp_idx < len {
      if is_digit(string_char_code_at(s, exp_idx)) {
        match parse_digits(s, exp_idx, 0) {
          OkInt(exp, exp_next) => {
            let adj = if exp_sign < 0 { 0 - exp } else { exp }
            OkNum(apply_exponent(value, adj), exp_next)
          }
          ErrInt(msg) => ErrNum(msg)
        }
      } else {
        ErrNum("expected exponent")
      }
    } else {
      ErrNum("expected exponent")
    }
  }
  if i < len {
    let c = string_char_code_at(s, i)
    if c == 'e' || c == 'E' {
      let exp_start = i + 1
      if exp_start < len {
        let sign_char = string_char_code_at(s, exp_start)
        if sign_char == '-' {
          parse_exp(-1, exp_start + 1)
        } else if sign_char == '+' {
          parse_exp(1, exp_start + 1)
        } else {
          parse_exp(1, exp_start)
        }
      } else {
        ErrNum("expected exponent")
      }
    } else {
      OkNum(value, i)
    }
  } else {
    OkNum(value, i)
  }
}

let parse_number_body = (
  s: String,
  idx: Int,
  sign: Double,
) -> Parse with {Error} {
  match parse_int_part(s, idx) {
    OkNum(int_part, next) =>
      match parse_fraction_if_any(s, next, int_part) {
        OkNum(with_frac, next_frac) =>
          match parse_exponent_if_any(s, next_frac, with_frac) {
            OkNum(with_exp, next_exp) => Ok(JNum(with_exp * sign), next_exp)
            ErrNum(msg) => ErrParse(msg)
          }
        ErrNum(msg) => ErrParse(msg)
      }
    ErrNum(msg) => ErrParse(msg)
  }
}

let parse_number = (s: String, i: Int) -> Parse with {Error} {
  if i >= string_length(s) {
    ErrParse("expected number")
  } else {
    let c = string_char_code_at(s, i)
    if c == '-' {
      parse_number_body(s, i + 1, -1.0)
    } else {
      parse_number_body(s, i, 1.0)
    }
  }
}

let rec parse_value = (s: String, i: Int) -> Parse with {Error} {
  let parse_array = (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = string_length(s)
      let idx = skip_ws(s, i + 1)
      if idx < len {
        if string_char_code_at(s, idx) == ']' {
          Ok(JArr(array_builder_freeze(array_builder())), idx + 1)
        } else {
          let builder = array_builder()
          let rec parse_items = (s: String, i: Int) -> Parse with {Error} {
            match parse_value(s, i) {
              Ok(value, next) => {
                array_builder_push(builder, value)
                let next_idx = skip_ws(s, next)
                if next_idx < len {
                  let ch = string_char_code_at(s, next_idx)
                  if ch == ',' {
                    parse_items(s, next_idx + 1)
                  } else if ch == ']' {
                    Ok(JArr(array_builder_freeze(builder)), next_idx + 1)
                  } else {
                    ErrParse("expected , or ]")
                  }
                } else {
                  ErrParse("expected , or ]")
                }
              }
              ErrParse(msg) => ErrParse(msg)
            }
          }
          parse_items(s, idx)
        }
      } else {
        ErrParse("unexpected eof")
      }
    }
  }

  let parse_object = (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = string_length(s)
      let idx = skip_ws(s, i + 1)
      if idx < len {
        if string_char_code_at(s, idx) == '}' {
          Ok(JObj(map_builder_freeze(map_builder())), idx + 1)
        } else {
          let builder = map_builder()
          let rec parse_members = (s: String, i: Int) -> Parse with {Error} {
            match parse_string(s, i) {
              OkStr(key, next) => {
                let colon_idx = skip_ws(s, next)
                if colon_idx >= len {
                  ErrParse("expected :")
                } else if string_char_code_at(s, colon_idx) != ':' {
                  ErrParse("expected :")
                } else {
                  match parse_value(s, colon_idx + 1) {
                    Ok(value, next_val) => {
                      map_builder_set(builder, key, value)
                      let next_idx = skip_ws(s, next_val)
                      if next_idx < len {
                        let ch = string_char_code_at(s, next_idx)
                        if ch == ',' {
                          parse_members(s, next_idx + 1)
                        } else if ch == '}' {
                          Ok(JObj(map_builder_freeze(builder)), next_idx + 1)
                        } else {
                          ErrParse("expected , or }")
                        }
                      } else {
                        ErrParse("expected , or }")
                      }
                    }
                    ErrParse(msg) => ErrParse(msg)
                  }
                }
              }
              ErrStr(msg) => ErrParse(msg)
            }
          }
          parse_members(s, idx)
        }
      } else {
        ErrParse("unexpected eof")
      }
    }
  }

  let idx = skip_ws(s, i)
  if idx >= string_length(s) {
    ErrParse("unexpected eof")
  } else {
    let c = string_char_code_at(s, idx)
    if c == 'n' {
      if starts_with(s, idx, "null") {
        Ok(JNull, idx + 4)
      } else {
        ErrParse("expected null")
      }
    } else if c == 't' {
      if starts_with(s, idx, "true") {
        Ok(JBool(true), idx + 4)
      } else {
        ErrParse("expected true")
      }
    } else if c == 'f' {
      if starts_with(s, idx, "false") {
        Ok(JBool(false), idx + 5)
      } else {
        ErrParse("expected false")
      }
    } else if c == '"' {
      match parse_string(s, idx) {
        OkStr(value, next) => Ok(JStr(value), next)
        ErrStr(msg) => ErrParse(msg)
      }
    } else if c == '[' {
      parse_array(s, idx)
    } else if c == '{' {
      parse_object(s, idx)
    } else if c == '-' || is_digit(c) {
      parse_number(s, idx)
    } else {
      ErrParse("unexpected token")
    }
  }
}

let parse = (s: String) -> Parse with {Error} {
  match parse_value(s, 0) {
    Ok(value, next) => {
      let end = skip_ws(s, next)
      if end == string_length(s) {
        Ok(value, end)
      } else {
        ErrParse("trailing input")
      }
    }
    ErrParse(msg) => ErrParse(msg)
  }
}

let is_ok = (s: String) -> Bool with {Error} {
  match parse(s) {
    Ok(_, _) => true
    _ => false
  }
}

let is_err = (s: String) -> Bool with {Error} {
  match parse(s) {
    ErrParse(_) => true
    _ => false
  }
}

let input = "{\"name\":\"xsh\",\"nums\":[1.5,2,3.25],\"ok\":true,\"meta\":null}"

test "json_parser" {
  let ok =
    match parse(input) {
      Ok(JObj(obj), _) =>
        match map_get(obj, "name") {
          JStr(name) => {
            let name_ok = string_equals(name, "xsh")
            let nums_ok =
              match map_get(obj, "nums") {
                JArr(arr) => {
                  let n0_ok = match array_get(arr, 0) { JNum(n) => n == 1.5 _ => false }
                  let n1_ok = match array_get(arr, 1) { JNum(n) => n == 2.0 _ => false }
                  let n2_ok = match array_get(arr, 2) { JNum(n) => n == 3.25 _ => false }
                  array_length(arr) == 3 && n0_ok && n1_ok && n2_ok
                }
                _ => false
              }
            let ok_ok = match map_get(obj, "ok") { JBool(b) => b _ => false }
            let meta_ok = match map_get(obj, "meta") { JNull => true _ => false }
            name_ok && nums_ok && ok_ok && meta_ok
          }
          _ => false
        }
      _ => false
    }
  assert(ok)
}

test "json_parser_numbers" {
  assert(match parse("0") { Ok(JNum(n), _) => n == 0.0 _ => false })
  assert(match parse("-12") { Ok(JNum(n), _) => n == -12.0 _ => false })
  assert(match parse("3.5") { Ok(JNum(n), _) => n == 3.5 _ => false })
  assert(match parse("1e3") { Ok(JNum(n), _) => n == 1000.0 _ => false })
  assert(match parse("1.25e-2") { Ok(JNum(n), _) => n == 0.0125 _ => false })
  assert(match parse("1E+2") { Ok(JNum(n), _) => n == 100.0 _ => false })
  assert(match parse("-0.0") { Ok(JNum(n), _) => n == -0.0 _ => false })
}

test "json_parser_whitespace" {
  let ok =
    match parse(" \n\t{\"a\": 1}\n ") {
      Ok(JObj(obj), _) =>
        match map_get(obj, "a") { JNum(n) => n == 1.0 _ => false }
      _ => false
    }
  assert(ok)
}

test "json_parser_nested" {
  let ok =
    match parse("{\"a\":[true,false,null,{\"b\":2}],\"c\":{}}") {
      Ok(JObj(obj), _) => {
        let a_ok =
          match map_get(obj, "a") {
            JArr(arr) => {
              let b0 = match array_get(arr, 0) { JBool(b) => b _ => false }
              let b1 = match array_get(arr, 1) { JBool(b) => !b _ => false }
              let b2 = match array_get(arr, 2) { JNull => true _ => false }
              let b3 =
                match array_get(arr, 3) {
                  JObj(inner) =>
                    match map_get(inner, "b") { JNum(n) => n == 2.0 _ => false }
                  _ => false
                }
              array_length(arr) == 4 && b0 && b1 && b2 && b3
            }
            _ => false
          }
        let c_ok = match map_get(obj, "c") { JObj(_) => true _ => false }
        a_ok && c_ok
      }
      _ => false
    }
  assert(ok)
}

test "json_parser_string" {
  let ok =
    match parse("\"he\\\\llo\\n\\t\\\"/\"") {
      Ok(JStr(s), _) => string_equals(s, "he\\llo\n\t\"/")
      _ => false
    }
  assert(ok)
}

test "json_parser_errors" {
  assert(is_err("\"abc"))
  assert(is_err("true false"))
  assert(is_err("1e"))
  assert(is_err("1e+"))
  assert(is_err("1e-"))
  assert(is_err("[1,]"))
  assert(is_err("{\"a\":1,}"))
  assert(is_err("\"a\\b\""))
  assert(is_err("01"))
  assert(is_err("-01"))
  assert(is_err("00"))
  assert(is_err(".1"))
  assert(is_err("1."))
  assert(is_err("+1"))
  assert(is_err("-"))
  assert(is_err("\"a\nb\""))
}
