///|
pub fn http_request(
  _meth : String,
  _url : String,
  _headers : String,
  _body : String,
) -> Result[Int, String] {
  Err("Http::request not supported on this target")
}

///|
pub fn http_response_status(_handle : Int) -> Result[Int, String] {
  Err("Http::response_status not supported on this target")
}

///|
pub fn http_response_header(
  _handle : Int,
  _name : String,
) -> Result[String, String] {
  Err("Http::response_header not supported on this target")
}

///|
pub fn http_response_body(_handle : Int) -> Result[String, String] {
  Err("Http::response_body not supported on this target")
}

///|
pub fn http_close(_handle : Int) -> Result[Unit, String] {
  Err("Http::close not supported on this target")
}

///|
pub fn http_listen(_port : Int) -> Result[Int, String] {
  Err("Http::listen not supported on this target")
}

///|
pub fn http_accept(_server_handle : Int) -> Result[Int, String] {
  Err("Http::accept not supported on this target")
}

///|
pub fn http_request_method(_handle : Int) -> Result[String, String] {
  Err("Http::request_method not supported on this target")
}

///|
pub fn http_request_url(_handle : Int) -> Result[String, String] {
  Err("Http::request_url not supported on this target")
}

///|
pub fn http_request_header(
  _handle : Int,
  _name : String,
) -> Result[String, String] {
  Err("Http::request_header not supported on this target")
}

///|
pub fn http_request_body(_handle : Int) -> Result[String, String] {
  Err("Http::request_body not supported on this target")
}

///|
pub fn http_respond(
  _handle : Int,
  _status : Int,
  _headers : String,
  _body : String,
) -> Result[Unit, String] {
  Err("Http::respond not supported on this target")
}
