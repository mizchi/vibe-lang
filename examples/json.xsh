enum Json {
  JNull,
  JBool(Bool),
  JNum(Int),
  JStr(String),
  JArr(Array[Json]),
  JObj(Map[Json])
}

enum Parse { Ok(Json, Int), ErrParse(String) }
enum ParseString { OkStr(String, Int), ErrStr(String) }
enum ParseInt { OkInt(Int, Int), ErrInt(String) }

let is_ws = fn (c: Int) -> Bool {
  c |> eq(' ') |> or(c |> eq('\n') |> or(c |> eq('\t') |> or(c |> eq('\r'))))
}

let is_digit = fn (c: Int) -> Bool {
  c |> lt('0') |> not |> and(c |> lt(':'))
}

let rec skip_ws = fn (s: String, i: Int) -> Int {
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

let starts_with = fn (s: String, i: Int, word: String) -> Bool {
  let end = i |> add(word |> string_length)
  if end |> lt(s |> string_length |> add(1)) {
    s |> string_substring(i, end) |> string_equals(word)
  } else {
    false
  }
}

let parse_string = fn (s: String, i: Int) -> ParseString with {Error} {
  if i |> lt(s |> string_length) |> not {
    ErrStr("unexpected eof")
  } else if s |> string_char_code_at(i) |> eq('"') |> not {
    ErrStr("expected string")
  } else {
    let rec scan = fn (s: String, idx: Int, start: Int) -> ParseString {
      if idx |> lt(s |> string_length) |> not {
        ErrStr("unterminated string")
      } else {
        let c = s |> string_char_code_at(idx)
        if c |> eq('"') {
          OkStr(s |> string_substring(start, idx), idx |> add(1))
        } else if c |> eq('\\') {
          ErrStr("escape not supported")
        } else {
          s |> scan(idx |> add(1), start)
        }
      }
    }
    s |> scan(i |> add(1), i |> add(1))
  }
}

let rec parse_digits = fn (s: String, i: Int, acc: Int) -> ParseInt with {Error} {
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

let parse_number = fn (s: String, i: Int) -> Parse with {Error} {
  if i |> lt(s |> string_length) |> not {
    ErrParse("expected number")
  } else {
    let c = s |> string_char_code_at(i)
    if c |> eq('-') {
      let start = i |> add(1)
      if start |> lt(s |> string_length) |> not {
        ErrParse("expected number")
      } else if s |> string_char_code_at(start) |> is_digit |> not {
        ErrParse("expected number")
      } else {
        match s |> parse_digits(start, 0) {
          OkInt(value, next) => Ok(JNum(sub(0, value)), next)
          ErrInt(msg) => ErrParse(msg)
        }
      }
    } else if is_digit(c) {
      match s |> parse_digits(i, 0) {
        OkInt(value, next) => Ok(JNum(value), next)
        ErrInt(msg) => ErrParse(msg)
      }
    } else {
      ErrParse("expected number")
    }
  }
}

let rec parse_value = fn (s: String, i: Int) -> Parse with {Error} {
  let parse_array = fn (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = s |> string_length
      let idx = s |> skip_ws(i |> add(1))
      if idx |> lt(len) |> and(s |> string_char_code_at(idx) |> eq(']')) {
        Ok(JArr(array_builder_freeze(array_builder())), idx |> add(1))
      } else {
        let builder = array_builder()
        let rec parse_items = fn (s: String, i: Int) -> Parse with {Error} {
          match s |> parse_value(i) {
            Ok(value, next) => {
              array_builder_push(builder, value)
              let next_idx = s |> skip_ws(next)
              if next_idx |> lt(len) |> and(
                s |> string_char_code_at(next_idx) |> eq(',')
              ) {
                s |> parse_items(next_idx |> add(1))
              } else if next_idx |> lt(len) |> and(
                s |> string_char_code_at(next_idx) |> eq(']')
              ) {
                Ok(JArr(array_builder_freeze(builder)), next_idx |> add(1))
              } else {
                ErrParse("expected , or ]")
              }
            }
            ErrParse(msg) => ErrParse(msg)
          }
        }
        s |> parse_items(idx)
      }
    }
  }

  let parse_object = fn (s: String, i: Int) -> Parse with {Error} {
    do {
      let len = s |> string_length
      let idx = s |> skip_ws(i |> add(1))
      if idx |> lt(len) |> and(s |> string_char_code_at(idx) |> eq('}')) {
        Ok(JObj(map_builder_freeze(map_builder())), idx |> add(1))
      } else {
        let builder = map_builder()
        let rec parse_members = fn (s: String, i: Int) -> Parse with {Error} {
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
                    if next_idx |> lt(len) |> and(
                      s |> string_char_code_at(next_idx) |> eq(',')
                    ) {
                      s |> parse_members(next_idx |> add(1))
                    } else if next_idx |> lt(len) |> and(
                      s |> string_char_code_at(next_idx) |> eq('}')
                    ) {
                      Ok(JObj(map_builder_freeze(builder)), next_idx |> add(1))
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

let parse = fn (s: String) -> Parse with {Error} {
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

let input = "{\"name\":\"xsh\",\"nums\":[1,2,3],\"ok\":true,\"meta\":null}"

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
                  let n0_ok = match arr |> array_get(0) { JNum(n) => n |> eq(1) _ => false }
                  let n1_ok = match arr |> array_get(1) { JNum(n) => n |> eq(2) _ => false }
                  let n2_ok = match arr |> array_get(2) { JNum(n) => n |> eq(3) _ => false }
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
