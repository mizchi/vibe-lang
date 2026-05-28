///|
/// Tests for `vibe profile` — the wasmtime --profile=guest wrapper
/// inspired by mizchi/pprof-mbt.

///|
test "parse_profile_backend accepts wasm and wasm-gc aliases" {
  @debug.assert_eq(parse_profile_backend("wasm"), Some(ProfileBackend::Wasm))
  @debug.assert_eq(parse_profile_backend("linear"), Some(ProfileBackend::Wasm))
  @debug.assert_eq(
    parse_profile_backend("wasm-gc"),
    Some(ProfileBackend::WasmGc),
  )
  @debug.assert_eq(parse_profile_backend("gc"), Some(ProfileBackend::WasmGc))
  @debug.assert_eq(
    parse_profile_backend("WASM-GC"),
    Some(ProfileBackend::WasmGc),
  )
  @debug.assert_eq(parse_profile_backend("nope"), None)
}

///|
test "default_profile_out_path replaces .vibe suffix" {
  @debug.assert_eq(
    default_profile_out_path("examples/foo.vibe"),
    "examples/foo.profile.json",
  )
  @debug.assert_eq(
    default_profile_out_path("bench/cases/heavy"),
    "bench/cases/heavy.profile.json",
  )
}

///|
test "parse_profile_cmd_args wires flags through to options" {
  let r = parse_profile_cmd_args([
    "foo.vibe", "--backend", "wasm-gc", "--out", "/tmp/out.json", "--interval-us",
    "250", "--invoke", "_bench_run", "--keep-wasm",
  ])
  let opts = match r {
    Ok(v) => v
    Err(msg) => {
      @debug.assert_eq(msg, "<no error>")
      return
    }
  }
  @debug.assert_eq(opts.entry_path, "foo.vibe")
  @debug.assert_eq(opts.backend, ProfileBackend::WasmGc)
  @debug.assert_eq(opts.out_path, "/tmp/out.json")
  @debug.assert_eq(opts.interval_us, 250)
  @debug.assert_eq(opts.invoke_name, "_bench_run")
  @debug.assert_eq(opts.keep_wasm, true)
  @debug.assert_eq(opts.iterations, 1)
}

///|
test "parse_profile_cmd_args defaults backend to wasm-gc with computed out path" {
  let r = parse_profile_cmd_args(["foo.vibe"])
  let opts = match r {
    Ok(v) => v
    Err(msg) => {
      @debug.assert_eq(msg, "<no error>")
      return
    }
  }
  @debug.assert_eq(opts.backend, ProfileBackend::WasmGc)
  @debug.assert_eq(opts.out_path, "foo.profile.json")
  @debug.assert_eq(opts.invoke_name, "_start")
  @debug.assert_eq(opts.keep_wasm, false)
}

///|
test "parse_profile_cmd_args rejects unknown flags and bad numbers" {
  match parse_profile_cmd_args(["foo.vibe", "--bogus"]) {
    Ok(_) => @debug.assert_eq("unexpected ok", "<should err>")
    Err(msg) => @debug.assert_eq(msg.contains("unknown arg --bogus"), true)
  }
  match parse_profile_cmd_args(["foo.vibe", "--interval-us", "0"]) {
    Ok(_) => @debug.assert_eq("unexpected ok", "<should err>")
    Err(msg) =>
      @debug.assert_eq(msg.contains("--interval-us must be > 0"), true)
  }
  match parse_profile_cmd_args([]) {
    Ok(_) => @debug.assert_eq("unexpected ok", "<should err>")
    Err(msg) => @debug.assert_eq(msg.contains("expected exactly one"), true)
  }
}

///|
test "build_wasmtime_profile_command emits --profile=guest with us interval" {
  let runner = BenchWasmRunner::{
    wasmtime_bin: "/usr/bin/wasmtime",
    wasm_flags: ["gc=y"],
    wasi_flags: [],
  }
  let cmd = build_wasmtime_profile_command(
    runner, "dist/foo.wasm", "_start", "out.json", 500,
  )
  @debug.assert_eq(cmd.contains("--profile="), true)
  // Each value gets independently shell-quoted, so look for the
  // composed segment as the wasmtime CLI will see it.
  @debug.assert_eq(cmd.contains("guest,out.json,500us"), true)
  @debug.assert_eq(cmd.contains("--invoke"), true)
  @debug.assert_eq(cmd.contains("_start"), true)
  @debug.assert_eq(cmd.contains("dist/foo.wasm"), true)
  @debug.assert_eq(cmd.contains("-W"), true)
  @debug.assert_eq(cmd.contains("gc=y"), true)
}
