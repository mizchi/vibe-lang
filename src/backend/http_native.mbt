///|
#borrow(method_ptr, url_ptr, headers_ptr, body_ptr)
extern "C" fn vibe_http_request(
  method_ptr : Bytes,
  method_len : Int,
  url_ptr : Bytes,
  url_len : Int,
  headers_ptr : Bytes,
  headers_len : Int,
  body_ptr : Bytes,
  body_len : Int,
) -> Int = "vibe_http_request"

///|
extern "C" fn vibe_http_response_status(handle : Int) -> Int = "vibe_http_response_status"

///|
#borrow(name_ptr, out_buf)
extern "C" fn vibe_http_response_header(
  handle : Int,
  name_ptr : Bytes,
  name_len : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_response_header"

///|
#borrow(out_buf)
extern "C" fn vibe_http_response_body(
  handle : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_response_body"

///|
extern "C" fn vibe_http_close(handle : Int) -> Int = "vibe_http_close"

///|
extern "C" fn vibe_http_listen(port : Int) -> Int = "vibe_http_listen"

///|
extern "C" fn vibe_http_accept(server_handle : Int) -> Int = "vibe_http_accept"

///|
#borrow(out_buf)
extern "C" fn vibe_http_request_method(
  handle : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_request_method"

///|
#borrow(out_buf)
extern "C" fn vibe_http_request_url(
  handle : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_request_url"

///|
#borrow(name_ptr, out_buf)
extern "C" fn vibe_http_request_header(
  handle : Int,
  name_ptr : Bytes,
  name_len : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_request_header"

///|
#borrow(out_buf)
extern "C" fn vibe_http_request_body(
  handle : Int,
  out_buf : Bytes,
  out_buf_len : Int,
) -> Int = "vibe_http_request_body"

///|
#borrow(headers_ptr, body_ptr)
extern "C" fn vibe_http_respond(
  handle : Int,
  status : Int,
  headers_ptr : Bytes,
  headers_len : Int,
  body_ptr : Bytes,
  body_len : Int,
) -> Int = "vibe_http_respond"

///|
fn http_string_to_utf8(s : String) -> Bytes {
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
fn http_utf8_to_string(bytes : Bytes, len : Int) -> String {
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
pub fn http_request(
  meth : String,
  url : String,
  headers : String,
  body : String,
) -> Result[Int, String] {
  let m = http_string_to_utf8(meth)
  let u = http_string_to_utf8(url)
  let h = http_string_to_utf8(headers)
  let b = http_string_to_utf8(body)
  let handle = vibe_http_request(
    m,
    m.length(),
    u,
    u.length(),
    h,
    h.length(),
    b,
    b.length(),
  )
  if handle < 0 {
    Err("http_request failed (errno=" + handle.to_string() + ")")
  } else {
    Ok(handle)
  }
}

///|
pub fn http_response_status(handle : Int) -> Result[Int, String] {
  let status = vibe_http_response_status(handle)
  if status < 0 {
    Err("http_response_status failed (errno=" + status.to_string() + ")")
  } else {
    Ok(status)
  }
}

///|
pub fn http_response_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  let n = http_string_to_utf8(name)
  let buf = Bytes::new(8192)
  let len = vibe_http_response_header(handle, n, n.length(), buf, 8192)
  if len < 0 {
    Err("http_response_header failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_response_body(handle : Int) -> Result[String, String] {
  let buf = Bytes::new(1048576)
  let len = vibe_http_response_body(handle, buf, 1048576)
  if len < 0 {
    Err("http_response_body failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_close(handle : Int) -> Result[Unit, String] {
  let ret = vibe_http_close(handle)
  if ret < 0 {
    Err("http_close failed (errno=" + ret.to_string() + ")")
  } else {
    Ok(())
  }
}

///|
pub fn http_listen(port : Int) -> Result[Int, String] {
  let handle = vibe_http_listen(port)
  if handle < 0 {
    Err("http_listen failed (errno=" + handle.to_string() + ")")
  } else {
    Ok(handle)
  }
}

///|
pub fn http_accept(server_handle : Int) -> Result[Int, String] {
  let handle = vibe_http_accept(server_handle)
  if handle < 0 {
    Err("http_accept failed (errno=" + handle.to_string() + ")")
  } else {
    Ok(handle)
  }
}

///|
pub fn http_request_method(handle : Int) -> Result[String, String] {
  let buf = Bytes::new(16)
  let len = vibe_http_request_method(handle, buf, 16)
  if len < 0 {
    Err("http_request_method failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_request_url(handle : Int) -> Result[String, String] {
  let buf = Bytes::new(4096)
  let len = vibe_http_request_url(handle, buf, 4096)
  if len < 0 {
    Err("http_request_url failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_request_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  let n = http_string_to_utf8(name)
  let buf = Bytes::new(8192)
  let len = vibe_http_request_header(handle, n, n.length(), buf, 8192)
  if len < 0 {
    Err("http_request_header failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_request_body(handle : Int) -> Result[String, String] {
  let buf = Bytes::new(1048576)
  let len = vibe_http_request_body(handle, buf, 1048576)
  if len < 0 {
    Err("http_request_body failed (errno=" + len.to_string() + ")")
  } else {
    Ok(http_utf8_to_string(buf, len))
  }
}

///|
pub fn http_respond(
  handle : Int,
  status : Int,
  headers : String,
  body : String,
) -> Result[Unit, String] {
  let h = http_string_to_utf8(headers)
  let b = http_string_to_utf8(body)
  let ret = vibe_http_respond(handle, status, h, h.length(), b, b.length())
  if ret < 0 {
    Err("http_respond failed (errno=" + ret.to_string() + ")")
  } else {
    Ok(())
  }
}
