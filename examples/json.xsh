enum Json {
  JNull,
  JBool(Bool),
  JNum(Double),
  JStr(String),
  JArr(Array[Json]),
  JObj(Map[Json])
}

let is_ws = (c: Int) -> Bool {
  c == ' ' || c == '\n' || c == '\t' || c == '\r'
}

let is_digit = (c: Int) -> Bool {
  c >= '0' && c < ':'
}

let digit_to_double = (c: Int) -> Double {
  match c - '0' {
    0 => 0.0
    1 => 1.0
    2 => 2.0
    3 => 3.0
    4 => 4.0
    5 => 5.0
    6 => 6.0
    7 => 7.0
    8 => 8.0
    9 => 9.0
    _ => 0.0
  }
}

let rec skip_ws = (s: String, i: Int) -> Int {
  if i < s.string_length() {
    let c = s.string_char_code_at(i)
    if is_ws(c) { skip_ws(s, i + 1) } else { i }
  } else {
    i
  }
}

let starts_with = (s: String, i: Int, word: String) -> Bool {
  let end = i + word.string_length()
  end <= s.string_length() && s.string_substring(i, end).string_equals(word)
}

let parse_string = (s: String, i: Int) -> (String, Int) with {Error} {
  if i >= s.string_length() {
    raise "unexpected eof"
  } else if s.string_char_code_at(i) != '"' {
    raise "expected string"
  } else {
    let len = s.string_length()
    let rec scan = (
      s: String,
      idx: Int,
      start: Int,
      acc: String,
    ) -> (String, Int) with {Error} {
      if idx >= len {
        raise "unterminated string"
      } else {
        let c = s.string_char_code_at(idx)
        if c < ' ' {
          raise "invalid string"
        } else if c == '"' {
          let chunk = s.string_substring(start, idx)
          (acc.string_concat(chunk), idx + 1)
        } else if c == '\\' {
          let chunk = s.string_substring(start, idx)
          let next = idx + 1
          if next >= len {
            raise "unterminated string"
          } else {
            let esc = s.string_char_code_at(next)
            if esc == '"' {
              scan(s, next + 1, next + 1, acc.string_concat(chunk).string_concat("\""))
            } else if esc == '\\' {
              scan(s, next + 1, next + 1, acc.string_concat(chunk).string_concat("\\"))
            } else if esc == '/' {
              scan(s, next + 1, next + 1, acc.string_concat(chunk).string_concat("/"))
            } else if esc == 'n' {
              scan(s, next + 1, next + 1, acc.string_concat(chunk).string_concat("\n"))
            } else if esc == 't' {
              scan(s, next + 1, next + 1, acc.string_concat(chunk).string_concat("\t"))
            } else {
              raise "invalid escape"
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

let rec parse_digits = (s: String, i: Int, acc: Int) -> (Int, Int) with {Error} {
  if i < s.string_length() {
    let c = s.string_char_code_at(i)
    if is_digit(c) {
      let digit = c - '0'
      parse_digits(s, i + 1, acc * 10 + digit)
    } else {
      (acc, i)
    }
  } else {
    (acc, i)
  }
}

let rec parse_digits_double = (
  s: String,
  i: Int,
  acc: Double,
  seen: Bool,
) -> (Double, Int) with {Error} {
  if i < s.string_length() {
    let c = s.string_char_code_at(i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      parse_digits_double(s, i + 1, acc * 10.0 + digit, true)
    } else if seen {
      (acc, i)
    } else {
      raise "expected digit"
    }
  } else if seen {
    (acc, i)
  } else {
    raise "expected digit"
  }
}

let parse_int_part = (s: String, i: Int) -> (Double, Int) with {Error} {
  let len = s.string_length()
  if i < len {
    let c = s.string_char_code_at(i)
    if c == '0' {
      let next = i + 1
      if next < len {
        if is_digit(s.string_char_code_at(next)) {
          raise "leading zero"
        } else {
          (0.0, next)
        }
      } else {
        (0.0, next)
      }
    } else if is_digit(c) {
      parse_digits_double(s, i, 0.0, false)
    } else {
      raise "expected digit"
    }
  } else {
    raise "expected digit"
  }
}

let rec parse_fraction = (
  s: String,
  i: Int,
  acc: Double,
  scale: Double,
  seen: Bool,
) -> (Double, Int) with {Error} {
  if i < s.string_length() {
    let c = s.string_char_code_at(i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      parse_fraction(s, i + 1, acc + digit / scale, scale * 10.0, true)
    } else if seen {
      (acc, i)
    } else {
      raise "expected fraction"
    }
  } else if seen {
    (acc, i)
  } else {
    raise "expected fraction"
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
) -> (Double, Int) with {Error} {
  if i < s.string_length() {
    if s.string_char_code_at(i) == '.' {
      let (frac, next) = parse_fraction(s, i + 1, 0.0, 10.0, false)
      (value + frac, next)
    } else {
      (value, i)
    }
  } else {
    (value, i)
  }
}

let parse_exponent_if_any = (
  s: String,
  i: Int,
  value: Double,
) -> (Double, Int) with {Error} {
  let len = s.string_length()
  let parse_exp = (exp_sign: Int, exp_idx: Int) -> (Double, Int) with {Error} {
    if exp_idx < len {
      if is_digit(s.string_char_code_at(exp_idx)) {
        let (exp, exp_next) = parse_digits(s, exp_idx, 0)
        let adj = if exp_sign < 0 { 0 - exp } else { exp }
        (apply_exponent(value, adj), exp_next)
      } else {
        raise "expected exponent"
      }
    } else {
      raise "expected exponent"
    }
  }
  if i < len {
    let c = s.string_char_code_at(i)
    if c == 'e' || c == 'E' {
      let exp_start = i + 1
      if exp_start < len {
        let sign_char = s.string_char_code_at(exp_start)
        if sign_char == '-' {
          parse_exp(-1, exp_start + 1)
        } else if sign_char == '+' {
          parse_exp(1, exp_start + 1)
        } else {
          parse_exp(1, exp_start)
        }
      } else {
        raise "expected exponent"
      }
    } else {
      (value, i)
    }
  } else {
    (value, i)
  }
}

let parse_number_body = (
  s: String,
  idx: Int,
  sign: Double,
) -> (Json, Int) with {Error} {
  let (int_part, next) = parse_int_part(s, idx)
  let (with_frac, next_frac) = parse_fraction_if_any(s, next, int_part)
  let (with_exp, next_exp) = parse_exponent_if_any(s, next_frac, with_frac)
  (JNum(with_exp * sign), next_exp)
}

let parse_number = (s: String, i: Int) -> (Json, Int) with {Error} {
  if i >= s.string_length() {
    raise "expected number"
  } else {
    let c = s.string_char_code_at(i)
    if c == '-' {
      parse_number_body(s, i + 1, -1.0)
    } else {
      parse_number_body(s, i, 1.0)
    }
  }
}

let rec parse_value = (s: String, i: Int) -> (Json, Int) with {Error} {
  let parse_array = (s: String, i: Int) -> (Json, Int) with {Error} {
    do {
      let len = s.string_length()
      let idx = skip_ws(s, i + 1)
      if idx < len {
        if s.string_char_code_at(idx) == ']' {
          (JArr(array_builder_freeze(array_builder())), idx + 1)
        } else {
          let builder = array_builder()
          let rec parse_items = (s: String, i: Int) -> (Json, Int) with {Error} {
            let (value, next) = parse_value(s, i)
            array_builder_push(builder, value)
            let next_idx = skip_ws(s, next)
            if next_idx < len {
              let ch = s.string_char_code_at(next_idx)
              if ch == ',' {
                parse_items(s, next_idx + 1)
              } else if ch == ']' {
                (JArr(array_builder_freeze(builder)), next_idx + 1)
              } else {
                raise "expected , or ]"
              }
            } else {
              raise "expected , or ]"
            }
          }
          parse_items(s, idx)
        }
      } else {
        raise "unexpected eof"
      }
    }
  }

  let parse_object = (s: String, i: Int) -> (Json, Int) with {Error} {
    do {
      let len = s.string_length()
      let idx = skip_ws(s, i + 1)
      if idx < len {
        if s.string_char_code_at(idx) == '}' {
          (JObj(map_builder_freeze(map_builder())), idx + 1)
        } else {
          let builder = map_builder()
          let rec parse_members = (s: String, i: Int) -> (Json, Int) with {Error} {
            let (key, next) = parse_string(s, i)
            let colon_idx = skip_ws(s, next)
            if colon_idx >= len {
              raise "expected :"
            } else if s.string_char_code_at(colon_idx) != ':' {
              raise "expected :"
            } else {
              let (value, next_val) = parse_value(s, colon_idx + 1)
              map_builder_set(builder, key, value)
              let next_idx = skip_ws(s, next_val)
              if next_idx < len {
                let ch = s.string_char_code_at(next_idx)
                if ch == ',' {
                  parse_members(s, next_idx + 1)
                } else if ch == '}' {
                  (JObj(map_builder_freeze(builder)), next_idx + 1)
                } else {
                  raise "expected , or }"
                }
              } else {
                raise "expected , or }"
              }
            }
          }
          parse_members(s, idx)
        }
      } else {
        raise "unexpected eof"
      }
    }
  }

  let idx = skip_ws(s, i)
  if idx >= s.string_length() {
    raise "unexpected eof"
  } else {
    let c = s.string_char_code_at(idx)
    if c == 'n' {
      if starts_with(s, idx, "null") {
        (JNull, idx + 4)
      } else {
        raise "expected null"
      }
    } else if c == 't' {
      if starts_with(s, idx, "true") {
        (JBool(true), idx + 4)
      } else {
        raise "expected true"
      }
    } else if c == 'f' {
      if starts_with(s, idx, "false") {
        (JBool(false), idx + 5)
      } else {
        raise "expected false"
      }
    } else if c == '"' {
      let (value, next) = parse_string(s, idx)
      (JStr(value), next)
    } else if c == '[' {
      parse_array(s, idx)
    } else if c == '{' {
      parse_object(s, idx)
    } else if c == '-' || is_digit(c) {
      parse_number(s, idx)
    } else {
      raise "unexpected token"
    }
  }
}

let parse = (s: String) -> (Json, Int) with {Error} {
  let (value, next) = parse_value(s, 0)
  let end = skip_ws(s, next)
  if end == s.string_length() {
    (value, end)
  } else {
    raise "trailing input"
  }
}

let is_ok = (s: String) -> Bool {
  try { let _ = parse(s); true } catch { false }
}

let is_err = (s: String) -> Bool {
  try { let _ = parse(s); false } catch { true }
}

let input = "{\"name\":\"xsh\",\"nums\":[1.5,2,3.25],\"ok\":true,\"meta\":null}"

test "json_parser" {
  let (json, _) = parse(input)
  let ok =
    match json {
      JObj(obj) =>
        match obj.map_get("name") {
          JStr(name) => {
            let name_ok = name.string_equals("xsh")
            let nums_ok =
              match obj.map_get("nums") {
                JArr(arr) => {
                  let n0_ok = match arr[0] { JNum(n) => n == 1.5 _ => false }
                  let n1_ok = match arr[1] { JNum(n) => n == 2.0 _ => false }
                  let n2_ok = match arr[2] { JNum(n) => n == 3.25 _ => false }
                  arr.array_length() == 3 && n0_ok && n1_ok && n2_ok
                }
                _ => false
              }
            let ok_ok = match obj.map_get("ok") { JBool(b) => b _ => false }
            let meta_ok = match obj.map_get("meta") { JNull => true _ => false }
            name_ok && nums_ok && ok_ok && meta_ok
          }
          _ => false
        }
      _ => false
    }
  assert(ok)
}

test "json_parser_numbers" {
  assert(match parse("0") { (JNum(n), _) => n == 0.0 _ => false })
  assert(match parse("-12") { (JNum(n), _) => n == -12.0 _ => false })
  assert(match parse("3.5") { (JNum(n), _) => n == 3.5 _ => false })
  assert(match parse("1e3") { (JNum(n), _) => n == 1000.0 _ => false })
  assert(match parse("1.25e-2") { (JNum(n), _) => n == 0.0125 _ => false })
  assert(match parse("1E+2") { (JNum(n), _) => n == 100.0 _ => false })
  assert(match parse("-0.0") { (JNum(n), _) => n == -0.0 _ => false })
}

test "json_parser_whitespace" {
  let (json, _) = parse(" \n\t{\"a\": 1}\n ")
  let ok =
    match json {
      JObj(obj) =>
        match obj.map_get("a") { JNum(n) => n == 1.0 _ => false }
      _ => false
    }
  assert(ok)
}

test "json_parser_nested" {
  let (json, _) = parse("{\"a\":[true,false,null,{\"b\":2}],\"c\":{}}")
  let ok =
    match json {
      JObj(obj) => {
        let a_ok =
          match obj.map_get("a") {
            JArr(arr) => {
              let b0 = match arr[0] { JBool(b) => b _ => false }
              let b1 = match arr[1] { JBool(b) => !b _ => false }
              let b2 = match arr[2] { JNull => true _ => false }
              let b3 =
                match arr[3] {
                  JObj(inner) =>
                    match inner.map_get("b") { JNum(n) => n == 2.0 _ => false }
                  _ => false
                }
              arr.array_length() == 4 && b0 && b1 && b2 && b3
            }
            _ => false
          }
        let c_ok = match obj.map_get("c") { JObj(_) => true _ => false }
        a_ok && c_ok
      }
      _ => false
    }
  assert(ok)
}

test "json_parser_string" {
  let (json, _) = parse("\"he\\\\llo\\n\\t\\\"/\"")
  let ok =
    match json {
      JStr(s) => s.string_equals("he\\llo\n\t\"/")
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
