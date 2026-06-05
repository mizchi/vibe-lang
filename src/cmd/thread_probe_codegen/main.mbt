///|
fn usage() -> String {
  let text =
    #|thread-probe-codegen <probe> [--out <path>]
    #|
    #|Probes:
    #|  trampoline-status
    #|  vibe-abi
    #|  channel-abi
    #|  channel-spawn-abi
    #|  speedup-serial
    #|  speedup-parallel
  text
}

///|
fn collect_cli_args() -> Array[String] {
  let args = @env.args()
  let out : Array[String] = []
  for i, arg in args {
    if i == 0 {
      continue
    }
    if i == 1 && arg.has_suffix(".js") {
      continue
    }
    out.push(arg)
  }
  out
}

///|
fn generated_probe_source(name : String) -> Result[String, String] {
  match name {
    "trampoline-status" =>
      Ok(
        @threads.component_model_unsafe_os_threads_trampoline_status_probe_wast(),
      )
    "vibe-abi" =>
      Ok(@threads.component_model_unsafe_os_threads_vibe_abi_probe_wast())
    "channel-abi" =>
      Ok(@threads.component_model_unsafe_os_threads_channel_abi_probe_wast())
    "channel-spawn-abi" =>
      Ok(
        @threads.component_model_unsafe_os_threads_channel_spawn_abi_probe_wast(),
      )
    "speedup-serial" =>
      Ok(
        @threads.component_model_unsafe_os_threads_vibe_abi_speedup_serial_wast(),
      )
    "speedup-parallel" =>
      Ok(
        @threads.component_model_unsafe_os_threads_vibe_abi_speedup_parallel_wast(),
      )
    _ => Err("unknown thread probe: " + name)
  }
}

///|
test "generated_probe_source supports channel spawn ABI probe" {
  match generated_probe_source("channel-spawn-abi") {
    Ok(source) => {
      assert_true(
        source.contains("Fork-local unsafe OS-thread channel spawn ABI probe"),
      )
      assert_true(source.contains("(canon thread.spawn-indirect"))
      assert_true(source.contains("call $channel-send"))
      assert_true(source.contains("call $channel-recv"))
      assert_false(source.contains("@VIBE_"))
    }
    Err(err) => fail("unexpected error: " + err)
  }
}

///|
test "generated_probe_source supports channel ABI probe" {
  match generated_probe_source("channel-abi") {
    Ok(source) => {
      assert_true(
        source.contains("Fork-local unsafe OS-thread channel ABI probe"),
      )
      assert_true(source.contains("i32.atomic.rmw.cmpxchg"))
      assert_false(source.contains("@VIBE_"))
    }
    Err(err) => fail("unexpected error: " + err)
  }
}

///|
fn parse_args(args : Array[String]) -> Result[(String, String?), String] {
  if args.length() == 0 {
    return Err("missing probe name")
  }
  let probe = args[0]
  let mut out_path : String? = None
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "--out" => {
        i += 1
        if i >= args.length() {
          return Err("missing path after --out")
        }
        out_path = Some(args[i])
      }
      "--help" | "-h" => return Err("")
      other => return Err("unknown argument: " + other)
    }
    i += 1
  }
  Ok((probe, out_path))
}

///|
fn emit_probe(probe : String, out_path : String?) -> Unit {
  let source = match generated_probe_source(probe) {
    Ok(source) => source
    Err(err) => {
      println(err)
      println(usage())
      @sys.exit(1)
      return
    }
  }
  match out_path {
    Some(path) =>
      @os_fs.write_string_to_file(path, source) catch {
        e => {
          println("write failed: " + e.to_string())
          @sys.exit(1)
        }
      }
    None => println(source)
  }
}

///|
fn main {
  let args = collect_cli_args()
  match parse_args(args) {
    Ok((probe, out_path)) => emit_probe(probe, out_path)
    Err("") => {
      println(usage())
      @sys.exit(0)
    }
    Err(err) => {
      println(err)
      println(usage())
      @sys.exit(1)
    }
  }
}
