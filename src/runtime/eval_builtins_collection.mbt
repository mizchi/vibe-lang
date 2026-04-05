///|
fn eval_collection_builtin(
  name : String,
  args : Array[@core.Value],
) -> @core.Value? raise EvalError {
  match name {
    "Array::length" | "FixedArray::length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(
          E(
            "Array::length: expected 1 argument, got " +
            args.length().to_string(),
          ),
        )
      }
      match args[0] {
        @core.Value::Array(items) =>
          Some(@core.Value::Int(items.length().to_int64()))
        _ =>
          raise EvalError::BadCall(
            E(
              "expected Array, got " +
              value_type_name(args[0]) +
              " (for-in requires an iterable)",
            ),
          )
      }
    }
    "Array::get" | "FixedArray::get" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E(
            "Array::get: expected 2 arguments, got " + args.length().to_string(),
          ),
        )
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall(
              E(
                "Array::get: index " +
                index.to_string() +
                " out of bounds (length " +
                items.length().to_string() +
                ")",
              ),
            )
          }
          Some(items[index.to_int()])
        }
        _ =>
          raise EvalError::BadCall(
            E(
              "Array::get: expected (Array, Int), got (" +
              value_type_name(args[0]) +
              ", " +
              value_type_name(args[1]) +
              ")",
            ),
          )
      }
    }
    "FixedArray::make" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("FixedArray::make"))
      }
      match args[0] {
        @core.Value::Int(size) => {
          if size < 0L {
            raise EvalError::BadCall(E("FixedArray::make"))
          }
          let out : Array[@core.Value] = []
          for _ in 0..<size.to_int() {
            out.push(args[1])
          }
          Some(@core.Value::Array(out))
        }
        _ => raise EvalError::BadCall(E("FixedArray::make"))
      }
    }
    "FixedArray::set" | "FixedArray::unsafe_set" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("FixedArray::set"))
      }
      match (args[0], args[1]) {
        (@core.Value::Array(items), @core.Value::Int(index)) => {
          if index < 0L || index >= items.length().to_int64() {
            raise EvalError::BadCall(E("FixedArray::set"))
          }
          items[index.to_int()] = args[2]
          Some(@core.Value::Unit)
        }
        _ => raise EvalError::BadCall(E("FixedArray::set"))
      }
    }
    "FixedArray::blit" => {
      if args.length() != 5 {
        raise EvalError::BadCall(E("FixedArray::blit"))
      }
      match (args[0], args[1], args[2], args[3], args[4]) {
        (
          @core.Value::Array(dst),
          @core.Value::Int(dst_off),
          @core.Value::Array(src),
          @core.Value::Int(src_off),
          @core.Value::Int(len),
        ) => {
          let d0 = dst_off.to_int()
          let s0 = src_off.to_int()
          let n = len.to_int()
          if d0 < 0 ||
            s0 < 0 ||
            n < 0 ||
            d0 + n > dst.length() ||
            s0 + n > src.length() {
            raise EvalError::BadCall(E("FixedArray::blit"))
          }
          for i in 0..<n {
            dst[d0 + i] = src[s0 + i]
          }
          Some(@core.Value::Unit)
        }
        _ => raise EvalError::BadCall(E("FixedArray::blit"))
      }
    }
    "Array::slice" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("Array::slice"))
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
          Some(@core.Value::Array(out))
        }
        _ => raise EvalError::BadCall(E("Array::slice"))
      }
    }
    "Map::get" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E("Map::get: expected 2 arguments, got " + args.length().to_string()),
        )
      }
      match args[0] {
        @core.Value::Map(items) => {
          let key = value_to_map_key(args[1])
          match items.get(key) {
            Some(value) => Some(value)
            None => raise EvalError::BadCall(MissingKey(op="Map::get", key~))
          }
        }
        _ =>
          raise EvalError::BadCall(
            E(
              "Map::get: expected (Map, key), got (" +
              value_type_name(args[0]) +
              ", " +
              value_type_name(args[1]) +
              ")",
            ),
          )
      }
    }
    "Map::set" => {
      if args.length() != 3 {
        raise EvalError::BadCall(
          E("Map::set: expected 3 arguments, got " + args.length().to_string()),
        )
      }
      match args[0] {
        @core.Value::Map(items) => {
          let key = value_to_map_key(args[1])
          let new_map : Map[String, @core.Value] = {}
          items.each(fn(k, v) { new_map[k] = v })
          new_map[key] = args[2]
          Some(@core.Value::Map(new_map))
        }
        _ =>
          raise EvalError::BadCall(
            E("Map::set: expected Map as first argument"),
          )
      }
    }
    "Map::keys" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Map::keys"))
      }
      match args[0] {
        @core.Value::Map(items) => {
          let keys : Array[@core.Value] = []
          for k, _ in items {
            keys.push(@core.Value::String(k))
          }
          Some(@core.Value::Array(keys))
        }
        _ => raise EvalError::BadCall(E("Map::keys"))
      }
    }
    "Map::values" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Map::values"))
      }
      match args[0] {
        @core.Value::Map(items) => {
          let values : Array[@core.Value] = []
          for _, v in items {
            values.push(v)
          }
          Some(@core.Value::Array(values))
        }
        _ => raise EvalError::BadCall(E("Map::values"))
      }
    }
    "Map::has_key" | "Map::has" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Map::has_key"))
      }
      match args[0] {
        @core.Value::Map(items) => {
          let key = value_to_map_key(args[1])
          Some(@core.Value::Bool(items.contains(key)))
        }
        _ => raise EvalError::BadCall(E("Map::has_key"))
      }
    }
    "Map::delete" => {
      if args.length() != 2 {
        raise EvalError::BadCall(
          E(
            "Map::delete: expected 2 arguments, got " +
            args.length().to_string(),
          ),
        )
      }
      match args[0] {
        @core.Value::Map(items) => {
          let key = value_to_map_key(args[1])
          let new_map : Map[String, @core.Value] = {}
          items.each(fn(k, v) { new_map[k] = v })
          new_map.remove(key)
          Some(@core.Value::Map(new_map))
        }
        _ =>
          raise EvalError::BadCall(
            E("Map::delete: expected Map as first argument"),
          )
      }
    }
    "Set::new" => {
      if args.length() != 0 {
        raise EvalError::BadCall(E("Set::new: expected 0 arguments"))
      }
      let items : Map[String, @core.Value] = {}
      Some(@core.Value::Set(items))
    }
    "Set::add" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Set::add: expected 2 arguments"))
      }
      match args[0] {
        @core.Value::Set(items) => {
          let key = value_to_map_key(args[1])
          let new_set : Map[String, @core.Value] = {}
          items.each(fn(k, v) { new_set[k] = v })
          new_set[key] = args[1]
          Some(@core.Value::Set(new_set))
        }
        _ =>
          raise EvalError::BadCall(
            E("Set::add: expected Set as first argument"),
          )
      }
    }
    "Set::contains" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Set::contains: expected 2 arguments"))
      }
      match args[0] {
        @core.Value::Set(items) => {
          let key = value_to_map_key(args[1])
          Some(@core.Value::Bool(items.contains(key)))
        }
        _ =>
          raise EvalError::BadCall(
            E("Set::contains: expected Set as first argument"),
          )
      }
    }
    "Set::remove" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Set::remove: expected 2 arguments"))
      }
      match args[0] {
        @core.Value::Set(items) => {
          let key = value_to_map_key(args[1])
          let new_set : Map[String, @core.Value] = {}
          items.each(fn(k, v) { if k != key { new_set[k] = v } })
          Some(@core.Value::Set(new_set))
        }
        _ =>
          raise EvalError::BadCall(
            E("Set::remove: expected Set as first argument"),
          )
      }
    }
    "Set::size" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Set::size: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Set(items) =>
          Some(@core.Value::Int(items.length().to_int64()))
        _ => raise EvalError::BadCall(E("Set::size: expected Set"))
      }
    }
    "Set::to_array" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Set::to_array: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Set(items) => {
          let arr : Array[@core.Value] = []
          for _, v in items {
            arr.push(v)
          }
          Some(@core.Value::Array(arr))
        }
        _ => raise EvalError::BadCall(E("Set::to_array: expected Set"))
      }
    }
    "Set::from_array" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Set::from_array: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Array(items) => {
          let set : Map[String, @core.Value] = {}
          for item in items {
            let key = value_to_map_key(item)
            set[key] = item
          }
          Some(@core.Value::Set(set))
        }
        _ => raise EvalError::BadCall(E("Set::from_array: expected Array"))
      }
    }
    "Bytes::length" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Bytes::length: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Bytes(data) =>
          Some(@core.Value::Int(data.length().to_int64()))
        _ => raise EvalError::BadCall(E("Bytes::length: expected Bytes"))
      }
    }
    "Bytes::get" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Bytes::get: expected 2 arguments"))
      }
      match (args[0], args[1]) {
        (@core.Value::Bytes(data), @core.Value::Int(index)) => {
          let i = index.to_int()
          if i < 0 || i >= data.length() {
            raise EvalError::BadCall(E("Bytes::get: index out of bounds"))
          }
          Some(@core.Value::Int(data[i].to_int().to_int64()))
        }
        _ => raise EvalError::BadCall(E("Bytes::get: expected (Bytes, Int)"))
      }
    }
    "Bytes::slice" => {
      if args.length() != 3 {
        raise EvalError::BadCall(E("Bytes::slice: expected 3 arguments"))
      }
      match (args[0], args[1], args[2]) {
        (
          @core.Value::Bytes(data),
          @core.Value::Int(start),
          @core.Value::Int(end_),
        ) => {
          let s = start.to_int()
          let e = end_.to_int()
          let result : Array[Byte] = []
          for i = s; i < e && i < data.length(); i = i + 1 {
            result.push(data[i])
          }
          Some(@core.Value::Bytes(result))
        }
        _ =>
          raise EvalError::BadCall(
            E("Bytes::slice: expected (Bytes, Int, Int)"),
          )
      }
    }
    "Bytes::concat" => {
      if args.length() != 2 {
        raise EvalError::BadCall(E("Bytes::concat: expected 2 arguments"))
      }
      match (args[0], args[1]) {
        (@core.Value::Bytes(a), @core.Value::Bytes(b)) => {
          let result : Array[Byte] = []
          for byte in a {
            result.push(byte)
          }
          for byte in b {
            result.push(byte)
          }
          Some(@core.Value::Bytes(result))
        }
        _ =>
          raise EvalError::BadCall(E("Bytes::concat: expected (Bytes, Bytes)"))
      }
    }
    "Bytes::from_array" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Bytes::from_array: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Array(items) => {
          let result : Array[Byte] = []
          for item in items {
            match item {
              @core.Value::Int(n) => result.push(n.to_int().to_byte())
              _ =>
                raise EvalError::BadCall(
                  E("Bytes::from_array: array elements must be Int"),
                )
            }
          }
          Some(@core.Value::Bytes(result))
        }
        _ =>
          raise EvalError::BadCall(E("Bytes::from_array: expected Array[Int]"))
      }
    }
    "Bytes::to_array" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Bytes::to_array: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Bytes(data) => {
          let result : Array[@core.Value] = []
          for byte in data {
            result.push(@core.Value::Int(byte.to_int().to_int64()))
          }
          Some(@core.Value::Array(result))
        }
        _ => raise EvalError::BadCall(E("Bytes::to_array: expected Bytes"))
      }
    }
    "Bytes::from_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Bytes::from_string: expected 1 argument"))
      }
      match args[0] {
        @core.Value::String(s) => {
          let result : Array[Byte] = []
          let bytes = @utf8.encode(s)
          for b in bytes {
            result.push(b)
          }
          Some(@core.Value::Bytes(result))
        }
        _ => raise EvalError::BadCall(E("Bytes::from_string: expected String"))
      }
    }
    "Bytes::to_string" => {
      if args.length() != 1 {
        raise EvalError::BadCall(E("Bytes::to_string: expected 1 argument"))
      }
      match args[0] {
        @core.Value::Bytes(data) => {
          let bytes = Bytes::from_array(data[:])
          let decoded : Result[String, @utf8.Malformed] = try? @utf8.decode(
            bytes[:],
          )
          match decoded {
            Ok(s) => Some(@core.Value::String(s))
            Err(_) =>
              raise EvalError::BadCall(
                E("Bytes::to_string: invalid UTF-8 sequence"),
              )
          }
        }
        _ => raise EvalError::BadCall(E("Bytes::to_string: expected Bytes"))
      }
    }
    _ => None
  }
}
