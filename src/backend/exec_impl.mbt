///|
pub fn exec_available() -> Bool {
  true
}

///|
#borrow(cmd_ptr)
#borrow(cmd_ptr, buf, out_len)
extern "c" fn c_popen_exec(
  cmd_ptr : Bytes,
  cmd_len : Int,
  buf : Bytes,
  buf_cap : Int,
  out_len : FixedArray[Int],
) -> Int = "vibe_popen_exec"

///|
pub fn exec_command_lines(cmd : String) -> Result[Array[String], String] {
  let cmd_bytes = string_to_utf8(cmd)
  let cmd_len = cmd_bytes.length()
  let buf_cap = 1024 * 1024 // 1 MB
  let buf = Bytes::new(buf_cap)
  let out_len : FixedArray[Int] = [0]
  let exit_code = c_popen_exec(cmd_bytes, cmd_len, buf, buf_cap, out_len)
  if exit_code < 0 {
    return Err("popen failed: " + cmd)
  }
  let actual_len = out_len[0]
  let text = utf8_to_string(buf, actual_len)
  if exit_code != 0 {
    return Err("command exited with code " + exit_code.to_string() + ": " + cmd)
  }
  let lines : Array[String] = []
  for part_view in text.split("\n") {
    lines.push(part_view.to_owned())
  }
  // Remove trailing empty line from final newline
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    let _ = lines.pop()
  }
  Ok(lines)
}

///|
/// Like `exec_command_lines` but surfaces the exit code instead of
/// treating non-zero as an error. Returns `Err` only when the subprocess
/// could not be spawned (popen failure). This is the variant `vibe check`
/// uses to delegate to the selfhost wasi bundle, where exit code 1 means
/// "the check found errors" rather than "the runner failed".
pub fn exec_command_capture(
  cmd : String,
) -> Result[(Int, Array[String]), String] {
  let cmd_bytes = string_to_utf8(cmd)
  let cmd_len = cmd_bytes.length()
  let buf_cap = 1024 * 1024
  let buf = Bytes::new(buf_cap)
  let out_len : FixedArray[Int] = [0]
  let exit_code = c_popen_exec(cmd_bytes, cmd_len, buf, buf_cap, out_len)
  if exit_code < 0 {
    return Err("popen failed: " + cmd)
  }
  let actual_len = out_len[0]
  let text = utf8_to_string(buf, actual_len)
  let lines : Array[String] = []
  for part_view in text.split("\n") {
    lines.push(part_view.to_owned())
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    let _ = lines.pop()
  }
  Ok((exit_code, lines))
}
