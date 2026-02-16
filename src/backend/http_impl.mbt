///|
priv enum HttpEntry {
  ClientResponse(
    status~ : Int,
    headers~ : Map[String, String],
    body~ : String,
  )
  ServerHandle(@http.Server)
  ServerRequest(
    conn~ : @http.ServerConnection,
    meth~ : String,
    url~ : String,
    headers~ : Map[String, String],
    body~ : String,
  )
}

///|
let http_table : Array[HttpEntry?] = []

///|
fn http_alloc_handle(entry : HttpEntry) -> Int {
  for i = 0; i < http_table.length(); i = i + 1 {
    if http_table[i] is None {
      http_table[i] = Some(entry)
      return i
    }
  }
  let idx = http_table.length()
  http_table.push(Some(entry))
  idx
}

///|
fn http_free_handle(idx : Int) -> Unit {
  if idx >= 0 && idx < http_table.length() {
    http_table[idx] = None
  }
}

///|
fn http_get_entry(handle : Int) -> HttpEntry? {
  if handle >= 0 && handle < http_table.length() {
    http_table[handle]
  } else {
    None
  }
}

///|
fn parse_headers_to_map(s : String) -> Map[String, String] {
  let result : Map[String, String] = {}
  if s.length() == 0 {
    return result
  }
  let key_buf : Array[Char] = []
  let val_buf : Array[Char] = []
  let mut in_value = false
  let mut skip_space = false
  for ch in s {
    if ch == '\n' {
      if key_buf.length() > 0 {
        result[String::from_array(key_buf)] = String::from_array(val_buf)
      }
      key_buf.clear()
      val_buf.clear()
      in_value = false
      skip_space = false
    } else if not(in_value) && ch == ':' {
      in_value = true
      skip_space = true
    } else if skip_space && ch == ' ' {
      skip_space = false
    } else if in_value {
      skip_space = false
      val_buf.push(ch)
    } else {
      key_buf.push(ch)
    }
  }
  if key_buf.length() > 0 {
    result[String::from_array(key_buf)] = String::from_array(val_buf)
  }
  result
}

///|
fn method_to_string(m : @http.RequestMethod) -> String {
  match m {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
  }
}

// --- Client API ---

///|
pub fn http_request(
  meth : String,
  url : String,
  headers : String,
  body : String,
) -> Result[Int, String] {
  let out : Ref[Result[Int, String]] = @ref.new(Err("not initialized"))
  @async.run_async_main(async fn() {
    let h = parse_headers_to_map(headers)
    let (response, data) = try {
      match meth {
        "POST" => @http.post(url, body, headers=h)
        "PUT" => @http.put(url, body, headers=h)
        _ => @http.get(url, headers=h)
      }
    } catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let body_text = try {
      data.text()
    } catch {
      _ => ""
    }
    let handle = http_alloc_handle(
      HttpEntry::ClientResponse(
        status=response.code,
        headers=response.headers,
        body=body_text,
      ),
    )
    out.val = Ok(handle)
  })
  out.val
}

///|
pub fn http_response_status(handle : Int) -> Result[Int, String] {
  match http_get_entry(handle) {
    Some(ClientResponse(status~, ..)) => Ok(status)
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_response_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ClientResponse(headers~, ..)) => {
      let lower_name = name.to_lower()
      let mut found = ""
      for k, v in headers {
        if k == lower_name {
          found = v
        }
      }
      Ok(found)
    }
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_response_body(handle : Int) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ClientResponse(body~, ..)) => Ok(body)
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_close(handle : Int) -> Result[Unit, String] {
  match http_get_entry(handle) {
    Some(ServerHandle(server)) => server.close()
    Some(ServerRequest(conn~, ..)) => conn.close()
    Some(ClientResponse(..)) => ()
    None => return Err("invalid handle: " + handle.to_string())
  }
  http_free_handle(handle)
  Ok(())
}

// --- Server API ---

///|
pub fn http_listen(port : Int) -> Result[Int, String] {
  let out : Ref[Result[Int, String]] = @ref.new(Err("not initialized"))
  @async.run_async_main(async fn() {
    let server = try {
      @http.Server::new(port=port)
    } catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let handle = http_alloc_handle(HttpEntry::ServerHandle(server))
    out.val = Ok(handle)
  })
  out.val
}

///|
pub fn http_accept(server_handle : Int) -> Result[Int, String] {
  let server = match http_get_entry(server_handle) {
    Some(ServerHandle(s)) => s
    _ =>
      return Err("invalid server handle: " + server_handle.to_string())
  }
  let out : Ref[Result[Int, String]] = @ref.new(Err("not initialized"))
  @async.run_async_main(async fn() {
    let (conn, _addr) = try {
      server.accept()
    } catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let request = try {
      conn.read_request()
    } catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let body_text = try {
      let data = @async_io.Reader::read_all(conn)
      data.text()
    } catch {
      _ => ""
    }
    let handle = http_alloc_handle(
      HttpEntry::ServerRequest(
        conn~,
        meth=method_to_string(request.meth),
        url=request.path,
        headers=request.headers,
        body=body_text,
      ),
    )
    out.val = Ok(handle)
  })
  out.val
}

///|
pub fn http_request_method(handle : Int) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ServerRequest(meth~, ..)) => Ok(meth)
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_request_url(handle : Int) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ServerRequest(url~, ..)) => Ok(url)
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_request_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ServerRequest(headers~, ..)) => {
      let lower_name = name.to_lower()
      let mut found = ""
      for k, v in headers {
        if k == lower_name {
          found = v
        }
      }
      Ok(found)
    }
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_request_body(handle : Int) -> Result[String, String] {
  match http_get_entry(handle) {
    Some(ServerRequest(body~, ..)) => Ok(body)
    _ => Err("invalid handle: " + handle.to_string())
  }
}

///|
pub fn http_respond(
  handle : Int,
  status : Int,
  headers : String,
  body : String,
) -> Result[Unit, String] {
  let conn = match http_get_entry(handle) {
    Some(ServerRequest(conn~, ..)) => conn
    _ => return Err("invalid handle: " + handle.to_string())
  }
  let out : Ref[Result[Unit, String]] = @ref.new(Err("not initialized"))
  let extra_headers = parse_headers_to_map(headers)
  @async.run_async_main(async fn() {
    try {
      conn.send_response(status, "OK", extra_headers~)
      @async_io.Writer::write(conn, body)
      conn.end_response()
    } catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    out.val = Ok(())
  })
  out.val
}
