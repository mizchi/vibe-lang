import {
  stdout_write,
  stdout_writeln,
  stdin_read,
  ansi_escape,
  tui_enter_alt_screen,
  tui_leave_alt_screen,
  tui_cursor_home,
  tui_clear_screen
} from "./io_stream.xsh"

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
