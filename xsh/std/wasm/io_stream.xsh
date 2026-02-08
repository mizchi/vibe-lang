// WASM-friendly stream I/O helpers for TUI-style rendering.
// Uses only stdio builtins that lower to wasi:cli + wasi:io/streams.

export let stdout_write = (s: String) -> Unit with {Stdout} {
  do {
    stdout_write_stream(s)
  }
}

export let stdout_writeln = (s: String) -> Unit with {Stdout} {
  do {
    stdout_write_stream(s)
    stdout_write_char(10)
  }
}

export let stdin_read = (max_bytes: Int) -> String with {Stdin} {
  do {
    stdin_read_stream(max_bytes)
  }
}

export let ansi_escape = (suffix: String) -> Unit with {Stdout} {
  do {
    stdout_write_char(27)
    stdout_write_stream(suffix)
  }
}

export let tui_enter_alt_screen = () -> Unit with {Stdout} {
  do {
    ansi_escape("[?1049h")
  }
}

export let tui_leave_alt_screen = () -> Unit with {Stdout} {
  do {
    ansi_escape("[?1049l")
  }
}

export let tui_cursor_home = () -> Unit with {Stdout} {
  do {
    ansi_escape("[H")
  }
}

export let tui_clear_screen = () -> Unit with {Stdout} {
  do {
    ansi_escape("[2J")
  }
}

test "stream helper signatures" {
  let _ = (n: Int, s: String) -> String with {Stdin, Stdout} {
    do {
      stdout_write(s)
      stdout_writeln(s)
      stdin_read(n)
    }
  }
  assert(true)
}

test "ansi escape helper signature" {
  let _ = (suffix: String) -> Unit with {Stdout} {
    do {
      ansi_escape(suffix)
    }
  }
  assert(true)
}

test "tui preset helpers typecheck" {
  let _ = () -> Unit with {Stdout} {
    do {
      tui_enter_alt_screen()
      tui_clear_screen()
      tui_cursor_home()
      tui_leave_alt_screen()
    }
  }
  assert(true)
}
