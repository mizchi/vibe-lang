///|
#borrow(host_ptr)
extern "C" fn vibe_tcp_connect(
  host_ptr : Bytes,
  host_len : Int,
  port : Int,
) -> Int = "vibe_tcp_connect"

///|
#borrow(buf)
extern "C" fn vibe_tcp_read(fd : Int, buf : Bytes, buf_len : Int) -> Int = "vibe_tcp_read"

///|
#borrow(buf)
extern "C" fn vibe_tcp_write(fd : Int, buf : Bytes, buf_len : Int) -> Int = "vibe_tcp_write"

///|
extern "C" fn vibe_tcp_close(fd : Int) -> Int = "vibe_tcp_close"

///|
fn string_to_utf8(s : String) -> Bytes {
  // For IPv4 addresses and typical ASCII data
  let arr : Array[Byte] = []
  for ch in s {
    let cp = ch.to_int()
    if cp < 0x80 {
      arr.push(cp.to_byte())
    } else if cp < 0x800 {
      arr.push((0xC0 | (cp >> 6)).to_byte())
      arr.push((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      arr.push((0xE0 | (cp >> 12)).to_byte())
      arr.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      arr.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      arr.push((0xF0 | (cp >> 18)).to_byte())
      arr.push((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      arr.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      arr.push((0x80 | (cp & 0x3F)).to_byte())
    }
  }
  Bytes::from_array(arr[:])
}

///|
fn utf8_to_string(bytes : Bytes, len : Int) -> String {
  let chars : Array[Char] = []
  let mut i = 0
  while i < len {
    let b0 = bytes[i].to_int()
    if b0 < 0x80 {
      chars.push(b0.unsafe_to_char())
      i += 1
    } else if b0 < 0xE0 {
      let cp = ((b0 & 0x1F) << 6) | (bytes[i + 1].to_int() & 0x3F)
      chars.push(cp.unsafe_to_char())
      i += 2
    } else if b0 < 0xF0 {
      let cp = ((b0 & 0x0F) << 12) |
        ((bytes[i + 1].to_int() & 0x3F) << 6) |
        (bytes[i + 2].to_int() & 0x3F)
      chars.push(cp.unsafe_to_char())
      i += 3
    } else {
      let cp = ((b0 & 0x07) << 18) |
        ((bytes[i + 1].to_int() & 0x3F) << 12) |
        ((bytes[i + 2].to_int() & 0x3F) << 6) |
        (bytes[i + 3].to_int() & 0x3F)
      chars.push(cp.unsafe_to_char())
      i += 4
    }
  }
  String::from_array(chars)
}

///|
pub fn tcp_connect(host : String, port : Int) -> Result[Int, String] {
  let bytes = string_to_utf8(host)
  let fd = vibe_tcp_connect(bytes, bytes.length(), port)
  if fd < 0 {
    Err("tcp_connect failed (errno=" + fd.to_string() + ")")
  } else {
    Ok(fd)
  }
}

///|
pub fn tcp_read(fd : Int, max_bytes : Int) -> Result[String, String] {
  let buf = Bytes::new(max_bytes)
  let n = vibe_tcp_read(fd, buf, max_bytes)
  if n < 0 {
    Err("tcp_read failed (errno=" + n.to_string() + ")")
  } else {
    Ok(utf8_to_string(buf, n))
  }
}

///|
pub fn tcp_write(fd : Int, data : String) -> Result[Unit, String] {
  let bytes = string_to_utf8(data)
  let n = vibe_tcp_write(fd, bytes, bytes.length())
  if n < 0 {
    Err("tcp_write failed (errno=" + n.to_string() + ")")
  } else {
    Ok(())
  }
}

///|
pub fn tcp_close(fd : Int) -> Result[Unit, String] {
  let ret = vibe_tcp_close(fd)
  if ret < 0 {
    Err("tcp_close failed (errno=" + ret.to_string() + ")")
  } else {
    Ok(())
  }
}
