///|
pub fn tcp_connect(host : String, port : Int) -> Result[Int, String] {
  let _ = host
  let _ = port
  Err("tcp_connect not supported on wasm target")
}

///|
pub fn tcp_read(fd : Int, max_bytes : Int) -> Result[String, String] {
  let _ = fd
  let _ = max_bytes
  Err("tcp_read not supported on wasm target")
}

///|
pub fn tcp_write(fd : Int, data : String) -> Result[Unit, String] {
  let _ = fd
  let _ = data
  Err("tcp_write not supported on wasm target")
}

///|
pub fn tcp_close(fd : Int) -> Result[Unit, String] {
  let _ = fd
  Err("tcp_close not supported on wasm target")
}
