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
  name == "string_utf8_length" ||
  name == "string_utf16_length" ||
  name == "string_unicode_length" ||
  name == "__lshift" ||
  name == "__rshift" ||
  name == "__bit_and" ||
  name == "__bit_or" ||
  name == "__bit_xor"
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
    "__add" => {
      if args.length() != 2 {
        raise EvalError::BadCall("__add")
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a + b)
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
        @core.Value::Unit => @core.Value::String("()")
        _ => raise EvalError::BadCall("__to_string")
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
