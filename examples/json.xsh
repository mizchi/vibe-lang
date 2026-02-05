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
  c |> eq(' ') |> or(c |> eq('\n') |> or(c |> eq('\t') |> or(c |> eq('\r'))))
}

let is_digit = (c: Int) -> Bool {
  c |> lt('0') |> not |> and(c |> lt(':'))
}

let digit_to_double = (c: Int) -> Double {
  if c |> eq('0') { 0.0 }
  else if c |> eq('1') { 1.0 }
  else if c |> eq('2') { 2.0 }
  else if c |> eq('3') { 3.0 }
  else if c |> eq('4') { 4.0 }
  else if c |> eq('5') { 5.0 }
  else if c |> eq('6') { 6.0 }
  else if c |> eq('7') { 7.0 }
  else if c |> eq('8') { 8.0 }
  else if c |> eq('9') { 9.0 }
  else { 0.0 }
}

let rec skip_ws = (s: String, i: Int) -> Int {
  if i |> lt(s |> string_length) {
    let c = s |> string_char_code_at(i)
    if is_ws(c) {
      s |> skip_ws(i |> add(1))
    } else {
      i
    }
  } else {
    i
  }
}

let starts_with = (s: String, i: Int, word: String) -> Bool {
  let end = i |> add(word |> string_length)
  if end |> lt(s |> string_length |> add(1)) {
    s |> string_substring(i, end) |> string_equals(word)
  } else {
    false
  }
}

let parse_string = (s: String, i: Int) -> ParseString with {Error} {
  if i |> lt(s |> string_length) |> not {
    ErrStr("unexpected eof")
  } else if s |> string_char_code_at(i) |> eq('"') |> not {
    ErrStr("expected string")
  } else {
    let len = s |> string_length
    let rec scan = (
      s: String,
      idx: Int,
      start: Int,
      acc: String,
    ) -> ParseString {
      if idx |> lt(len) |> not {
        ErrStr("unterminated string")
      } else {
        let c = s |> string_char_code_at(idx)
        if c |> lt(' ') {
          ErrStr("invalid string")
        } else if c |> eq('"') {
          let chunk = s |> string_substring(start, idx)
          OkStr(string_concat(acc, chunk), idx |> add(1))
        } else if c |> eq('\\') {
          let chunk = s |> string_substring(start, idx)
          let next = idx |> add(1)
          if next |> lt(len) |> not {
            ErrStr("unterminated string")
          } else {
            let esc = s |> string_char_code_at(next)
            if esc |> eq('"') {
              s |> scan(next |> add(1), next |> add(1), string_concat(string_concat(acc, chunk), "\""))
            } else if esc |> eq('\\') {
              s |> scan(next |> add(1), next |> add(1), string_concat(string_concat(acc, chunk), "\\"))
            } else if esc |> eq('/') {
              s |> scan(next |> add(1), next |> add(1), string_concat(string_concat(acc, chunk), "/"))
            } else if esc |> eq('n') {
              s |> scan(next |> add(1), next |> add(1), string_concat(string_concat(acc, chunk), "\n"))
            } else if esc |> eq('t') {
              s |> scan(next |> add(1), next |> add(1), string_concat(string_concat(acc, chunk), "\t"))
            } else {
              ErrStr("invalid escape")
            }
          }
        } else {
          s |> scan(idx |> add(1), start, acc)
        }
      }
    }
    s |> scan(i |> add(1), i |> add(1), "")
  }
}

let rec parse_digits = (s: String, i: Int, acc: Int) -> ParseInt with {Error} {
  if i |> lt(s |> string_length) {
    let c = s |> string_char_code_at(i)
    if is_digit(c) {
      let digit = c |> sub('0')
      s |> parse_digits(i |> add(1), acc |> mul(10) |> add(digit))
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
  if i |> lt(s |> string_length) {
    let c = s |> string_char_code_at(i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      s |> parse_digits_double(i |> add(1), acc * 10.0 + digit, true)
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
  let len = s |> string_length
  if i |> lt(len) {
    let c = s |> string_char_code_at(i)
    if c |> eq('0') {
      let next = i |> add(1)
      if next |> lt(len) {
        if s |> string_char_code_at(next) |> is_digit {
          ErrNum("leading zero")
        } else {
          OkNum(0.0, next)
        }
      } else {
        OkNum(0.0, next)
      }
    } else if is_digit(c) {
      s |> parse_digits_double(i, 0.0, false)
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
  if i |> lt(s |> string_length) {
    let c = s |> string_char_code_at(i)
    if is_digit(c) {
      let digit = digit_to_double(c)
      s |> parse_fraction(i |> add(1), acc + digit / scale, scale * 10.0, true)
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
  if exp |> eq(0) {
    value
  } else if exp |> lt(0) {
    apply_exponent(value / 10.0, exp |> add(1))
  } else {
    apply_exponent(value * 10.0, exp |> sub(1))
  }
}

let parse_fraction_if_any = (
  s: String,
  i: Int,
  value: Double,
) -> ParseNumber with {Error} {
  if i |> lt(s |> string_length) {
    let c = s |> string_char_code_at(i)
    if c |> eq('.') {
      match s |> parse_fraction(i |> add(1), 0.0, 10.0, false) {
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
  let len = s |> string_length
  let parse_exp = (exp_sign: Int, exp_idx: Int) -> ParseNumber with {Error} {
    if exp_idx |> lt(len) {
      if s |> string_char_code_at(exp_idx) |> is_digit {
        match s |> parse_digits(exp_idx, 0) {
          OkInt(exp, exp_next) => {
            let adj = if exp_sign |> lt(0) { sub(0, exp) } else { exp }
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
  if i |> lt(len) {
    let c = s |> string_char_code_at(i)
    if c |> eq('e') |> or(c |> eq('E')) {
      let exp_start = i |> add(1)
      if exp_start |> lt(len) {
        let sign_char = s |> string_char_code_at(exp_start)
        if sign_char |> eq('-') {
          parse_exp(-1, exp_start |> add(1))
        } else if sign_char |> eq('+') {
          parse_exp(1, exp_start |> add(1))
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
  match s |> parse_int_part(idx) {
    OkNum(int_part, next) =>
      match s |> parse_fraction_if_any(next, int_part) {
        OkNum(with_frac, next_frac) =>
          match s |> parse_exponent_if_any(next_frac, with_frac) {
            OkNum(with_exp, next_exp) => Ok(JNum(with_exp * sign), next_exp)
            ErrNum(msg) => ErrParse(msg)
          }
        ErrNum(msg) => ErrParse(msg)
      }
    ErrNum(msg) => ErrParse(msg)
  }
}

let parse_number = (s: String, i: Int) -> Parse with {Error} {
  if i |> lt(s |> string_length) |> not {
    ErrParse("expected number")
  } else {
    let c = s |> string_char_code_at(i)
    if c |> eq('-') {
      s |> parse_number_body(i |> add(1), -1.0)
    } else {
      s |> parse_number_body(i, 1.0)
    }
  }
}

let rec parse_value = (s: String, i: Int) -> Parse with {Error} {
  let parse_array = (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = s |> string_length
      let idx = s |> skip_ws(i |> add(1))
      if idx |> lt(len) {
        if s |> string_char_code_at(idx) |> eq(']') {
          Ok(JArr(array_builder_freeze(array_builder())), idx |> add(1))
        } else {
          let builder = array_builder()
          let rec parse_items = (s: String, i: Int) -> Parse with {Error} {
            match s |> parse_value(i) {
              Ok(value, next) => {
                array_builder_push(builder, value)
                let next_idx = s |> skip_ws(next)
                if next_idx |> lt(len) {
                  if s |> string_char_code_at(next_idx) |> eq(',') {
                    s |> parse_items(next_idx |> add(1))
                  } else if s |> string_char_code_at(next_idx) |> eq(']') {
                    Ok(JArr(array_builder_freeze(builder)), next_idx |> add(1))
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
          s |> parse_items(idx)
        }
      } else {
        ErrParse("unexpected eof")
      }
    }
  }

  let parse_object = (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = s |> string_length
      let idx = s |> skip_ws(i |> add(1))
      if idx |> lt(len) {
        if s |> string_char_code_at(idx) |> eq('}') {
          Ok(JObj(map_builder_freeze(map_builder())), idx |> add(1))
        } else {
          let builder = map_builder()
          let rec parse_members = (s: String, i: Int) -> Parse with {Error} {
            match s |> parse_string(i) {
              OkStr(key, next) => {
                let colon_idx = s |> skip_ws(next)
                if colon_idx |> lt(len) |> not {
                  ErrParse("expected :")
                } else if s |> string_char_code_at(colon_idx) |> eq(':') |> not {
                  ErrParse("expected :")
                } else {
                  match s |> parse_value(colon_idx |> add(1)) {
                    Ok(value, next_val) => {
                      map_builder_set(builder, key, value)
                      let next_idx = s |> skip_ws(next_val)
                      if next_idx |> lt(len) {
                        if s |> string_char_code_at(next_idx) |> eq(',') {
                          s |> parse_members(next_idx |> add(1))
                        } else if s |> string_char_code_at(next_idx) |> eq('}') {
                          Ok(JObj(map_builder_freeze(builder)), next_idx |> add(1))
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
          s |> parse_members(idx)
        }
      } else {
        ErrParse("unexpected eof")
      }
    }
  }

  let idx = s |> skip_ws(i)
  if idx |> lt(s |> string_length) |> not {
    ErrParse("unexpected eof")
  } else {
    let c = s |> string_char_code_at(idx)
    if c |> eq('n') {
      if s |> starts_with(idx, "null") {
        Ok(JNull, idx |> add(4))
      } else {
        ErrParse("expected null")
      }
    } else if c |> eq('t') {
      if s |> starts_with(idx, "true") {
        Ok(JBool(true), idx |> add(4))
      } else {
        ErrParse("expected true")
      }
    } else if c |> eq('f') {
      if s |> starts_with(idx, "false") {
        Ok(JBool(false), idx |> add(5))
      } else {
        ErrParse("expected false")
      }
    } else if c |> eq('"') {
      match s |> parse_string(idx) {
        OkStr(value, next) => Ok(JStr(value), next)
        ErrStr(msg) => ErrParse(msg)
      }
    } else if c |> eq('[') {
      s |> parse_array(idx)
    } else if c |> eq('{') {
      s |> parse_object(idx)
    } else if c |> eq('-') |> or(is_digit(c)) {
      s |> parse_number(idx)
    } else {
      ErrParse("unexpected token")
    }
  }
}

let parse = (s: String) -> Parse with {Error} {
  match s |> parse_value(0) {
    Ok(value, next) => {
      let end = s |> skip_ws(next)
      if end |> eq(s |> string_length) {
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
        match obj |> map_get("name") {
          JStr(name) => {
            let name_ok = name |> string_equals("xsh")
            let nums_ok =
              match obj |> map_get("nums") {
                JArr(arr) => {
                  let n0_ok = match arr |> array_get(0) { JNum(n) => n == 1.5 _ => false }
                  let n1_ok = match arr |> array_get(1) { JNum(n) => n == 2.0 _ => false }
                  let n2_ok = match arr |> array_get(2) { JNum(n) => n == 3.25 _ => false }
                  arr |> array_length |> eq(3)
                  |> and(n0_ok |> and(n1_ok |> and(n2_ok)))
                }
                _ => false
              }
            let ok_ok = match obj |> map_get("ok") { JBool(b) => b _ => false }
            let meta_ok = match obj |> map_get("meta") { JNull => true _ => false }
            name_ok |> and(nums_ok |> and(ok_ok |> and(meta_ok)))
          }
          _ => false
        }
      _ => false
    }
  assert(ok)
}

test "json_parser_numbers" {
  let n0 = match parse("0") { Ok(JNum(n), _) => n == 0.0 _ => false }
  let n1 = match parse("-12") { Ok(JNum(n), _) => n == -12.0 _ => false }
  let n2 = match parse("3.5") { Ok(JNum(n), _) => n == 3.5 _ => false }
  let n3 = match parse("1e3") { Ok(JNum(n), _) => n == 1000.0 _ => false }
  let n4 = match parse("1.25e-2") { Ok(JNum(n), _) => n == 0.0125 _ => false }
  let n5 = match parse("1E+2") { Ok(JNum(n), _) => n == 100.0 _ => false }
  let n6 = match parse("-0.0") { Ok(JNum(n), _) => n == -0.0 _ => false }
  assert(n0 |> and(n1 |> and(n2 |> and(n3 |> and(n4 |> and(n5 |> and(n6)))))))
}

test "json_parser_whitespace" {
  let ok =
    match parse(" \n\t{\"a\": 1}\n ") {
      Ok(JObj(obj), _) =>
        match obj |> map_get("a") { JNum(n) => n == 1.0 _ => false }
      _ => false
    }
  assert(ok)
}

test "json_parser_nested" {
  let ok =
    match parse("{\"a\":[true,false,null,{\"b\":2}],\"c\":{}}") {
      Ok(JObj(obj), _) => {
        let a_ok =
          match obj |> map_get("a") {
            JArr(arr) => {
              let b0 = match arr |> array_get(0) { JBool(b) => b _ => false }
              let b1 = match arr |> array_get(1) { JBool(b) => not(b) _ => false }
              let b2 = match arr |> array_get(2) { JNull => true _ => false }
              let b3 =
                match arr |> array_get(3) {
                  JObj(inner) =>
                    match inner |> map_get("b") { JNum(n) => n == 2.0 _ => false }
                  _ => false
                }
              arr |> array_length |> eq(4)
              |> and(b0 |> and(b1 |> and(b2 |> and(b3))))
            }
            _ => false
          }
        let c_ok = match obj |> map_get("c") { JObj(_) => true _ => false }
        a_ok |> and(c_ok)
      }
      _ => false
    }
  assert(ok)
}

test "json_parser_string" {
  let ok =
    match parse("\"he\\\\llo\\n\\t\\\"/\"") {
      Ok(JStr(s), _) => s |> string_equals("he\\llo\n\t\"/")
      _ => false
    }
  assert(ok)
}

test "json_parser_errors" {
  let e0 = is_err("\"abc")
  let e1 = is_err("true false")
  let e2 = is_err("1e")
  let e3 = is_err("1e+")
  let e4 = is_err("1e-")
  let e5 = is_err("[1,]")
  let e6 = is_err("{\"a\":1,}")
  let e7 = is_err("\"a\\b\"")
  let e8 = is_err("01")
  let e9 = is_err("-01")
  let e10 = is_err("00")
  let e11 = is_err(".1")
  let e12 = is_err("1.")
  let e13 = is_err("+1")
  let e14 = is_err("-")
  let e15 = is_err("\"a\nb\"")
  assert(
    e0 |> and(
      e1 |> and(
        e2 |> and(
          e3 |> and(
            e4 |> and(
              e5 |> and(
                e6 |> and(
                  e7 |> and(
                    e8 |> and(
                      e9 |> and(
                        e10 |> and(
                          e11 |> and(
                            e12 |> and(
                              e13 |> and(e14 |> and(e15))
                            )
                          )
                        )
                      )
                    )
                  )
                )
              )
            )
          )
        )
      )
    )
  )
}
