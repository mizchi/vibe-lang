// High-level stdio API.
// Stream builtins (for TUI-like usage):
// - stdout_write_stream(text: String) with {Stdout}
// - stdin_read_stream(max_bytes: Int) -> String with {Stdin}
// Char builtins (compatibility):
// - stdout_write_char(code: Int) with {Stdout}
// - stdin_read_char() -> Int with {Stdin}

export let stdout_write = (s: String) -> Unit with {Stdout} {
  do {
    stdout_write_stream(s)
  }
}

export let stdout_writeln = (s: String) -> Unit with {Stdout} {
  do {
    stdout_write(s)
    stdout_write_char(10)
  }
}

export let stdin_read = (max_bytes: Int) -> String with {Stdin} {
  do {
    stdin_read_stream(max_bytes)
  }
}

export let stdin_read_line = () -> String with {Stdin} {
  do {
    let mut acc = ""
    let mut done = false
    while not(done) {
      let c = stdin_read_char()
      let stop = c < 0 || c == 10
      done = stop
      acc = if stop {
        acc
      } else {
        string_concat(acc, string_from_char_code(c))
      }
    }
    acc
  }
}

