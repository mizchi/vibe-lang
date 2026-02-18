///|
pub fn exec_command_lines(cmd : String) -> Result[Array[String], String] {
  let out : Ref[Result[Array[String], String]] = @ref.new(
    Err("not initialized"),
  )
  @async.run_async_main(async fn() {
    let (exit_code, data) = @async_process.collect_stdout("sh", ["-c", cmd]) catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    if exit_code != 0 {
      out.val = Err(
        "command exited with code " + exit_code.to_string() + ": " + cmd,
      )
      return
    }
    let text = data.text() catch { _ => "" }
    let lines : Array[String] = []
    for part in text.split("\n") {
      lines.push(part.to_string())
    }
    // Remove trailing empty line from final newline
    if lines.length() > 0 && lines[lines.length() - 1] == "" {
      let _ = lines.pop()
    }
    out.val = Ok(lines)
  })
  out.val
}
