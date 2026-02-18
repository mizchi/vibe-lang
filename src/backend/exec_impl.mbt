///|
#borrow(cmd_ptr)
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
    return Err(
      "command exited with code " + exit_code.to_string() + ": " + cmd,
    )
  }
  let lines : Array[String] = []
  for part_view in text.split("\n") {
    lines.push(part_view.to_string())
  }
  // Remove trailing empty line from final newline
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    let _ = lines.pop()
  }
  Ok(lines)
}
