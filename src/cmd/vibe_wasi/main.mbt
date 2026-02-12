///|
pub enum LineReplIoMode {
  Plain
  Tty
}

///|
pub struct LineReplOptions {
  prompt : String
  prompt_enabled : Bool
  io_mode : LineReplIoMode
  features : @runtime.RuntimeFeatureFlags
}

///|
fn parse_line_repl_options(
  args : Array[String],
  cmd_name : String,
  prompt : String,
) -> Result[LineReplOptions, String] {
  let mut prompt_enabled = true
  let mut io_mode = LineReplIoMode::Plain
  let mut unstable_async = false
  let mut unstable_threads = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "--tty" => {
        io_mode = LineReplIoMode::Tty
        i += 1
      }
      "--no-tty" => {
        io_mode = LineReplIoMode::Plain
        i += 1
      }
      "--unstable-async" => {
        unstable_async = true
        i += 1
      }
      "--unstable-threads" => {
        unstable_threads = true
        i += 1
      }
      _ => return Err(cmd_name + ": unknown arg " + arg)
    }
  }
  Ok({
    prompt,
    prompt_enabled,
    io_mode,
    features: @runtime.RuntimeFeatureFlags::new(
      unstable_async, unstable_threads,
    ),
  })
}

///|
fn short_hash(hash : String) -> String {
  if hash.length() <= 7 {
    hash
  } else {
    (try! hash[0:7]).to_string()
  }
}

///|
fn extract_let_name(line : String) -> String? {
  let t = line.trim()
  if not(t.has_prefix("let ")) {
    return None
  }
  let mut rest = (try! t[4:]).trim().to_string()
  if rest.has_prefix("rec ") {
    rest = (try! rest[4:]).trim().to_string()
  }
  let out = StringBuilder::new()
  for _, c in rest {
    if c == ' ' || c == '=' || c == ':' || c == '(' {
      break
    }
    out.write_char(c)
  }
  let name = out.to_string().trim().to_string()
  if name.length() == 0 {
    None
  } else {
    Some(name)
  }
}

///|
fn ffi_get_stdin() -> Int = "wasi:cli/stdin@0.2.0" "get-stdin"

///|
fn ffi_get_stdout() -> Int = "wasi:cli/stdout@0.2.0" "get-stdout"

///|
fn ffi_input_stream_blocking_read(
  stream : Int,
  len : Int64,
  retptr : Int,
) -> Int = "wasi:io/streams@0.2.0" "[method]input-stream.blocking-read"

///|
fn ffi_output_stream_blocking_write_and_flush(
  stream : Int,
  ptr : Int,
  len : Int,
  retptr : Int,
) -> Int = "wasi:io/streams@0.2.0" "[method]output-stream.blocking-write-and-flush"

///|
extern "wasm" fn wasm_memory_size_pages() -> Int =
  #|(func (result i32) memory.size)

///|
extern "wasm" fn wasm_load8_u(offset : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 i32.load8_u)

///|
extern "wasm" fn wasm_load32(offset : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 i32.load)

///|
extern "wasm" fn wasm_store8(offset : Int, value : Int) =
  #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store8)

///|
struct WasiLineIo {
  stdin_stream : Int
  stdout_stream : Int
  read_retptr : Int
  write_retptr : Int
  one_byte_ptr : Int
}

///|
fn wasi_scratch_base() -> Int {
  // Reserve a tiny scratch area near linear-memory tail for canonical ABI retptr data.
  wasm_memory_size_pages() * 65536 - 64
}

///|
fn WasiLineIo::new() -> WasiLineIo {
  let scratch = wasi_scratch_base()
  {
    stdin_stream: ffi_get_stdin(),
    stdout_stream: ffi_get_stdout(),
    read_retptr: scratch,
    write_retptr: scratch + 16,
    one_byte_ptr: scratch + 32,
  }
}

///|
fn WasiLineIo::read_byte(self : WasiLineIo) -> Int {
  let _ = ffi_input_stream_blocking_read(
    self.stdin_stream,
    1L,
    self.read_retptr,
  )
  let result_tag = wasm_load32(self.read_retptr)
  if result_tag != 0 {
    return -1
  }
  let data_ptr = wasm_load32(self.read_retptr + 4)
  let data_len = wasm_load32(self.read_retptr + 8)
  if data_len <= 0 {
    -1
  } else {
    wasm_load8_u(data_ptr)
  }
}

///|
fn WasiLineIo::write_byte(self : WasiLineIo, b : Int) -> Unit {
  wasm_store8(self.one_byte_ptr, b)
  let _ = ffi_output_stream_blocking_write_and_flush(
    self.stdout_stream,
    self.one_byte_ptr,
    1,
    self.write_retptr,
  )
}

///|
fn WasiLineIo::write_char_utf8(self : WasiLineIo, ch : Char) -> Unit {
  let code = Char::to_int(ch)
  if code <= 0x7f {
    self.write_byte(code)
  } else if code <= 0x7ff {
    self.write_byte(0xc0 + (code >> 6))
    self.write_byte(0x80 + (code & 0x3f))
  } else if code <= 0xffff {
    self.write_byte(0xe0 + (code >> 12))
    self.write_byte(0x80 + ((code >> 6) & 0x3f))
    self.write_byte(0x80 + (code & 0x3f))
  } else {
    self.write_byte(0xf0 + (code >> 18))
    self.write_byte(0x80 + ((code >> 12) & 0x3f))
    self.write_byte(0x80 + ((code >> 6) & 0x3f))
    self.write_byte(0x80 + (code & 0x3f))
  }
}

///|
fn WasiLineIo::write_string(self : WasiLineIo, s : String) -> Unit {
  for _, ch in s {
    self.write_char_utf8(ch)
  }
}

///|
fn WasiLineIo::writeln(self : WasiLineIo, s : String) -> Unit {
  self.write_string(s)
  self.write_byte(10)
}

///|
fn WasiLineIo::read_line(self : WasiLineIo) -> String? {
  let buf = StringBuilder::new()
  let mut wrote = false
  while true {
    let b = self.read_byte()
    if b < 0 {
      if wrote {
        return Some(buf.to_string())
      }
      return None
    }
    if b == 13 {
      continue
    }
    if b == 10 {
      return Some(buf.to_string())
    }
    match Int::to_char(b) {
      Some(ch) => {
        buf.write_char(ch)
        wrote = true
      }
      None => ()
    }
  }
  None
}

///|
fn print_eval_result(io : WasiLineIo, result : @runtime.EvalResult) -> Unit {
  match result.last {
    Some(value) => io.writeln("last: " + value.to_string())
    None => ()
  }
  for effect in result.effects {
    match effect {
      @runtime.Effect::PosixDesugar(message) => io.writeln("note: " + message)
      _ => io.writeln("effect: " + effect.to_string())
    }
  }
}

///|
fn parse_cmd_args() -> Result[LineReplOptions, String] {
  let args = @sys.get_cli_args()
  let tail : Array[String] = []
  for i in 1..<args.length() {
    tail.push(args[i])
  }
  parse_line_repl_options(tail, "repl-wasi", "wasi> ")
}

///|
fn run_repl(options : LineReplOptions) -> Unit {
  let io = WasiLineIo::new()
  let rt = @runtime.Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    options.features,
  )
  match options.io_mode {
    LineReplIoMode::Tty =>
      io.writeln(
        "note: --tty mode is enabled (line backend; PTY is not enabled yet)",
      )
    LineReplIoMode::Plain => ()
  }
  if options.prompt_enabled {
    io.write_string(options.prompt)
  }
  while true {
    match io.read_line() {
      None => break
      Some(line) => {
        let trimmed = line.trim().to_string()
        if trimmed.length() == 0 {
          if options.prompt_enabled {
            io.write_string(options.prompt)
          }
          continue
        }
        match trimmed {
          ":q" | ":quit" | ":exit" | "exit" => break
          _ => {
            let result = rt.eval_script(trimmed) catch {
              e => {
                io.writeln("error: " + e.to_string())
                if options.prompt_enabled {
                  io.write_string(options.prompt)
                }
                continue
              }
            }
            print_eval_result(io, result)
            match extract_let_name(trimmed) {
              Some(name) =>
                match rt.get_addr(name) {
                  Some(addr) =>
                    io.writeln("addr: " + name + "#" + short_hash(addr))
                  None => ()
                }
              None => ()
            }
          }
        }
        if options.prompt_enabled {
          io.write_string(options.prompt)
        }
      }
    }
  }
}

///|
fn main {
  let options = match parse_cmd_args() {
    Ok(opts) => opts
    Err(msg) => {
      let io = WasiLineIo::new()
      io.writeln(msg)
      io.writeln("usage: repl-wasi [--no-prompt] [--tty|--no-tty]")
      return
    }
  }
  run_repl(options)
}
