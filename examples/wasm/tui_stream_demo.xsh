// Stream-based pseudo TUI demo for wasm component runtime.
// Run:
//   printf 'hello\nworld\n' | just component-run examples/wasm/tui_stream_demo.xsh
//
// Notes:
// - Uses stdin/stdout stream builtins.
// - In many hosts stdin is line-buffered, so input arrives after Enter.
// - This demo avoids alternate-screen so output is visible in all terminals.

import { stdout_write, stdout_writeln, stdin_read } from "../std/wasm/io_stream.xsh"

let main = () -> Int with {Stdin, Stdout} {
  do {
    // Read first byte to suppress duplicate output when host invokes twice.
    let first = stdin_read_char()
    if first < 0 {
      0
    } else {
      stdout_writeln("xsh stream tui demo")
      stdout_writeln("input is read in chunks from stdin")
      stdout_writeln("")
      stdout_write("input> ")
      stdout_write_char(first)
      let chunk = stdin_read(127)
      stdout_writeln("")
      stdout_writeln("")
      stdout_writeln("last chunk:")
      stdout_write("> ")
      stdout_write_char(first)
      stdout_write(chunk)
      stdout_writeln("")
      stdout_writeln("")
      stdout_writeln("send multiple lines to observe redraw")
      0
    }
  }
}

main()
