///|
pub fn http_request(
  meth : String,
  url : String,
  headers : String,
  body : String,
) -> Result[Int, String] {
  let _ = meth
  let _ = url
  let _ = headers
  let _ = body
  Err("http_request not supported on js target")
}

///|
pub fn http_response_status(handle : Int) -> Result[Int, String] {
  let _ = handle
  Err("http_response_status not supported on js target")
}

///|
pub fn http_response_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  let _ = handle
  let _ = name
  Err("http_response_header not supported on js target")
}

///|
pub fn http_response_body(handle : Int) -> Result[String, String] {
  let _ = handle
  Err("http_response_body not supported on js target")
}

///|
pub fn http_close(handle : Int) -> Result[Unit, String] {
  let _ = handle
  Err("http_close not supported on js target")
}

///|
pub fn http_listen(port : Int) -> Result[Int, String] {
  let _ = port
  Err("http_listen not supported on js target")
}

///|
pub fn http_accept(server_handle : Int) -> Result[Int, String] {
  let _ = server_handle
  Err("http_accept not supported on js target")
}

///|
pub fn http_request_method(handle : Int) -> Result[String, String] {
  let _ = handle
  Err("http_request_method not supported on js target")
}

///|
pub fn http_request_url(handle : Int) -> Result[String, String] {
  let _ = handle
  Err("http_request_url not supported on js target")
}

///|
pub fn http_request_header(
  handle : Int,
  name : String,
) -> Result[String, String] {
  let _ = handle
  let _ = name
  Err("http_request_header not supported on js target")
}

///|
pub fn http_request_body(handle : Int) -> Result[String, String] {
  let _ = handle
  Err("http_request_body not supported on js target")
}

///|
pub fn http_respond(
  handle : Int,
  status : Int,
  headers : String,
  body : String,
) -> Result[Unit, String] {
  let _ = handle
  let _ = status
  let _ = headers
  let _ = body
  Err("http_respond not supported on js target")
}
