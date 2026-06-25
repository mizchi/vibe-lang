// wasmtime-backed runner for moon-emitted `--target wasm` modules.
//
// Mirrors the moonrun host import surface (stdout via spectest::print_char
// or wasi_snapshot_preview1::fd_write + __moonbit_fs_unstable::* +
// __moonbit_time_unstable::* + __moonbit_sys_unstable::is_windows) but uses wasmtime's Cranelift JIT /
// pre-compiled `.cwasm` so selfhost bench wallclock isn't dominated by
// v8's wasm interpretation overhead.
//
// CLI matches moonrun's positional shape:
//   moonrun_wt <wasm|cwasm> [args...]              run, forward args
//   moonrun_wt --precompile <wasm> [-o out.cwasm]  AOT compile only
//   moonrun_wt --dump-imports <wasm>               list import surface (drift guard)
//   moonrun_wt --daemon <wasm|cwasm>               long-running mode (#400)
//   moonrun_wt --help

use std::any::Any;
use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use wasmtime::{
    bail, format_err, Caller, Config, Engine, ExternRef, ExternType, Linker, Module, Result,
    Rooted, Store, StoreLimits, StoreLimitsBuilder, Strategy, TypedFunc, Val, ValType,
};

const FFI_END_OF_STRING_ARRAY: &str = "ffi_end_of_/string_array";
const WASI_ERRNO_SUCCESS: i32 = 0;
const WASI_ERRNO_BADF: i32 = 8;
const WASI_ERRNO_FAULT: i32 = 21;
const WASI_ERRNO_INVAL: i32 = 28;
const WASI_ERRNO_IO: i32 = 29;

// Per-handle moonrun shapes. Mirror the JS objects in moonrun's embedded glue:
//   begin_create_string()      -> StringWriter
//   begin_read_string(s)       -> StringReader(chars, pos)
//   begin_create_byte_array()  -> ByteArrayWriter
//   begin_read_byte_array(arr) -> ByteArrayReader
//   begin_read_string_array(a) -> StringArrayReader
//   instant_now()              -> Instant
enum MoonValue {
    StringWriter(Mutex<String>),
    StringReader(Mutex<StringReader>),
    String(String),
    ByteArrayWriter(Mutex<Vec<u8>>),
    ByteArrayReader(Mutex<ByteArrayReader>),
    ByteArray(Arc<Vec<u8>>),
    StringArrayReader(Mutex<StringArrayReader>),
    StringArray(Arc<Vec<String>>),
    Instant(Instant),
}

// Sentinel error returned from `__moonbit_sys_unstable::exit` so the runner
// can translate the trap into a real process exit code instead of a
// "trap: ..." log line.
#[derive(Debug)]
struct ExitTrap(i32);

impl std::fmt::Display for ExitTrap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "moonbit exit({})", self.0)
    }
}

impl std::error::Error for ExitTrap {}

struct StringReader {
    chars: Vec<u16>,
    pos: usize,
}

struct ByteArrayReader {
    bytes: Arc<Vec<u8>>,
    pos: usize,
}

struct StringArrayReader {
    arr: Arc<Vec<String>>,
    pos: usize,
}

struct HostState {
    last_error: Option<String>,
    args: Arc<Vec<String>>,
    print_buf: Vec<u16>,
    pending_bytes: Option<Arc<Vec<u8>>>,
    pending_strings: Option<Arc<Vec<String>>>,
    limits: StoreLimits,
    // Daemon mode: when set, print_char's flushed lines go into
    // captured_stdout instead of host stdout. The daemon loop emits
    // them as part of the per-request JSON response envelope so they
    // don't get interleaved with the daemon's own protocol traffic.
    capture_stdout: bool,
    captured_stdout: Vec<u8>,
    start_instant: Instant,
}

impl HostState {
    fn new(args: Vec<String>, limits: StoreLimits) -> Self {
        Self {
            last_error: None,
            args: Arc::new(args),
            print_buf: Vec::new(),
            pending_bytes: None,
            pending_strings: None,
            limits,
            capture_stdout: false,
            captured_stdout: Vec::new(),
            start_instant: Instant::now(),
        }
    }

    fn record_err<E: std::fmt::Display>(&mut self, e: E) -> i32 {
        self.last_error = Some(format!("{e}"));
        -1
    }
}

fn encode_tagged_int(value: i64) -> i64 {
    value << 2
}

fn elapsed_profile_us(start: Instant) -> i64 {
    let max = (i64::MAX >> 2) as u128;
    let elapsed = start.elapsed().as_micros();
    if elapsed > max {
        i64::MAX >> 2
    } else {
        elapsed as i64
    }
}

fn print_help() {
    eprintln!(
        "moonrun_wt — wasmtime-backed runner for moon `--target wasm` modules\n\
         \n\
         USAGE:\n\
           moonrun_wt <wasm|cwasm> [args...]\n\
           moonrun_wt --precompile <input.wasm> [-o <output.cwasm>]\n\
           moonrun_wt --dump-imports <input.wasm>\n\
           moonrun_wt --daemon <wasm|cwasm>\n\
           moonrun_wt --help\n\
         \n\
         ENV:\n\
           MOONRUN_WT_MEMORY_MB    soft cap on linear memory (default 8192)\n\
         "
    );
}

fn engine_config() -> Config {
    let mut cfg = Config::new();
    cfg.strategy(Strategy::Cranelift);
    cfg.cranelift_opt_level(wasmtime::OptLevel::Speed);
    cfg.wasm_reference_types(true);
    cfg.wasm_function_references(true);
    cfg.wasm_gc(true);
    cfg.wasm_exceptions(true);
    cfg.wasm_bulk_memory(true);
    cfg.wasm_multi_value(true);
    cfg.wasm_simd(true);
    cfg.wasm_relaxed_simd(true);
    cfg.wasm_tail_call(true);
    cfg
}

fn precompile(input: &str, output: Option<&str>) -> Result<()> {
    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let wasm = fs::read(input).map_err(|e| format_err!("read {input}: {e}"))?;
    let bytes = engine
        .precompile_module(&wasm)
        .map_err(|e| format_err!("precompile_module: {e}"))?;
    let out_path = match output {
        Some(p) => PathBuf::from(p),
        None => {
            let mut p = PathBuf::from(input);
            p.set_extension("cwasm");
            p
        }
    };
    fs::write(&out_path, &bytes).map_err(|e| format_err!("write {}: {e}", out_path.display()))?;
    eprintln!(
        "moonrun_wt: precompiled {} → {} ({} bytes)",
        input,
        out_path.display(),
        bytes.len()
    );
    Ok(())
}

// Wrapper for ValType -> short stable string. Used by `--dump-imports`;
// kept narrow on purpose so any new ValType variant fails the build (we'd
// rather notice schema drift here than ship a silent `?` for new types).
fn valtype_short(t: &ValType) -> &'static str {
    match t {
        ValType::I32 => "i32",
        ValType::I64 => "i64",
        ValType::F32 => "f32",
        ValType::F64 => "f64",
        ValType::V128 => "v128",
        ValType::Ref(r) => {
            if r.is_nullable() {
                match r.heap_type() {
                    wasmtime::HeapType::Extern => "externref",
                    wasmtime::HeapType::Func => "funcref",
                    _ => "ref_null",
                }
            } else {
                "ref"
            }
        }
    }
}

// Print the module's import surface in a deterministic, diffable shape.
// Format per line:   <module>\t<name>\t<kind>\t<sig>
// `func` sigs are `(p1,p2)->(r1,r2)`; everything else uses `-`.
// Output is sorted to make diffs against a baseline meaningful.
fn dump_imports(input: &str) -> Result<()> {
    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let module =
        Module::from_file(&engine, input).map_err(|e| format_err!("from_file {input}: {e}"))?;
    let mut lines: Vec<String> = Vec::new();
    for imp in module.imports() {
        let module_name = imp.module();
        let name = imp.name();
        let (kind, sig) = match imp.ty() {
            ExternType::Func(ft) => {
                let params: Vec<&'static str> = ft.params().map(|t| valtype_short(&t)).collect();
                let results: Vec<&'static str> = ft.results().map(|t| valtype_short(&t)).collect();
                let s = format!("({})->({})", params.join(","), results.join(","));
                ("func", s)
            }
            ExternType::Table(_) => ("table", "-".to_string()),
            ExternType::Memory(_) => ("memory", "-".to_string()),
            ExternType::Global(_) => ("global", "-".to_string()),
            ExternType::Tag(_) => ("tag", "-".to_string()),
        };
        lines.push(format!("{module_name}\t{name}\t{kind}\t{sig}"));
    }
    lines.sort();
    let stdout = std::io::stdout();
    let mut h = stdout.lock();
    for line in &lines {
        writeln!(h, "{line}").ok();
    }
    Ok(())
}

fn load_module(engine: &Engine, path: &str) -> Result<Module> {
    if path.ends_with(".cwasm") {
        // SAFETY: cwasm produced by `moonrun_wt --precompile` uses the same
        // engine config above, so deserializing here is sound. Loading a
        // cwasm built with a different wasmtime version / config is UB —
        // don't share cwasm files across toolchain versions.
        unsafe { Module::deserialize_file(engine, path) }
            .map_err(|e| format_err!("deserialize cwasm: {e}"))
    } else {
        Module::from_file(engine, path).map_err(|e| format_err!("from_file: {e}"))
    }
}

fn run(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        print_help();
        bail!("missing wasm/cwasm argument");
    }
    let wasm_path = &args[0];
    let prog_args: Vec<String> = std::iter::once("moonrun_wt".to_string())
        .chain(args.iter().skip(1).cloned())
        .collect();

    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;

    let memory_mb: usize = std::env::var("MOONRUN_WT_MEMORY_MB")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8192);
    let limits = StoreLimitsBuilder::new()
        .memory_size(memory_mb * 1024 * 1024)
        .build();

    let mut store = Store::new(&engine, HostState::new(prog_args, limits));
    store.limiter(|s| &mut s.limits);

    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;

    let instance = linker.instantiate(&mut store, &module)?;
    let start: TypedFunc<(), ()> = instance.get_typed_func(&mut store, "_start")?;
    let result = start.call(&mut store, ());

    // Flush buffered prints if execution didn't end with a newline.
    {
        let buf = std::mem::take(&mut store.data_mut().print_buf);
        if !buf.is_empty() {
            let s = String::from_utf16_lossy(&buf);
            let stdout = std::io::stdout();
            let mut h = stdout.lock();
            let _ = h.write_all(s.as_bytes());
        }
    }

    match result {
        Ok(()) => Ok(0),
        Err(e) => {
            // `__moonbit_sys_unstable::exit(code)` traps via `ExitTrap(code)`.
            // Recover the code and propagate as our exit status.
            if let Some(ExitTrap(code)) = e.downcast_ref::<ExitTrap>() {
                return Ok(*code);
            }
            // A guest trap (e.g. an uncaught vibe `throw`/type error surfacing as
            // a Wasm exception) should read as a tool error, not a runner crash —
            // show only the message. Set VIBE_RUNNER_BACKTRACE=1 (or RUST_BACKTRACE)
            // for the full anyhow backtrace when debugging the runner itself.
            if std::env::var_os("VIBE_RUNNER_BACKTRACE").is_some()
                || std::env::var_os("RUST_BACKTRACE").is_some()
            {
                eprintln!("moonrun_wt: {e:?}");
            } else {
                eprintln!("moonrun_wt: {e}");
            }
            Ok(1)
        }
    }
}

// Long-running daemon: instantiate the wasm module ONCE and reuse the
// store/instance across many requests. moonbit module-level state
// (top-level let-bindings, e.g. `default_typecheck_session` which holds
// `cached_builtins_env`) survives between requests, so the cold-start
// cost of `ensure_builtin_modules` (#400, ~125ms/case) is paid only
// once instead of every invocation.
//
// Protocol: line-delimited JSON over stdin/stdout.
//   request  ← stdin   {"args": ["--check", "file.vibe"]}
//   response → stdout  {"exit_code": 0, "stdout": "<captured wasm stdout>"}
//   EOF on stdin → daemon exits cleanly.
//
// Wasm stdout is captured (HostState.capture_stdout) so it doesn't
// interleave with the protocol on stdout. Diagnostic / panic messages
// from moonrun_wt itself still go to stderr.
fn daemon(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        bail!("--daemon: missing <wasm|cwasm> argument");
    }
    let wasm_path = &args[0];

    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;

    let memory_mb: usize = std::env::var("MOONRUN_WT_MEMORY_MB")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8192);
    let limits = StoreLimitsBuilder::new()
        .memory_size(memory_mb * 1024 * 1024)
        .build();

    // Empty initial args; daemon will populate per-request before each
    // `_start` call. capture_stdout is set true so per-request output
    // accumulates in HostState.captured_stdout for the JSON envelope.
    let mut state = HostState::new(vec!["moonrun_wt".to_string()], limits);
    state.capture_stdout = true;
    let mut store = Store::new(&engine, state);
    store.limiter(|s| &mut s.limits);

    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;

    let instance = linker.instantiate(&mut store, &module)?;
    let start: TypedFunc<(), ()> = instance.get_typed_func(&mut store, "_start")?;

    eprintln!("moonrun_wt: daemon ready ({} loaded)", wasm_path);

    use std::io::BufRead;
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut req_id: u64 = 0;

    for line_res in stdin.lock().lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(e) => {
                eprintln!("moonrun_wt: daemon stdin read failed: {e}");
                break;
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        req_id += 1;

        // Parse request. Accept either {"args": [...]} or a bare ["a","b"]
        // array for convenience.
        let req_args_res: Result<Vec<String>> = (|| {
            let v: serde_json::Value =
                serde_json::from_str(trimmed).map_err(|e| format_err!("bad request json: {e}"))?;
            let arr = if v.is_array() {
                v
            } else if let Some(a) = v.get("args").cloned() {
                a
            } else {
                bail!("request missing `args` array");
            };
            let arr = arr
                .as_array()
                .ok_or_else(|| format_err!("`args` not array"))?;
            arr.iter()
                .map(|x| {
                    x.as_str()
                        .map(|s| s.to_string())
                        .ok_or_else(|| format_err!("arg not string"))
                })
                .collect()
        })();

        let req_args = match req_args_res {
            Ok(a) => a,
            Err(e) => {
                let resp = serde_json::json!({
                    "req_id": req_id,
                    "exit_code": 2,
                    "stdout": "",
                    "error": format!("{e}"),
                });
                let mut h = stdout.lock();
                writeln!(h, "{}", resp).ok();
                h.flush().ok();
                continue;
            }
        };

        // Reset per-request state. Keep capture_stdout=true.
        //
        // `pending_bytes` / `pending_strings` are the host-side staging
        // slots for `read_file_to_bytes_new` → `get_file_content` and
        // `read_dir_new` → `get_dir_files`. If the previous request
        // populated one of these but trapped / early-exited before the
        // matching `get_*` consumer ran, the value would leak into this
        // request and surface as stale file/dir data. One-shot mode
        // can't hit this (fresh process per invocation); daemon mode
        // must clear them explicitly.
        {
            let host = store.data_mut();
            host.args = Arc::new(
                std::iter::once("moonrun_wt".to_string())
                    .chain(req_args.into_iter())
                    .collect(),
            );
            host.print_buf.clear();
            host.captured_stdout.clear();
            host.last_error = None;
            host.pending_bytes = None;
            host.pending_strings = None;
            host.start_instant = Instant::now();
        }

        // Server-side wall-clock for _start. Bench harness uses this to
        // attribute per-request elapsed time without paying for the JSON
        // protocol round-trip (which would otherwise inflate measurements
        // by ~1ms/req of stdin/stdout copying).
        let t0 = std::time::Instant::now();
        let result = start.call(&mut store, ());
        let elapsed_us = t0.elapsed().as_micros() as u64;

        // Flush any leftover print_buf bytes that didn't end on a newline.
        {
            let host = store.data_mut();
            if !host.print_buf.is_empty() {
                let s = String::from_utf16_lossy(&host.print_buf);
                host.print_buf.clear();
                host.captured_stdout.extend_from_slice(s.as_bytes());
            }
        }

        let (exit_code, err_msg): (i32, Option<String>) = match result {
            Ok(()) => (0, None),
            Err(e) => {
                if let Some(ExitTrap(code)) = e.downcast_ref::<ExitTrap>() {
                    (*code, None)
                } else {
                    // wasm trap. Store may be in a poisoned state after
                    // a trap — wasmtime allows reuse for non-trap errors
                    // but traps generally leave the instance in an
                    // unrecoverable state. Surface the error and exit
                    // the daemon so the client gets a clean failure
                    // instead of silently-garbage subsequent responses.
                    let msg = format!("{e:?}");
                    let captured = std::mem::take(&mut store.data_mut().captured_stdout);
                    let captured_str = String::from_utf8_lossy(&captured).to_string();
                    let resp = serde_json::json!({
                        "req_id": req_id,
                        "exit_code": 1,
                        "stdout": captured_str,
                        "error": msg,
                        "daemon_aborting": true,
                    });
                    let mut h = stdout.lock();
                    writeln!(h, "{}", resp).ok();
                    h.flush().ok();
                    eprintln!("moonrun_wt: daemon aborting after wasm trap: {e:?}");
                    return Ok(1);
                }
            }
        };

        let captured = std::mem::take(&mut store.data_mut().captured_stdout);
        let captured_str = String::from_utf8_lossy(&captured).to_string();
        let mut resp = serde_json::json!({
            "req_id": req_id,
            "exit_code": exit_code,
            "stdout": captured_str,
            "elapsed_us": elapsed_us,
        });
        if let Some(msg) = err_msg {
            resp["error"] = serde_json::Value::String(msg);
        }
        let mut h = stdout.lock();
        writeln!(h, "{}", resp).ok();
        h.flush().ok();
    }

    eprintln!("moonrun_wt: daemon shutting down (stdin EOF, handled {req_id} requests)");
    Ok(0)
}

// Pull the MoonValue clone-bits we need without holding the Caller's
// immutable borrow across the next ExternRef::new mutable borrow.
fn read_str(caller: &Caller<'_, HostState>, h: Option<Rooted<ExternRef>>) -> Result<String> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::String(s) => Ok(s.clone()),
        MoonValue::StringWriter(cell) => Ok(cell.lock().unwrap().clone()),
        _ => bail!("expected String / StringWriter handle"),
    }
}

fn read_bytes(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
) -> Result<Arc<Vec<u8>>> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::ByteArray(b) => Ok(b.clone()),
        MoonValue::ByteArrayWriter(cell) => Ok(Arc::new(cell.lock().unwrap().clone())),
        _ => bail!("expected ByteArray / ByteArrayWriter handle"),
    }
}

fn read_string_array(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
) -> Result<Arc<Vec<String>>> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::StringArray(a) => Ok(a.clone()),
        _ => bail!("expected StringArray handle"),
    }
}

// `with_value` runs `f` against a borrowed MoonValue without producing a new
// externref. Use this for handles whose only output is a primitive.
fn with_value<R>(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
    f: impl FnOnce(&MoonValue) -> Result<R>,
) -> Result<R> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    f(v)
}

fn read_wasi_u32(
    memory: &wasmtime::Memory,
    caller: &Caller<'_, HostState>,
    offset: usize,
) -> std::result::Result<u32, i32> {
    let mut buf = [0u8; 4];
    memory
        .read(caller, offset, &mut buf)
        .map_err(|_| WASI_ERRNO_FAULT)?;
    Ok(u32::from_le_bytes(buf))
}

fn write_wasi_fd(host: &mut HostState, fd: i32, bytes: &[u8]) -> io::Result<()> {
    match fd {
        1 if host.capture_stdout => {
            host.captured_stdout.extend_from_slice(bytes);
            Ok(())
        }
        1 => {
            let stdout = std::io::stdout();
            stdout.lock().write_all(bytes)
        }
        2 => {
            let stderr = std::io::stderr();
            stderr.lock().write_all(bytes)
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported WASI fd",
        )),
    }
}

fn wasi_fd_write(
    caller: &mut Caller<'_, HostState>,
    fd: i32,
    iovs: i32,
    iovs_len: i32,
    nwritten: i32,
) -> i32 {
    if fd != 1 && fd != 2 {
        return WASI_ERRNO_BADF;
    }
    if iovs < 0 || iovs_len < 0 || nwritten < 0 {
        return WASI_ERRNO_INVAL;
    }

    let memory = match caller
        .get_export("memory")
        .and_then(|ext| ext.into_memory())
    {
        Some(memory) => memory,
        None => return WASI_ERRNO_FAULT,
    };

    let mut written: u32 = 0;
    let iovs_base = iovs as usize;
    for index in 0..(iovs_len as usize) {
        let iov_offset = match iovs_base.checked_add(index.saturating_mul(8)) {
            Some(offset) => offset,
            None => return WASI_ERRNO_INVAL,
        };
        let ptr = match read_wasi_u32(&memory, caller, iov_offset) {
            Ok(ptr) => ptr as usize,
            Err(errno) => return errno,
        };
        let len = match read_wasi_u32(&memory, caller, iov_offset + 4) {
            Ok(len) => len as usize,
            Err(errno) => return errno,
        };
        let mut bytes = vec![0u8; len];
        if memory.read(&*caller, ptr, &mut bytes).is_err() {
            return WASI_ERRNO_FAULT;
        }
        if write_wasi_fd(caller.data_mut(), fd, &bytes).is_err() {
            return WASI_ERRNO_IO;
        }
        written = match written.checked_add(len as u32) {
            Some(total) => total,
            None => return WASI_ERRNO_INVAL,
        };
    }

    if memory
        .write(caller, nwritten as usize, &written.to_le_bytes())
        .is_err()
    {
        return WASI_ERRNO_FAULT;
    }
    WASI_ERRNO_SUCCESS
}

// ---- selfhost raw-ABI (`vibe::*`) host imports ----
//
// The selfhost CLI wasm (entry `cli_main`) talks to the host through `vibe::*`
// imports under the "raw" ABI (`VIBE_SELFHOST_IMPORT_ABI=raw`). Strings cross
// the boundary packed into a single i64 = `(ptr << 32) | len` referencing the
// guest's exported linear `memory`. Host-produced strings are bump-allocated on
// the guest's exported `__heap_ptr` global. Ints/Bools are passed as raw i64.
// This mirrors the JS host (`scripts/wasm_vibe_host_runner.js`) so the Rust
// runner can run the same selfhost CLI artifacts as the production `vibe`
// command (`docs/release-roadmap.md`, テーマ 1).

fn vibe_memory(caller: &mut Caller<'_, HostState>) -> Result<wasmtime::Memory> {
    caller
        .get_export("memory")
        .and_then(|e| e.into_memory())
        .ok_or_else(|| format_err!("vibe host import: missing exported `memory`"))
}

fn vibe_read_packed_str(caller: &mut Caller<'_, HostState>, packed: i64) -> Result<String> {
    let mem = vibe_memory(caller)?;
    let u = packed as u64;
    let ptr = (u >> 32) as usize;
    let len = (u & 0xffff_ffff) as usize;
    let mut buf = vec![0u8; len];
    mem.read(&*caller, ptr, &mut buf)
        .map_err(|e| format_err!("vibe host import: string read @{ptr}+{len}: {e}"))?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

// raw Bytes value is a pointer to a struct `{ _cap@0, len@4, data_ptr@8 }`.
fn vibe_read_packed_bytes(caller: &mut Caller<'_, HostState>, value: i64) -> Result<Vec<u8>> {
    let mem = vibe_memory(caller)?;
    let base = (value as u64) as usize;
    let mut hdr = [0u8; 4];
    mem.read(&*caller, base + 4, &mut hdr)
        .map_err(|e| format_err!("vibe host import: bytes len read: {e}"))?;
    let len = u32::from_le_bytes(hdr) as usize;
    mem.read(&*caller, base + 8, &mut hdr)
        .map_err(|e| format_err!("vibe host import: bytes ptr read: {e}"))?;
    let data_ptr = u32::from_le_bytes(hdr) as usize;
    let mut buf = vec![0u8; len];
    mem.read(&*caller, data_ptr, &mut buf)
        .map_err(|e| format_err!("vibe host import: bytes data read: {e}"))?;
    Ok(buf)
}

// Bump-allocate `s` on the guest heap and return it packed as `(ptr << 32) | len`.
fn vibe_alloc_packed_str(caller: &mut Caller<'_, HostState>, s: &str) -> Result<i64> {
    let bytes = s.as_bytes();
    let mem = vibe_memory(caller)?;
    let heap = caller
        .get_export("__heap_ptr")
        .and_then(|e| e.into_global())
        .ok_or_else(|| format_err!("vibe host import: missing `__heap_ptr` global"))?;
    let (cur, is_i64) = match heap.get(&mut *caller) {
        Val::I32(v) => (v as u32 as u64, false),
        Val::I64(v) => (v as u64, true),
        other => bail!("vibe host import: __heap_ptr unexpected type: {other:?}"),
    };
    let align = 8u64;
    let aligned = (cur + (align - 1)) & !(align - 1);
    let size = bytes.len() as u64;
    let next = (aligned + size + (align - 1)) & !(align - 1);
    let cur_size = mem.data_size(&*caller) as u64;
    if next > cur_size {
        let pages = (next - cur_size).div_ceil(65536);
        mem.grow(&mut *caller, pages)
            .map_err(|e| format_err!("vibe host import: memory.grow({pages}): {e}"))?;
    }
    mem.write(&mut *caller, aligned as usize, bytes)
        .map_err(|e| format_err!("vibe host import: string write @{aligned}: {e}"))?;
    let set = if is_i64 {
        Val::I64(next as i64)
    } else {
        Val::I32(next as i32)
    };
    heap.set(&mut *caller, set)
        .map_err(|e| format_err!("vibe host import: set __heap_ptr: {e}"))?;
    Ok(((aligned as i64) << 32) | (size as i64))
}

fn vibe_ensure_parent_dir(path: &str) {
    if let Some(dir) = std::path::Path::new(path).parent() {
        if !dir.as_os_str().is_empty() {
            let _ = fs::create_dir_all(dir);
        }
    }
}

// fnv-ish stat token mixing size + mtime; mirrors the JS host so cwasm/cache
// keys agree across runners. Only needs to change when the file changes.
fn vibe_stat_token(path: &str) -> i64 {
    match fs::metadata(path) {
        Ok(meta) => {
            let size = meta.len();
            let mtime_ns = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            let lower =
                size.wrapping_mul(0x9e37_79b1_85eb_ca87) ^ mtime_ns ^ 0x243f_6a88_85a3_08d3;
            let upper = (mtime_ns << 1) ^ (size << 17) ^ 0x1319_8a2e_0370_7344;
            ((lower ^ upper) & ((1u64 << 61) - 1)) as i64
        }
        Err(_) => 0,
    }
}

fn register_vibe_imports(linker: &mut Linker<HostState>) -> Result<()> {
    linker.func_wrap(
        "vibe",
        "env-get",
        |mut caller: Caller<'_, HostState>, name: i64| -> Result<i64> {
            let name = vibe_read_packed_str(&mut caller, name)?;
            let val = std::env::var(&name).unwrap_or_default();
            vibe_alloc_packed_str(&mut caller, &val)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "args-get",
        |mut caller: Caller<'_, HostState>, index: i64| -> Result<i64> {
            // HostState.args[0] is the runner name; program args start at [1],
            // so `vibe args-get(0)` is the first user argument.
            let val = if index < 0 {
                String::new()
            } else {
                caller
                    .data()
                    .args
                    .get(index as usize + 1)
                    .cloned()
                    .unwrap_or_default()
            };
            vibe_alloc_packed_str(&mut caller, &val)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_read_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content =
                fs::read(&path).map_err(|e| format_err!("vibe fs_read_file '{path}': {e}"))?;
            let s = String::from_utf8_lossy(&content).into_owned();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_exists",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(i64::from(std::path::Path::new(&path).exists()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_stat_token",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(vibe_stat_token(&path))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_file",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            vibe_ensure_parent_dir(&path);
            fs::write(&path, content.as_bytes())
                .map_err(|e| format_err!("vibe fs_write_file '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_bytes",
        |mut caller: Caller<'_, HostState>, path: i64, bytes: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let data = vibe_read_packed_bytes(&mut caller, bytes)?;
            vibe_ensure_parent_dir(&path);
            fs::write(&path, &data).map_err(|e| format_err!("vibe fs_write_bytes '{path}': {e}"))?;
            Ok(())
        },
    )?;
    Ok(())
}

fn register_imports(linker: &mut Linker<HostState>) -> Result<()> {
    register_vibe_imports(linker)?;
    // Current moon emits WASI Preview1 fd_write for stdout/stderr.
    linker.func_wrap(
        "wasi_snapshot_preview1",
        "fd_write",
        |mut caller: Caller<'_, HostState>, fd: i32, iovs: i32, iovs_len: i32, nwritten: i32| {
            wasi_fd_write(&mut caller, fd, iovs, iovs_len, nwritten)
        },
    )?;

    // spectest::print_char — moonbit emits UTF-16 code units. Buffer until
    // newline, then decode lossily so multibyte sequences land on stdout
    // as one write.
    linker.func_wrap(
        "spectest",
        "print_char",
        |mut caller: Caller<'_, HostState>, ch: i32| {
            let host = caller.data_mut();
            let cu = (ch as u32 & 0xFFFF) as u16;
            host.print_buf.push(cu);
            if cu == 0x0A {
                let s = String::from_utf16_lossy(&host.print_buf);
                host.print_buf.clear();
                if host.capture_stdout {
                    host.captured_stdout.extend_from_slice(s.as_bytes());
                } else {
                    let stdout = std::io::stdout();
                    let mut h = stdout.lock();
                    let _ = h.write_all(s.as_bytes());
                }
            }
        },
    )?;

    linker.func_wrap("__moonbit_sys_unstable", "is_windows", || -> i32 {
        if cfg!(windows) {
            1
        } else {
            0
        }
    })?;

    // moonbit's std emits `__moonbit_sys_unstable::exit(code)` for
    // `@sys.exit`. Trap with a sentinel error the runner unwraps below
    // into a real process exit code.
    linker.func_wrap(
        "__moonbit_sys_unstable",
        "exit",
        |_caller: Caller<'_, HostState>, code: i32| -> Result<()> { Err(ExitTrap(code).into()) },
    )?;

    // ------------- time -------------
    linker.func_wrap(
        "__moonbit_time_unstable",
        "instant_now",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let r = ExternRef::new(&mut caller, MoonValue::Instant(Instant::now()))?;
            Ok(Some(r))
        },
    )?;
    linker.func_wrap(
        "__moonbit_time_unstable",
        "instant_elapsed_as_secs_f64",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<f64> {
            with_value(&caller, h, |v| match v {
                MoonValue::Instant(t) => Ok(t.elapsed().as_secs_f64()),
                _ => bail!("instant_elapsed_as_secs_f64: wrong handle type"),
            })
        },
    )?;

    // Selfhost profiling imports. The MoonBit-hosted compiler lowers
    // `perform Profiler::NowUs` to `Profiler/NowUs(env)`, while the
    // selfhost WASI backend emits a direct `vibe/profile-now-us` builtin.
    linker.func_wrap(
        "Profiler",
        "NowUs",
        |caller: Caller<'_, HostState>, _env: i32| -> i64 {
            encode_tagged_int(elapsed_profile_us(caller.data().start_instant))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "profile-now-us",
        |caller: Caller<'_, HostState>| -> i64 {
            encode_tagged_int(elapsed_profile_us(caller.data().start_instant))
        },
    )?;

    // ------------- string create / read -------------
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "begin_create_string",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::StringWriter(Mutex::new(String::new())),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "string_append_char",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>, ch: i32| -> Result<()> {
            with_value(&caller, h, |v| match v {
                MoonValue::StringWriter(cell) => {
                    let cu = (ch as u32 & 0xFFFF) as u16;
                    let mut s = cell.lock().unwrap();
                    if let Some(c) = char::from_u32(cu as u32) {
                        s.push(c);
                    } else {
                        s.push('\u{FFFD}');
                    }
                    Ok(())
                }
                _ => bail!("string_append_char: wrong handle type"),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "finish_create_string",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let s = read_str(&caller, h)?;
            Ok(Some(ExternRef::new(&mut caller, MoonValue::String(s))?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "begin_read_string",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let chars: Vec<u16> = read_str(&caller, h)?.encode_utf16().collect();
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::StringReader(Mutex::new(StringReader { chars, pos: 0 })),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "string_read_char",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            with_value(&caller, h, |v| match v {
                MoonValue::StringReader(cell) => {
                    let mut r = cell.lock().unwrap();
                    if r.pos >= r.chars.len() {
                        Ok(-1)
                    } else {
                        let c = r.chars[r.pos] as i32;
                        r.pos += 1;
                        Ok(c)
                    }
                }
                _ => bail!("string_read_char: wrong handle type"),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "finish_read_string",
        |_caller: Caller<'_, HostState>, _h: Option<Rooted<ExternRef>>| {},
    )?;

    // ------------- byte array create / read -------------
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "begin_create_byte_array",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::ByteArrayWriter(Mutex::new(Vec::new())),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "byte_array_append_byte",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>, b: i32| -> Result<()> {
            with_value(&caller, h, |v| match v {
                MoonValue::ByteArrayWriter(cell) => {
                    cell.lock().unwrap().push((b as u32 & 0xFF) as u8);
                    Ok(())
                }
                _ => bail!("byte_array_append_byte: wrong handle type"),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "finish_create_byte_array",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let arr = read_bytes(&caller, h)?;
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::ByteArray(arr),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "begin_read_byte_array",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let bytes = read_bytes(&caller, h)?;
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::ByteArrayReader(Mutex::new(ByteArrayReader { bytes, pos: 0 })),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "byte_array_read_byte",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            with_value(&caller, h, |v| match v {
                MoonValue::ByteArrayReader(cell) => {
                    let mut r = cell.lock().unwrap();
                    if r.pos >= r.bytes.len() {
                        Ok(-1)
                    } else {
                        let b = r.bytes[r.pos] as i32;
                        r.pos += 1;
                        Ok(b)
                    }
                }
                _ => bail!("byte_array_read_byte: wrong handle type"),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "finish_read_byte_array",
        |_caller: Caller<'_, HostState>, _h: Option<Rooted<ExternRef>>| {},
    )?;

    // ------------- string array read -------------
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "begin_read_string_array",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let arr = read_string_array(&caller, h)?;
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::StringArrayReader(Mutex::new(StringArrayReader { arr, pos: 0 })),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "string_array_read_string",
        |mut caller: Caller<'_, HostState>,
         h: Option<Rooted<ExternRef>>|
         -> Result<Option<Rooted<ExternRef>>> {
            let s = with_value(&caller, h, |v| match v {
                MoonValue::StringArrayReader(cell) => {
                    let mut r = cell.lock().unwrap();
                    if r.pos >= r.arr.len() {
                        Ok(FFI_END_OF_STRING_ARRAY.to_string())
                    } else {
                        let s = r.arr[r.pos].clone();
                        r.pos += 1;
                        Ok(s)
                    }
                }
                _ => bail!("string_array_read_string: wrong handle type"),
            })?;
            Ok(Some(ExternRef::new(&mut caller, MoonValue::String(s))?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "finish_read_string_array",
        |_caller: Caller<'_, HostState>, _h: Option<Rooted<ExternRef>>| {},
    )?;

    // ------------- env -------------
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "args_get",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let args = caller.data().args.clone();
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::StringArray(args),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "current_dir",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let cwd = match std::env::current_dir() {
                Ok(p) => p.to_string_lossy().to_string(),
                Err(_) => String::new(),
            };
            Ok(Some(ExternRef::new(&mut caller, MoonValue::String(cwd))?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "get_error_message",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let msg = caller.data().last_error.clone().unwrap_or_default();
            Ok(Some(ExternRef::new(&mut caller, MoonValue::String(msg))?))
        },
    )?;

    // ------------- fs ops -------------
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "path_exists",
        |caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            Ok(if PathBuf::from(&p).exists() { 1 } else { 0 })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "is_file_new",
        |mut caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            Ok(match fs::metadata(&p) {
                Ok(m) if m.is_file() => 1,
                Ok(_) => 0,
                Err(e) => caller.data_mut().record_err(e),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "is_dir_new",
        |mut caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            Ok(match fs::metadata(&p) {
                Ok(m) if m.is_dir() => 1,
                Ok(_) => 0,
                Err(e) => caller.data_mut().record_err(e),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "create_dir_new",
        |mut caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            Ok(match fs::create_dir_all(&p) {
                Ok(()) => 0,
                Err(e) => caller.data_mut().record_err(e),
            })
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "read_file_to_bytes_new",
        |mut caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            match fs::read(&p) {
                Ok(bytes) => {
                    caller.data_mut().pending_bytes = Some(Arc::new(bytes));
                    Ok(0)
                }
                Err(e) => Ok(caller.data_mut().record_err(e)),
            }
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "get_file_content",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let bytes = caller.data_mut().pending_bytes.take().unwrap_or_default();
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::ByteArray(bytes),
            )?))
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "write_bytes_to_file_new",
        |mut caller: Caller<'_, HostState>,
         hp: Option<Rooted<ExternRef>>,
         hb: Option<Rooted<ExternRef>>|
         -> Result<i32> {
            let p = read_str(&caller, hp)?;
            let bytes = read_bytes(&caller, hb)?;
            if let Some(parent) = PathBuf::from(&p).parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::write(&p, bytes.as_ref()) {
                Ok(()) => Ok(0),
                Err(e) => Ok(caller.data_mut().record_err(e)),
            }
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "read_dir_new",
        |mut caller: Caller<'_, HostState>, h: Option<Rooted<ExternRef>>| -> Result<i32> {
            let p = read_str(&caller, h)?;
            match fs::read_dir(&p) {
                Ok(entries) => {
                    let mut names: Vec<String> = Vec::new();
                    for e in entries.flatten() {
                        names.push(e.file_name().to_string_lossy().to_string());
                    }
                    caller.data_mut().pending_strings = Some(Arc::new(names));
                    Ok(0)
                }
                Err(e) => Ok(caller.data_mut().record_err(e)),
            }
        },
    )?;
    linker.func_wrap(
        "__moonbit_fs_unstable",
        "get_dir_files",
        |mut caller: Caller<'_, HostState>| -> Result<Option<Rooted<ExternRef>>> {
            let arr = caller.data_mut().pending_strings.take().unwrap_or_default();
            Ok(Some(ExternRef::new(
                &mut caller,
                MoonValue::StringArray(arr),
            )?))
        },
    )?;

    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        print_help();
        std::process::exit(0);
    }
    if args.first().map(|s| s.as_str()) == Some("--dump-imports") {
        let input = match args.get(1) {
            Some(s) => s.clone(),
            None => {
                eprintln!("--dump-imports: missing <input.wasm>");
                std::process::exit(2);
            }
        };
        if args.len() > 2 {
            eprintln!("--dump-imports: unexpected extra args");
            std::process::exit(2);
        }
        if let Err(e) = dump_imports(&input) {
            eprintln!("moonrun_wt: dump-imports failed: {e:?}");
            std::process::exit(1);
        }
        return;
    }
    if args.first().map(|s| s.as_str()) == Some("--daemon") {
        let daemon_args: Vec<String> = args.iter().skip(1).cloned().collect();
        match daemon(daemon_args) {
            Ok(code) => std::process::exit(code),
            Err(e) => {
                eprintln!("moonrun_wt: daemon failed: {e:?}");
                std::process::exit(1);
            }
        }
    }
    if args.first().map(|s| s.as_str()) == Some("--precompile") {
        let mut iter = args.iter().skip(1);
        let input = match iter.next() {
            Some(s) => s.clone(),
            None => {
                eprintln!("--precompile: missing <input.wasm>");
                std::process::exit(2);
            }
        };
        let mut output: Option<String> = None;
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "-o" => match iter.next() {
                    Some(p) => output = Some(p.clone()),
                    None => {
                        eprintln!("-o: missing path");
                        std::process::exit(2);
                    }
                },
                other => {
                    eprintln!("--precompile: unknown arg `{other}`");
                    std::process::exit(2);
                }
            }
        }
        if let Err(e) = precompile(&input, output.as_deref()) {
            eprintln!("moonrun_wt: precompile failed: {e:?}");
            std::process::exit(1);
        }
        return;
    }
    match run(args) {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("moonrun_wt: {e:?}");
            std::process::exit(1);
        }
    }
}
