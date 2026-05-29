///|
pub fn exec_available() -> Bool {
  true
}

///|
/// Runs `cmd` and captures its full stdout into an internal growable buffer,
/// writing the captured length to `out_len[0]`. Returns the subprocess exit
/// code, or a negative value on spawn failure. Pair with `c_popen_drain`.
#borrow(cmd_ptr, out_len)
extern "c" fn c_popen_exec(
  cmd_ptr : Bytes,
  cmd_len : Int,
  out_len : FixedArray[Int],
) -> Int = "vibe_popen_exec"

///|
/// Copies up to `cap` bytes of the most recent capture into `buf` and frees
/// the internal buffer. Returns the number of bytes copied.
#borrow(buf)
extern "c" fn c_popen_drain(buf : Bytes, cap : Int) -> Int = "vibe_popen_drain"

///|
/// Runs `cmd` and returns its exit code together with the full captured
/// stdout. There is no output-size cap: the C side reads into a growable
/// buffer and reports the true length, so large outputs are never silently
/// truncated. Returns `Err` only when the subprocess could not be spawned.
fn run_command(cmd : String) -> Result[(Int, String), String] {
  let cmd_bytes = string_to_utf8(cmd)
  let cmd_len = cmd_bytes.length()
  let out_len : FixedArray[Int] = [0]
  let exit_code = c_popen_exec(cmd_bytes, cmd_len, out_len)
  if exit_code < 0 {
    return Err("popen failed: " + cmd)
  }
  let actual_len = out_len[0]
  let buf = Bytes::new(actual_len)
  // Always drain, even for empty output, to release the internal buffer.
  let _ = c_popen_drain(buf, actual_len)
  Ok((exit_code, utf8_to_string(buf, actual_len)))
}

///|
/// Splits captured text into lines, dropping the trailing empty line that a
/// final newline produces.
fn split_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  for part_view in text.split("\n") {
    lines.push(part_view.to_owned())
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    let _ = lines.pop()
  }
  lines
}

///|
pub fn exec_command_lines(cmd : String) -> Result[Array[String], String] {
  match run_command(cmd) {
    Err(e) => Err(e)
    Ok((exit_code, text)) =>
      if exit_code != 0 {
        Err("command exited with code " + exit_code.to_string() + ": " + cmd)
      } else {
        Ok(split_lines(text))
      }
  }
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
  match run_command(cmd) {
    Err(e) => Err(e)
    Ok((exit_code, text)) => Ok((exit_code, split_lines(text)))
  }
}
