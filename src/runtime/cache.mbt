///|
/// Pure function result cache (external snapshot)
pub struct PureCache {
  entries : Map[String, @core.Value]
} derive(Eq)

///|
pub impl Show for PureCache with fn output(self, logger) {
  logger.write_string("PureCache(len=")
  logger.write_string(self.entries.length().to_string())
  logger.write_string(")")
}

///|
pub fn PureCache::new() -> PureCache {
  { entries: {} }
}

///|
pub fn PureCache::get(self : PureCache, key : String) -> @core.Value? {
  self.entries.get(key)
}

///|
pub fn PureCache::set(
  self : PureCache,
  key : String,
  value : @core.Value,
) -> Unit {
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
    let line_str = line.to_owned()
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
fn encode_value(value : @core.Value) -> String {
  match value {
    @core.Value::Int(n) => "i:" + n.to_string()
    @core.Value::Float(n) => "f32:" + n.to_string()
    @core.Value::Double(n) => "f64:" + n.to_string()
    @core.Value::Bool(b) => "b:" + (if b { "1" } else { "0" })
    @core.Value::Char(c) => "c:" + c.to_int().to_string()
    @core.Value::String(s) => "s:" + escape_cache(s)
    @core.Value::Path(p) => "p:" + escape_cache(p.as_string())
    @core.Value::PromptText(pt) => "pt:" + escape_cache(pt.as_string())
    @core.Value::Unit => "u:"
    @core.Value::Tuple(items) => "t:" + encode_list(items)
    @core.Value::Record(fields) => "r:" + encode_record(fields)
    @core.Value::Array(items) => "a:" + encode_list(items)
    @core.Value::Map(fields) => "m:" + encode_record(fields)
    @core.Value::Set(items) => "set:" + encode_record(items)
    @core.Value::ArrayBuilder(items) => "ab:" + encode_list(items)
    @core.Value::MapBuilder(fields) => "mb:" + encode_record(fields)
    @core.Value::StringBuilder(chunks) => {
      let mut s = "sb:"
      for i, chunk in chunks {
        if i > 0 {
          s = s + ","
        }
        s = s + chunk
      }
      s
    }
    @core.Value::Bytes(data) => {
      let mut s = "by:"
      for i, b in data {
        if i > 0 {
          s = s + ","
        }
        s = s + b.to_int().to_string()
      }
      s
    }
    @core.Value::Fn(_) => "f:"
    @core.Value::Continuation(_) => "k:"
  }
}

///|
fn decode_value(encoded : String) -> @core.Value? {
  if encoded.has_prefix("i:") {
    let rest = slice_from(encoded, 2)
    let parsed : Result[Int64, Error] = try? @string.parse_int64(rest)
    match parsed {
      Ok(v) => Some(@core.Value::Int(v))
      Err(_) => None
    }
  } else if encoded.has_prefix("f32:") {
    let rest = slice_from(encoded, 4)
    let parsed : Result[Double, Error] = try? @string.parse_double(rest)
    match parsed {
      Ok(v) => Some(@core.Value::Float(Float::from_double(v)))
      Err(_) => None
    }
  } else if encoded.has_prefix("f64:") {
    let rest = slice_from(encoded, 4)
    let parsed : Result[Double, Error] = try? @string.parse_double(rest)
    match parsed {
      Ok(v) => Some(@core.Value::Double(v))
      Err(_) => None
    }
  } else if encoded.has_prefix("s:") {
    let rest = slice_from(encoded, 2)
    Some(@core.Value::String(unescape_cache(rest)))
  } else if encoded.has_prefix("b:") {
    let rest = slice_from(encoded, 2)
    if rest == "1" {
      Some(@core.Value::Bool(true))
    } else if rest == "0" {
      Some(@core.Value::Bool(false))
    } else {
      None
    }
  } else if encoded.has_prefix("c:") {
    let rest = slice_from(encoded, 2)
    let parsed : Result[Int, Error] = try? @string.parse_int(rest)
    match parsed {
      Ok(code) =>
        match Int::to_char(code) {
          Some(ch) => Some(@core.Value::Char(ch))
          None => None
        }
      Err(_) => None
    }
  } else if encoded.has_prefix("pt:") {
    let rest = slice_from(encoded, 3)
    Some(@core.Value::PromptText(@core.PromptText::new(unescape_cache(rest))))
  } else if encoded.has_prefix("p:") {
    let rest = slice_from(encoded, 2)
    Some(@core.Value::Path(@core.Path::new(unescape_cache(rest))))
  } else if encoded == "u:" {
    Some(@core.Value::Unit)
  } else if encoded.has_prefix("t:") {
    let rest = slice_from(encoded, 2)
    match decode_list(rest) {
      Some(items) => Some(@core.Value::Tuple(items))
      None => None
    }
  } else if encoded.has_prefix("a:") {
    let rest = slice_from(encoded, 2)
    match decode_list(rest) {
      Some(items) => Some(@core.Value::Array(items))
      None => None
    }
  } else if encoded.has_prefix("r:") {
    let rest = slice_from(encoded, 2)
    match decode_record(rest) {
      Some(fields) => Some(@core.Value::Record(fields))
      None => None
    }
  } else if encoded.has_prefix("m:") {
    let rest = slice_from(encoded, 2)
    match decode_record(rest) {
      Some(fields) => Some(@core.Value::Map(fields))
      None => None
    }
  } else if encoded.has_prefix("ab:") {
    let rest = slice_from(encoded, 3)
    match decode_list(rest) {
      Some(items) => Some(@core.Value::ArrayBuilder(items))
      None => None
    }
  } else if encoded.has_prefix("mb:") {
    let rest = slice_from(encoded, 3)
    match decode_record(rest) {
      Some(fields) => Some(@core.Value::MapBuilder(fields))
      None => None
    }
  } else if encoded.has_prefix("sb:") {
    let rest = slice_from(encoded, 3)
    let chunks : Array[String] = []
    if rest.length() > 0 {
      // Simple split by comma (chunks shouldn't contain commas in practice)
      chunks.push(rest)
    }
    Some(@core.Value::StringBuilder(chunks))
  } else {
    None
  }
}

///|
fn encode_list(items : Array[@core.Value]) -> String {
  let buf = StringBuilder::new()
  buf.write_string(items.length().to_string())
  for item in items {
    let enc = encode_value(item)
    write_segment(buf, enc)
  }
  buf.to_string()
}

///|
fn encode_record(fields : Map[String, @core.Value]) -> String {
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
fn decode_list(s : String) -> Array[@core.Value]? {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let (count, idx) = match read_number(chars, 0) {
    Some(v) => v
    None => return None
  }
  let out : Array[@core.Value] = []
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
fn decode_record(s : String) -> Map[String, @core.Value]? {
  let chars : Array[Char] = []
  for c in s {
    chars.push(c)
  }
  let (count, idx) = match read_number(chars, 0) {
    Some(v) => v
    None => return None
  }
  let out : Map[String, @core.Value] = {}
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
  if !saw {
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
