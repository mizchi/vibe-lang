///|
fn eval_string_builtin(
  name : String,
  args : Array[@core.Value],
) -> @core.Value? raise EvalError {
  match name {
    "String::length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E(
            "String::length: expected 1 argument, got " +
            args.length().to_string(),
          ),
        )
      }
      match args[0] {
        @core.Value::String(s) =>
          Some(@core.Value::Int(String::length(s).to_int64()))
        _ as v =>
          raise EvalError::BadCall(
            E("String::length: got " + value_type_name(v)),
          )
      }
    }
    "String::utf8_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::utf8_length"))
      }
      match args[0] {
        @core.Value::String(s) =>
          Some(@core.Value::Int(string_utf8_length(s).to_int64()))
        _ => raise EvalError::BadCall(E("String::utf8_length"))
      }
    }
    "String::utf16_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::utf16_length"))
      }
      match args[0] {
        @core.Value::String(s) =>
          Some(@core.Value::Int(string_utf16_length(s).to_int64()))
        _ => raise EvalError::BadCall(E("String::utf16_length"))
      }
    }
    "String::unicode_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::unicode_length"))
      }
      match args[0] {
        @core.Value::String(s) =>
          Some(@core.Value::Int(string_unicode_length(s).to_int64()))
        _ => raise EvalError::BadCall(E("String::unicode_length"))
      }
    }
    "String::char_code_at" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::char_code_at"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::Int(index)) => {
          if index < 0L || index >= String::length(s).to_int64() {
            raise EvalError::BadCall(E("String::char_code_at"))
          }
          let code = String::code_unit_at(s, index.to_int())
          Some(@core.Value::Int(UInt16::to_int(code).to_int64()))
        }
        _ => raise EvalError::BadCall(E("String::char_code_at"))
      }
    }
    "String::substring" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("String::substring"))
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::String(s), @core.Value::Int(start), @core.Value::Int(end)) => {
          let len = String::length(s).to_int64()
          let mut a = start
          let mut b = end
          if a < 0L {
            a = 0L
          }
          if b < 0L {
            b = 0L
          }
          if a > len {
            a = len
          }
          if b > len {
            b = len
          }
          let (from, to) = if a <= b { (a, b) } else { (b, a) }
          Some(
            @core.Value::String(
              String::unsafe_substring(s, start=from.to_int(), end=to.to_int()),
            ),
          )
        }
        _ => raise EvalError::BadCall(E("String::substring"))
      }
    }
    "String::concat" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E(
            "String::concat: expected 2 arguments, got " +
            args.length().to_string(),
          ),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          Some(@core.Value::String(String::add(a, b)))
        _ =>
          raise EvalError::BadCall(
            E(
              "String::concat: expected (String, String), got (" +
              value_type_name(args[0]) +
              ", " +
              value_type_name(args[1]) +
              ")",
            ),
          )
      }
    }
    "String::equals" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::equals"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          Some(@core.Value::Bool(String::equal(a, b)))
        _ => raise EvalError::BadCall(E("String::equals"))
      }
    }
    "String::split" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::split"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sep)) => {
          let parts : Array[@core.Value] = []
          for part in String::split(s, sep[:]) {
            parts.push(@core.Value::String(part.to_string()))
          }
          Some(@core.Value::Array(parts))
        }
        _ => raise EvalError::BadCall(E("String::split"))
      }
    }
    "String::index_of" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::index_of"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          match String::find(s, sub[:]) {
            Some(idx) => Some(@core.Value::Int(idx.to_int64()))
            None => Some(@core.Value::Int(-1L))
          }
        _ => raise EvalError::BadCall(E("String::index_of"))
      }
    }
    "String::contains" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::contains"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          Some(@core.Value::Bool(String::contains(s, sub[:])))
        _ => raise EvalError::BadCall(E("String::contains"))
      }
    }
    "String::trim" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::trim"))
      }
      match args[0] {
        @core.Value::String(s) => Some(@core.Value::String(trim_whitespace(s)))
        _ => raise EvalError::BadCall(E("String::trim"))
      }
    }
    "String::from_char_code" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::from_char_code"))
      }
      match args[0] {
        @core.Value::Int(code) =>
          if code < 0L || code > 1114111L {
            raise EvalError::BadCall(E("String::from_char_code"))
          } else {
            match Int::to_char(code.to_int()) {
              Some(ch) => Some(@core.Value::String(ch.to_string()))
              None => raise EvalError::BadCall(E("String::from_char_code"))
            }
          }
        _ => raise EvalError::BadCall(E("String::from_char_code"))
      }
    }
    "String::join" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::join"))
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::String(sep)) => {
          let buf = StringBuilder::new()
          for i, item in items {
            if i > 0 {
              buf.write_string(sep)
            }
            match item {
              @core.Value::String(s) => buf.write_string(s)
              _ => raise EvalError::BadCall(E("String::join"))
            }
          }
          Some(@core.Value::String(buf.to_string()))
        }
        _ => raise EvalError::BadCall(E("String::join"))
      }
    }
    "String::starts_with" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::starts_with"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(prefix)) =>
          Some(@core.Value::Bool(String::has_prefix(s, prefix[:])))
        _ => raise EvalError::BadCall(E("String::starts_with"))
      }
    }
    "String::ends_with" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::ends_with"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(suffix)) =>
          Some(@core.Value::Bool(String::has_suffix(s, suffix[:])))
        _ => raise EvalError::BadCall(E("String::ends_with"))
      }
    }
    "String::replace" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("String::replace"))
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::String(s),
          @core.Value::String(pattern),
          @core.Value::String(replacement),
        ) =>
          match String::find(s, pattern[:]) {
            None => Some(@core.Value::String(s))
            Some(idx) => {
              let before = String::unsafe_substring(s, start=0, end=idx)
              let after = String::unsafe_substring(
                s,
                start=idx + pattern.length(),
                end=s.length(),
              )
              Some(@core.Value::String(before + replacement + after))
            }
          }
        _ => raise EvalError::BadCall(E("String::replace"))
      }
    }
    "String::replace_all" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("String::replace_all"))
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::String(s),
          @core.Value::String(pattern),
          @core.Value::String(replacement),
        ) =>
          if pattern.length() == 0 {
            Some(@core.Value::String(s))
          } else {
            Some(
              @core.Value::String(
                String::replace_all(s, old=pattern[:], new=replacement[:]),
              ),
            )
          }
        _ => raise EvalError::BadCall(E("String::replace_all"))
      }
    }
    "String::trim_start" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::trim_start"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let len = s.length()
          let mut start = 0
          while start < len &&
                is_whitespace(s.unsafe_get(start).to_int().unsafe_to_char()) {
            start = start + 1
          }
          if start == 0 {
            Some(@core.Value::String(s))
          } else {
            Some(
              @core.Value::String(String::unsafe_substring(s, start~, end=len)),
            )
          }
        }
        _ => raise EvalError::BadCall(E("String::trim_start"))
      }
    }
    "String::trim_end" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::trim_end"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let len = s.length()
          let mut end = len
          while end > 0 &&
                is_whitespace(s.unsafe_get(end - 1).to_int().unsafe_to_char()) {
            end = end - 1
          }
          if end == len {
            Some(@core.Value::String(s))
          } else {
            Some(
              @core.Value::String(String::unsafe_substring(s, start=0, end~)),
            )
          }
        }
        _ => raise EvalError::BadCall(E("String::trim_end"))
      }
    }
    "String::last_index_of" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::last_index_of"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) => {
          let s_len = s.length()
          let sub_len = sub.length()
          if sub_len > s_len {
            Some(@core.Value::Int(-1L))
          } else if sub_len == 0 {
            Some(@core.Value::Int(s_len.to_int64()))
          } else {
            let mut i = s_len - sub_len
            let mut found = -1L
            while i >= 0 {
              if String::has_prefix(
                  String::unsafe_substring(s, start=i, end=i + sub_len),
                  sub[:],
                ) {
                found = i.to_int64()
                break
              }
              i = i - 1
            }
            Some(@core.Value::Int(found))
          }
        }
        _ => raise EvalError::BadCall(E("String::last_index_of"))
      }
    }
    "String::count" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("String::count"))
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) => {
          let s_len = s.length()
          let sub_len = sub.length()
          if sub_len == 0 || sub_len > s_len {
            Some(@core.Value::Int(0L))
          } else {
            let mut count = 0L
            let mut i = 0
            while i <= s_len - sub_len {
              if String::has_prefix(
                  String::unsafe_substring(s, start=i, end=i + sub_len),
                  sub[:],
                ) {
                count = count + 1L
                i = i + sub_len
              } else {
                i = i + 1
              }
            }
            Some(@core.Value::Int(count))
          }
        }
        _ => raise EvalError::BadCall(E("String::count"))
      }
    }
    "String::to_upper" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::to_upper"))
      }
      match args[0] {
        @core.Value::String(s) => Some(@core.Value::String(s.to_upper()))
        _ => raise EvalError::BadCall(E("String::to_upper"))
      }
    }
    "String::to_lower" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("String::to_lower"))
      }
      match args[0] {
        @core.Value::String(s) => Some(@core.Value::String(s.to_lower()))
        _ => raise EvalError::BadCall(E("String::to_lower"))
      }
    }
    _ => None
  }
}
