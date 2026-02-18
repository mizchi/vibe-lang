///|
fn is_pure_builtin(name : String) -> Bool {
  name == "path" ||
  name == "path_ref" ||
  name == "path_to_string" ||
  name == "path_is_absolute" ||
  name == "addr" ||
  name == "array_length" ||
  name == "array_get" ||
  name == "map_get" ||
  name == "string_length" ||
  name == "string_char_code_at" ||
  name == "string_substring" ||
  name == "string_concat" ||
  name == "string_equals" ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__mod" ||
  name == "__index" ||
  name == "__set_index" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__neg" ||
  name == "__assert" ||
  name == "record_set" ||
  name == "map_keys" ||
  name == "map_values" ||
  name == "map_has_key" ||
  name == "array_slice" ||
  name == "int_to_float" ||
  name == "int_to_double" ||
  name == "float_to_int" ||
  name == "float_to_double" ||
  name == "double_to_int" ||
  name == "double_to_float" ||
  name == "__to_string" ||
  name == "string_split" ||
  name == "string_index_of" ||
  name == "string_contains" ||
  name == "string_trim" ||
  name == "string_from_char_code" ||
  name == "char_to_int" ||
  name == "char_from_int" ||
  name == "string_utf8_length" ||
  name == "string_utf16_length" ||
  name == "string_unicode_length" ||
  name == "__lshift" ||
  name == "__rshift" ||
  name == "__bit_and" ||
  name == "__bit_or" ||
  name == "__bit_xor" ||
  name == "string_join" ||
  name == "from_lines" ||
  name == "to_lines" ||
  name == "to_json" ||
  name == "from_json" ||
  name == "to_jsonl" ||
  name == "from_jsonl" ||
  name == "json_type" ||
  name == "json_get" ||
  name == "json_index" ||
  name == "json_string" ||
  name == "json_number" ||
  name == "json_bool" ||
  name == "json_is_null" ||
  name == "json_length" ||
  name == "json_keys" ||
  name == "string_starts_with" ||
  name == "string_ends_with" ||
  name == "string_replace" ||
  name == "string_replace_all" ||
  name == "string_trim_start" ||
  name == "string_trim_end" ||
  name == "string_last_index_of" ||
  name == "string_count" ||
  name == "int_abs" ||
  name == "int_max" ||
  name == "int_min" ||
  name == "int_clamp" ||
  name == "int_signum" ||
  name == "int_is_even" ||
  name == "int_is_odd" ||
  name == "double_abs" ||
  name == "double_max" ||
  name == "double_min" ||
  name == "double_floor" ||
  name == "double_ceil" ||
  name == "prompt_text" ||
  name == "prompt_text_to_string" ||
  name == "select" ||
  name == "string_to_upper" ||
  name == "string_to_lower"
}

///|
fn eval_pure_builtin(
  name : String,
  args : Array[@core.Value],
) -> @core.Value raise EvalError {
  match name {
    "path" | "path_ref" => {
      let builtin_name = name
      if args.length() != 1 {
        raise EvalError::BadCall(builtin_name)
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Path(@core.Path::new(s))
        _ => raise EvalError::BadCall(builtin_name)
      }
    }
    "path_to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall("path_to_string")
      }
      match args[0] {
        @core.Value::Path(p) => @core.Value::String(p.as_string())
        _ => raise EvalError::BadCall("path_to_string")
      }
    }
    "path_is_absolute" => {
      if args.length() != 1 {
        raise EvalError::BadCall("path_is_absolute")
      }
      match args[0] {
        @core.Value::Path(p) => @core.Value::Bool(p.as_string().has_prefix("/"))
        _ => raise EvalError::BadCall("path_is_absolute")
      }
    }
    "array_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("array_length")
      }
      match args[0] {
        @core.Value::Array(items) => @core.Value::Int(items.length().to_int64())
        _ => raise EvalError::BadCall("array_length")
      }
    }
    "array_get" => {
      if args.length() != 2 {
        raise EvalError::BadCall("array_get")
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall("array_get")
          }
          items[index.to_int()]
        }
        _ => raise EvalError::BadCall("array_get")
      }
    }
    "map_get" => {
      if args.length() != 2 {
        raise EvalError::BadCall("map_get")
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          match items.get(key) {
            Some(value) => value
            None => raise EvalError::BadCall("map_get")
          }
        _ => raise EvalError::BadCall("map_get")
      }
    }
    "string_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_length")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Int(String::length(s).to_int64())
        _ => raise EvalError::BadCall("string_length")
      }
    }
    "string_utf8_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_utf8_length")
      }
      match args[0] {
        @core.Value::String(s) =>
          @core.Value::Int(string_utf8_length(s).to_int64())
        _ => raise EvalError::BadCall("string_utf8_length")
      }
    }
    "string_utf16_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_utf16_length")
      }
      match args[0] {
        @core.Value::String(s) =>
          @core.Value::Int(string_utf16_length(s).to_int64())
        _ => raise EvalError::BadCall("string_utf16_length")
      }
    }
    "string_unicode_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_unicode_length")
      }
      match args[0] {
        @core.Value::String(s) =>
          @core.Value::Int(string_unicode_length(s).to_int64())
        _ => raise EvalError::BadCall("string_unicode_length")
      }
    }
    "string_char_code_at" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_char_code_at")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::Int(index)) => {
          if index < 0L || index >= String::length(s).to_int64() {
            raise EvalError::BadCall("string_char_code_at")
          }
          let code = String::code_unit_at(s, index.to_int())
          @core.Value::Int(UInt16::to_int(code).to_int64())
        }
        _ => raise EvalError::BadCall("string_char_code_at")
      }
    }
    "string_substring" => {
      if args.length() != 3 {
        raise EvalError::BadCall("string_substring")
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
          @core.Value::String(
            String::unsafe_substring(s, start=from.to_int(), end=to.to_int()),
          )
        }
        _ => raise EvalError::BadCall("string_substring")
      }
    }
    "string_concat" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_concat")
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::String(String::add(a, b))
        _ => raise EvalError::BadCall("string_concat")
      }
    }
    "string_equals" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_equals")
      }
      match (args[0], args[1]) {
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::Bool(String::equal(a, b))
        _ => raise EvalError::BadCall("string_equals")
      }
    }
    "string_split" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_split")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sep)) => {
          let parts : Array[@core.Value] = []
          for part in String::split(s, sep[:]) {
            parts.push(@core.Value::String(part.to_string()))
          }
          @core.Value::Array(parts)
        }
        _ => raise EvalError::BadCall("string_split")
      }
    }
    "string_index_of" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_index_of")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          match String::find(s, sub[:]) {
            Some(idx) => @core.Value::Int(idx.to_int64())
            None => @core.Value::Int(-1L)
          }
        _ => raise EvalError::BadCall("string_index_of")
      }
    }
    "string_contains" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_contains")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) =>
          @core.Value::Bool(String::contains(s, sub[:]))
        _ => raise EvalError::BadCall("string_contains")
      }
    }
    "string_trim" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_trim")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(trim_whitespace(s))
        _ => raise EvalError::BadCall("string_trim")
      }
    }
    "string_from_char_code" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_from_char_code")
      }
      match args[0] {
        @core.Value::Int(code) =>
          if code < 0L || code > 1114111L {
            raise EvalError::BadCall("string_from_char_code")
          } else {
            match Int::to_char(code.to_int()) {
              Some(ch) => @core.Value::String(ch.to_string())
              None => raise EvalError::BadCall("string_from_char_code")
            }
          }
        _ => raise EvalError::BadCall("string_from_char_code")
      }
    }
    "char_to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("char_to_int")
      }
      match args[0] {
        @core.Value::Char(ch) => @core.Value::Int(ch.to_int().to_int64())
        _ => raise EvalError::BadCall("char_to_int")
      }
    }
    "char_from_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("char_from_int")
      }
      match args[0] {
        @core.Value::Int(code) =>
          if code < 0L || code > 1114111L {
            raise EvalError::BadCall("char_from_int")
          } else {
            match Int::to_char(code.to_int()) {
              Some(ch) => @core.Value::Char(ch)
              None => raise EvalError::BadCall("char_from_int")
            }
          }
        _ => raise EvalError::BadCall("char_from_int")
      }
    }
    "__add" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__add")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a + b)
        (@core.Value::Int(a), @core.Value::Char(b)) =>
          @core.Value::Int(a + b.to_int().to_int64())
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          @core.Value::Int(a.to_int().to_int64() + b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a + b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a + b)
        _ => raise EvalError::BadCall("__add")
      }
    }
    "__sub" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__sub")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a - b)
        (@core.Value::Int(a), @core.Value::Char(b)) =>
          @core.Value::Int(a - b.to_int().to_int64())
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          @core.Value::Int(a.to_int().to_int64() - b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a - b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a - b)
        _ => raise EvalError::BadCall("__sub")
      }
    }
    "__mul" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__mul")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a * b)
        (@core.Value::Int(a), @core.Value::Char(b)) =>
          @core.Value::Int(a * b.to_int().to_int64())
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          @core.Value::Int(a.to_int().to_int64() * b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a * b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a * b)
        _ => raise EvalError::BadCall("__mul")
      }
    }
    "__div" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__div")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__div")
          } else {
            @core.Value::Int(a / b)
          }
        (@core.Value::Int(a), @core.Value::Char(b)) => {
          let bv = b.to_int().to_int64()
          if bv == 0 {
            raise EvalError::BadCall("__div")
          } else {
            @core.Value::Int(a / bv)
          }
        }
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__div")
          } else {
            @core.Value::Int(a.to_int().to_int64() / b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a / b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a / b)
        _ => raise EvalError::BadCall("__div")
      }
    }
    "__mod" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__mod")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__mod")
          } else {
            @core.Value::Int(a % b)
          }
        (@core.Value::Int(a), @core.Value::Char(b)) => {
          let bv = b.to_int().to_int64()
          if bv == 0 {
            raise EvalError::BadCall("__mod")
          } else {
            @core.Value::Int(a % bv)
          }
        }
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall("__mod")
          } else {
            @core.Value::Int(a.to_int().to_int64() % b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(Float::mod(a, b))
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(Double::mod(a, b))
        _ => raise EvalError::BadCall("__mod")
      }
    }
    "__index" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__index")
      }
      match (args[0], args[1]) {
        (@core.Value::Array(arr), @core.Value::Int(i)) =>
          if i >= 0L && i < arr.length().to_int64() {
            arr[i.to_int()]
          } else {
            raise EvalError::BadCall("__index: out of bounds")
          }
        (@core.Value::Record(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        (@core.Value::Map(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        (@core.Value::MapBuilder(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall("__index: missing key")
          }
        _ => raise EvalError::BadCall("__index")
      }
    }
    "__set_index" => {
      if args.length() != 3 {
        raise EvalError::BadCall("__set_index")
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::Array(arr), @core.Value::Int(i), value) =>
          if i >= 0L && i < arr.length().to_int64() {
            arr[i.to_int()] = value
            value
          } else {
            raise EvalError::BadCall("__set_index: out of bounds")
          }
        (@core.Value::Record(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        (@core.Value::Map(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        (@core.Value::MapBuilder(map), @core.Value::String(key), value) => {
          map[key] = value
          value
        }
        _ => raise EvalError::BadCall("__set_index")
      }
    }
    "__eq" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__eq")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Bool(a == b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::Bool(a), @core.Value::Bool(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::Char(a), @core.Value::Char(b)) =>
          @core.Value::Bool(a == b)
        (@core.Value::Int(a), @core.Value::Char(b)) =>
          @core.Value::Bool(a == b.to_int().to_int64())
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          @core.Value::Bool(a.to_int().to_int64() == b)
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::Bool(a == b)
        _ => raise EvalError::BadCall("__eq")
      }
    }
    "__lt" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__lt")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Bool(a < b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Bool(a < b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Bool(a < b)
        (@core.Value::Char(a), @core.Value::Char(b)) => @core.Value::Bool(a < b)
        (@core.Value::Int(a), @core.Value::Char(b)) =>
          @core.Value::Bool(a < b.to_int().to_int64())
        (@core.Value::Char(a), @core.Value::Int(b)) =>
          @core.Value::Bool(a.to_int().to_int64() < b)
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::Bool(String::compare(a, b) < 0)
        _ => raise EvalError::BadCall("__lt")
      }
    }
    "__neg" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__neg")
      }
      match args[0] {
        @core.Value::Int(a) => @core.Value::Int(-a)
        @core.Value::Float(a) => @core.Value::Float(-a)
        @core.Value::Double(a) => @core.Value::Double(-a)
        _ => raise EvalError::BadCall("__neg")
      }
    }
    "__lshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__lshift")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(a << b.to_int())
        _ => raise EvalError::BadCall("__lshift")
      }
    }
    "__rshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__rshift")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(a >> b.to_int())
        _ => raise EvalError::BadCall("__rshift")
      }
    }
    "__bit_and" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_and")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a & b)
        _ => raise EvalError::BadCall("__bit_and")
      }
    }
    "__bit_or" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_or")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a | b)
        _ => raise EvalError::BadCall("__bit_or")
      }
    }
    "__bit_xor" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__bit_xor")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a ^ b)
        _ => raise EvalError::BadCall("__bit_xor")
      }
    }
    "__assert" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__assert")
      }
      match args[0] {
        @core.Value::Bool(b) =>
          if b {
            @core.Value::Unit
          } else {
            raise EvalError::BadCall("assert")
          }
        _ => raise EvalError::BadCall("__assert")
      }
    }
    "record_set" => {
      if args.length() != 3 {
        raise EvalError::BadCall("record_set")
      }
      match (args[0], args[1]) {
        (@core.Value::Record(map), @core.Value::String(name)) => {
          if not(map.contains(name)) {
            raise EvalError::BadCall("record_set")
          }
          let out : Map[String, @core.Value] = {}
          for k, v in map {
            out[k] = v
          }
          out[name] = args[2]
          @core.Value::Record(out)
        }
        _ => raise EvalError::BadCall("record_set")
      }
    }
    "map_keys" => {
      if args.length() != 1 {
        raise EvalError::BadCall("map_keys")
      }
      match args[0] {
        @core.Value::Map(items) => {
          let keys : Array[@core.Value] = []
          for k, _ in items {
            keys.push(@core.Value::String(k))
          }
          @core.Value::Array(keys)
        }
        _ => raise EvalError::BadCall("map_keys")
      }
    }
    "map_values" => {
      if args.length() != 1 {
        raise EvalError::BadCall("map_values")
      }
      match args[0] {
        @core.Value::Map(items) => {
          let values : Array[@core.Value] = []
          for _, v in items {
            values.push(v)
          }
          @core.Value::Array(values)
        }
        _ => raise EvalError::BadCall("map_values")
      }
    }
    "map_has_key" => {
      if args.length() != 2 {
        raise EvalError::BadCall("map_has_key")
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          @core.Value::Bool(items.contains(key))
        _ => raise EvalError::BadCall("map_has_key")
      }
    }
    "array_slice" => {
      if args.length() != 3 {
        raise EvalError::BadCall("array_slice")
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::Array(items),
          @core.Value::Int(start),
          @core.Value::Int(end),
        ) => {
          let len = items.length().to_int64()
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
          if a > b {
            a = b
          }
          let out : Array[@core.Value] = []
          for i in a.to_int()..<b.to_int() {
            out.push(items[i])
          }
          @core.Value::Array(out)
        }
        _ => raise EvalError::BadCall("array_slice")
      }
    }
    "int_to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_to_float")
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Float(Float::from_int(n.to_int()))
        _ => raise EvalError::BadCall("int_to_float")
      }
    }
    "int_to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_to_double")
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Double(n.to_double())
        _ => raise EvalError::BadCall("int_to_double")
      }
    }
    "float_to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("float_to_int")
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Int(f.to_int().to_int64())
        _ => raise EvalError::BadCall("float_to_int")
      }
    }
    "float_to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall("float_to_double")
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Double(f.to_double())
        _ => raise EvalError::BadCall("float_to_double")
      }
    }
    "double_to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_to_int")
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Int(d.to_int().to_int64())
        _ => raise EvalError::BadCall("double_to_int")
      }
    }
    "double_to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_to_float")
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Float(Float::from_double(d))
        _ => raise EvalError::BadCall("double_to_float")
      }
    }
    "__to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall("__to_string")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s)
        @core.Value::Int(n) => @core.Value::String(n.to_string())
        @core.Value::Float(f) => @core.Value::String(f.to_string())
        @core.Value::Double(d) => @core.Value::String(d.to_string())
        @core.Value::Bool(b) =>
          @core.Value::String(if b { "true" } else { "false" })
        @core.Value::Char(c) => @core.Value::String(c.to_string())
        @core.Value::Unit => @core.Value::String("()")
        _ => raise EvalError::BadCall("__to_string")
      }
    }
    "string_join" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_join")
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
              _ => raise EvalError::BadCall("string_join")
            }
          }
          @core.Value::String(buf.to_string())
        }
        _ => raise EvalError::BadCall("string_join")
      }
    }
    "from_lines" => {
      if args.length() != 1 {
        raise EvalError::BadCall("from_lines")
      }
      match args[0] {
        @core.Value::String(s) => {
          let parts : Array[@core.Value] = []
          for part in String::split(s, "\n") {
            parts.push(@core.Value::String(part.to_string()))
          }
          @core.Value::Array(parts)
        }
        _ => raise EvalError::BadCall("from_lines")
      }
    }
    "to_lines" => {
      if args.length() != 1 {
        raise EvalError::BadCall("to_lines")
      }
      match args[0] {
        @core.Value::Array(items) => {
          let buf = StringBuilder::new()
          for i, item in items {
            if i > 0 {
              buf.write_char('\n')
            }
            match item {
              @core.Value::String(s) => buf.write_string(s)
              _ => raise EvalError::BadCall("to_lines")
            }
          }
          @core.Value::String(buf.to_string())
        }
        _ => raise EvalError::BadCall("to_lines")
      }
    }
    "to_json" => {
      if args.length() != 1 {
        raise EvalError::BadCall("to_json")
      }
      @core.Value::String(value_to_json_string(args[0]))
    }
    "from_json" => {
      if args.length() != 1 {
        raise EvalError::BadCall("from_json")
      }
      match args[0] {
        @core.Value::String(s) => parse_json_value(s)
        _ => raise EvalError::BadCall("from_json")
      }
    }
    "to_jsonl" => {
      if args.length() != 1 {
        raise EvalError::BadCall("to_jsonl")
      }
      match args[0] {
        @core.Value::Array(items) => {
          let buf = StringBuilder::new()
          for i, item in items {
            if i > 0 {
              buf.write_char('\n')
            }
            buf.write_string(value_to_json_string(item))
          }
          @core.Value::String(buf.to_string())
        }
        _ => raise EvalError::BadCall("to_jsonl")
      }
    }
    "from_jsonl" => {
      if args.length() != 1 {
        raise EvalError::BadCall("from_jsonl")
      }
      match args[0] {
        @core.Value::String(s) => {
          let result : Array[@core.Value] = []
          for line in String::split(s, "\n") {
            let trimmed = trim_whitespace(line.to_string())
            if trimmed.length() > 0 {
              result.push(parse_json_value(trimmed))
            }
          }
          @core.Value::Array(result)
        }
        _ => raise EvalError::BadCall("from_jsonl")
      }
    }
    "json_type" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_type")
      }
      let type_name = match args[0] {
        @core.Value::Unit => "null"
        @core.Value::Bool(_) => "bool"
        @core.Value::Int(_) | @core.Value::Double(_) | @core.Value::Float(_) =>
          "number"
        @core.Value::String(_) => "string"
        @core.Value::Array(_) => "array"
        @core.Value::Map(_) => "object"
        _ => raise EvalError::BadCall("json_type")
      }
      @core.Value::String(type_name)
    }
    "json_get" => {
      if args.length() != 2 {
        raise EvalError::BadCall("json_get")
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          match items.get(key) {
            Some(value) => value
            None => raise EvalError::BadCall("json_get: missing key: " + key)
          }
        _ => raise EvalError::BadCall("json_get")
      }
    }
    "json_index" => {
      if args.length() != 2 {
        raise EvalError::BadCall("json_index")
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall("json_index: out of bounds")
          }
          items[index.to_int()]
        }
        _ => raise EvalError::BadCall("json_index")
      }
    }
    "json_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_string")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s)
        _ => raise EvalError::BadCall("json_string: not a string")
      }
    }
    "json_number" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_number")
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Double(d)
        @core.Value::Int(n) => @core.Value::Double(n.to_double())
        @core.Value::Float(f) => @core.Value::Double(f.to_double())
        _ => raise EvalError::BadCall("json_number: not a number")
      }
    }
    "json_bool" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_bool")
      }
      match args[0] {
        @core.Value::Bool(b) => @core.Value::Bool(b)
        _ => raise EvalError::BadCall("json_bool: not a bool")
      }
    }
    "json_is_null" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_is_null")
      }
      @core.Value::Bool(args[0] is @core.Value::Unit)
    }
    "json_length" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_length")
      }
      match args[0] {
        @core.Value::Array(items) => @core.Value::Int(items.length().to_int64())
        @core.Value::Map(items) => @core.Value::Int(items.length().to_int64())
        @core.Value::String(s) => @core.Value::Int(s.length().to_int64())
        _ => raise EvalError::BadCall("json_length")
      }
    }
    "json_keys" => {
      if args.length() != 1 {
        raise EvalError::BadCall("json_keys")
      }
      match args[0] {
        @core.Value::Map(items) => {
          let keys : Array[@core.Value] = []
          for k, _ in items {
            keys.push(@core.Value::String(k))
          }
          @core.Value::Array(keys)
        }
        _ => raise EvalError::BadCall("json_keys")
      }
    }
    "string_starts_with" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_starts_with")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(prefix)) =>
          @core.Value::Bool(String::has_prefix(s, prefix[:]))
        _ => raise EvalError::BadCall("string_starts_with")
      }
    }
    "string_ends_with" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_ends_with")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(suffix)) =>
          @core.Value::Bool(String::has_suffix(s, suffix[:]))
        _ => raise EvalError::BadCall("string_ends_with")
      }
    }
    "string_replace" => {
      if args.length() != 3 {
        raise EvalError::BadCall("string_replace")
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::String(s),
          @core.Value::String(pattern),
          @core.Value::String(replacement),
        ) =>
          match String::find(s, pattern[:]) {
            None => @core.Value::String(s)
            Some(idx) => {
              let before = String::unsafe_substring(s, start=0, end=idx)
              let after = String::unsafe_substring(
                s,
                start=idx + pattern.length(),
                end=s.length(),
              )
              @core.Value::String(before + replacement + after)
            }
          }
        _ => raise EvalError::BadCall("string_replace")
      }
    }
    "string_replace_all" => {
      if args.length() != 3 {
        raise EvalError::BadCall("string_replace_all")
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::String(s),
          @core.Value::String(pattern),
          @core.Value::String(replacement),
        ) =>
          if pattern.length() == 0 {
            @core.Value::String(s)
          } else {
            @core.Value::String(
              String::replace(s, old=pattern[:], new=replacement[:]),
            )
          }
        _ => raise EvalError::BadCall("string_replace_all")
      }
    }
    "string_trim_start" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_trim_start")
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
            @core.Value::String(s)
          } else {
            @core.Value::String(String::unsafe_substring(s, start~, end=len))
          }
        }
        _ => raise EvalError::BadCall("string_trim_start")
      }
    }
    "string_trim_end" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_trim_end")
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
            @core.Value::String(s)
          } else {
            @core.Value::String(String::unsafe_substring(s, start=0, end~))
          }
        }
        _ => raise EvalError::BadCall("string_trim_end")
      }
    }
    "string_last_index_of" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_last_index_of")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) => {
          let s_len = s.length()
          let sub_len = sub.length()
          if sub_len > s_len {
            @core.Value::Int(-1L)
          } else if sub_len == 0 {
            @core.Value::Int(s_len.to_int64())
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
            @core.Value::Int(found)
          }
        }
        _ => raise EvalError::BadCall("string_last_index_of")
      }
    }
    "string_count" => {
      if args.length() != 2 {
        raise EvalError::BadCall("string_count")
      }
      match (args[0], args[1]) {
        (@core.Value::String(s), @core.Value::String(sub)) => {
          let s_len = s.length()
          let sub_len = sub.length()
          if sub_len == 0 || sub_len > s_len {
            @core.Value::Int(0L)
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
            @core.Value::Int(count)
          }
        }
        _ => raise EvalError::BadCall("string_count")
      }
    }
    "int_abs" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_abs")
      }
      match args[0] {
        @core.Value::Int(x) =>
          if x < 0L {
            @core.Value::Int(-x)
          } else {
            @core.Value::Int(x)
          }
        _ => raise EvalError::BadCall("int_abs")
      }
    }
    "int_max" => {
      if args.length() != 2 {
        raise EvalError::BadCall("int_max")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(if a > b { a } else { b })
        _ => raise EvalError::BadCall("int_max")
      }
    }
    "int_min" => {
      if args.length() != 2 {
        raise EvalError::BadCall("int_min")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(if a < b { a } else { b })
        _ => raise EvalError::BadCall("int_min")
      }
    }
    "int_clamp" => {
      if args.length() != 3 {
        raise EvalError::BadCall("int_clamp")
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::Int(x), @core.Value::Int(lo), @core.Value::Int(hi)) =>
          @core.Value::Int(if x < lo { lo } else if x > hi { hi } else { x })
        _ => raise EvalError::BadCall("int_clamp")
      }
    }
    "int_signum" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_signum")
      }
      match args[0] {
        @core.Value::Int(x) =>
          @core.Value::Int(if x < 0L { -1L } else if x > 0L { 1L } else { 0L })
        _ => raise EvalError::BadCall("int_signum")
      }
    }
    "int_is_even" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_is_even")
      }
      match args[0] {
        @core.Value::Int(x) => @core.Value::Bool(x % 2L == 0L)
        _ => raise EvalError::BadCall("int_is_even")
      }
    }
    "int_is_odd" => {
      if args.length() != 1 {
        raise EvalError::BadCall("int_is_odd")
      }
      match args[0] {
        @core.Value::Int(x) => @core.Value::Bool(x % 2L != 0L)
        _ => raise EvalError::BadCall("int_is_odd")
      }
    }
    "double_abs" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_abs")
      }
      match args[0] {
        @core.Value::Double(x) =>
          @core.Value::Double(if x < 0.0 { -x } else { x })
        _ => raise EvalError::BadCall("double_abs")
      }
    }
    "double_max" => {
      if args.length() != 2 {
        raise EvalError::BadCall("double_max")
      }
      match (args[0], args[1]) {
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(if a > b { a } else { b })
        _ => raise EvalError::BadCall("double_max")
      }
    }
    "double_min" => {
      if args.length() != 2 {
        raise EvalError::BadCall("double_min")
      }
      match (args[0], args[1]) {
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(if a < b { a } else { b })
        _ => raise EvalError::BadCall("double_min")
      }
    }
    "double_floor" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_floor")
      }
      match args[0] {
        @core.Value::Double(x) => {
          let min_int_d = -2305843009213693952.0
          if x <= min_int_d {
            @core.Value::Double(min_int_d)
          } else {
            let i = x.to_int64()
            let d = i.to_double()
            if d > x {
              @core.Value::Double((i - 1L).to_double())
            } else {
              @core.Value::Double(d)
            }
          }
        }
        _ => raise EvalError::BadCall("double_floor")
      }
    }
    "double_ceil" => {
      if args.length() != 1 {
        raise EvalError::BadCall("double_ceil")
      }
      match args[0] {
        @core.Value::Double(x) => {
          let max_int_d = 2305843009213693951.0
          if x >= max_int_d {
            @core.Value::Double(max_int_d)
          } else {
            let i = x.to_int64()
            let d = i.to_double()
            if d < x {
              @core.Value::Double((i + 1L).to_double())
            } else {
              @core.Value::Double(d)
            }
          }
        }
        _ => raise EvalError::BadCall("double_ceil")
      }
    }
    "prompt_text" => {
      if args.length() != 1 {
        raise EvalError::BadCall("prompt_text")
      }
      match args[0] {
        @core.Value::String(s) =>
          @core.Value::PromptText(@core.PromptText::new(s))
        @core.Value::PromptText(_) as pt => pt
        _ => raise EvalError::BadCall("prompt_text")
      }
    }
    "prompt_text_to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall("prompt_text_to_string")
      }
      match args[0] {
        @core.Value::PromptText(pt) => @core.Value::String(pt.as_string())
        _ => raise EvalError::BadCall("prompt_text_to_string")
      }
    }
    "string_to_upper" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_to_upper")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s.to_upper())
        _ => raise EvalError::BadCall("string_to_upper")
      }
    }
    "string_to_lower" => {
      if args.length() != 1 {
        raise EvalError::BadCall("string_to_lower")
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s.to_lower())
        _ => raise EvalError::BadCall("string_to_lower")
      }
    }
    "select" => {
      if args.length() < 2 {
        raise EvalError::BadCall("select")
      }
      let field_names : Array[String] = []
      for i in 1..<args.length() {
        match args[i] {
          @core.Value::String(s) => field_names.push(s)
          _ => raise EvalError::BadCall("select")
        }
      }
      match args[0] {
        @core.Value::Record(map) => {
          let out : Map[String, @core.Value] = {}
          for name in field_names {
            match map.get(name) {
              Some(v) => out[name] = v
              None => raise EvalError::BadCall("select: missing field: " + name)
            }
          }
          @core.Value::Record(out)
        }
        @core.Value::Array(items) => {
          let result : Array[@core.Value] = []
          for item in items {
            match item {
              @core.Value::Record(map) => {
                let out : Map[String, @core.Value] = {}
                for name in field_names {
                  match map.get(name) {
                    Some(v) => out[name] = v
                    None =>
                      raise EvalError::BadCall("select: missing field: " + name)
                  }
                }
                result.push(@core.Value::Record(out))
              }
              _ => raise EvalError::BadCall("select")
            }
          }
          @core.Value::Array(result)
        }
        _ => raise EvalError::BadCall("select")
      }
    }
    _ => raise EvalError::BadCall(name)
  }
}

///|
fn string_utf16_unit_at(s : String, index : Int) -> Int {
  UInt16::to_int(String::code_unit_at(s, index))
}

///|
fn is_high_surrogate(code : Int) -> Bool {
  code >= 55296 && code <= 56319
}

///|
fn is_low_surrogate(code : Int) -> Bool {
  code >= 56320 && code <= 57343
}

///|
fn utf8_bytes_of_utf16_unit(code : Int) -> Int {
  if code <= 127 {
    1
  } else if code <= 2047 {
    2
  } else {
    3
  }
}

///|
fn string_utf16_length(s : String) -> Int {
  String::length(s)
}

///|
fn string_unicode_length(s : String) -> Int {
  let len16 = String::length(s)
  let mut i = 0
  let mut acc = 0
  while i < len16 {
    let unit0 = string_utf16_unit_at(s, i)
    if is_high_surrogate(unit0) && i + 1 < len16 {
      let unit1 = string_utf16_unit_at(s, i + 1)
      if is_low_surrogate(unit1) {
        i = i + 2
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
    acc = acc + 1
  }
  acc
}

///|
fn string_utf8_length(s : String) -> Int {
  let len16 = String::length(s)
  let mut i = 0
  let mut acc = 0
  while i < len16 {
    let unit0 = string_utf16_unit_at(s, i)
    if is_high_surrogate(unit0) && i + 1 < len16 {
      let unit1 = string_utf16_unit_at(s, i + 1)
      if is_low_surrogate(unit1) {
        i = i + 2
        acc = acc + 4
      } else {
        i = i + 1
        acc = acc + utf8_bytes_of_utf16_unit(unit0)
      }
    } else {
      i = i + 1
      acc = acc + utf8_bytes_of_utf16_unit(unit0)
    }
  }
  acc
}

///|
fn split_shell_args(cmd : String) -> Array[String] {
  let out : Array[String] = []
  let trimmed = trim_whitespace(cmd)
  for part in trimmed.split(" ") {
    let token = part.trim().to_string()
    if token.length() > 0 {
      out.push(token)
    }
  }
  out
}

///|
fn join_shell_args(parts : Array[String], start : Int) -> String {
  let out = StringBuilder::new()
  for i in start..<parts.length() {
    if i > start {
      out.write_char(' ')
    }
    out.write_string(parts[i])
  }
  out.to_string()
}

///|
fn execute_shell_lines(cmd : String) -> Array[String] raise EvalError {
  // Try host-backed execution first (native target)
  match @backend.exec_command_lines(cmd) {
    Ok(lines) => return lines
    Err(_) => () // fall through to deterministic fallback
  }
  // Deterministic fallback for non-native targets
  let parts = split_shell_args(cmd)
  if parts.length() == 0 {
    raise EvalError::BadCall("sh_lines")
  }
  match parts[0] {
    "ls" => {
      if parts.length() > 2 {
        raise EvalError::BadCall("sh_lines")
      }
      let dir = if parts.length() == 2 { parts[1] } else { "." }
      match @io.shell_ls_lines(dir) {
        Ok(lines) => lines
        Err(_) => raise EvalError::BadCall("sh_lines")
      }
    }
    "cat" => {
      if parts.length() != 2 {
        raise EvalError::BadCall("sh_lines")
      }
      match @io.shell_cat_lines(parts[1]) {
        Ok(lines) => lines
        Err(_) => raise EvalError::BadCall("sh_lines")
      }
    }
    "echo" =>
      if parts.length() <= 1 {
        [""]
      } else {
        [join_shell_args(parts, 1)]
      }
    _ => raise EvalError::BadCall("sh_lines")
  }
}

///|
fn pure_call_key(name : String, args : Array[@core.Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("pure:")
  buf.write_string(name)
  for arg in args {
    buf.write_char('\n')
    buf.write_string(value_hash(arg))
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn fn_call_key(addr : String, args : Array[@core.Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string("fn:")
  buf.write_string(addr)
  for arg in args {
    buf.write_char('\n')
    buf.write_string(value_hash(arg))
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn has_alias_prefix_rt(rt : Runtime, name : String) -> Bool {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  let buf = StringBuilder::new()
  for i in 0..<dot {
    buf.write_char(chars[i])
  }
  let prefix = buf.to_string()
  rt.get_alias(prefix) is Some(_)
}

///|
fn is_whitespace(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
fn trim_whitespace(s : String) -> String {
  let len = s.length()
  let mut start = 0
  while start < len &&
        is_whitespace(s.unsafe_get(start).to_int().unsafe_to_char()) {
    start = start + 1
  }
  let mut end = len
  while end > start &&
        is_whitespace(s.unsafe_get(end - 1).to_int().unsafe_to_char()) {
    end = end - 1
  }
  if start == 0 && end == len {
    s
  } else {
    s.unsafe_substring(start~, end~)
  }
}

///|
fn json_escape_string(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  let len = s.length()
  let mut i = 0
  while i < len {
    let ch = s.unsafe_get(i).to_int().unsafe_to_char()
    match ch {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      '\r' => buf.write_string("\\r")
      _ =>
        if ch.to_int() < 32 {
          buf.write_string("\\u")
          let code = ch.to_int()
          let hex = "0123456789abcdef"
          buf.write_char(
            hex.unsafe_get((code >> 12) & 15).to_int().unsafe_to_char(),
          )
          buf.write_char(
            hex.unsafe_get((code >> 8) & 15).to_int().unsafe_to_char(),
          )
          buf.write_char(
            hex.unsafe_get((code >> 4) & 15).to_int().unsafe_to_char(),
          )
          buf.write_char(hex.unsafe_get(code & 15).to_int().unsafe_to_char())
        } else {
          buf.write_char(ch)
        }
    }
    i = i + 1
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn value_to_json_string(value : @core.Value) -> String {
  let buf = StringBuilder::new()
  value_to_json_buf(value, buf)
  buf.to_string()
}

///|
fn value_to_json_buf(value : @core.Value, buf : StringBuilder) -> Unit {
  match value {
    @core.Value::Unit => buf.write_string("null")
    @core.Value::Bool(b) => buf.write_string(if b { "true" } else { "false" })
    @core.Value::Int(n) => buf.write_string(n.to_string())
    @core.Value::Double(d) =>
      if d == d.floor() && d.abs() < 1.0e15 {
        buf.write_string(d.to_int64().to_string())
      } else {
        buf.write_string(d.to_string())
      }
    @core.Value::Float(f) => buf.write_string(f.to_string())
    @core.Value::String(s) => buf.write_string(json_escape_string(s))
    @core.Value::Array(items) => {
      buf.write_char('[')
      for i, item in items {
        if i > 0 {
          buf.write_char(',')
        }
        value_to_json_buf(item, buf)
      }
      buf.write_char(']')
    }
    @core.Value::Map(fields) => {
      buf.write_char('{')
      let mut first = true
      for key, val in fields {
        if not(first) {
          buf.write_char(',')
        }
        first = false
        buf.write_string(json_escape_string(key))
        buf.write_char(':')
        value_to_json_buf(val, buf)
      }
      buf.write_char('}')
    }
    _ => buf.write_string("null")
  }
}

///|
fn parse_json_value(input : String) -> @core.Value raise EvalError {
  let state = JsonParser::{ input, pos: 0 }
  state.skip_ws()
  let result = state.parse_value()
  state.skip_ws()
  if state.pos != state.input.length() {
    raise EvalError::BadCall("from_json: unexpected trailing content")
  }
  result
}

///|
priv struct JsonParser {
  input : String
  mut pos : Int
}

///|
fn JsonParser::peek(self : JsonParser) -> Char {
  if self.pos >= self.input.length() {
    '\u0000'
  } else {
    self.input.unsafe_get(self.pos).to_int().unsafe_to_char()
  }
}

///|
fn JsonParser::advance(self : JsonParser) -> Char {
  let ch = self.peek()
  self.pos = self.pos + 1
  ch
}

///|
fn JsonParser::skip_ws(self : JsonParser) -> Unit {
  while self.pos < self.input.length() {
    let ch = self.input.unsafe_get(self.pos).to_int().unsafe_to_char()
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      self.pos = self.pos + 1
    } else {
      break
    }
  }
}

///|
fn JsonParser::expect(
  self : JsonParser,
  expected : String,
) -> Unit raise EvalError {
  let len = expected.length()
  if self.pos + len > self.input.length() {
    raise EvalError::BadCall("from_json: unexpected end of input")
  }
  for i in 0..<len {
    if self.input.unsafe_get(self.pos + i) != expected.unsafe_get(i) {
      raise EvalError::BadCall("from_json: unexpected character")
    }
  }
  self.pos = self.pos + len
}

///|
fn JsonParser::parse_value(self : JsonParser) -> @core.Value raise EvalError {
  self.skip_ws()
  let ch = self.peek()
  match ch {
    '"' => self.parse_string()
    't' => {
      self.expect("true")
      @core.Value::Bool(true)
    }
    'f' => {
      self.expect("false")
      @core.Value::Bool(false)
    }
    'n' => {
      self.expect("null")
      @core.Value::Unit
    }
    '[' => self.parse_array()
    '{' => self.parse_object()
    '-' | '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' =>
      self.parse_number()
    '\u0000' => raise EvalError::BadCall("from_json: unexpected end of input")
    _ =>
      raise EvalError::BadCall(
        "from_json: unexpected character: " + ch.to_string(),
      )
  }
}

///|
fn JsonParser::parse_string(self : JsonParser) -> @core.Value raise EvalError {
  let s = self.parse_string_raw()
  @core.Value::String(s)
}

///|
fn JsonParser::parse_string_raw(self : JsonParser) -> String raise EvalError {
  if self.advance() != '"' {
    raise EvalError::BadCall("from_json: expected '\"'")
  }
  let buf = StringBuilder::new()
  while true {
    if self.pos >= self.input.length() {
      raise EvalError::BadCall("from_json: unterminated string")
    }
    let ch = self.advance()
    if ch == '"' {
      break
    }
    if ch == '\\' {
      if self.pos >= self.input.length() {
        raise EvalError::BadCall("from_json: unterminated escape")
      }
      let esc = self.advance()
      match esc {
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        '/' => buf.write_char('/')
        'b' => buf.write_char('\u0008')
        'f' => buf.write_char('\u000C')
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
        'r' => buf.write_char('\r')
        'u' => {
          let code = self.parse_hex4()
          match Int::to_char(code) {
            Some(c) => buf.write_char(c)
            None => buf.write_char('\uFFFD')
          }
        }
        _ =>
          raise EvalError::BadCall(
            "from_json: invalid escape: \\" + esc.to_string(),
          )
      }
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
fn JsonParser::parse_hex4(self : JsonParser) -> Int raise EvalError {
  let mut code = 0
  for i in 0..<4 {
    if self.pos >= self.input.length() {
      raise EvalError::BadCall("from_json: incomplete unicode escape")
    }
    let _ = i
    let ch = self.advance()
    let digit = if ch >= '0' && ch <= '9' {
      ch.to_int() - '0'.to_int()
    } else if ch >= 'a' && ch <= 'f' {
      ch.to_int() - 'a'.to_int() + 10
    } else if ch >= 'A' && ch <= 'F' {
      ch.to_int() - 'A'.to_int() + 10
    } else {
      raise EvalError::BadCall("from_json: invalid hex digit")
    }
    code = code * 16 + digit
  }
  code
}

///|
fn JsonParser::parse_number(self : JsonParser) -> @core.Value raise EvalError {
  let start = self.pos
  if self.peek() == '-' {
    self.pos = self.pos + 1
  }
  if self.pos >= self.input.length() {
    raise EvalError::BadCall("from_json: unexpected end in number")
  }
  if self.peek() == '0' {
    self.pos = self.pos + 1
  } else if self.peek() >= '1' && self.peek() <= '9' {
    while self.pos < self.input.length() &&
          self.peek() >= '0' &&
          self.peek() <= '9' {
      self.pos = self.pos + 1
    }
  } else {
    raise EvalError::BadCall("from_json: invalid number")
  }
  let mut is_float = false
  if self.pos < self.input.length() && self.peek() == '.' {
    is_float = true
    self.pos = self.pos + 1
    if self.pos >= self.input.length() || self.peek() < '0' || self.peek() > '9' {
      raise EvalError::BadCall("from_json: invalid number after decimal point")
    }
    while self.pos < self.input.length() &&
          self.peek() >= '0' &&
          self.peek() <= '9' {
      self.pos = self.pos + 1
    }
  }
  if self.pos < self.input.length() &&
    (self.peek() == 'e' || self.peek() == 'E') {
    is_float = true
    self.pos = self.pos + 1
    if self.pos < self.input.length() &&
      (self.peek() == '+' || self.peek() == '-') {
      self.pos = self.pos + 1
    }
    if self.pos >= self.input.length() || self.peek() < '0' || self.peek() > '9' {
      raise EvalError::BadCall("from_json: invalid number exponent")
    }
    while self.pos < self.input.length() &&
          self.peek() >= '0' &&
          self.peek() <= '9' {
      self.pos = self.pos + 1
    }
  }
  let num_str = self.input.unsafe_substring(start~, end=self.pos)
  if is_float {
    let parsed : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
      num_str[:],
    )
    match parsed {
      Ok(d) => @core.Value::Double(d)
      Err(_) =>
        raise EvalError::BadCall("from_json: invalid number: " + num_str)
    }
  } else {
    let parsed_int : Result[Int64, @strconv.StrConvError] = try? @strconv.parse_int64(
      num_str[:],
    )
    match parsed_int {
      Ok(n) => @core.Value::Int(n)
      Err(_) => {
        let parsed_dbl : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
          num_str[:],
        )
        match parsed_dbl {
          Ok(d) => @core.Value::Double(d)
          Err(_) =>
            raise EvalError::BadCall("from_json: invalid number: " + num_str)
        }
      }
    }
  }
}

///|
fn JsonParser::parse_array(self : JsonParser) -> @core.Value raise EvalError {
  self.pos = self.pos + 1
  self.skip_ws()
  let items : Array[@core.Value] = []
  if self.peek() == ']' {
    self.pos = self.pos + 1
    return @core.Value::Array(items)
  }
  while true {
    self.skip_ws()
    items.push(self.parse_value())
    self.skip_ws()
    if self.peek() == ',' {
      self.pos = self.pos + 1
    } else if self.peek() == ']' {
      self.pos = self.pos + 1
      break
    } else {
      raise EvalError::BadCall("from_json: expected ',' or ']' in array")
    }
  }
  @core.Value::Array(items)
}

///|
fn JsonParser::parse_object(self : JsonParser) -> @core.Value raise EvalError {
  self.pos = self.pos + 1
  self.skip_ws()
  let fields : Map[String, @core.Value] = {}
  if self.peek() == '}' {
    self.pos = self.pos + 1
    return @core.Value::Map(fields)
  }
  while true {
    self.skip_ws()
    if self.peek() != '"' {
      raise EvalError::BadCall("from_json: expected string key in object")
    }
    let key = self.parse_string_raw()
    self.skip_ws()
    if self.advance() != ':' {
      raise EvalError::BadCall("from_json: expected ':' in object")
    }
    self.skip_ws()
    let val = self.parse_value()
    fields[key] = val
    self.skip_ws()
    if self.peek() == ',' {
      self.pos = self.pos + 1
    } else if self.peek() == '}' {
      self.pos = self.pos + 1
      break
    } else {
      raise EvalError::BadCall("from_json: expected ',' or '}' in object")
    }
  }
  @core.Value::Map(fields)
}
