///|
/// Pure function result cache (external snapshot)
pub struct PureCache {
  entries : Map[String, Value]
} derive(Show, Eq)

///|
pub fn PureCache::new() -> PureCache {
  { entries: {} }
}

///|
pub fn PureCache::get(self : PureCache, key : String) -> Value? {
  self.entries.get(key)
}

///|
pub fn PureCache::set(self : PureCache, key : String, value : Value) -> Unit {
  self.entries[key] = value
}

///|
pub fn PureCache::len(self : PureCache) -> Int {
  self.entries.length()
}

///| Serialize cache to a line-based snapshot.

///| Format: <hash>\t<encoded-value>

///|
/// Encoded values use prefixes: i:, s:, p:, u:
pub fn PureCache::snapshot(self : PureCache) -> String {
  let buf = StringBuilder::new()
  let mut first = true
  for key, value in self.entries {
    if first {
      first = false
    } else {
      buf.write_char('\n')
    }
    buf.write_string(key)
    buf.write_char('\t')
    buf.write_string(encode_value(value))
  }
  buf.to_string()
}

///|
/// Load snapshot entries into the cache (invalid lines are ignored).
pub fn PureCache::load(self : PureCache, snapshot : String) -> Unit {
  for line in snapshot.split("\n") {
    let line_str = line.to_string()
    if line_str.is_empty() {
      continue
    }
    match split_cache_line(line_str) {
      Some(entry) =>
        match decode_value(entry.value) {
          Some(value) => self.entries[entry.key] = value
          None => ()
        }
      None => ()
    }
  }
}

///|
priv struct CacheLine {
  key : String
  value : String
}

///|
fn split_cache_line(line : String) -> CacheLine? {
  let chars : Array[Char] = []
  for c in line {
    chars.push(c)
  }
  let mut tab = -1
  for i in 0..<chars.length() {
    if chars[i] == '\t' {
      tab = i
      break
    }
  }
  if tab == -1 {
    return None
  }
  let left = StringBuilder::new()
  for i in 0..<tab {
    left.write_char(chars[i])
  }
  let right = StringBuilder::new()
  for i in (tab + 1)..<chars.length() {
    right.write_char(chars[i])
  }
  Some(CacheLine::{ key: left.to_string(), value: right.to_string() })
}

///|
fn encode_value(value : Value) -> String {
  match value {
    Value::Int(n) => "i:" + n.to_string()
    Value::Bool(b) => "b:" + (if b { "1" } else { "0" })
    Value::String(s) => "s:" + escape_cache(s)
    Value::Path(p) => "p:" + escape_cache(p.as_string())
    Value::Unit => "u:"
    Value::Tuple(items) => "t:" + encode_list(items)
    Value::Record(fields) => "r:" + encode_record(fields)
    Value::Array(items) => "a:" + encode_list(items)
    Value::Map(fields) => "m:" + encode_record(fields)
    Value::ArrayBuilder(items) => "ab:" + encode_list(items)
    Value::MapBuilder(fields) => "mb:" + encode_record(fields)
    Value::Fn(_) => "f:"
  }
}

///|
fn decode_value(encoded : String) -> Value? {
  if encoded.has_prefix("i:") {
    let rest = slice_from(encoded, 2)
    let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(
      rest,
    )
    match parsed {
      Ok(v) => Some(Value::Int(v))
      Err(_) => None
    }
  } else if encoded.has_prefix("s:") {
    let rest = slice_from(encoded, 2)
    Some(Value::String(unescape_cache(rest)))
  } else if encoded.has_prefix("b:") {
    let rest = slice_from(encoded, 2)
    if rest == "1" {
      Some(Value::Bool(true))
    } else if rest == "0" {
      Some(Value::Bool(false))
    } else {
      None
    }
  } else if encoded.has_prefix("p:") {
    let rest = slice_from(encoded, 2)
    Some(Value::Path(Path::new(unescape_cache(rest))))
  } else if encoded == "u:" {
    Some(Value::Unit)
  } else if encoded.has_prefix("t:") {
    let rest = slice_from(encoded, 2)
    match decode_list(rest) {
      Some(items) => Some(Value::Tuple(items))
      None => None
    }
  } else if encoded.has_prefix("a:") {
    let rest = slice_from(encoded, 2)
    match decode_list(rest) {
      Some(items) => Some(Value::Array(items))
      None => None
    }
  } else if encoded.has_prefix("r:") {
    let rest = slice_from(encoded, 2)
    match decode_record(rest) {
      Some(fields) => Some(Value::Record(fields))
      None => None
    }
  } else if encoded.has_prefix("m:") {
    let rest = slice_from(encoded, 2)
    match decode_record(rest) {
      Some(fields) => Some(Value::Map(fields))
      None => None
    }
  } else if encoded.has_prefix("ab:") {
    let rest = slice_from(encoded, 3)
    match decode_list(rest) {
      Some(items) => Some(Value::ArrayBuilder(items))
      None => None
    }
  } else if encoded.has_prefix("mb:") {
    let rest = slice_from(encoded, 3)
    match decode_record(rest) {
      Some(fields) => Some(Value::MapBuilder(fields))
      None => None
    }
  } else {
    None
  }
}

///|
fn encode_list(items : Array[Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string(items.length().to_string())
  for item in items {
    let enc = encode_value(item)
    write_segment(buf, enc)
  }
  buf.to_string()
}

///|
fn encode_record(fields : Map[String, Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string(fields.length().to_string())
  for name, value in fields {
    write_segment(buf, name)
    let enc = encode_value(value)
    write_segment(buf, enc)
  }
  buf.to_string()
}

///|
fn write_segment(buf : StringBuilder, s : String) -> Unit {
  buf.write_char(':')
  buf.write_string(s.length().to_string())
  buf.write_char(':')
  buf.write_string(s)
}

///|
fn decode_list(s : String) -> Array[Value]? {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let (count, idx) = match read_number(chars, 0) {
    Some(v) => v
    None => return None
  }
  let out : Array[Value] = []
  let mut pos = idx
  for _ in 0..<count {
    let (seg, next_pos) = match read_segment(chars, pos) {
      Some(v) => v
      None => return None
    }
    match decode_value(seg) {
      Some(v) => out.push(v)
      None => return None
    }
    pos = next_pos
  }
  if pos != chars.length() {
    return None
  }
  Some(out)
}

///|
fn decode_record(s : String) -> Map[String, Value]? {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let (count, idx) = match read_number(chars, 0) {
    Some(v) => v
    None => return None
  }
  let out : Map[String, Value] = {}
  let mut pos = idx
  for _ in 0..<count {
    let (name, next_pos) = match read_segment(chars, pos) {
      Some(v) => v
      None => return None
    }
    let (val_str, next_pos2) = match read_segment(chars, next_pos) {
      Some(v) => v
      None => return None
    }
    match decode_value(val_str) {
      Some(v) => out[name] = v
      None => return None
    }
    pos = next_pos2
  }
  if pos != chars.length() {
    return None
  }
  Some(out)
}

///|
fn read_number(chars : Array[Char], start : Int) -> (Int, Int)? {
  let mut i = start
  if i >= chars.length() {
    return None
  }
  let mut value = 0
  let mut saw = false
  while i < chars.length() {
    let c = chars[i]
    if c < '0' || c > '9' {
      break
    }
    value = value * 10 + (c.to_int() - '0'.to_int())
    saw = true
    i += 1
  }
  if not(saw) {
    return None
  }
  Some((value, i))
}

///|
fn read_segment(chars : Array[Char], start : Int) -> (String, Int)? {
  if start >= chars.length() || chars[start] != ':' {
    return None
  }
  let (len, idx) = match read_number(chars, start + 1) {
    Some(v) => v
    None => return None
  }
  if idx >= chars.length() || chars[idx] != ':' {
    return None
  }
  let seg_start = idx + 1
  let seg_end = seg_start + len
  if seg_end > chars.length() {
    return None
  }
  let buf = StringBuilder::new()
  for i in seg_start..<seg_end {
    buf.write_char(chars[i])
  }
  Some((buf.to_string(), seg_end))
}

///|
fn escape_cache(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s {
    match ch {
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
fn unescape_cache(s : String) -> String {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let buf = StringBuilder::new()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' && i + 1 < chars.length() {
      let next = chars[i + 1]
      match next {
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
        '\\' => buf.write_char('\\')
        _ => buf.write_char(next)
      }
      i += 2
    } else {
      buf.write_char(c)
      i += 1
    }
  }
  buf.to_string()
}

///|
fn slice_from(s : String, start : Int) -> String {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let buf = StringBuilder::new()
  if start < chars.length() {
    for i in start..<chars.length() {
      buf.write_char(chars[i])
    }
  }
  buf.to_string()
}
