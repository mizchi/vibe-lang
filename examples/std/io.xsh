// High-level stdio API built on wasm/component-friendly char I/O builtins.
// - stdout_write_char(code: Int) with {Stdout}
// - stdin_read_char() -> Int with {Stdin}

export let stdout_write = (s: String) -> Unit with {Stdout} {
  do {
    let mut i = 0
    while i < string_length(s) {
      stdout_write_char(string_char_code_at(s, i))
      i = i + 1
    }
  }
}

export let stdout_writeln = (s: String) -> Unit with {Stdout} {
  do {
    stdout_write(s)
    stdout_write_char(10)
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

test "string_from_char_code basic" {
  assert(string_equals(string_from_char_code(65), "A"))
}

test "stdin_read_line eof is empty by default" {
  assert(string_equals(stdin_read_line(), ""))
}

test "stdout helpers typecheck" {
  let _ = (s: String) -> Unit with {Stdout} {
    do {
      stdout_write(s)
      stdout_writeln(s)
    }
  }
  assert(true)
}
