///|
pub fn exec_available() -> Bool {
  false
}

///|
pub fn exec_command_lines(_cmd : String) -> Result[Array[String], String] {
  Err("process execution not available on this target")
}

///|
pub fn exec_command_capture(
  _cmd : String,
) -> Result[(Int, Array[String]), String] {
  Err("process execution not available on this target")
}
