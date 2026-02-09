import {
  stdout_write,
  stdout_writeln,
  stdin_read,
  stdin_read_line
} from "./io.xsh"

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

test "stream helpers typecheck" {
  let _ = (n: Int, s: String) -> String with {Stdin, Stdout} {
    do {
      stdout_write(s)
      stdin_read(n)
    }
  }
  assert(true)
}
