///|
/// Convert a Value to a string key for Map lookup.
/// Supports Hash-implementing types: String, Int, Float, Double, Bool, Char.
fn value_to_map_key(value : @core.Value) -> String {
  match value {
    @core.Value::String(s) => s
    @core.Value::Int(n) => n.to_string()
    @core.Value::Float(f) => f.to_string()
    @core.Value::Double(d) => d.to_string()
    @core.Value::Bool(b) => if b { "true" } else { "false" }
    @core.Value::Char(c) => c.to_string()
    _ => value.to_string()
  }
}

///|
/// Cheap pure builtins: execute directly without cache.
/// Cache key computation (pure_call_key → git_blob_hash_string) is
/// more expensive than executing these operations.
fn is_cheap_pure_builtin(name : String) -> Bool {
  name == "array_new" ||
  name == "String::concat" ||
  name == "String::equals" ||
  name == "String::length" ||
  name == "String::char_code_at" ||
  name == "String::substring" ||
  name == "Array::length" ||
  name == "Array::get" ||
  name == "Array::slice" ||
  name == "FixedArray::make" ||
  name == "FixedArray::length" ||
  name == "FixedArray::get" ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__mod" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__neg" ||
  name == "__index" ||
  name == "__len" ||
  name == "__slice" ||
  name == "__set_index" ||
  name == "__assert" ||
  name == "__to_string" ||
  name == "__lshift" ||
  name == "__rshift" ||
  name == "__bit_and" ||
  name == "__bit_or" ||
  name == "__bit_xor" ||
  name == "Int::to_float" ||
  name == "Int::to_double" ||
  name == "Float::to_int" ||
  name == "Float::to_double" ||
  name == "Double::to_int" ||
  name == "Double::to_float" ||
  name == "Double::to_i64_bits" ||
  name == "Double::from_i64_bits" ||
  name == "Char::to_int" ||
  name == "Char::from_int" ||
  name == "String::from_char_code" ||
  name == "Int::abs" ||
  name == "Int::max" ||
  name == "Int::min" ||
  name == "Int::clamp" ||
  name == "Int::signum" ||
  name == "Int::is_even" ||
  name == "Int::is_odd" ||
  name == "Double::abs" ||
  name == "Double::max" ||
  name == "Double::min" ||
  name == "Double::floor" ||
  name == "Double::ceil" ||
  name == "Map::get" ||
  name == "Map::set" ||
  name == "Map::has_key" ||
  name == "Set::new" ||
  name == "Set::add" ||
  name == "Set::contains" ||
  name == "Set::remove" ||
  name == "Set::size" ||
  name == "Set::to_array" ||
  name == "Set::from_array" ||
  name == "record_set" ||
  name == "String::contains" ||
  name == "String::index_of" ||
  name == "String::starts_with" ||
  name == "String::ends_with" ||
  name == "String::trim" ||
  name == "String::trim_start" ||
  name == "String::trim_end" ||
  name == "String::to_upper" ||
  name == "String::to_lower" ||
  name == "String::count" ||
  name == "String::last_index_of" ||
  name == "String::utf8_length" ||
  name == "String::utf16_length" ||
  name == "String::unicode_length" ||
  name == "Bytes::length" ||
  name == "Bytes::get" ||
  name == "Bytes::slice" ||
  name == "Bytes::concat" ||
  name == "Bytes::from_array" ||
  name == "Bytes::to_array" ||
  name == "Bytes::from_string" ||
  name == "Bytes::to_string" ||
  name == "Int::parse" ||
  name == "Double::parse"
}

///|
/// Expensive pure builtins: use SHA-based cache for deduplication.
fn is_pure_builtin(name : String) -> Bool {
  is_cheap_pure_builtin(name) ||
  name == "path" ||
  name == "Path::ref" ||
  name == "Path::to_string" ||
  name == "Path::is_absolute" ||
  name == "addr" ||
  name == "String::split" ||
  name == "String::join" ||
  name == "String::replace" ||
  name == "String::replace_all" ||
  name == "Lines::parse" ||
  name == "Lines::stringify" ||
  name == "Json::stringify" ||
  name == "Json::parse" ||
  name == "Json::stringify_lines" ||
  name == "Json::parse_lines" ||
  name == "Json::type_of" ||
  name == "Json::get" ||
  name == "Json::index" ||
  name == "Json::string" ||
  name == "Json::number" ||
  name == "Json::bool" ||
  name == "Json::is_null" ||
  name == "Json::length" ||
  name == "Json::keys" ||
  name == "Map::keys" ||
  name == "Map::values" ||
  name == "PromptText::new" ||
  name == "PromptText::to_string" ||
  name == "select"
}

///|
fn eval_pure_builtin(
  name : String,
  args : Array[@core.Value],
) -> @core.Value raise EvalError {
  match eval_string_builtin(name, args) {
    Some(v) => return v
    None => ()
  }
  match eval_collection_builtin(name, args) {
    Some(v) => return v
    None => ()
  }
  match name {
    "array_new" => {
      if args.length() != 0 {
        raise EvalError::BadCall(
          E("array_new: expected 0 arguments, got " + args.length().to_string()),
        )
      }
      @core.Value::Array([])
    }
    "path" | "Path::ref" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          BuiltinArity(fn_name=name, expected=1, got=args.length()),
        )
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Path(@core.Path::new(s))
        _ =>
          raise EvalError::BadCall(
            BuiltinType(
              fn_name=name,
              expected="String",
              got=value_type_name(args[0]),
            ),
          )
      }
    }
    "Path::to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Path::to_string"))
      }
      match args[0] {
        @core.Value::Path(p) => @core.Value::String(p.as_string())
        _ => raise EvalError::BadCall(E("Path::to_string"))
      }
    }
    "Path::is_absolute" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Path::is_absolute"))
      }
      match args[0] {
        @core.Value::Path(p) => @core.Value::Bool(p.as_string().has_prefix("/"))
        _ => raise EvalError::BadCall(E("Path::is_absolute"))
      }
    }
    "Int::parse" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::parse"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let trimmed = s.trim()
          let len = trimmed.length()
          if len == 0 {
            let none_map : Map[String, @core.Value] = {}
            none_map["None"] = @core.Value::Unit
            return @core.Value::Record(none_map)
          }
          let mut start = 0
          let mut negative = false
          let first_char = trimmed[start]
          if first_char == '-' {
            negative = true
            start = start + 1
          } else if first_char == '+' {
            start = start + 1
          }
          if start >= len {
            let none_map : Map[String, @core.Value] = {}
            none_map["None"] = @core.Value::Unit
            return @core.Value::Record(none_map)
          }
          let mut result : Int64 = 0L
          let mut valid = true
          for i = start; i < len; i = i + 1 {
            let c = trimmed[i]
            if c >= '0' && c <= '9' {
              result = result * 10L + (c.to_int() - 48).to_int64()
            } else {
              valid = false
              break
            }
          }
          if not(valid) {
            let none_map : Map[String, @core.Value] = {}
            none_map["None"] = @core.Value::Unit
            @core.Value::Record(none_map)
          } else {
            if negative {
              result = -result
            }
            let some_map : Map[String, @core.Value] = {}
            some_map["Some"] = @core.Value::Int(result)
            @core.Value::Record(some_map)
          }
        }
        _ => raise EvalError::BadCall(E("Int::parse"))
      }
    }
    "Double::parse" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::parse"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let trimmed = s.trim()
          let value : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
            trimmed,
          )
          match value {
            Ok(v) => {
              let some_map : Map[String, @core.Value] = {}
              some_map["Some"] = @core.Value::Double(v)
              @core.Value::Record(some_map)
            }
            Err(_) => {
              let none_map : Map[String, @core.Value] = {}
              none_map["None"] = @core.Value::Unit
              @core.Value::Record(none_map)
            }
          }
        }
        _ => raise EvalError::BadCall(E("Double::parse"))
      }
    }
    "Char::to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Char::to_int"))
      }
      match args[0] {
        @core.Value::Char(ch) => @core.Value::Int(ch.to_int().to_int64())
        _ => raise EvalError::BadCall(E("Char::to_int"))
      }
    }
    "Char::from_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Char::from_int"))
      }
      match args[0] {
        @core.Value::Int(code) =>
          if code < 0L || code > 1114111L {
            raise EvalError::BadCall(E("Char::from_int"))
          } else {
            match Int::to_char(code.to_int()) {
              Some(ch) => @core.Value::Char(ch)
              None => raise EvalError::BadCall(E("Char::from_int"))
            }
          }
        _ => raise EvalError::BadCall(E("Char::from_int"))
      }
    }
    "__add" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("+: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a + b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a + b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a + b)
        (@core.Value::String(a), @core.Value::String(b)) =>
          @core.Value::String(a + b)
        _ =>
          raise EvalError::BadCall(
            E(
              "+: type mismatch, got " +
              value_type_name(args[0]) +
              " + " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__sub" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("-: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a - b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a - b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a - b)
        _ =>
          raise EvalError::BadCall(
            E(
              "-: type mismatch, got " +
              value_type_name(args[0]) +
              " - " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__mul" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("*: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a * b)
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a * b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a * b)
        _ =>
          raise EvalError::BadCall(
            E(
              "*: type mismatch, got " +
              value_type_name(args[0]) +
              " * " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__div" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("/: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall(E("/: division by zero"))
          } else {
            @core.Value::Int(a / b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(a / b)
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(a / b)
        _ =>
          raise EvalError::BadCall(
            E(
              "/: type mismatch, got " +
              value_type_name(args[0]) +
              " / " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__mod" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("%: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          if b == 0 {
            raise EvalError::BadCall(E("%: division by zero"))
          } else {
            @core.Value::Int(a % b)
          }
        (@core.Value::Float(a), @core.Value::Float(b)) =>
          @core.Value::Float(Float::mod(a, b))
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(Double::mod(a, b))
        _ =>
          raise EvalError::BadCall(
            E(
              "%: type mismatch, got " +
              value_type_name(args[0]) +
              " % " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__len" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E("__len: expected 1 argument, got " + args.length().to_string()),
        )
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::Int(s.length().to_int64())
        @core.Value::Array(arr) => @core.Value::Int(arr.length().to_int64())
        @core.Value::Bytes(data) => @core.Value::Int(data.length().to_int64())
        _ =>
          raise EvalError::BadCall(
            E("__len: cannot take length of " + value_type_name(args[0])),
          )
      }
    }
    "__index" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("[]: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Array(arr), @core.Value::Int(i)) =>
          if i >= 0L && i < arr.length().to_int64() {
            arr[i.to_int()]
          } else {
            raise EvalError::BadCall(
              E(
                "[]: index " +
                i.to_string() +
                " out of bounds (length " +
                arr.length().to_string() +
                ")",
              ),
            )
          }
        (@core.Value::Record(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall(MissingKey(op="[]", key~))
          }
        (@core.Value::Map(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall(MissingKey(op="[]", key~))
          }
        (@core.Value::MapBuilder(map), @core.Value::String(key)) =>
          match map.get(key) {
            Some(v) => v
            None => raise EvalError::BadCall(MissingKey(op="[]", key~))
          }
        (@core.Value::String(s), @core.Value::Int(i)) => {
          let idx = i.to_int()
          if idx >= 0 && idx < s.length() {
            @core.Value::String(s[idx:idx + 1].to_string())
          } else {
            raise EvalError::BadCall(
              E(
                "[]: string index " +
                i.to_string() +
                " out of bounds (length " +
                s.length().to_string() +
                ")",
              ),
            )
          }
        }
        (@core.Value::Bytes(data), @core.Value::Int(i)) => {
          let idx = i.to_int()
          if idx >= 0 && idx < data.length() {
            @core.Value::Int(data[idx].to_int().to_int64())
          } else {
            raise EvalError::BadCall(
              E(
                "[]: bytes index " +
                i.to_string() +
                " out of bounds (length " +
                data.length().to_string() +
                ")",
              ),
            )
          }
        }
        _ =>
          raise EvalError::BadCall(
            E(
              "[]: cannot index " +
              value_type_name(args[0]) +
              " with " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__slice" => {
      if args.length() != 3 {
        raise EvalError::BadCall(
          E("[..]: expected 3 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::String(s), @core.Value::Int(start), @core.Value::Int(end_)
        ) => {
          let len = s.length().to_int64()
          let s0 = if start < 0L {
            0L
          } else if start > len {
            len
          } else {
            start
          }
          let e0 = if end_ < 0L { 0L } else if end_ > len { len } else { end_ }
          @core.Value::String(s[s0.to_int():e0.to_int()].to_string())
        }
        (
          @core.Value::Array(arr),
          @core.Value::Int(start),
          @core.Value::Int(end_),
        ) => {
          let len = arr.length().to_int64()
          let s0 = if start < 0L {
            0L
          } else if start > len {
            len
          } else {
            start
          }
          let e0 = if end_ < 0L { 0L } else if end_ > len { len } else { end_ }
          let result : Array[@core.Value] = []
          for i in s0.to_int()..<e0.to_int() {
            result.push(arr[i])
          }
          @core.Value::Array(result)
        }
        (
          @core.Value::Bytes(data),
          @core.Value::Int(start),
          @core.Value::Int(end_),
        ) => {
          let len = data.length().to_int64()
          let s0 = if start < 0L {
            0L
          } else if start > len {
            len
          } else {
            start
          }
          let e0 = if end_ < 0L { 0L } else if end_ > len { len } else { end_ }
          let result : Array[Byte] = []
          for i in s0.to_int()..<e0.to_int() {
            result.push(data[i])
          }
          @core.Value::Bytes(result)
        }
        _ =>
          raise EvalError::BadCall(
            E("[..]: cannot slice " + value_type_name(args[0])),
          )
      }
    }
    "__set_index" => {
      if args.length() != 3 {
        raise EvalError::BadCall(
          E("[]=: expected 3 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::Array(arr), @core.Value::Int(i), value) =>
          if i >= 0L && i < arr.length().to_int64() {
            arr[i.to_int()] = value
            value
          } else {
            raise EvalError::BadCall(
              E(
                "[]=: index " +
                i.to_string() +
                " out of bounds (length " +
                arr.length().to_string() +
                ")",
              ),
            )
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
        _ =>
          raise EvalError::BadCall(
            E("[]=: cannot assign index on " + value_type_name(args[0])),
          )
      }
    }
    "__eq" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("==: expected 2 arguments, got " + args.length().to_string()),
        )
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
        (@core.Value::Record(rec), @core.Value::String(s)) =>
          match (rec.get("source"), rec.get("start"), rec.get("end")) {
            (
              Some(@core.Value::String(src)),
              Some(@core.Value::Int(start)),
              Some(@core.Value::Int(end_)),
            ) =>
              @core.Value::Bool(
                src[start.to_int():end_.to_int()].to_string() == s,
              )
            _ => @core.Value::Bool(false)
          }
        (@core.Value::String(s), @core.Value::Record(rec)) =>
          match (rec.get("source"), rec.get("start"), rec.get("end")) {
            (
              Some(@core.Value::String(src)),
              Some(@core.Value::Int(start)),
              Some(@core.Value::Int(end_)),
            ) =>
              @core.Value::Bool(
                s == src[start.to_int():end_.to_int()].to_string(),
              )
            _ => @core.Value::Bool(false)
          }
        (a, b) => @core.Value::Bool(a == b)
      }
    }
    "__lt" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E(
            "comparison: expected 2 arguments, got " + args.length().to_string(),
          ),
        )
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
        _ =>
          raise EvalError::BadCall(
            E(
              "comparison: type mismatch, cannot compare " +
              value_type_name(args[0]) +
              " with " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__neg" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E("unary -: expected 1 argument, got " + args.length().to_string()),
        )
      }
      match args[0] {
        @core.Value::Int(a) => @core.Value::Int(-a)
        @core.Value::Float(a) => @core.Value::Float(-a)
        @core.Value::Double(a) => @core.Value::Double(-a)
        _ =>
          raise EvalError::BadCall(
            E("unary -: expected number, got " + value_type_name(args[0])),
          )
      }
    }
    "__lshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("<<: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(a << b.to_int())
        _ =>
          raise EvalError::BadCall(
            E(
              "<<: type mismatch, got " +
              value_type_name(args[0]) +
              " << " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__rshift" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E(">>: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(a >> b.to_int())
        _ =>
          raise EvalError::BadCall(
            E(
              ">>: type mismatch, got " +
              value_type_name(args[0]) +
              " >> " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__bit_and" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("&: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a & b)
        _ =>
          raise EvalError::BadCall(
            E(
              "&: type mismatch, got " +
              value_type_name(args[0]) +
              " & " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__bit_or" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("|: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a | b)
        _ =>
          raise EvalError::BadCall(
            E(
              "|: type mismatch, got " +
              value_type_name(args[0]) +
              " | " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__bit_xor" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("^: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) => @core.Value::Int(a ^ b)
        _ =>
          raise EvalError::BadCall(
            E(
              "^: type mismatch, got " +
              value_type_name(args[0]) +
              " ^ " +
              value_type_name(args[1]),
            ),
          )
      }
    }
    "__assert" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E("assert: expected 1 argument, got " + args.length().to_string()),
        )
      }
      match args[0] {
        @core.Value::Bool(b) =>
          if b {
            @core.Value::Unit
          } else {
            raise EvalError::BadCall(AssertFail)
          }
        _ =>
          raise EvalError::BadCall(
            E("assert: expected Bool, got " + value_type_name(args[0])),
          )
      }
    }
    "record_set" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("record_set"))
      }
      match (args[0], args[1]) {
        (@core.Value::Record(map), @core.Value::String(name)) => {
          if not(map.contains(name)) {
            raise EvalError::BadCall(E("record_set"))
          }
          let out : Map[String, @core.Value] = {}
          for k, v in map {
            out[k] = v
          }
          out[name] = args[2]
          @core.Value::Record(out)
        }
        _ => raise EvalError::BadCall(E("record_set"))
      }
    }
    "Int::to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::to_float"))
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Float(Float::from_int(n.to_int()))
        _ => raise EvalError::BadCall(E("Int::to_float"))
      }
    }
    "Int::to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::to_double"))
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Double(n.to_double())
        _ => raise EvalError::BadCall(E("Int::to_double"))
      }
    }
    "Float::to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Float::to_int"))
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Int(f.to_int().to_int64())
        _ => raise EvalError::BadCall(E("Float::to_int"))
      }
    }
    "Float::to_double" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Float::to_double"))
      }
      match args[0] {
        @core.Value::Float(f) => @core.Value::Double(f.to_double())
        _ => raise EvalError::BadCall(E("Float::to_double"))
      }
    }
    "Double::to_int" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::to_int"))
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Int(d.to_int().to_int64())
        _ => raise EvalError::BadCall(E("Double::to_int"))
      }
    }
    "Double::to_float" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::to_float"))
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Float(Float::from_double(d))
        _ => raise EvalError::BadCall(E("Double::to_float"))
      }
    }
    "Double::to_i64_bits" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::to_i64_bits"))
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Int(d.reinterpret_as_int64())
        _ => raise EvalError::BadCall(E("Double::to_i64_bits"))
      }
    }
    "Double::from_i64_bits" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::from_i64_bits"))
      }
      match args[0] {
        @core.Value::Int(n) => @core.Value::Double(n.reinterpret_as_double())
        _ => raise EvalError::BadCall(E("Double::from_i64_bits"))
      }
    }
    "__to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E("to_string: expected 1 argument, got " + args.length().to_string()),
        )
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
        _ =>
          raise EvalError::BadCall(
            E("to_string: cannot convert " + value_type_name(args[0])),
          )
      }
    }
    "Lines::parse" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Lines::parse"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let parts : Array[@core.Value] = []
          for part in String::split(s, "\n") {
            parts.push(@core.Value::String(part.to_string()))
          }
          @core.Value::Array(parts)
        }
        _ => raise EvalError::BadCall(E("Lines::parse"))
      }
    }
    "Lines::stringify" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Lines::stringify"))
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
              _ => raise EvalError::BadCall(E("Lines::stringify"))
            }
          }
          @core.Value::String(buf.to_string())
        }
        _ => raise EvalError::BadCall(E("Lines::stringify"))
      }
    }
    "Json::stringify" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::stringify"))
      }
      @core.Value::String(value_to_json_string(args[0]))
    }
    "Json::parse" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::parse"))
      }
      match args[0] {
        @core.Value::String(s) => parse_json_value(s)
        _ => raise EvalError::BadCall(E("Json::parse"))
      }
    }
    "Json::stringify_lines" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::stringify_lines"))
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
        _ => raise EvalError::BadCall(E("Json::stringify_lines"))
      }
    }
    "Json::parse_lines" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::parse_lines"))
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
        _ => raise EvalError::BadCall(E("Json::parse_lines"))
      }
    }
    "Json::type_of" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::type_of"))
      }
      let type_name = match args[0] {
        @core.Value::Unit => "null"
        @core.Value::Bool(_) => "bool"
        @core.Value::Int(_) | @core.Value::Double(_) | @core.Value::Float(_) =>
          "number"
        @core.Value::String(_) => "string"
        @core.Value::Array(_) => "array"
        @core.Value::Map(_) => "object"
        _ => raise EvalError::BadCall(E("Json::type_of"))
      }
      @core.Value::String(type_name)
    }
    "Json::get" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Json::get"))
      }
      match (args[0], args[1]) {
        (@core.Value::Map(items), @core.Value::String(key)) =>
          match items.get(key) {
            Some(value) => value
            None => raise EvalError::BadCall(MissingKey(op="Json::get", key~))
          }
        _ => raise EvalError::BadCall(E("Json::get"))
      }
    }
    "Json::index" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Json::index"))
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall(E("Json::index: out of bounds"))
          }
          items[index.to_int()]
        }
        _ => raise EvalError::BadCall(E("Json::index"))
      }
    }
    "Json::string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::string"))
      }
      match args[0] {
        @core.Value::String(s) => @core.Value::String(s)
        _ => raise EvalError::BadCall(E("Json::string: not a string"))
      }
    }
    "Json::number" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::number"))
      }
      match args[0] {
        @core.Value::Double(d) => @core.Value::Double(d)
        @core.Value::Int(n) => @core.Value::Double(n.to_double())
        @core.Value::Float(f) => @core.Value::Double(f.to_double())
        _ => raise EvalError::BadCall(E("Json::number: not a number"))
      }
    }
    "Json::bool" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::bool"))
      }
      match args[0] {
        @core.Value::Bool(b) => @core.Value::Bool(b)
        _ => raise EvalError::BadCall(E("Json::bool: not a bool"))
      }
    }
    "Json::is_null" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::is_null"))
      }
      @core.Value::Bool(args[0] is @core.Value::Unit)
    }
    "Json::length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::length"))
      }
      match args[0] {
        @core.Value::Array(items) => @core.Value::Int(items.length().to_int64())
        @core.Value::Map(items) => @core.Value::Int(items.length().to_int64())
        @core.Value::String(s) => @core.Value::Int(s.length().to_int64())
        _ => raise EvalError::BadCall(E("Json::length"))
      }
    }
    "Json::keys" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Json::keys"))
      }
      match args[0] {
        @core.Value::Map(items) => {
          let keys : Array[@core.Value] = []
          for k, _ in items {
            keys.push(@core.Value::String(k))
          }
          @core.Value::Array(keys)
        }
        _ => raise EvalError::BadCall(E("Json::keys"))
      }
    }
    "Int::abs" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::abs"))
      }
      match args[0] {
        @core.Value::Int(x) =>
          if x < 0L {
            @core.Value::Int(-x)
          } else {
            @core.Value::Int(x)
          }
        _ => raise EvalError::BadCall(E("Int::abs"))
      }
    }
    "Int::max" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Int::max"))
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(if a > b { a } else { b })
        _ => raise EvalError::BadCall(E("Int::max"))
      }
    }
    "Int::min" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Int::min"))
      }
      match (args[0], args[1]) {
        (@core.Value::Int(a), @core.Value::Int(b)) =>
          @core.Value::Int(if a < b { a } else { b })
        _ => raise EvalError::BadCall(E("Int::min"))
      }
    }
    "Int::clamp" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("Int::clamp"))
      }
      match (args[0], args[1], args[2]) {
        (@core.Value::Int(x), @core.Value::Int(lo), @core.Value::Int(hi)) =>
          @core.Value::Int(if x < lo { lo } else if x > hi { hi } else { x })
        _ => raise EvalError::BadCall(E("Int::clamp"))
      }
    }
    "Int::signum" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::signum"))
      }
      match args[0] {
        @core.Value::Int(x) =>
          @core.Value::Int(if x < 0L { -1L } else if x > 0L { 1L } else { 0L })
        _ => raise EvalError::BadCall(E("Int::signum"))
      }
    }
    "Int::is_even" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::is_even"))
      }
      match args[0] {
        @core.Value::Int(x) => @core.Value::Bool(x % 2L == 0L)
        _ => raise EvalError::BadCall(E("Int::is_even"))
      }
    }
    "Int::is_odd" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Int::is_odd"))
      }
      match args[0] {
        @core.Value::Int(x) => @core.Value::Bool(x % 2L != 0L)
        _ => raise EvalError::BadCall(E("Int::is_odd"))
      }
    }
    "Double::abs" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::abs"))
      }
      match args[0] {
        @core.Value::Double(x) =>
          @core.Value::Double(if x < 0.0 { -x } else { x })
        _ => raise EvalError::BadCall(E("Double::abs"))
      }
    }
    "Double::max" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Double::max"))
      }
      match (args[0], args[1]) {
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(if a > b { a } else { b })
        _ => raise EvalError::BadCall(E("Double::max"))
      }
    }
    "Double::min" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Double::min"))
      }
      match (args[0], args[1]) {
        (@core.Value::Double(a), @core.Value::Double(b)) =>
          @core.Value::Double(if a < b { a } else { b })
        _ => raise EvalError::BadCall(E("Double::min"))
      }
    }
    "Double::floor" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::floor"))
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
        _ => raise EvalError::BadCall(E("Double::floor"))
      }
    }
    "Double::ceil" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Double::ceil"))
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
        _ => raise EvalError::BadCall(E("Double::ceil"))
      }
    }
    "PromptText::new" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("PromptText::new"))
      }
      match args[0] {
        @core.Value::String(s) =>
          @core.Value::PromptText(@core.PromptText::new(s))
        @core.Value::PromptText(_) as pt => pt
        _ => raise EvalError::BadCall(E("PromptText::new"))
      }
    }
    "PromptText::to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("PromptText::to_string"))
      }
      match args[0] {
        @core.Value::PromptText(pt) => @core.Value::String(pt.as_string())
        _ => raise EvalError::BadCall(E("PromptText::to_string"))
      }
    }
    "select" => {
      if args.length() < 2 {
        raise EvalError::BadCall(E("select"))
      }
      let field_names : Array[String] = []
      for i in 1..<args.length() {
        match args[i] {
          @core.Value::String(s) => field_names.push(s)
          _ => raise EvalError::BadCall(E("select"))
        }
      }
      match args[0] {
        @core.Value::Record(map) => {
          let out : Map[String, @core.Value] = {}
          for name in field_names {
            match map.get(name) {
              Some(v) => out[name] = v
              None => raise EvalError::BadCall(NoField(field=name, on="Record"))
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
                      raise EvalError::BadCall(NoField(field=name, on="Record"))
                  }
                }
                result.push(@core.Value::Record(out))
              }
              _ => raise EvalError::BadCall(E("select"))
            }
          }
          @core.Value::Array(result)
        }
        _ => raise EvalError::BadCall(E("select"))
      }
    }
    _ => raise EvalError::BadCall(UnknownFn(name~))
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
  if @backend.exec_available() {
    match @backend.exec_command_lines(cmd) {
      Ok(lines) => lines
      Err(msg) => raise EvalError::BadCall(Io(op="sh_lines", detail=msg))
    }
  } else {
    execute_shell_lines_fallback(cmd)
  }
}

///|
fn execute_shell_lines_fallback(cmd : String) -> Array[String] raise EvalError {
  let parts = split_shell_args(cmd)
  if parts.length() == 0 {
    raise EvalError::BadCall(Io(op="sh_lines", detail="empty command"))
  }
  match parts[0] {
    "ls" => {
      if parts.length() > 2 {
        raise EvalError::BadCall(
          Io(
            op="sh_lines",
            detail="ls: expected 0 or 1 arguments, got " +
              (parts.length() - 1).to_string(),
          ),
        )
      }
      let dir = if parts.length() == 2 { parts[1] } else { "." }
      match @io.shell_ls_lines(dir) {
        Ok(lines) => lines
        Err(e) => raise EvalError::BadCall(Io(op="sh_lines", detail="ls: " + e))
      }
    }
    "cat" => {
      if parts.length() != 2 {
        raise EvalError::BadCall(
          Io(
            op="sh_lines",
            detail="cat: expected exactly 1 file argument, got " +
              (parts.length() - 1).to_string(),
          ),
        )
      }
      match @io.shell_cat_lines(parts[1]) {
        Ok(lines) => lines
        Err(e) =>
          raise EvalError::BadCall(Io(op="sh_lines", detail="cat: " + e))
      }
    }
    "echo" =>
      if parts.length() <= 1 {
        [""]
      } else {
        [join_shell_args(parts, 1)]
      }
    _ => {
      let command = parts[0]
      raise EvalError::BadCall(
        Io(
          op="sh_lines",
          detail="command '" +
            command +
            "' is not available on this target (only ls, cat, echo are supported in fallback mode)",
        ),
      )
    }
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
    raise EvalError::BadCall(JsonParse(detail="unexpected trailing content"))
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
    raise EvalError::BadCall(JsonParse(detail="unexpected end of input"))
  }
  for i in 0..<len {
    if self.input.unsafe_get(self.pos + i) != expected.unsafe_get(i) {
      raise EvalError::BadCall(JsonParse(detail="unexpected character"))
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
    '\u0000' =>
      raise EvalError::BadCall(JsonParse(detail="unexpected end of input"))
    _ =>
      raise EvalError::BadCall(
        E("Json::parse: unexpected character: " + ch.to_string()),
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
    raise EvalError::BadCall(E("Json::parse: expected '\"'"))
  }
  let buf = StringBuilder::new()
  while true {
    if self.pos >= self.input.length() {
      raise EvalError::BadCall(JsonParse(detail="unterminated string"))
    }
    let ch = self.advance()
    if ch == '"' {
      break
    }
    if ch == '\\' {
      if self.pos >= self.input.length() {
        raise EvalError::BadCall(JsonParse(detail="unterminated escape"))
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
            E("Json::parse: invalid escape: \\" + esc.to_string()),
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
      raise EvalError::BadCall(JsonParse(detail="incomplete unicode escape"))
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
      raise EvalError::BadCall(JsonParse(detail="invalid hex digit"))
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
    raise EvalError::BadCall(JsonParse(detail="unexpected end in number"))
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
    raise EvalError::BadCall(JsonParse(detail="invalid number"))
  }
  let mut is_float = false
  if self.pos < self.input.length() && self.peek() == '.' {
    is_float = true
    self.pos = self.pos + 1
    if self.pos >= self.input.length() || self.peek() < '0' || self.peek() > '9' {
      raise EvalError::BadCall(
        JsonParse(detail="invalid number after decimal point"),
      )
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
      raise EvalError::BadCall(JsonParse(detail="invalid number exponent"))
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
        raise EvalError::BadCall(JsonParse(detail="invalid number: " + num_str))
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
            raise EvalError::BadCall(
              JsonParse(detail="invalid number: " + num_str),
            )
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
      raise EvalError::BadCall(JsonParse(detail="expected ',' or ']' in array"))
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
      raise EvalError::BadCall(
        JsonParse(detail="expected string key in object"),
      )
    }
    let key = self.parse_string_raw()
    self.skip_ws()
    if self.advance() != ':' {
      raise EvalError::BadCall(JsonParse(detail="expected ':' in object"))
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
      raise EvalError::BadCall(
        JsonParse(detail="expected ',' or '}' in object"),
      )
    }
  }
  @core.Value::Map(fields)
}
