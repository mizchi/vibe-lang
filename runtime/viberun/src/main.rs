// viberun: wasmtime-backed runner for wasm modules produced by the selfhost
// vibe compiler (lib/@vibe/compiler).
//
// The host import surface (stdout via spectest::print_char or
// wasi_snapshot_preview1::fd_write + __moonbit_fs_unstable::* +
// __moonbit_time_unstable::* + __moonbit_sys_unstable::is_windows) mirrors
// the original moonrun runner's import namespaces for ABI compatibility with
// codegen, but this runner uses wasmtime's Cranelift JIT / pre-compiled
// `.cwasm` so selfhost bench wallclock isn't dominated by v8's wasm
// interpretation overhead.
//
// CLI matches moonrun's positional shape:
//   viberun <wasm|cwasm> [args...]              run, forward args
//   viberun --precompile <wasm> [-o out.cwasm]  AOT compile only
//   viberun --dump-imports <wasm>               list import surface (drift guard)
//   viberun --dump-linemap <wasm>               dump `vibe.linemap` (#644)
//   viberun --daemon <wasm|cwasm>               long-running mode (#400)
//   viberun --help

use std::any::Any;
use std::fs;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use wasmtime::{
    bail, format_err, Caller, Config, Engine, ExternRef, ExternType, Instance, Linker, Module,
    ResourceLimiter, Result, Rooted, Store, StoreLimits, StoreLimitsBuilder, Strategy, Trap,
    TypedFunc, Val, ValType,
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

// Memory ResourceLimiter that delegates the size cap to an inner StoreLimits but
// also records every accepted `memory.grow` as a growth-timeline event (tier 2
// of docs/spec/profiling.md). Recording is gated (`record`) so non-profiling runs
// pay nothing. wasmtime routes BOTH guest `memory.grow` and host `Memory::grow`
// (the bump-string allocator) through this, so the timeline is complete.
struct MemLimiter {
    inner: StoreLimits,
    record: bool,
    start: Instant,
    // (elapsed_ns, from_bytes, to_bytes) per accepted growth.
    events: Vec<(u128, u64, u64)>,
}

impl MemLimiter {
    fn new(inner: StoreLimits) -> Self {
        MemLimiter {
            inner,
            record: false,
            start: Instant::now(),
            events: Vec::new(),
        }
    }
}

impl ResourceLimiter for MemLimiter {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> Result<bool> {
        let allowed = self.inner.memory_growing(current, desired, maximum)?;
        if self.record && allowed && desired > current {
            self.events.push((
                self.start.elapsed().as_nanos(),
                current as u64,
                desired as u64,
            ));
        }
        Ok(allowed)
    }
    fn table_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> Result<bool> {
        self.inner.table_growing(current, desired, maximum)
    }
}

#[derive(Default)]
struct HostFsScopeCounters {
    read_file_calls: u64,
    read_file_returned_bytes: u64,
    read_bytes_calls: u64,
    read_bytes_returned_bytes: u64,
    stat_token_calls: u64,
    exists_calls: u64,
}

// Opt-in, runner-owned observation of the core `vibe` filesystem imports.
// This deliberately reports host import calls, not compiler source hashes or
// cache decisions.
struct HostFsScope {
    output: PathBuf,
    nonce: String,
    counters: HostFsScopeCounters,
}

struct HostState {
    last_error: Option<String>,
    args: Arc<Vec<String>>,
    print_buf: Vec<u16>,
    pending_bytes: Option<Arc<Vec<u8>>>,
    pending_strings: Option<Arc<Vec<String>>>,
    mem: MemLimiter,
    // Daemon mode: when set, print_char's flushed lines go into
    // captured_stdout instead of host stdout. The daemon loop emits
    // them as part of the per-request JSON response envelope so they
    // don't get interleaved with the daemon's own protocol traffic.
    capture_stdout: bool,
    captured_stdout: Vec<u8>,
    start_instant: Instant,
    // Profiling tier 3 (heap sampling over time). When `__heap_ptr` sampling is
    // on, the epoch-deadline callback reads this global on each epoch tick and
    // appends (elapsed_ns, heap_ptr_bytes) — a fine-grained allocation curve that
    // sees activity WITHIN the module's initial memory (where no memory.grow, and
    // hence no tier-2 event, fires). `sample_start` anchors elapsed times.
    sample_global: Option<wasmtime::Global>,
    sample_start: Instant,
    samples: Vec<(u128, u64)>,
    // debugger breakpoints (DAP P1): set of function names to pause at (from
    // VIBE_BREAK), and whether to auto-continue without reading stdin (not a
    // TTY, or VIBE_BREAK_AUTO=1). Empty set => the `vibe::dbg_break` hook is a
    // no-op even when the module imports it.
    break_set: Arc<Vec<String>>,
    break_auto: bool,
    // span-arc step5: line-granularity breakpoints. VIBE_BREAK entries of the
    // form `<file>:<line>` or bare `<line>` are parsed into this set (alongside
    // the function-name `break_set`). At a `vibe::dbg_break` pause we resolve the
    // entering function's declaration line via `funcmap` and pause when it is in
    // this set (file matched against `break_file` when a file is given). This
    // reuses the existing per-function-entry hook — no new codegen instrumentation
    // — so the default self-compile path stays byte-identical (fixpoint holds).
    // Each entry is (optional file basename, 1-based line).
    line_break_set: Arc<Vec<(Option<String>, u32)>>,
    // function-name -> 1-based declaration line, parsed from the `.funcmap`
    // sidecar named by VIBE_FUNCMAP. Lets the line-break-set match an entering
    // function to its source line. Empty => no line resolution => no line hits.
    funcmap: Arc<std::collections::HashMap<String, u32>>,
    // basename of the entry source file (VIBE_BREAK_FILE), used to confirm a
    // `<file>:<line>` spec's file matches the program being run.
    break_file: Option<String>,
    // debugger argument inspection (DAP P2): addresses of the dbgargs region,
    // parsed from the module's `vibe.dbgargs` custom section at load time (only
    // present in break builds). count_addr holds an i32 arg count; base holds
    // that many i64 vibe values. None => no section => no `args:` line.
    // dbgargs_tag_mode: 0 => plain untagged i64 ints (enable_rc off); 1 => 1-bit
    // tagged (low bit 0 => int raw>>1, low bit 1 => heap pointer shown as hex).
    dbgargs_count_addr: Option<usize>,
    dbgargs_base: Option<usize>,
    dbgargs_tag_mode: u32,
    // debugger named-parameter inspection (DAP P4): per-function parameter names
    // parsed from the module's `vibe.dbgnames` custom section at load time (only
    // present in break builds). Keyed by function name; the value is that
    // function's parameter names in declaration order. Used to pair the spilled
    // dbgargs values with their names so a breakpoint prints `args: [name=value]`.
    // Empty => no section => fall back to positional values.
    dbgnames: Arc<std::collections::HashMap<String, Vec<String>>>,
    // interior-line breakpoints (span-arc step5, multi-file): source-file
    // basenames indexed by file id, parsed from the `vibe.dbgfiles` custom section
    // (break builds with dbg_line only). `vibe::dbg_line(file_id, line)` passes the
    // file id; we index this to recover the basename and match a `--break
    // <file>:<line>` spec's file against it. Empty => bare-line specs still match.
    dbgfiles: Arc<Vec<String>>,
    // #644: static (wasm func index -> sorted (code offset, file id, line))
    // table parsed from the module's `vibe.linemap` custom section (break
    // builds with dbg_line only, same gating as `dbgfiles`). Lets a captured
    // `wasmtime::WasmBacktrace` frame's (func_index, func_offset) resolve to
    // an exact source line without needing that frame to have called
    // `vibe::dbg_line` itself -- e.g. a frame paused/trapped mid-statement,
    // or any CALLER frame in a pause's stack dump. Empty => no section =>
    // resolve_linemap always returns None (existing behavior unaffected).
    linemap: Arc<std::collections::HashMap<u32, Vec<(u32, u32, u32)>>>,
    // debugger step execution (DAP P3): at a pause the runner reads a command and
    // sets a step mode, consulted at every function-entry dbg_break hook to decide
    // WHEN to pause next. pause_depth records the call depth (backtrace frame
    // count) at the last pause, used by StepOver/StepOut to compare against the
    // entering frame's depth.
    step_mode: StepMode,
    pause_depth: usize,
    // Profiling tier 4 (per-function allocation attribution). When alloc_site is on
    // (VIBE_ALLOC_SITE=1, set by `vibe run --alloc-site`), the `vibe::dbg_break`
    // hook — emitted at EVERY user-function entry by the break-mode codegen, so no
    // new instrumentation — reads `__heap_ptr` on each entry and credits the bump
    // delta SINCE the previous entry to the function that was running (the most
    // recently entered one). That yields leaf-style attribution: the innermost
    // active function gets the bytes it allocated, like massif/heaptrack by-frame.
    // dbg_break fires reliably regardless of let-vs-mut, so coverage is complete.
    // Reuses the break build, so the default self-compile path stays byte-identical
    // (fixpoint holds). funcmap resolves a function name to its declaration line.
    alloc_site: bool,
    alloc_prev_fn: Option<String>,
    alloc_prev_heap: u64,
    alloc_sites: std::collections::HashMap<String, u64>,
    // #901: structured subprocess result (`vibe.sh_capture*`), mirroring
    // wasm_vibe_host_runner.js's handle-map shape so the 3 accessor imports
    // are cheap map reads, not re-execs of the command.
    sh_capture_results: std::collections::HashMap<i64, ShCaptureResult>,
    next_sh_capture_handle: i64,
    // Socket::tcp_connect/tcp_read/tcp_write/tcp_close -- same handle-map
    // shape as sh_capture_results above (the handle IS the Int the guest
    // holds; TcpStream itself can't cross the wasm ABI).
    tcp_connections: std::collections::HashMap<i64, std::net::TcpStream>,
    next_tcp_handle: i64,
    // #1226: Http::request/response_status/response_header/response_body/close
    // -- same handle-map shape as sh_capture_results/tcp_connections above.
    // `request` runs the call ONCE and parks the full response, so the 3
    // accessor imports are cheap map reads (mirrors sh_capture's shape).
    http_responses: std::collections::HashMap<i64, HttpResponseData>,
    next_http_handle: i64,
    // #lsp-selfhost review follow-up: bytes read by `stdin_read_stream` that
    // don't yet form a complete UTF-8 sequence (a pipe read can return a
    // chunk boundary in the middle of a multi-byte character), held back
    // across calls instead of being lossy-decoded and corrupted in place.
    // See stdin_read_stream's own comment for why this matters for the
    // self-hosted LSP's JSON-RPC framing.
    stdin_pending: Vec<u8>,
    host_fs_scope: Option<HostFsScope>,
}

// #901: {exit_code, stdout, stderr} parked behind a handle by `sh_capture`,
// read by the exit_code/stdout/stderr accessors, freed by `sh_capture_close`.
struct ShCaptureResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

// #1226: a completed HTTP response parked behind a handle by `http_request`.
// `headers` keeps lowercased names (HTTP header names are case-insensitive)
// so `http_response_header` can do a simple linear-scan lookup.
struct HttpResponseData {
    status: i64,
    headers: Vec<(String, String)>,
    body: String,
}

// DAP P3 step modes. Continue: only pause at explicit break_set hits. StepInto:
// pause at the very next function entry. StepOver: pause at the next entry whose
// depth <= pause_depth (skip nested calls). StepOut: pause once we return to a
// shallower frame (depth < pause_depth).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StepMode {
    Continue,
    StepInto,
    StepOver,
    StepOut,
}

impl HostState {
    fn new(args: Vec<String>, mem: MemLimiter) -> Self {
        // VIBE_BREAK is a comma-separated list mixing function-name specs and
        // line specs. A line spec is either `<file>:<line>` or a bare `<line>`
        // (all-digit). Everything else is a function name. Split them so both
        // kinds keep working (function break + new line break).
        let raw_break: Vec<String> = std::env::var("VIBE_BREAK")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|p| p.trim().to_string())
                    .filter(|p| !p.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let mut break_set: Vec<String> = Vec::new();
        let mut line_break_set: Vec<(Option<String>, u32)> = Vec::new();
        for spec in raw_break {
            if let Some((file, line)) = parse_line_break_spec(&spec) {
                line_break_set.push((file, line));
            } else {
                break_set.push(spec);
            }
        }
        // .funcmap sidecar (name<TAB>declLine) used to resolve an entering
        // function to its source line for line-break matching.
        let funcmap: std::collections::HashMap<String, u32> = std::env::var("VIBE_FUNCMAP")
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|text| parse_funcmap(&text))
            .unwrap_or_default();
        let break_file = std::env::var("VIBE_BREAK_FILE")
            .ok()
            .filter(|s| !s.is_empty());
        // break_auto: auto-continue at every pause WITHOUT reading stdin. Only
        // VIBE_BREAK_AUTO=1 enables this. Note: we intentionally do NOT treat a
        // non-TTY stdin as auto — DAP P3 stepping reads debugger commands from
        // piped/scripted stdin, and on real EOF the read path falls back to
        // continue-and-don't-block (so a pipe with no data still completes).
        let break_auto = std::env::var("VIBE_BREAK_AUTO").as_deref() == Ok("1");
        let alloc_site = std::env::var("VIBE_ALLOC_SITE").as_deref() == Ok("1");
        Self {
            last_error: None,
            args: Arc::new(args),
            print_buf: Vec::new(),
            pending_bytes: None,
            pending_strings: None,
            mem,
            capture_stdout: false,
            captured_stdout: Vec::new(),
            start_instant: Instant::now(),
            sample_global: None,
            sample_start: Instant::now(),
            samples: Vec::new(),
            break_set: Arc::new(break_set),
            break_auto,
            line_break_set: Arc::new(line_break_set),
            funcmap: Arc::new(funcmap),
            break_file,
            dbgargs_count_addr: None,
            dbgargs_base: None,
            dbgargs_tag_mode: 0,
            dbgnames: Arc::new(std::collections::HashMap::new()),
            dbgfiles: Arc::new(Vec::new()),
            linemap: Arc::new(std::collections::HashMap::new()),
            step_mode: StepMode::Continue,
            pause_depth: 0,
            alloc_site,
            alloc_prev_fn: None,
            alloc_prev_heap: 0,
            alloc_sites: std::collections::HashMap::new(),
            sh_capture_results: std::collections::HashMap::new(),
            next_sh_capture_handle: 1,
            tcp_connections: std::collections::HashMap::new(),
            next_tcp_handle: 1,
            http_responses: std::collections::HashMap::new(),
            next_http_handle: 1,
            stdin_pending: Vec::new(),
            host_fs_scope: None,
        }
    }

    fn record_err<E: std::fmt::Display>(&mut self, e: E) -> i32 {
        self.last_error = Some(format!("{e}"));
        -1
    }

    fn host_fs_scope_mut(&mut self) -> Option<&mut HostFsScopeCounters> {
        self.host_fs_scope.as_mut().map(|scope| &mut scope.counters)
    }
}

// True when stdin is an interactive terminal. Retained for future TTY-aware
// prompting; debugger pausing now reads stdin regardless (DAP P3 scripted steps)
// and only VIBE_BREAK_AUTO=1 skips the read.
#[allow(dead_code)]
fn atty_stdin() -> bool {
    use std::io::IsTerminal;
    std::io::stdin().is_terminal()
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
        "viberun — wasmtime-backed runner for wasm modules produced by the selfhost vibe compiler\n\
         \n\
         USAGE:\n\
           viberun <wasm|cwasm> [args...]\n\
           viberun --precompile <input.wasm> [-o <output.cwasm>]\n\
           viberun --dump-imports <input.wasm>\n\
           viberun --dump-linemap <input.wasm>\n\
           viberun --daemon <wasm|cwasm>\n\
           viberun --help\n\
         \n\
         A Component Model binary is detected from its header and run through\n\
         the async component path instead (#1230 M1b-3c-2): its `run` export is\n\
         driven to completion and the returned value printed.\n\
         \n\
         ENV:\n\
           MOONRUN_WT_MEMORY_MB      soft cap on linear memory (default 8192)\n\
           VIBE_ASYNC_GET_DELAY_MS   async component path: suspend applied by the\n\
                                     `get-async` host import (default 300)\n\
           VIBE_ASYNC_FUTURES        async component path: comma-separated\n\
                                     name=value:delay_ms list; each entry links a\n\
                                     `name: func() -> future<u32>` host import\n\
                                     resolving to `value` after `delay_ms`\n\
           VIBE_ASYNC_STREAMS        async component path: comma-separated\n\
                                     name=b1|b2|b3[@delay_ms] list; each entry\n\
                                     links a `name: func() -> stream<u8>` host\n\
                                     import producing those bytes then EOS,\n\
                                     one byte per `delay_ms` when given\n\
         "
    );
}

// Wasm stack budget. wasmtime's default max_wasm_stack (512 KiB) is far too
// small for the compiler's recursive-descent parser on deep sources — hashing
// or compiling @vibe/parser exhausts it ("wasm trap: call stack exhausted")
// while the node runner (V8, bigger default) sails through. The wasm stack
// must stay comfortably below the native stack of the executing thread, so
// main() re-launches onto a worker thread sized wasm_stack + 8 MiB.
fn wasm_stack_bytes() -> usize {
    let mb = std::env::var("MOONRUN_WT_WASM_STACK_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(64);
    mb.max(1) * 1024 * 1024
}

// The `MOONRUN_WT_MEMORY_MB` soft cap, in the shape every store here wants.
// Factored out for #1242 review: the component path was constructing a
// limiter-less `Store`, silently ignoring the cap that `--help` documents.
fn store_mem_limits() -> StoreLimits {
    let memory_mb: usize = std::env::var("MOONRUN_WT_MEMORY_MB")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8192);
    StoreLimitsBuilder::new()
        .memory_size(memory_mb * 1024 * 1024)
        .build()
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
    cfg.max_wasm_stack(wasm_stack_bytes());
    // The crate builds wasmtime with the async feature (the daemon path), and
    // wasmtime validates max_wasm_stack <= async_stack_size even for sync
    // stores — keep the async fiber stack one page-cluster ahead.
    cfg.async_stack_size(wasm_stack_bytes() + 1024 * 1024);
    // debugger breakpoint (DAP P1): wasm backtraces are enabled by default in
    // wasmtime, so `vibe::dbg_break` can name the entering function and the call
    // stack via the name section without extra config.
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
        "viberun: precompiled {} → {} ({} bytes)",
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

// #644: dump the `vibe.linemap` custom section (if any) as
// `<func_index>\t<code_offset>\t<file>\t<line>` lines, sorted by
// (func_index, offset). `<file>` is the basename from `vibe.dbgfiles` when
// present, else the raw file id. Missing/empty section => no output (exit 0,
// like `vibe diagnostics` on a clean file) rather than an error, since most
// modules (non-debug-break builds) simply don't carry one.
fn dump_linemap(input: &str) -> Result<()> {
    let wasm = fs::read(input).map_err(|e| format_err!("read {input}: {e}"))?;
    let dbgfiles = find_custom_section(&wasm, "vibe.dbgfiles")
        .map(|s| parse_dbgfiles(&s))
        .unwrap_or_default();
    let section = match find_custom_section(&wasm, "vibe.linemap") {
        Some(s) => s,
        None => return Ok(()),
    };
    let by_func = parse_linemap(&section);
    let mut func_idxs: Vec<u32> = by_func.keys().copied().collect();
    func_idxs.sort_unstable();
    let stdout = std::io::stdout();
    let mut h = stdout.lock();
    for func_idx in func_idxs {
        for (offset, file_id, line) in &by_func[&func_idx] {
            let file = dbgfiles
                .get(*file_id as usize)
                .cloned()
                .unwrap_or_else(|| file_id.to_string());
            writeln!(h, "{func_idx}\t{offset}\t{file}\t{line}").ok();
        }
    }
    Ok(())
}

// #1230 M1b-3c-2: default suspend for the placeholder `get-async` import
// below. Matches tools/wasip3_component_probe/'s 300ms so the gate can assert
// that the guest genuinely suspended and resumed (a trivially-ready import
// would pass a value check while proving nothing about the wait machinery).
const ASYNC_COMPONENT_GET_DELAY_MS: u64 = 300;
const ASYNC_COMPONENT_GET_VALUE: u32 = 42;

/// #1230 M1b-3c-2: run an async Component Model binary of the shape
/// `component_codegen.vibe`'s `comp_emit_component_wasm_async_spawned_future`
/// emits -- imports `get-async: async func() -> u32`, exports
/// `run: async func() -> u32` -- and print the returned value (matching what
/// `wasmtime --invoke run` prints, which is what the async component gates
/// already assert against).
///
/// Before this, nothing in the project could drive such a component: bare
/// `wasmtime --invoke` deadlock-traps on a component importing a
/// `func_wrap_concurrent` host function, so
/// scripts/test_spawned_future_component_gate.sh had to shell out to a
/// dedicated Rust host binary under tools/wasip3_component_probe/ (needing a
/// Rust toolchain and crates.io access at gate time). This is that driver,
/// moved into the real runtime.
///
/// Two non-obvious constraints, both found the hard way by the probe and
/// documented in tools/wasip3_component_probe/stackful/README.md:
///
///  1. **Driving API pairing.** A `func_wrap_concurrent` import must be driven
///     via `Store::run_concurrent` + `TypedFunc::call_concurrent`. The
///     "plain" `TypedFunc::call_async(&mut store, ...)` pattern -- correct for
///     `func_wrap`/`func_wrap_async` -- traps with "deadlock detected: event
///     loop cannot make further progress" the moment the concurrent import
///     resolves.
///  2. **Its own Engine, but derived from `engine_config()`.** The
///     component/concurrency options below are additive on top of the shared
///     config, so this path keeps `max_wasm_stack`
///     (`MOONRUN_WT_WASM_STACK_MB`, 64 MiB by default) and the rest of the
///     wasm feature set. #1242 review: starting from a bare `Config::new()`
///     silently reverted to wasmtime's small default wasm stack, which is
///     exactly what `engine_config()` exists to raise -- deeply recursive
///     guest code would have traped with call-stack exhaustion here while
///     working fine on the core-module path.
///
/// The store carries the same `MOONRUN_WT_MEMORY_MB` limiter every other
/// store here does (#1242 review: it previously had none, so a component
/// with an embedded core memory could grow unbounded despite `--help`
/// documenting the cap). `MemLimiter`'s growth-event recording is a
/// core-module profiling feature (`VIBE_MEM`) with no component-path
/// equivalent, so it stays off; only the size cap matters.
///
/// Scope: `get-async` is the async host-import surface the emitter currently
/// produces -- a probe-shaped placeholder, not yet a real WASI interface. It
/// is implemented here with a genuinely-suspending timer (a `tokio::time`
/// sleep, i.e. the same thing a `wasi:clocks` backing would do), NOT a
/// blocking `std::thread::sleep`, which would defeat the point. As the
/// emitter grows real `wasi:clocks`/`wasi:http` imports, this linker grows
/// with it; the driving machinery above does not change.
/// ADR-0089 Decision 3 (#1218): a `stream<u8>` producer that delivers ONE
/// byte per `delay` tick. wasmtime's own `Vec<u8>` producer hands the whole
/// buffer to the pipe on its first poll, after which every guest read
/// completes inline -- correct, but it never exercises the reader's
/// BLOCKED -> waitable-park path and gives a gate nothing to measure. This
/// producer returns `Poll::Pending` from a real `tokio::time::Sleep` before
/// each byte, so each `stream.read` genuinely blocks and the wall clock of
/// a full drain is bounded below by `bytes * delay` -- the same
/// "concurrency must be observable" discipline as VIBE_ASYNC_FUTURES'
/// per-entry delays.
struct DelayedByteStreamProducer {
    bytes: Vec<u8>,
    idx: usize,
    delay: std::time::Duration,
    sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
}

impl<D> wasmtime::component::StreamProducer<D> for DelayedByteStreamProducer {
    type Item = u8;
    type Buffer = wasmtime::component::VecBuffer<u8>;

    fn poll_produce<'a>(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        _store: wasmtime::StoreContextMut<'a, D>,
        mut dst: wasmtime::component::Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> std::task::Poll<Result<wasmtime::component::StreamResult>> {
        use std::future::Future;
        use std::task::Poll;
        use wasmtime::component::StreamResult;
        let this = self.get_mut();
        if this.idx >= this.bytes.len() {
            return Poll::Ready(Ok(StreamResult::Dropped));
        }
        let sleep = this
            .sleep
            .get_or_insert_with(|| Box::pin(tokio::time::sleep(this.delay)));
        match sleep.as_mut().poll(cx) {
            Poll::Pending => {
                if finish {
                    // Asked to wrap up early: complete the pending read with
                    // nothing written; the stream itself stays open.
                    return Poll::Ready(Ok(StreamResult::Cancelled));
                }
                Poll::Pending
            }
            Poll::Ready(()) => {
                this.sleep = None;
                let b = this.bytes[this.idx];
                this.idx += 1;
                dst.set_buffer(vec![b].into());
                Poll::Ready(Ok(if this.idx >= this.bytes.len() {
                    StreamResult::Dropped
                } else {
                    StreamResult::Completed
                }))
            }
        }
    }
}

fn run_async_component(path: &str) -> Result<i32> {
    use wasmtime::component::{Accessor, Component, Linker as ComponentLinker};

    let delay_ms: u64 = std::env::var("VIBE_ASYNC_GET_DELAY_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(ASYNC_COMPONENT_GET_DELAY_MS);
    // Percentage applied to every suspend below. `get-after`'s delays come
    // from the GUEST (baked into the probe components), so unlike
    // VIBE_ASYNC_GET_DELAY_MS there is otherwise no way to scale them from
    // outside -- and a gate that only needs to warm the JIT would sit through
    // the probe's full timings for nothing. Scaling here keeps every ratio
    // intact, so completion ORDER, and therefore what the probes assert, is
    // unchanged. Raise it above 100 on a loaded machine to widen the margins.
    let delay_scale_pct: u64 = std::env::var("VIBE_ASYNC_DELAY_SCALE_PCT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);
    // A nonzero request must stay nonzero: an async-lowered call that
    // completes eagerly takes a different path through the guest (no subtask
    // is created), which several probes deliberately reject with an
    // `unreachable`. Scaling must not silently turn a blocking call into an
    // eager one.
    let scale = move |ms: u64| -> u64 {
        if ms == 0 {
            0
        } else {
            std::cmp::max(1, ms.saturating_mul(delay_scale_pct) / 100)
        }
    };

    let mut cfg = engine_config();
    cfg.wasm_component_model(true);
    cfg.wasm_component_model_async(true);
    cfg.wasm_component_model_async_stackful(true);
    cfg.concurrency_support(true);
    let engine = Engine::new(&cfg)?;

    let bytes = fs::read(path).map_err(|e| format_err!("read {path}: {e}"))?;
    let component = Component::from_binary(&engine, &bytes)
        .map_err(|e| format_err!("component from_binary {path}: {e}"))?;

    let mut linker: ComponentLinker<StoreLimits> = ComponentLinker::new(&engine);
    linker
        .root()
        .func_wrap_concurrent(
            "get-async",
            move |_acc: &Accessor<StoreLimits>, _params: ()| {
                Box::pin(async move {
                    let ms = scale(delay_ms);
                    if ms > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                    }
                    Ok((ASYNC_COMPONENT_GET_VALUE,))
                })
            },
        )
        .map_err(|e| format_err!("link get-async: {e}"))?;
    // #1230 M1b-3c-1c: same thing with a caller-chosen delay, returned as the
    // value. `get-async`'s single fixed delay makes every in-flight call
    // resolve at the same moment, which is enough to show that calls OVERLAP
    // (M1b-3c-3) but cannot show anything about the ORDER continuations run
    // in -- completion order and start order coincide. A per-call delay makes
    // them differ observably, which is what the interleaving probe needs.
    // Echoing `ms` back also lets the guest identify a completion by value,
    // independently of the waitable handle.
    linker
        .root()
        .func_wrap_concurrent(
            "get-after",
            move |_acc: &Accessor<StoreLimits>, (ms,): (u32,)| {
                Box::pin(async move {
                    // The value echoed back is the guest's ORIGINAL request,
                    // not the scaled sleep -- probes identify a completion by
                    // it, so scaling must stay invisible to the guest.
                    let slept = scale(ms as u64);
                    if slept > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(slept)).await;
                    }
                    Ok((ms,))
                })
            },
        )
        .map_err(|e| format_err!("link get-after: {e}"))?;
    // ADR-0089 D2 / step 4 (#1218): a host-supplied `future<u32>` VALUE --
    // `get-future: func() -> future<u32>`. Unlike `get-async` (an async func
    // whose wait folds into the [async-lower] call itself), this returns an
    // explicit future handle the guest must `future.read` and park on: the
    // read comes back BLOCKED, the guest joins it into a waitable set, and
    // `waitable-set.wait` suspends the task until this producer's timer
    // fires -- the completion-order wake path the host_future_value probe
    // and comp_emit_component_wasm_host_future_value measure. Creating the
    // pair is synchronous (the import call itself completes eagerly); only
    // the PRODUCER suspends, on the same genuinely-async tokio timer as
    // `get-async` (a `FutureReader::new` producer future is polled by
    // wasmtime's event loop once a read is pending -- pull-based, but
    // observably identical to a writer writing after a delay).
    linker
        .root()
        .func_wrap_concurrent(
            "get-future",
            move |acc: &Accessor<StoreLimits>, _params: ()| {
                Box::pin(async move {
                    let ms = scale(delay_ms);
                    let reader = acc.with(|mut access| {
                        wasmtime::component::FutureReader::<u32>::new(&mut access, async move {
                            if ms > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                            }
                            Ok::<u32, wasmtime::Error>(ASYNC_COMPONENT_GET_VALUE)
                        })
                    })?;
                    Ok((reader,))
                })
            },
        )
        .map_err(|e| format_err!("link get-future: {e}"))?;
    // ADR-0089 (c) (#1218): GENERALIZED named host futures. Every entry in
    // VIBE_ASYNC_FUTURES="name=value:delay_ms,name2=value2:delay_ms2" links an
    // additional root import `name: func() -> future<u32>` with its own
    // producer value and delay -- the WIT-derived-import generalization of the
    // fixed `get-future` above, which stays as the unnamed default. Per-entry
    // values and delays are what make concurrency OBSERVABLE: two futures
    // fetched before either is awaited must finish in delay order, not in
    // call order, and the total wall clock must be the max of the two delays
    // rather than their sum. The delay is scaled like every other suspend
    // here, so VIBE_ASYNC_DELAY_SCALE_PCT keeps working.
    if let Ok(spec) = std::env::var("VIBE_ASYNC_FUTURES") {
        for ent in spec.split(',').filter(|s| !s.trim().is_empty()) {
            let (name, rest) = ent.split_once('=').ok_or_else(|| {
                format_err!("VIBE_ASYNC_FUTURES entry '{ent}': expected name=value:delay_ms")
            })?;
            let (val_s, delay_s) = rest.split_once(':').ok_or_else(|| {
                format_err!("VIBE_ASYNC_FUTURES entry '{ent}': expected name=value:delay_ms")
            })?;
            let name = name.trim().to_string();
            // #1337 Codex review: `get-future` / `get-async` / `get-after` are
            // already registered unconditionally above, and the component
            // linker has shadowing disabled -- registering one of them here
            // fails with "map entry `get-future` defined twice" before the
            // component is even instantiated (measured). They are valid
            // component labels, so `host_future_named("get-future")` can ask
            // for one; say so plainly instead of surfacing a linker error.
            if matches!(name.as_str(), "get-future" | "get-async" | "get-after") {
                bail!(
                    "VIBE_ASYNC_FUTURES '{name}': that name is one of the runner's \
                     built-in imports (get-future, get-async, get-after) and cannot be \
                     redefined -- rename the host future"
                );
            }
            let value: u32 = val_s
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad value: {e}"))?;
            let entry_delay: u64 = delay_s
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad delay: {e}"))?;
            // `func_wrap_concurrent` takes a `&'static str`; the spec is read
            // once at startup and every linked name lives as long as the
            // process, so leaking these few strings is the cheap way to get
            // there (they are bounded by the component's import count).
            let link_name: &'static str = Box::leak(name.clone().into_boxed_str());
            linker
                .root()
                .func_wrap_concurrent(
                    link_name,
                    move |acc: &Accessor<StoreLimits>, _params: ()| {
                        let ms = scale(entry_delay);
                        Box::pin(async move {
                            let reader = acc.with(|mut access| {
                                wasmtime::component::FutureReader::<u32>::new(
                                    &mut access,
                                    async move {
                                        if ms > 0 {
                                            tokio::time::sleep(
                                                std::time::Duration::from_millis(ms),
                                            )
                                            .await;
                                        }
                                        Ok::<u32, wasmtime::Error>(value)
                                    },
                                )
                            })?;
                            Ok((reader,))
                        })
                    },
                )
                .map_err(|e| format_err!("link {name}: {e}"))?;
        }
    }
    // ADR-0089 Decision 3 (#1218): host-supplied `stream<u8>`. Every entry
    // in VIBE_ASYNC_STREAMS="name=b1|b2|b3[@delay_ms]" links a root import
    // `name: func() -> stream<u8>` whose producer is exactly those bytes,
    // then end-of-stream. Born as the D3 terminal probe's host half (what
    // does `stream.read` report at EOS under wasmtime 47? -- measured:
    // amount 0 / code 1, inline) and now also the host side of the
    // `host_stream_named` guest surface.
    //
    // Without `@delay_ms` the producer is wasmtime's own `Vec<u8>`
    // StreamProducer impl (everything delivered on the first poll -- the
    // probe deliberately measures the RUNTIME's behavior, so keep it
    // unhosted). With `@delay_ms` each byte is preceded by that delay via
    // the custom producer below, which is what makes PARKING observable: a
    // reader that never suspends would still get the right sum, but the
    // wall clock could not reach bytes*delay. The delay is scaled like
    // every other suspend here (VIBE_ASYNC_DELAY_SCALE_PCT).
    if let Ok(spec) = std::env::var("VIBE_ASYNC_STREAMS") {
        for ent in spec.split(',').filter(|s| !s.trim().is_empty()) {
            let (name, rest) = ent.split_once('=').ok_or_else(|| {
                format_err!("VIBE_ASYNC_STREAMS entry '{ent}': expected name=b1|b2|b3[@delay_ms]")
            })?;
            let name = name.trim().to_string();
            // Same reserved set as VIBE_ASYNC_FUTURES: these root imports are
            // registered unconditionally above and the linker rejects
            // shadowing (measured on the future side, #1337 Codex review).
            if matches!(name.as_str(), "get-future" | "get-async" | "get-after") {
                bail!(
                    "VIBE_ASYNC_STREAMS '{name}': that name is one of the runner's \
                     built-in imports (get-future, get-async, get-after) and cannot be \
                     redefined -- rename the host stream"
                );
            }
            let (bytes_s, delay_s) = match rest.split_once('@') {
                Some((b, d)) => (b, Some(d)),
                None => (rest, None),
            };
            let mut bytes: Vec<u8> = Vec::new();
            for b in bytes_s.split('|').filter(|s| !s.trim().is_empty()) {
                bytes.push(
                    b.trim()
                        .parse()
                        .map_err(|e| format_err!("VIBE_ASYNC_STREAMS '{name}': bad byte: {e}"))?,
                );
            }
            let per_byte_delay: u64 = match delay_s {
                Some(d) => d
                    .trim()
                    .parse()
                    .map_err(|e| format_err!("VIBE_ASYNC_STREAMS '{name}': bad delay: {e}"))?,
                None => 0,
            };
            // Leaked for the same reason as the named-future link above.
            let link_name: &'static str = Box::leak(name.clone().into_boxed_str());
            let scaled_delay = scale(per_byte_delay);
            linker
                .root()
                .func_wrap_concurrent(
                    link_name,
                    move |acc: &Accessor<StoreLimits>, _params: ()| {
                        let items = bytes.clone();
                        Box::pin(async move {
                            let reader = acc.with(|mut access| {
                                if scaled_delay > 0 {
                                    wasmtime::component::StreamReader::<u8>::new(
                                        &mut access,
                                        DelayedByteStreamProducer {
                                            bytes: items,
                                            idx: 0,
                                            delay: std::time::Duration::from_millis(scaled_delay),
                                            sleep: None,
                                        },
                                    )
                                } else {
                                    wasmtime::component::StreamReader::<u8>::new(&mut access, items)
                                }
                            })?;
                            Ok((reader,))
                        })
                    },
                )
                .map_err(|e| format_err!("link {name}: {e}"))?;
        }
    }

    // A current-thread runtime is enough (and keeps this off the thread pool):
    // the only await points are this timer and wasmtime's own event loop.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .map_err(|e| format_err!("tokio runtime: {e}"))?;

    let result: u32 = rt.block_on(async {
        let mut store = Store::new(&engine, store_mem_limits());
        store.limiter(|s| s);
        let instance = linker.instantiate_async(&mut store, &component).await?;
        let run = instance.get_typed_func::<(), (u32,)>(&mut store, "run")?;
        let (value,) = store
            .run_concurrent(async move |accessor| run.call_concurrent(accessor, ()).await)
            .await??;
        Ok::<u32, wasmtime::Error>(value)
    })?;

    println!("{result}");
    Ok(0)
}

fn load_module(engine: &Engine, path: &str) -> Result<Module> {
    if path.ends_with(".cwasm") {
        // SAFETY: cwasm produced by `viberun --precompile` uses the same
        // engine config above, so deserializing here is sound. Loading a
        // cwasm built with a different wasmtime version / config is UB —
        // don't share cwasm files across toolchain versions.
        unsafe { Module::deserialize_file(engine, path) }
            .map_err(|e| format_err!("deserialize cwasm: {e}"))
    } else {
        Module::from_file(engine, path).map_err(|e| format_err!("from_file: {e}"))
    }
}

// #1230 M1b-3c-2: a Component Model binary and a core module share the
// `\0asm` magic and differ only in the 4 bytes after it -- core modules carry
// version 1 / layer 0 (`01 00 00 00`), components carry version 13 / layer 1
// (`0d 00 01 00`). Everything this runtime did before M1b-3c-2 assumed the
// core-module shape, so a component reached `Module::from_file` and died with
// an opaque parse error. Sniff the header instead and route components to the
// async path. Deliberately byte-level rather than via wasmparser: this is the
// only place the distinction matters and the header is fixed-width.
fn is_component_file(path: &str) -> bool {
    // A precompiled .cwasm is always a core module (--precompile only accepts
    // one), and reading it here would just be wasted IO.
    if path.ends_with(".cwasm") {
        return false;
    }
    let mut buf = [0u8; 8];
    let Ok(mut f) = fs::File::open(path) else {
        return false;
    };
    if f.read_exact(&mut buf).is_err() {
        return false;
    }
    buf == [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00]
}

fn run(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        print_help();
        bail!("missing wasm/cwasm argument");
    }
    let wasm_path = &args[0];
    let host_fs_scope = prepare_host_fs_scope()?;
    if is_component_file(wasm_path) {
        if host_fs_scope.is_some() {
            bail!(
                "host_fs_scope: unsupported for component guests (no core vibe filesystem imports)"
            );
        }
        return run_async_component(wasm_path);
    }
    let prog_args: Vec<String> = std::iter::once("viberun".to_string())
        .chain(args.iter().skip(1).cloned())
        .collect();

    // Profiling tier 3: sample `__heap_ptr` every VIBE_MEM_SAMPLE_MS ms via epoch
    // interruption. Only enable epoch checks (a small per-checkpoint cost in the
    // guest) when sampling is requested, so normal/bench runs are unaffected.
    let sample_ms: Option<u64> = std::env::var("VIBE_MEM_SAMPLE_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|n| *n > 0);
    // A precompiled `.cwasm` was serialized with the plain engine config; flipping
    // on epoch_interruption here would make deserialization fail (the config must
    // match), and the AOT image has no epoch checkpoints to sample at anyway.
    // Disable sampling for `.cwasm` (the `vibe run` path always passes a fresh
    // `.wasm`, so this only guards direct `viberun <module.cwasm>` use).
    let sample_ms = if sample_ms.is_some() && wasm_path.ends_with(".cwasm") {
        eprintln!("vibe: --mem-sample needs a fresh .wasm (a precompiled .cwasm has no epoch checkpoints); sampling disabled");
        None
    } else {
        sample_ms
    };
    let mut cfg = engine_config();
    if sample_ms.is_some() {
        cfg.epoch_interruption(true);
    }
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;

    let limits = store_mem_limits();

    let mut state = HostState::new(prog_args, MemLimiter::new(limits));
    state.host_fs_scope = host_fs_scope;
    let mut store = Store::new(&engine, state);
    store.limiter(|s| &mut s.mem);

    // DAP P2: if the module is a break build it carries a `vibe.dbgargs` custom
    // section publishing the two addresses of the spilled-argument region. Parse
    // them once here so the `vibe::dbg_break` hook can read argument values out
    // of guest memory at a breakpoint. (Break builds always pass a fresh `.wasm`.)
    if let Ok(wasm) = std::fs::read(wasm_path) {
        if let Some(section) = find_custom_section(&wasm, "vibe.dbgargs") {
            if let (Some(count_addr), Some(base)) =
                (read_u32_le(&section, 0), read_u32_le(&section, 4))
            {
                let tag_mode = read_u32_le(&section, 8).unwrap_or(0);
                let data = store.data_mut();
                data.dbgargs_count_addr = Some(count_addr as usize);
                data.dbgargs_base = Some(base as usize);
                data.dbgargs_tag_mode = tag_mode;
            }
        }
        // DAP P4: parse the `vibe.dbgnames` custom section (break builds only) into
        // a function-name -> parameter-names map so the dbg_break hook can label
        // the spilled values. Records are newline-delimited; within a record the
        // first tab-delimited field is the function name and the rest are its
        // parameter names. Absent => empty map => positional fallback.
        if let Some(section) = find_custom_section(&wasm, "vibe.dbgnames") {
            store.data_mut().dbgnames = Arc::new(parse_dbgnames(&section));
        }
        // Interior-line breakpoints (span-arc step5): the source-file table for
        // `vibe::dbg_line(file_id, line)` -> basename resolution.
        if let Some(section) = find_custom_section(&wasm, "vibe.dbgfiles") {
            store.data_mut().dbgfiles = Arc::new(parse_dbgfiles(&section));
        }
        // #644: static instruction-offset -> line table, groundwork for
        // resolving arbitrary (func_index, func_offset) pairs from a captured
        // backtrace (see resolve_linemap).
        if let Some(section) = find_custom_section(&wasm, "vibe.linemap") {
            store.data_mut().linemap = Arc::new(parse_linemap(&section));
        }
    }

    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;

    let instance = linker.instantiate(&mut store, &module)?;
    let start: TypedFunc<(), ()> = instance.get_typed_func(&mut store, "_start")?;
    // Memory profiling (tier 1): `__heap_ptr` is the bump-allocator high-water
    // mark. Read it right after instantiation (the static-data base, before any
    // program allocation) and again after the run; the delta is everything the
    // program — and host-produced strings — allocated. No instrumentation, ~zero
    // overhead. Gated by VIBE_MEM=1 (set by `vibe run --mem`).
    let mem_profile = std::env::var("VIBE_MEM").as_deref() == Ok("1");
    let heap_base = if mem_profile {
        read_heap_ptr(&instance, &mut store)
    } else {
        None
    };
    if mem_profile {
        // Start recording memory.grow events (tier 2 timeline) relative to the
        // run, from this point — before `_start`, after instantiation.
        let m = &mut store.data_mut().mem;
        m.record = true;
        m.start = Instant::now();
        m.events.clear();
    }

    // tier 3 sampler: arm the epoch-deadline callback to record (elapsed, heap)
    // on each tick, and spawn a thread that bumps the engine epoch every `ms`.
    let stop_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut sampler_thread = None;
    if let Some(ms) = sample_ms {
        if let Some(g) = instance.get_global(&mut store, "__heap_ptr") {
            {
                let d = store.data_mut();
                d.sample_global = Some(g);
                d.sample_start = Instant::now();
                d.samples.clear();
            }
            store.set_epoch_deadline(1);
            store.epoch_deadline_callback(|mut ctx| {
                let gopt = ctx.data().sample_global;
                if let Some(g) = gopt {
                    let v = match g.get(&mut ctx) {
                        Val::I32(x) => x as u32 as u64,
                        Val::I64(x) => x as u64,
                        _ => 0,
                    };
                    let t = ctx.data().sample_start.elapsed().as_nanos();
                    ctx.data_mut().samples.push((t, v));
                }
                Ok(wasmtime::UpdateDeadline::Continue(1))
            });
            let eng = engine.clone();
            let stop = stop_flag.clone();
            let interval = std::time::Duration::from_millis(ms);
            // Sleep in small chunks (<=10ms) so the stop flag is observed promptly:
            // a coarse `--mem-sample=1000` must not stall shutdown for a full
            // second at join. Increment the epoch once per full `interval`.
            let chunk = interval.min(std::time::Duration::from_millis(10));
            sampler_thread = Some(std::thread::spawn(move || {
                let mut since_tick = std::time::Duration::ZERO;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    std::thread::sleep(chunk);
                    since_tick += chunk;
                    if since_tick >= interval {
                        eng.increment_epoch();
                        since_tick = std::time::Duration::ZERO;
                    }
                }
            }));
        }
    }

    let result = start.call(&mut store, ());

    // Stop the sampler thread before reading samples.
    stop_flag.store(true, std::sync::atomic::Ordering::Relaxed);
    if let Some(h) = sampler_thread {
        let _ = h.join();
    }

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

    // debugger trace (DAP P1 groundwork): if VIBE_TRACE_OUT=1 and the module
    // carries a `vibe.trace` custom section (debug-trace build), dump the
    // function-call entry sequence to stderr. Runs after the program finishes,
    // success OR trap, mirroring the coverage-bitmap read model.
    if std::env::var("VIBE_TRACE_OUT").as_deref() == Ok("1") {
        dump_trace(wasm_path, &instance, &mut store);
    }

    // Emit the memory report after the run (success OR trap), mirroring the trace
    // dump model, so a program that traps still reports what it allocated.
    if mem_profile {
        let heap_peak = read_heap_ptr(&instance, &mut store);
        let committed = instance
            .get_memory(&mut store, "memory")
            .map(|m| m.data_size(&store) as u64);
        let events = std::mem::take(&mut store.data_mut().mem.events);
        report_memory(heap_base, heap_peak, committed, &events);
    }

    // tier 3 heap-sampling timeline.
    if sample_ms.is_some() {
        let samples = std::mem::take(&mut store.data_mut().samples);
        report_samples(&samples);
    }

    // tier 4 per-function allocation attribution. Credit the last-running
    // function's tail growth (heap delta from its entry to the post-run high-water
    // mark) before reporting, so allocations after the final function entry aren't
    // lost. funcmap resolves names to declaration lines.
    if store.data().alloc_site {
        if let Some(prev_fn) = store.data_mut().alloc_prev_fn.take() {
            if let Some(end) = read_heap_ptr(&instance, &mut store) {
                let prev_heap = store.data().alloc_prev_heap;
                let delta = end.saturating_sub(prev_heap);
                if delta > 0 {
                    *store.data_mut().alloc_sites.entry(prev_fn).or_insert(0) += delta;
                }
            }
        }
        let limit: usize = std::env::var("VIBE_ALLOC_SITE_TOP")
            .ok()
            .and_then(|s| s.parse().ok())
            .filter(|n| *n > 0)
            .unwrap_or(20);
        let sites = std::mem::take(&mut store.data_mut().alloc_sites);
        let funcmap = Arc::clone(&store.data().funcmap);
        report_alloc_sites(&sites, &funcmap, limit);
    }

    match result {
        Ok(()) => {
            if let Some(scope) = store.data().host_fs_scope.as_ref() {
                publish_host_fs_scope(scope)?;
            }
            Ok(0)
        }
        Err(e) => {
            // `__moonbit_sys_unstable::exit(code)` traps via `ExitTrap(code)`.
            // Recover the code and propagate as our exit status.
            if let Some(ExitTrap(code)) = e.downcast_ref::<ExitTrap>() {
                if *code == 0 {
                    if let Some(scope) = store.data().host_fs_scope.as_ref() {
                        publish_host_fs_scope(scope)?;
                    }
                }
                return Ok(*code);
            }
            // `vibe::dbg_break` user abort (`q` at an interactive breakpoint).
            if e.downcast_ref::<BreakAbort>().is_some() {
                eprintln!("viberun: run aborted at breakpoint");
                return Ok(130);
            }
            // #946(4): a pathologically deep expression (e.g. thousands of
            // chained `+`) recurses the checker (itself compiled to wasm) past
            // the configured wasm stack. wasmtime raises this as a graceful
            // `Trap::StackOverflow` ("call stack exhausted") rather than a host
            // crash, but nothing inside the compiled program's own
            // `handle {...} with Error {...}` can intercept it -- it used to
            // surface here as an ordinary trap message, which `vibe
            // check`/`vibe diagnostics`'s `>/dev/null 2>&1 || true` wrapper
            // silently swallowed into "clean". Write the same `.diag` sidecar
            // the checker's own error paths use (cli_adapter.vibe's
            // emit_compile_diag reads it back via read_arg_or_env(1,
            // "VIBE_OUTPUT")) so those commands report a real (if unlocated)
            // diagnostic instead.
            //
            // #1007 review (Codex P2): read_arg_or_env prefers the POSITIONAL
            // arg over the env var (only falling back to VIBE_OUTPUT when the
            // arg is absent) -- `runtime/vibe` never unsets an inherited
            // VIBE_OUTPUT before invoking the runner, so preferring the env
            // var here (as the first cut did) could write the sidecar beside
            // a stale inherited path while the compiled program itself (and
            // the shell script waiting on `$out.diag`) used the real
            // positional one, silently losing the diagnostic all over again.
            // Match read_arg_or_env's precedence: positional arg first.
            if matches!(e.downcast_ref::<Trap>(), Some(Trap::StackOverflow)) {
                let output_path = args
                    .get(2)
                    .cloned()
                    .filter(|s| !s.is_empty())
                    .or_else(|| std::env::var("VIBE_OUTPUT").ok());
                if let Some(output_path) = output_path {
                    let _ = std::fs::write(
                        format!("{output_path}.diag"),
                        "expression too deeply nested (stack overflow while type-checking)\n",
                    );
                }
                eprintln!("viberun: stack overflow: expression too deeply nested");
                return Ok(1);
            }
            // A guest trap (e.g. an uncaught vibe `throw`/type error surfacing as
            // a Wasm exception) should read as a tool error, not a runner crash —
            // show only the message. Set VIBE_RUNNER_BACKTRACE=1 (or RUST_BACKTRACE)
            // for the full anyhow backtrace when debugging the runner itself.
            if std::env::var_os("VIBE_RUNNER_BACKTRACE").is_some()
                || std::env::var_os("RUST_BACKTRACE").is_some()
            {
                eprintln!("viberun: {e:?}");
            } else {
                eprintln!("viberun: {e}");
                // #644: a debug-break build (non-empty `linemap`) that traps
                // mid-run -- not via an explicit `--break` pause -- still
                // deserves a precise per-frame source line, not just the bare
                // function name wasmtime's default Display already shows via
                // the name section. A genuine wasm trap/uncaught exception
                // carries a WasmBacktrace in the same error chain (verified
                // against wasmtime 45); resolve each frame's
                // (func_index, func_offset) through the same linemap
                // vibe::dbg_break/dbg_line already rely on.
                //
                // Deliberately labelled "frame:", NOT "  at " -- runtime/vibe's
                // stderr annotator (annotate_run_stream) pattern-matches any
                // "  at <name>" line and appends a SECOND, declaration-line
                // annotation from the `.funcmap` sidecar. Since ALL of this
                // runner's stderr is piped through that annotator (see the
                // `run` case's FIFO), reusing "  at " here would double-
                // annotate ("helper (prog.vibex:1) (prog.vibex:1)", the two
                // numbers disagreeing whenever the trap isn't on helper's
                // first line). Best-effort: silent when the module carries no
                // linemap (the overwhelmingly common case) or nothing resolves.
                if !store.data().linemap.is_empty() {
                    if let Some(bt) = e.downcast_ref::<wasmtime::WasmBacktrace>() {
                        let dbgfiles = Arc::clone(&store.data().dbgfiles);
                        let linemap = Arc::clone(&store.data().linemap);
                        for frame in bt.frames() {
                            let name = frame.func_name().unwrap_or("<unknown>");
                            match frame
                                .func_offset()
                                .and_then(|off| resolve_linemap(&linemap, frame.func_index(), off as u32))
                            {
                                Some((file_id, line)) => {
                                    let file = dbgfiles
                                        .get(file_id as usize)
                                        .map(|s| s.as_str())
                                        .unwrap_or("?");
                                    eprintln!("  frame: {name} ({file}:{line})");
                                }
                                None => eprintln!("  frame: {name}"),
                            }
                        }
                    }
                }
            }
            Ok(1)
        }
    }
}

// Format a nanosecond duration with an adaptive unit.
fn fmt_ns(ns: u128) -> String {
    if ns < 1_000 {
        format!("{ns} ns")
    } else if ns < 1_000_000 {
        format!("{:.2} µs", ns as f64 / 1_000.0)
    } else if ns < 1_000_000_000 {
        format!("{:.2} ms", ns as f64 / 1_000_000.0)
    } else {
        format!("{:.2} s", ns as f64 / 1_000_000_000.0)
    }
}

// Format an ops/second figure with a k/M suffix.
fn fmt_ops(ops: f64) -> String {
    if ops >= 1_000_000.0 {
        format!("{:.1}M", ops / 1_000_000.0)
    } else if ops >= 1_000.0 {
        format!("{:.0}k", ops / 1_000.0)
    } else {
        format!("{ops:.0}")
    }
}

// Benchmark mode. Instantiate one Store+Instance PER BENCH BLOCK (#747: the
// linear backend never frees, so sharing an instance let an earlier block's
// bump-heap high-water mark inflate later blocks 8-10×), warm the block on its
// fresh instance, then time `iters` calls and read `__heap_ptr` before/after
// the batch for bytes/op. Per-block `__bench_<name>` exports give block
// granularity; files without them fall back to timing `_start` (all bodies
// together). Reports ns/op (min/p50/p95/mean), ops/sec, and bytes/op
// (bump-heap delta / iters — the average allocation per iteration).
//
//   viberun --bench <wasm|cwasm>
// Env: VIBE_BENCH_ITERS (default 1000), VIBE_BENCH_WARMUP (default 50),
//      VIBE_BENCH_LABEL (report label; default the wasm path).
fn bench(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        bail!("--bench: missing <wasm|cwasm> argument");
    }
    let wasm_path = &args[0];
    let iters: u64 = std::env::var("VIBE_BENCH_ITERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|n| *n > 0)
        .unwrap_or(1000);
    let warmup: u64 = std::env::var("VIBE_BENCH_WARMUP")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(50);
    let label = std::env::var("VIBE_BENCH_LABEL").unwrap_or_else(|_| wasm_path.clone());

    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;
    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;

    // #747: one Store+Instance PER BENCH BLOCK. The linear backend never frees,
    // so on a shared instance an earlier block's bump-heap growth (e.g. an
    // O(N²) concat bench leaving a ~200MB high-water mark) inflated the blocks
    // after it 8-10×. A fresh instance gives every block the same pristine
    // heap; per-block warmup below still pays lazy module init before timing.
    let make_instance = |linker: &Linker<HostState>| -> Result<(Store<HostState>, Instance)> {
        let mut state = HostState::new(vec!["viberun".to_string()], MemLimiter::new(store_mem_limits()));
        state.capture_stdout = true; // suppress per-iteration program output
        let mut store = Store::new(&engine, state);
        store.limiter(|s| &mut s.mem);
        let instance = linker.instantiate(&mut store, &module)?;
        Ok((store, instance))
    };

    // Per-block benchmarking: a `__no_entry__` build (`vibe bench`) exports one
    // `__bench_<name>` function per `bench "name" { }` block (codegen emits each
    // as a 0-arg-by-env, i64-returning user function). When present, time each
    // block in isolation so a file with several benches reports a row each. When
    // absent (a wasm from an older compiler, or a `test {}`-only file), fall back
    // to timing `_start`, which runs every test/bench body together (file level).
    let bench_names: Vec<String> = module
        .exports()
        .filter_map(|e| {
            e.name()
                .strip_prefix("__bench_")
                .map(|n| (e.name().to_string(), n))
        })
        .map(|(full, _)| full)
        .collect();

    // Bench a single callable. `invoke` runs one iteration (clearing captured
    // stdout first); we warm it, then time `iters` calls and read the bump-heap
    // delta across the batch for bytes/op (tier 1 reused).
    fn bench_one(
        store: &mut Store<HostState>,
        instance: &Instance,
        block_label: &str,
        warmup: u64,
        iters: u64,
        mut invoke: impl FnMut(&mut Store<HostState>, &str) -> Result<()>,
    ) -> Result<()> {
        for _ in 0..warmup {
            invoke(store, "warmup")?;
        }
        let heap_before = read_heap_ptr(instance, store);
        let mut samples: Vec<u128> = Vec::with_capacity(iters as usize);
        for _ in 0..iters {
            let t0 = Instant::now();
            invoke(store, "measurement")?;
            samples.push(t0.elapsed().as_nanos());
        }
        let heap_after = read_heap_ptr(instance, store);

        samples.sort_unstable();
        let n = samples.len();
        let sum: u128 = samples.iter().sum();
        let mean = sum / n as u128;
        let min = samples[0];
        let p50 = samples[(n / 2).min(n - 1)];
        let p95 = samples[(n * 95 / 100).min(n - 1)];
        let ops_per_sec = if mean > 0 {
            1_000_000_000f64 / mean as f64
        } else {
            0.0
        };
        let bytes_per_op = match (heap_before, heap_after) {
            (Some(b), Some(a)) => Some(a.saturating_sub(b) / iters),
            _ => None,
        };

        // Machine-readable line (tools/CI parse this) + a human summary, both stdout.
        println!(
            "vibe::bench label={block_label} iters={iters} ns_min={min} ns_p50={p50} ns_p95={p95} ns_mean={mean} ops_per_sec={ops_per_sec:.0} bytes_per_op={}",
            bytes_per_op.map(|b| b.to_string()).unwrap_or_else(|| "na".into()),
        );
        println!(
            "bench {block_label}: {iters} iters — {}/op (min {}, p50 {}, p95 {}), {} ops/s, {}",
            fmt_ns(mean),
            fmt_ns(min),
            fmt_ns(p50),
            fmt_ns(p95),
            fmt_ops(ops_per_sec),
            bytes_per_op
                .map(|b| format!("{}/op", human_bytes(b)))
                .unwrap_or_else(|| "mem n/a".into()),
        );
        Ok(())
    }

    if !bench_names.is_empty() {
        // Per-block: each `__bench_<name>` is `(i64 env) -> i64`; we pass env=0 and
        // drop the result, mirroring how `_start` invokes test/bench bodies.
        for full in &bench_names {
            let name = full.strip_prefix("__bench_").unwrap_or(full);
            let block_label = format!("{label}::{name}");
            let (mut store, instance) = make_instance(&linker)?;
            let func: TypedFunc<i64, i64> = instance.get_typed_func(&mut store, full)?;
            bench_one(
                &mut store,
                &instance,
                &block_label,
                warmup,
                iters,
                |store, phase| {
                    store.data_mut().captured_stdout.clear();
                    match func.call(&mut *store, 0) {
                        Ok(_) => Ok(()),
                        Err(e) => match e.downcast_ref::<ExitTrap>() {
                            Some(ExitTrap(0)) => Ok(()),
                            Some(ExitTrap(code)) => {
                                bail!("bench `{block_label}`: exit({code}) during {phase}")
                            }
                            None => bail!("bench `{block_label}`: trap during {phase}: {e}"),
                        },
                    }
                },
            )?;
        }
        return Ok(0);
    }

    // Fallback (no per-block exports): time the whole `_start`.
    let (mut store, instance) = make_instance(&linker)?;
    let start: TypedFunc<(), ()> = instance.get_typed_func(&mut store, "_start")?;
    bench_one(
        &mut store,
        &instance,
        &label,
        warmup,
        iters,
        |store, phase| {
            store.data_mut().captured_stdout.clear();
            match start.call(&mut *store, ()) {
                Ok(()) => Ok(()),
                // A clean `proc_exit(0)` is fine; any other trap aborts the bench.
                Err(e) => match e.downcast_ref::<ExitTrap>() {
                    Some(ExitTrap(0)) => Ok(()),
                    Some(ExitTrap(code)) => bail!("bench `{label}`: exit({code}) during {phase}"),
                    None => bail!("bench `{label}`: trap during {phase}: {e}"),
                },
            }
        },
    )?;
    Ok(0)
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
// from viberun itself still go to stderr.
fn daemon(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        bail!("--daemon: missing <wasm|cwasm> argument");
    }
    let wasm_path = &args[0];

    let cfg = engine_config();
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;

    let limits = store_mem_limits();

    // Empty initial args; daemon will populate per-request before each
    // `_start` call. capture_stdout is set true so per-request output
    // accumulates in HostState.captured_stdout for the JSON envelope.
    let mut state = HostState::new(vec!["viberun".to_string()], MemLimiter::new(limits));
    state.capture_stdout = true;
    let mut store = Store::new(&engine, state);
    store.limiter(|s| &mut s.mem);

    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;

    let instance = linker.instantiate(&mut store, &module)?;
    let start: TypedFunc<(), ()> = instance.get_typed_func(&mut store, "_start")?;

    eprintln!("viberun: daemon ready ({} loaded)", wasm_path);

    use std::io::BufRead;
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut req_id: u64 = 0;

    for line_res in stdin.lock().lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(e) => {
                eprintln!("viberun: daemon stdin read failed: {e}");
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
                std::iter::once("viberun".to_string())
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
                    eprintln!("viberun: daemon aborting after wasm trap: {e:?}");
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

    eprintln!("viberun: daemon shutting down (stdin EOF, handled {req_id} requests)");
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
// imports under the "raw" ABI (`VIBE_IMPORT_ABI=raw`). Strings cross
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

// Bump-allocate `data` as a raw Bytes value `{ -cap@0, len@4, data_ptr@8 }` with
// the bytes inline at +12, returning the (untagged) struct pointer — the inverse
// of vibe_read_packed_bytes. Capacity is stored negated (the guest reads
// `avail = 0 - cap`). #632 fs_read_bytes.
fn vibe_alloc_packed_bytes(caller: &mut Caller<'_, HostState>, data: &[u8]) -> Result<i64> {
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
    let len = data.len() as u64;
    let next = (aligned + 12 + len + (align - 1)) & !(align - 1);
    let cur_size = mem.data_size(&*caller) as u64;
    if next > cur_size {
        let pages = (next - cur_size).div_ceil(65536);
        mem.grow(&mut *caller, pages)
            .map_err(|e| format_err!("vibe host import: memory.grow({pages}): {e}"))?;
    }
    let base = aligned as usize;
    let neg_cap = 0u32.wrapping_sub(len as u32);
    mem.write(&mut *caller, base, &neg_cap.to_le_bytes())
        .map_err(|e| format_err!("vibe host import: bytes cap write @{base}: {e}"))?;
    mem.write(&mut *caller, base + 4, &(len as u32).to_le_bytes())
        .map_err(|e| format_err!("vibe host import: bytes len write: {e}"))?;
    mem.write(&mut *caller, base + 8, &((aligned + 12) as u32).to_le_bytes())
        .map_err(|e| format_err!("vibe host import: bytes ptr write: {e}"))?;
    mem.write(&mut *caller, base + 12, data)
        .map_err(|e| format_err!("vibe host import: bytes data write: {e}"))?;
    let set = if is_i64 {
        Val::I64(next as i64)
    } else {
        Val::I32(next as i32)
    };
    heap.set(&mut *caller, set)
        .map_err(|e| format_err!("vibe host import: set __heap_ptr: {e}"))?;
    Ok(aligned as i64)
}

fn vibe_ensure_parent_dir(path: &std::path::Path) {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            let _ = fs::create_dir_all(dir);
        }
    }
}

// Guest Fs::write_file / Fs::write_bytes land here. Write via a same-dir temp
// file + rename so a concurrent reader never sees a truncated file -- mirrors
// scripts/wasm_vibe_host_runner.js's atomicWriteFileSync (same rationale: the
// persistent caches under _build/vibe_* are content-keyed and shared across
// concurrent compiler invocations -- parallel unit-test runs and #906's
// --jobs pre-warm publish path both write these hot keys from more than one
// process/worker -- and a plain fs::write opens with O_TRUNC, exposing a
// partial-file window a racing reader can observe as a corrupt cache row).
// rename() is atomic on POSIX; same-content racers simply last-write-win as
// complete files, which is safe because a cache path already encodes its
// content's own fingerprint (#906 acceptance criteria: partial cache writes
// must never be published).
static VIBE_TMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn vibe_atomic_write(path: &str, data: &[u8]) -> Result<()> {
    vibe_ensure_parent_dir(std::path::Path::new(path));
    let counter = VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = format!("{path}.tmp-{}-{counter}", std::process::id());
    let write_result = fs::write(&tmp, data);
    match write_result {
        Ok(()) => fs::rename(&tmp, path).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            format_err!("vibe atomic write rename '{tmp}' -> '{path}': {e}")
        }),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(format_err!("vibe atomic write '{tmp}': {e}"))
        }
    }
}

// Prepare the opt-in telemetry sidecar before the guest can run. A stale file
// is removed even when the nonce is invalid, so callers cannot accidentally
// accept an old observation after this invocation fails closed.
fn prepare_host_fs_scope() -> Result<Option<HostFsScope>> {
    let Some(output) = std::env::var_os("VIBE_HOST_FS_SCOPE_OUT") else {
        return Ok(None);
    };
    if output.is_empty() {
        return Ok(None);
    }
    let output = PathBuf::from(output);
    match fs::remove_file(&output) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => bail!("host_fs_scope: remove stale '{}': {e}", output.display()),
    }
    let nonce = std::env::var("VIBE_HOST_FS_SCOPE_NONCE")
        .map_err(|_| format_err!("host_fs_scope: VIBE_HOST_FS_SCOPE_NONCE is required"))?;
    if nonce.is_empty() || nonce.chars().any(char::is_control) {
        bail!("host_fs_scope: VIBE_HOST_FS_SCOPE_NONCE must be non-empty and contain no control characters");
    }
    Ok(Some(HostFsScope {
        output,
        nonce,
        counters: HostFsScopeCounters::default(),
    }))
}

fn host_fs_scope_json(scope: &HostFsScope) -> Result<Vec<u8>> {
    serde_json::to_vec(&serde_json::json!({
        "schema": "host_fs_scope",
        "version": 1,
        "nonce": scope.nonce,
        "read_file_calls": scope.counters.read_file_calls,
        "read_file_returned_bytes": scope.counters.read_file_returned_bytes,
        "read_bytes_calls": scope.counters.read_bytes_calls,
        "read_bytes_returned_bytes": scope.counters.read_bytes_returned_bytes,
        "stat_token_calls": scope.counters.stat_token_calls,
        "exists_calls": scope.counters.exists_calls,
    }))
    .map_err(|e| format_err!("host_fs_scope: serialize sidecar: {e}"))
}

// This is intentionally a host-side write after `_start` returns successfully,
// so it cannot itself show up as a guest filesystem-import counter.
fn publish_host_fs_scope(scope: &HostFsScope) -> Result<()> {
    let json = host_fs_scope_json(scope)?;
    // `vibe_atomic_write` takes a UTF-8 guest ABI path. The host-side output
    // path may be a native non-UTF-8 path, so use the same atomic protocol
    // directly without lossy path conversion.
    vibe_ensure_parent_dir(&scope.output);
    let counter = VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut tmp_name = scope.output.file_name().unwrap_or_default().to_os_string();
    tmp_name.push(format!(".tmp-{}-{counter}", std::process::id()));
    let tmp = scope.output.with_file_name(tmp_name);
    match fs::write(&tmp, &json) {
        Ok(()) => fs::rename(&tmp, &scope.output).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            format_err!("host_fs_scope: publish '{}': {e}", scope.output.display())
        }),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(format_err!(
                "host_fs_scope: publish '{}': {e}",
                scope.output.display()
            ))
        }
    }
}

// Read the `__heap_ptr` bump-allocator pointer (an i32/i64 mut global) as bytes,
// or None when the module doesn't export it. Used by the `--mem` memory report.
fn read_heap_ptr(instance: &wasmtime::Instance, store: &mut Store<HostState>) -> Option<u64> {
    let g = instance.get_global(&mut *store, "__heap_ptr")?;
    match g.get(&mut *store) {
        Val::I32(v) => Some(v as u32 as u64),
        Val::I64(v) => Some(v as u64),
        _ => None,
    }
}

// Human-readable byte size (binary units).
fn human_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

// Print the `--mem` report to stderr: a machine-readable line + a human line.
// `allocated` = peak − base (everything the run bump-allocated; the linear
// backend never frees, so peak == total). `committed` = wasm memory pages.
fn report_memory(
    base: Option<u64>,
    peak: Option<u64>,
    committed: Option<u64>,
    grow_events: &[(u128, u64, u64)],
) {
    match (base, peak) {
        (Some(b), Some(p)) => {
            let allocated = p.saturating_sub(b);
            let c = committed.unwrap_or(0);
            eprintln!("vibe::mem heap_base={b} heap_peak={p} allocated={allocated} committed={c} grow_events={}", grow_events.len());
            eprintln!(
                "vibe: memory — allocated {} ({allocated} B), peak heap {}, committed {}, {} growth event(s)",
                human_bytes(allocated),
                human_bytes(p),
                human_bytes(c),
                grow_events.len(),
            );
            // Growth timeline (tier 2): one machine-readable line per
            // `memory.grow`, with the time since run start and the page-commitment
            // jump. Empty for programs that stay within the module's initial
            // memory. A trailing human summary of the first/last event bounds the
            // timeline without flooding for allocation-heavy runs.
            for (elapsed_ns, from, to) in grow_events {
                let pages = to.saturating_sub(*from) / 65536;
                eprintln!(
                    "vibe::memgrow t_us={} from={from} to={to} pages=+{pages}",
                    elapsed_ns / 1_000
                );
            }
            if let (Some((t0, f0, _)), Some((t1, _, l1))) =
                (grow_events.first(), grow_events.last())
            {
                eprintln!(
                    "vibe:   growth {} -> {} across {} event(s), {} … {}",
                    human_bytes(*f0),
                    human_bytes(*l1),
                    grow_events.len(),
                    fmt_ns(*t0),
                    fmt_ns(*t1),
                );
            }
        }
        _ => eprintln!("vibe: memory — unavailable (module exports no `__heap_ptr` global)"),
    }
}

// Print the tier-3 heap-sampling timeline: one machine-readable line per sample
// (elapsed since run start + heap-pointer bytes) plus a human summary. Empty when
// the program ran faster than one sample interval.
fn report_samples(samples: &[(u128, u64)]) {
    for (elapsed_ns, heap) in samples {
        eprintln!("vibe::memsample t_us={} heap={heap}", elapsed_ns / 1_000);
    }
    match (samples.first(), samples.last()) {
        (Some((t0, h0)), Some((t1, h1))) => eprintln!(
            "vibe: heap samples — {} over {} … {}, {} -> {} (peak {})",
            samples.len(),
            fmt_ns(*t0),
            fmt_ns(*t1),
            human_bytes(*h0),
            human_bytes(*h1),
            human_bytes(samples.iter().map(|(_, h)| *h).max().unwrap_or(0)),
        ),
        _ => eprintln!("vibe: heap samples — 0 (program ran faster than one sample interval)"),
    }
}

// Profiling tier 4: per-function allocation attribution. `sites` maps a function
// name to the bytes credited to it; `funcmap` resolves a name to its 1-based
// declaration line (empty => `line=?`). Emit one machine-readable `vibe::allocsite`
// line per function (top `limit` by bytes) plus a human summary, all to stderr
// (stdout stays the program's).
fn report_alloc_sites(
    sites: &std::collections::HashMap<String, u64>,
    funcmap: &std::collections::HashMap<String, u32>,
    limit: usize,
) {
    let total: u64 = sites.values().sum();
    let mut rows: Vec<(&String, u64)> = sites.iter().map(|(k, v)| (k, *v)).collect();
    // Sort by bytes desc, then by name for a stable order on ties.
    rows.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    let shown = rows.len().min(limit);
    for (name, bytes) in rows.iter().take(shown) {
        let line = funcmap
            .get(*name)
            .map(|l| l.to_string())
            .unwrap_or_else(|| "?".to_string());
        eprintln!("vibe::allocsite fn={name} line={line} bytes={bytes}");
    }
    if rows.is_empty() {
        eprintln!("vibe: alloc sites — none (no allocations attributed; needs a --break-instrumented build)");
    } else {
        eprintln!(
            "vibe: alloc sites — {} function(s), {} attributed total, top {} shown",
            rows.len(),
            human_bytes(total),
            shown,
        );
    }
}

// fnv-ish stat token mixing size + mtime + ino; mirrors the JS host so
// cwasm/cache keys agree across runners. Only needs to change when the file
// changes. ino guards the "racy stat" window: a rename-in rewrite landing in
// the same kernel timestamp tick with the same size would otherwise keep the
// token identical (see buildFsMetadataHashParts in wasm_vibe_host_runner.js).
fn vibe_stat_token(path: &str) -> i64 {
    if fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
    {
        return -1;
    }
    match fs::metadata(path) {
        Ok(meta) => {
            let size = meta.len();
            let mtime_ns = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            #[cfg(unix)]
            let ino = {
                use std::os::unix::fs::MetadataExt;
                meta.ino()
            };
            #[cfg(not(unix))]
            let ino = 0u64;
            let lower = size.wrapping_mul(0x9e37_79b1_85eb_ca87)
                ^ mtime_ns
                ^ 0x243f_6a88_85a3_08d3
                ^ ino.wrapping_mul(0x1000_0000_01b3);
            let upper = (mtime_ns << 1) ^ (size << 17) ^ 0x1319_8a2e_0370_7344 ^ (ino << 7);
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
        "args-len",
        // `Env::args_len` -> number of USER arguments. args[0] is the runner
        // name, so the user-visible count is args.len() - 1 (raw i64 per the raw
        // ABI). Without this import a program using Env::args_len fails to
        // instantiate with an unknown import before user code runs.
        |caller: Caller<'_, HostState>| -> i64 {
            (caller.data().args.len().saturating_sub(1)) as i64
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_read_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_file_calls += 1;
            }
            let content =
                fs::read(&path).map_err(|e| format_err!("vibe fs_read_file '{path}': {e}"))?;
            let s = String::from_utf8_lossy(&content).into_owned();
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_file_returned_bytes += s.len() as u64;
            }
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_exists",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.exists_calls += 1;
            }
            Ok(i64::from(std::path::Path::new(&path).exists()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_stat_token",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.stat_token_calls += 1;
            }
            Ok(vibe_stat_token(&path))
        },
    )?;
    // #901: Fs::remove/is_dir/is_file -- like Stdout/Stderr/Process above,
    // present in the JS runner and the builtin registry but never ported
    // here, so scripts/cache_clean.vibex (which calls all three) failed to
    // instantiate under the real `vibe run`.
    linker.func_wrap(
        "vibe",
        "fs_remove",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            fs::remove_file(&path).map_err(|e| format_err!("vibe fs_remove '{path}': {e}"))?;
            Ok(())
        },
    )?;
    // #1220: Fs::rename -- declared builtin with real call sites
    // (lib/@vibe/cli/coverage_local_merge.vibe, coverage_acc_tool.vibe's
    // tmp-write + rename atomic-write pattern) but, like fs_remove above,
    // present in the JS runner (scripts/wasm_vibe_host_runner.js's
    // fs.renameSync) and never ported here -- any compiled program calling
    // Fs::rename crashed the real `vibe run` with an unknown-import trap.
    linker.func_wrap(
        "vibe",
        "fs_rename",
        |mut caller: Caller<'_, HostState>, src: i64, dst: i64| -> Result<()> {
            let src = vibe_read_packed_str(&mut caller, src)?;
            let dst = vibe_read_packed_str(&mut caller, dst)?;
            fs::rename(&src, &dst)
                .map_err(|e| format_err!("vibe fs_rename '{src}' -> '{dst}': {e}"))?;
            Ok(())
        },
    )?;
    // #1220 follow-up: the rest of the JS runner's fs surface
    // (scripts/wasm_vibe_host_runner.js) that was never ported here either --
    // same unknown-import crash under the real `vibe run` as fs_rename above,
    // just not yet hit by a call site that runs through viberun. Declared
    // builtins with real call sites in lib/@vibex/shell/commands.vibe (a
    // general-purpose library any user program can import) and
    // scripts/vibe_md.vibex.
    linker.func_wrap(
        "vibe",
        "fs_mkdir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            fs::create_dir(&path).map_err(|e| format_err!("vibe fs_mkdir '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_mkdir_p",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            fs::create_dir_all(&path).map_err(|e| format_err!("vibe fs_mkdir_p '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_getcwd",
        |mut caller: Caller<'_, HostState>| -> Result<i64> {
            let cwd = std::env::current_dir().map_err(|e| format_err!("vibe fs_getcwd: {e}"))?;
            vibe_alloc_packed_str(&mut caller, &cwd.to_string_lossy())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_chdir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            std::env::set_current_dir(&path)
                .map_err(|e| format_err!("vibe fs_chdir '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_copy",
        |mut caller: Caller<'_, HostState>, src: i64, dst: i64| -> Result<()> {
            let src = vibe_read_packed_str(&mut caller, src)?;
            let dst = vibe_read_packed_str(&mut caller, dst)?;
            fs::copy(&src, &dst).map_err(|e| format_err!("vibe fs_copy '{src}' -> '{dst}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_append",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            let mut f = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| format_err!("vibe fs_append '{path}': {e}"))?;
            f.write_all(content.as_bytes())
                .map_err(|e| format_err!("vibe fs_append '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_is_dir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(i64::from(std::path::Path::new(&path).is_dir()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_is_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(i64::from(std::path::Path::new(&path).is_file()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_file",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            vibe_atomic_write(&path, content.as_bytes())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_bytes",
        |mut caller: Caller<'_, HostState>, path: i64, bytes: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let data = vibe_read_packed_bytes(&mut caller, bytes)?;
            vibe_atomic_write(&path, &data)
        },
    )?;
    // #632: fs_read_bytes — binary-exact file read into a guest Bytes value (the
    // inverse of fs_write_bytes; unlike fs_read_file it does not lossily utf8).
    linker.func_wrap(
        "vibe",
        "fs_read_bytes",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_bytes_calls += 1;
            }
            let data =
                fs::read(&path).map_err(|e| format_err!("vibe fs_read_bytes '{path}': {e}"))?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_bytes_returned_bytes += data.len() as u64;
            }
            vibe_alloc_packed_bytes(&mut caller, &data)
        },
    )?;
    // #729/#730: Fs::readdir — entry NAMES of a directory, byte-sorted and
    // "\n"-joined into ONE packed string (same (i64)->i64 ABI as fs_read_file,
    // so no host-side array building and it works under RC and bump alike;
    // codegen splits guest-side). Empty dir -> "". Missing dir -> error,
    // matching fs_read_file.
    linker.func_wrap(
        "vibe",
        "fs_read_dir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let mut names: Vec<String> = fs::read_dir(&path)
                .map_err(|e| format_err!("vibe fs_read_dir '{path}': {e}"))?
                .filter_map(|ent| ent.ok())
                .map(|ent| ent.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            vibe_alloc_packed_str(&mut caller, &names.join("\n"))
        },
    )?;
    // #901: Stdout/Stderr stream builtins (lib/@vibe/io's Stdout::write_stream
    // / write_char and the new Stderr counterparts) -- previously only
    // implemented in scripts/wasm_vibe_host_runner.js (the JS runner used by
    // scripts/vibe_run.sh), never ported to this Rust runner (the one the
    // real `vibe run` CLI actually uses), so any program using them failed to
    // instantiate here with an unknown-import error. Writes immediately (no
    // buffering), matching the JS runner's semantics exactly -- the older,
    // buffered `spectest::print_char` above is a SEPARATE, legacy mechanism
    // for `print_int`/plain program output and is left untouched.
    linker.func_wrap(
        "vibe",
        "stdout_write_stream",
        |mut caller: Caller<'_, HostState>, s: i64| -> Result<()> {
            let s = vibe_read_packed_str(&mut caller, s)?;
            let stdout = io::stdout();
            let mut h = stdout.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stdout_write_stream: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "stdout_write_char",
        |code: i64| -> Result<()> {
            let cu = (code as u32 & 0xffff) as u16;
            let s = String::from_utf16_lossy(&[cu]);
            let stdout = io::stdout();
            let mut h = stdout.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stdout_write_char: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "stderr_write_stream",
        |mut caller: Caller<'_, HostState>, s: i64| -> Result<()> {
            let s = vibe_read_packed_str(&mut caller, s)?;
            let stderr = io::stderr();
            let mut h = stderr.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stderr_write_stream: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "stderr_write_char",
        |code: i64| -> Result<()> {
            let cu = (code as u32 & 0xffff) as u16;
            let s = String::from_utf16_lossy(&[cu]);
            let stderr = io::stderr();
            let mut h = stderr.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stderr_write_char: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    // #lsp-selfhost: `Stdin` (lib/@vibe/io) -- same pre-existing-JS-only gap
    // as Stdout/Stderr above (#901), just never hit until a program that
    // actually READS stdin (rather than only writing it) was run under this
    // Rust runner: `scripts/wasm_vibe_host_runner.js`'s `stdin_read_char`/
    // `stdin_read_stream` only ever fed a FIXED, pre-buffered
    // `VIBE_STDIN_BYTES` env var set before the process starts (a testing
    // convenience for one-shot batch fixtures, see that file's own comment),
    // never a live incremental read from a real stdin pipe -- so any program
    // using `Stdin::read_char`/`read_stream` failed to instantiate here at
    // all (unknown import) and could never have worked interactively (e.g.
    // piped from a live editor process) under either runner. Blocking reads
    // straight off `std::io::stdin()`, matching Stdout/Stderr's write-
    // straight-through-no-buffering semantics: `read_char` blocks for
    // exactly one byte (-1 at EOF); `read_stream(n)` issues one blocking
    // `Read::read` for up to `n` bytes and returns whatever came back
    // (short reads preserved, "" at EOF) -- the "one bounded pull, cursor
    // advances across calls" contract lib/@vibe/io/io.vibe's own doc
    // comment documents. `.lock()` is re-acquired fresh each call (cheap,
    // and correct: the underlying buffered reader is process-global, no
    // state lives in the lock guard itself), matching every other stdio
    // host function here.
    // Length of the longest prefix of `buf` that ends on a complete UTF-8
    // sequence boundary -- i.e. everything past the returned index (if any)
    // is a lead byte whose continuation bytes haven't arrived yet. Used by
    // `stdin_read_stream` so a pipe read that splits a multi-byte character
    // across two `read()` calls doesn't get lossy-decoded (and thereby
    // corrupted) in the earlier call; the incomplete tail is held back and
    // prefixed onto the next read instead.
    fn utf8_complete_prefix_len(buf: &[u8]) -> usize {
        let len = buf.len();
        if len == 0 {
            return 0;
        }
        // Walk back over trailing continuation bytes (0x80..=0xBF, at most 3 --
        // a well-formed sequence is at most 4 bytes total) to find the start of
        // the last (possibly incomplete) sequence.
        let mut lead_pos = len;
        let mut back = 0;
        while back < 3 && lead_pos > 0 && (buf[lead_pos - 1] & 0xC0) == 0x80 {
            lead_pos -= 1;
            back += 1;
        }
        if lead_pos == 0 {
            // Nothing but continuation bytes within the lookback window and no
            // lead byte in view -- not a shape a real UTF-8 stream produces;
            // nothing sensible to hold back.
            return len;
        }
        let lead = buf[lead_pos - 1];
        let seq_len: usize = if (0xF0..=0xF7).contains(&lead) {
            4
        } else if (0xE0..=0xEF).contains(&lead) {
            3
        } else if (0xC2..=0xDF).contains(&lead) {
            2
        } else {
            // ASCII, or not a valid multi-byte lead byte -- nothing pending.
            return len;
        };
        if lead_pos - 1 + seq_len > len {
            lead_pos - 1
        } else {
            len
        }
    }

    // `sleep(Int) -> Unit with { Async }` -- codegen (linked_compile.vibe)
    // emits `vibe.sleep (i64) -> ()` whenever a program calls the builtin,
    // but neither this runner nor the Node dev runner ever registered it,
    // so any real caller (e.g. lib/@vibe/time's public `sleep_ms`,
    // lib/@vibex/shell's `sleep`) crashed the real `vibe run` at
    // instantiation with an unknown-import trap -- never reached `sleep`
    // actually running, let alone sleeping the wrong amount. A plain
    // blocking `thread::sleep` (matching tools/async_host/src/main.rs's own
    // reference impl) fixes the crash and is correct for the common case of
    // a single sequential caller; it does NOT give concurrently-`spawn`ed
    // tasks true interleaved sleep (each `sleep` blocks the whole wasm
    // instance) -- that needs wasmtime's async-fiber support
    // (tools/async_host/src/concurrency.rs's `func_wrap_async`, a much
    // larger change to how this store/linker are configured) and no known
    // caller needs it today.
    linker.func_wrap(
        "vibe",
        "sleep",
        |_caller: Caller<'_, HostState>, ms: i64| -> Result<()> {
            if ms > 0 {
                std::thread::sleep(std::time::Duration::from_millis(ms as u64));
            }
            Ok(())
        },
    )?;

    linker.func_wrap(
        "vibe",
        "stdin_read_char",
        |_caller: Caller<'_, HostState>| -> Result<i64> {
            let mut buf = [0u8; 1];
            let stdin = io::stdin();
            let mut h = stdin.lock();
            match h.read(&mut buf) {
                Ok(0) => Ok(-1),
                Ok(_) => Ok(buf[0] as i64),
                Err(e) => Err(format_err!("vibe stdin_read_char: {e}")),
            }
        },
    )?;
    linker.func_wrap(
        "vibe",
        "stdin_read_stream",
        |mut caller: Caller<'_, HostState>, n: i64| -> Result<i64> {
            if n <= 0 {
                return vibe_alloc_packed_str(&mut caller, "");
            }
            let mut buf = std::mem::take(&mut caller.data_mut().stdin_pending);
            let before_pending = buf.len();
            buf.resize(before_pending + n as usize, 0);
            let read = {
                let stdin = io::stdin();
                let mut h = stdin.lock();
                h.read(&mut buf[before_pending..])
                    .map_err(|e| format_err!("vibe stdin_read_stream: {e}"))?
            };
            buf.truncate(before_pending + read);
            // Hold back a trailing incomplete UTF-8 sequence (if any) for the
            // next call instead of lossy-decoding it now -- see this closure's
            // registration comment and utf8_complete_prefix_len's doc comment.
            // At EOF (read == 0 and nothing new arrived) there's nothing left
            // to wait for, so decode whatever's pending lossily rather than
            // holding it forever.
            let complete_len = if read == 0 {
                buf.len()
            } else {
                utf8_complete_prefix_len(&buf)
            };
            let pending = buf.split_off(complete_len);
            let s = String::from_utf8_lossy(&buf).into_owned();
            caller.data_mut().stdin_pending = pending;
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    // #901: `Process` effect (lib/@vibe/process) -- same pre-existing-JS-only
    // gap as Stdout/Stderr above. `sh` inherits stdio (so the child's own
    // output goes straight to the real terminal, matching a shell `$(...)`
    // running interactively) and throws (a host-call Err, which surfaces as a
    // wasm trap) on a non-zero exit -- there is no successful-but-failed
    // return value, mirroring wasm_vibe_host_runner.js's unconditional
    // `execSync(cmd, {stdio: "inherit"})` (which throws JS-side on failure).
    linker.func_wrap(
        "vibe",
        "sh",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let status = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .status()
                .map_err(|e| format_err!("vibe sh '{cmd}': {e}"))?;
            if !status.success() {
                bail!("vibe sh '{cmd}': exited with {status}");
            }
            Ok(0)
        },
    )?;
    // `sh_lines`: combined stdout+stderr (matching the JS runner's `execSync`
    // with piped stdio, which merges neither by default -- only stdout is
    // captured on success), trimmed of a trailing newline; on failure returns
    // an "error: "-prefixed string instead of throwing (the JS runner's
    // try/catch shape), since callers pattern-match this prefix rather than
    // branch on a real exit code (that's what `sh_capture` below is for).
    linker.func_wrap(
        "vibe",
        "sh_lines",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let output = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .output()
                .map_err(|e| format_err!("vibe sh_lines '{cmd}': {e}"))?;
            let result = if output.status.success() {
                String::from_utf8_lossy(&output.stdout)
                    .trim_end()
                    .to_string()
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let stderr = stderr.trim();
                if stderr.is_empty() {
                    format!("error: exited with {}", output.status)
                } else {
                    format!("error: {stderr}")
                }
            };
            vibe_alloc_packed_str(&mut caller, &result)
        },
    )?;
    // #901 (originally #865): structured subprocess result. `sh_capture` runs
    // the command ONCE via `output()` (which reports stdout/stderr/status
    // uniformly for both the success and failure case, unlike `sh`/`sh_lines`
    // above) and parks {exit_code, stdout, stderr} behind a handle so the 3
    // accessor imports below are cheap map reads, not re-execs -- same shape
    // as wasm_vibe_host_runner.js's `shCaptureResults` map.
    linker.func_wrap(
        "vibe",
        "sh_capture",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let output = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .output()
                .map_err(|e| format_err!("vibe sh_capture '{cmd}': {e}"))?;
            // On Unix a signal-killed child has no exit code; fall back to
            // 128 (the shell convention), matching wasm_vibe_host_runner.js's
            // signal-vs-status handling since Rust's ExitStatus doesn't
            // separately report "not exited yet" the way Node's does.
            let exit_code = output.status.code().unwrap_or(128);
            let host = caller.data_mut();
            let handle = host.next_sh_capture_handle;
            host.next_sh_capture_handle += 1;
            host.sh_capture_results.insert(
                handle,
                ShCaptureResult {
                    exit_code,
                    stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                },
            );
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_exit_code",
        |caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let entry = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_exit_code: unknown handle"))?;
            Ok(entry.exit_code as i64)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_stdout",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let s = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_stdout: unknown handle"))?
                .stdout
                .clone();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_stderr",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let s = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_stderr: unknown handle"))?
                .stderr
                .clone();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    // Tolerates unknown handles, like the JS runner's `sh_capture_close` --
    // a double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "sh_capture_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().sh_capture_results.remove(&handle);
            Ok(())
        },
    )?;
    // Socket::tcp_connect/tcp_read/tcp_write/tcp_close -- declared builtins
    // (checker/builtin_registry.vibe) with a real call site
    // (lib/@vibe/socket/tcp.vibe's low-level layer) but, like fs_rename
    // before #1220, never wired to a host import here, so any real caller
    // crashed `vibe run` with an unknown-import trap. Blocking `std::net`
    // calls, same synchronous-ABI convention as every other host import in
    // this file (see this file's `sleep` import for the same tradeoff
    // spelled out) -- handles are parked in `tcp_connections`, same
    // handle-map shape as `sh_capture_results` above (a TcpStream itself
    // can't cross the wasm ABI).
    linker.func_wrap(
        "vibe",
        "tcp_connect",
        |mut caller: Caller<'_, HostState>, host: i64, port: i64| -> Result<i64> {
            let host = vibe_read_packed_str(&mut caller, host)?;
            let port = u16::try_from(port)
                .map_err(|_| format_err!("vibe tcp_connect: invalid port {port}"))?;
            let stream = std::net::TcpStream::connect((host.as_str(), port))
                .map_err(|e| format_err!("vibe tcp_connect '{host}:{port}': {e}"))?;
            let host_state = caller.data_mut();
            let handle = host_state.next_tcp_handle;
            host_state.next_tcp_handle += 1;
            host_state.tcp_connections.insert(handle, stream);
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "tcp_read",
        |mut caller: Caller<'_, HostState>, handle: i64, max_bytes: i64| -> Result<i64> {
            let max_bytes = usize::try_from(max_bytes.max(0))
                .map_err(|_| format_err!("vibe tcp_read: invalid max_bytes {max_bytes}"))?;
            let mut buf = vec![0u8; max_bytes];
            let read = {
                let stream = caller
                    .data_mut()
                    .tcp_connections
                    .get_mut(&handle)
                    .ok_or_else(|| format_err!("vibe tcp_read: unknown handle"))?;
                stream
                    .read(&mut buf)
                    .map_err(|e| format_err!("vibe tcp_read: {e}"))?
            };
            buf.truncate(read);
            let s = String::from_utf8_lossy(&buf).into_owned();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "tcp_write",
        |mut caller: Caller<'_, HostState>, handle: i64, data: i64| -> Result<()> {
            let data = vibe_read_packed_str(&mut caller, data)?;
            let stream = caller
                .data_mut()
                .tcp_connections
                .get_mut(&handle)
                .ok_or_else(|| format_err!("vibe tcp_write: unknown handle"))?;
            stream
                .write_all(data.as_bytes())
                .map_err(|e| format_err!("vibe tcp_write: {e}"))?;
            Ok(())
        },
    )?;
    // Tolerates unknown handles, like sh_capture_close above -- a
    // double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "tcp_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().tcp_connections.remove(&handle);
            Ok(())
        },
    )?;
    // #1226: Http::request/response_status/response_header/response_body/close
    // -- declared builtins (checker/builtin_registry.vibe) with real call
    // sites (lib/@vibe/http/http.vibe's client-side raw dunder calls, #794)
    // but no host-import registration anywhere, so any real caller crashed
    // `vibe run` with an unknown-import trap. `headers` is a "name:
    // value\n"-joined string (lib/@vibe/http/high_level.vibe's
    // `headers_to_wire`), matching what a caller building on the low-level
    // `request()` already produces.
    linker.func_wrap(
        "vibe",
        "http_request",
        |mut caller: Caller<'_, HostState>, method: i64, url: i64, headers: i64, body: i64| -> Result<i64> {
            let method = vibe_read_packed_str(&mut caller, method)?;
            let url = vibe_read_packed_str(&mut caller, url)?;
            let headers = vibe_read_packed_str(&mut caller, headers)?;
            let body = vibe_read_packed_str(&mut caller, body)?;
            let mut req = ureq::request(&method, &url);
            for line in headers.split('\n') {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Some((name, value)) = line.split_once(':') {
                    req = req.set(name.trim(), value.trim());
                }
            }
            let result = if body.is_empty() {
                req.call()
            } else {
                req.send_string(&body)
            };
            let response = match result {
                Ok(resp) => resp,
                // ureq treats a 4xx/5xx response as Err by default -- it's
                // still a real, well-formed response (do_404 in
                // http_e2e_test.vibe expects to read a 404 status, not a
                // trap), so unwrap it the same way as the Ok case. Only a
                // genuine transport failure (DNS, connect refused, TLS)
                // falls through to the trap below.
                Err(ureq::Error::Status(_, resp)) => resp,
                Err(e) => return Err(format_err!("vibe http_request '{method} {url}': {e}")),
            };
            let status = response.status() as i64;
            let resp_headers: Vec<(String, String)> = response
                .headers_names()
                .into_iter()
                .filter_map(|name| {
                    let value = response.header(&name)?.to_string();
                    Some((name.to_lowercase(), value))
                })
                .collect();
            let resp_body = response
                .into_string()
                .map_err(|e| format_err!("vibe http_request '{method} {url}': reading body: {e}"))?;
            let host_state = caller.data_mut();
            let handle = host_state.next_http_handle;
            host_state.next_http_handle += 1;
            host_state.http_responses.insert(
                handle,
                HttpResponseData {
                    status,
                    headers: resp_headers,
                    body: resp_body,
                },
            );
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_status",
        |caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let entry = caller
                .data()
                .http_responses
                .get(&handle)
                .ok_or_else(|| format_err!("vibe http_response_status: unknown handle"))?;
            Ok(entry.status)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_header",
        |mut caller: Caller<'_, HostState>, handle: i64, name: i64| -> Result<i64> {
            let name = vibe_read_packed_str(&mut caller, name)?;
            let name_lower = name.to_lowercase();
            let value = {
                let entry = caller
                    .data()
                    .http_responses
                    .get(&handle)
                    .ok_or_else(|| format_err!("vibe http_response_header: unknown handle"))?;
                entry
                    .headers
                    .iter()
                    .find(|(hn, _)| *hn == name_lower)
                    .map(|(_, v)| v.clone())
                    .unwrap_or_default()
            };
            vibe_alloc_packed_str(&mut caller, &value)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_body",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let body = caller
                .data()
                .http_responses
                .get(&handle)
                .ok_or_else(|| format_err!("vibe http_response_body: unknown handle"))?
                .body
                .clone();
            vibe_alloc_packed_str(&mut caller, &body)
        },
    )?;
    // Tolerates unknown handles, like sh_capture_close/tcp_close above -- a
    // double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "http_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().http_responses.remove(&handle);
            Ok(())
        },
    )?;
    // #903/#865: `Process::exit(code)` -- propagates a guest-chosen code to
    // the real OS exit status by reusing the SAME trap mechanism the legacy
    // `__moonbit_sys_unstable::exit` import already relies on (see `run()`'s
    // ExitTrap downcast below): trapping here unwinds straight out of the
    // wasm call, and the caller recovers the code and exits the process
    // with it instead of treating the trap as a real error.
    linker.func_wrap(
        "vibe",
        "process_exit",
        |_caller: Caller<'_, HostState>, code: i64| -> Result<()> {
            Err(ExitTrap(code as i32).into())
        },
    )?;
    // debugger breakpoint (DAP P1): the break-mode codegen emits a bare
    // `call vibe::dbg_break` at each user function entry. We capture the wasm
    // backtrace, name the entering function (the innermost user frame via the
    // name section), and pause when it is in the VIBE_BREAK set, printing the
    // call stack, then continue. Always registered (harmless no-op when the
    // module doesn't import it, or when VIBE_BREAK is empty).
    linker.func_wrap(
        "vibe",
        "dbg_break",
        |caller: Caller<'_, HostState>| -> Result<()> { vibe_dbg_break(caller) },
    )?;
    // Interior-line breakpoint (span-arc step5): the break-mode codegen emits
    // `call vibe::dbg_line (i32 line)` at each statement boundary. Pauses on a
    // line-break-set match or step. Always registered (harmless no-op when the
    // module doesn't import it, or when no line breakpoints / step are active).
    linker.func_wrap(
        "vibe",
        "dbg_line",
        |caller: Caller<'_, HostState>, file_id: i32, line: i32| -> Result<()> {
            vibe_dbg_line(caller, file_id, line)
        },
    )?;
    Ok(())
}

// Capture frame names from the wasm backtrace, innermost first. Frame 0 is the
// `vibe::dbg_break` import call site (the entering user function). Unnamed
// frames are skipped. Returns the named frame list (e.g. ["helper", "main"]).
fn dbg_break_frames(caller: &Caller<'_, HostState>) -> Vec<String> {
    let bt = wasmtime::WasmBacktrace::capture(caller);
    let mut out = Vec::new();
    for frame in bt.frames() {
        if let Some(name) = frame.func_name() {
            out.push(name.to_string());
        }
    }
    out
}

// Sentinel: user typed `q` at an interactive breakpoint to abort the run. The
// run loop maps it to exit code 130 (128 + SIGINT), like a Ctrl-C.
#[derive(Debug)]
struct BreakAbort;

impl std::fmt::Display for BreakAbort {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "breakpoint: aborted by user")
    }
}

impl std::error::Error for BreakAbort {}

// DAP P2/P4: read the argument values the codegen spilled into the dbgargs region
// before calling this hook, and format them as `[name=v0, name=v1, ...]`. Returns
// None if the module has no `vibe.dbgargs` section (non-break build) or memory
// access fails. Each value is decoded per tag_mode (see below). When the entering
// function's parameter names are known (from the `vibe.dbgnames` section, DAP P4)
// AND the name count matches the spilled value count, each value is labelled
// `name=value`; otherwise it falls back to a bare positional `value`.
fn dbg_read_args(caller: &mut Caller<'_, HostState>, entering: &str) -> Option<String> {
    let count_addr = caller.data().dbgargs_count_addr?;
    let base = caller.data().dbgargs_base?;
    let tag_mode = caller.data().dbgargs_tag_mode;
    let names = caller.data().dbgnames.get(entering).cloned();
    let memory = caller.get_export("memory").and_then(|e| e.into_memory())?;
    let mut count_buf = [0u8; 4];
    if memory.read(&*caller, count_addr, &mut count_buf).is_err() {
        return None;
    }
    let count = (u32::from_le_bytes(count_buf) as usize).min(16);
    // Only label by name when the name count matches the value count exactly;
    // any mismatch (missing section, cap truncation skew) falls back to positional.
    let use_names = names.as_ref().map(|n| n.len() == count).unwrap_or(false);
    let mut parts: Vec<String> = Vec::with_capacity(count);
    let mut i = 0usize;
    while i < count {
        let mut val_buf = [0u8; 8];
        if memory.read(&*caller, base + i * 8, &mut val_buf).is_err() {
            break;
        }
        let raw = i64::from_le_bytes(val_buf);
        // tag_mode 0: plain untagged i64 int. tag_mode 1: 1-bit tagged — low bit
        // 0 => int (raw >> 1), low bit 1 => heap pointer shown as raw hex.
        let val = if tag_mode == 1 {
            if raw & 1 == 0 {
                format!("{}", raw >> 1)
            } else {
                format!("0x{:x}", raw)
            }
        } else {
            format!("{raw}")
        };
        if use_names {
            // SAFETY: use_names implies names.len() == count, so index i is valid.
            let nm = &names.as_ref().unwrap()[i];
            parts.push(format!("{nm}={val}"));
        } else {
            parts.push(val);
        }
        i += 1;
    }
    Some(format!("[{}]", parts.join(", ")))
}

// Read the guest's exported `__heap_ptr` bump pointer from a hook Caller, or None
// if the module doesn't export it. Used by tier-4 alloc-site accounting.
fn caller_heap_ptr(caller: &mut Caller<'_, HostState>) -> Option<u64> {
    let g = caller
        .get_export("__heap_ptr")
        .and_then(|e| e.into_global())?;
    Some(match g.get(&mut *caller) {
        Val::I32(v) => v as u32 as u64,
        Val::I64(v) => v as u64,
        _ => 0,
    })
}

// Profiling tier 4: one allocation-attribution sample. Credit the heap bump SINCE
// the last sample to the function that was running THEN (`alloc_prev_fn`), then
// record the function running NOW (innermost user frame) as the new "previous".
// Called from BOTH `dbg_break` (function entry) and `dbg_line` (statement
// boundary), so the running function is re-read at every instrumented point — not
// only at entries. That matters for caller/callee accuracy: after a helper
// returns, the caller's next statement re-takes a sample with the caller on top,
// so allocation it does post-call is charged to the CALLER, not left dangling on
// the returned helper (which entry-only sampling would mis-attribute). Residual
// error is bounded to the gap between instrumentation points (e.g. a run of `mut`
// assignments, which emit no dbg_line, inside one function). No-op unless
// alloc_site is on, so non-profiling runs pay nothing.
fn alloc_account(caller: &mut Caller<'_, HostState>) {
    if !caller.data().alloc_site {
        return;
    }
    let cur = match caller_heap_ptr(caller) {
        Some(c) => c,
        None => return,
    };
    // Innermost named frame = the user function whose body is executing now.
    let running = dbg_break_frames(caller).into_iter().next();
    let data = caller.data_mut();
    if let Some(prev) = data.alloc_prev_fn.take() {
        let delta = cur.saturating_sub(data.alloc_prev_heap);
        if delta > 0 {
            *data.alloc_sites.entry(prev).or_insert(0) += delta;
        }
    }
    data.alloc_prev_fn = running;
    data.alloc_prev_heap = cur;
}

fn vibe_dbg_break(mut caller: Caller<'_, HostState>) -> Result<()> {
    alloc_account(&mut caller);
    let break_set = Arc::clone(&caller.data().break_set);
    let line_break_set = Arc::clone(&caller.data().line_break_set);
    let step_mode = caller.data().step_mode;
    // Fast path: nothing can ever pause us. No explicit breakpoints (neither
    // function-name NOR line) AND we are in plain Continue mode. The hook stays a
    // no-op, so non-break / no-match runs pay only a backtrace-free early return.
    if break_set.is_empty() && line_break_set.is_empty() && step_mode == StepMode::Continue {
        return Ok(());
    }
    let frames = dbg_break_frames(&caller);
    // The entering function is the innermost named frame (the body that just
    // called dbg_break). If we can't name it, there is nothing to match on.
    let entering = match frames.first() {
        Some(n) => n.clone(),
        None => return Ok(()),
    };
    // Current call depth = number of named frames on the stack. Used by
    // StepOver/StepOut to compare against the depth recorded at the last pause.
    let depth = frames.len();
    // DAP P3: decide whether to pause at THIS entry. An explicit break_set hit
    // always pauses (and keeps the `breakpoint hit:` label so existing tests
    // pass). Otherwise the active step mode decides.
    let is_name_hit = break_set.iter().any(|b| *b == entering);
    // span-arc step5: resolve the entering function's declaration line via the
    // funcmap; pause when it is in the line-break-set. A line spec with a file
    // matches only when the file basename equals VIBE_BREAK_FILE (the program's
    // entry file); a bare-line spec matches any file. The hit line drives the
    // `breakpoint hit: <file>:<line>` label below.
    let entering_line = caller.data().funcmap.get(&entering).copied();
    let break_file = caller.data().break_file.clone();
    let line_hit: Option<u32> = entering_line.and_then(|ln| {
        if line_break_set.iter().any(|(file, l)| {
            *l == ln
                && match file {
                    Some(f) => break_file.as_deref() == Some(f.as_str()),
                    None => true,
                }
        }) {
            Some(ln)
        } else {
            None
        }
    });
    let is_break_hit = is_name_hit || line_hit.is_some();
    let step_pause = match step_mode {
        StepMode::Continue => false,
        StepMode::StepInto => true,
        StepMode::StepOver => depth <= caller.data().pause_depth,
        StepMode::StepOut => depth < caller.data().pause_depth,
    };
    if !is_break_hit && !step_pause {
        return Ok(());
    }
    // DAP P2: read the spilled argument values for the entering function out of
    // guest memory and format them. count_addr holds an i32 arg count; base holds
    // that many i64 vibe values. Decode each: a tagged INT (low 2 bits == 00) is
    // shown as the integer (raw >> 2); anything else is shown as `0x<hex>` raw.
    let args_line = dbg_read_args(&mut caller, &entering);
    {
        let stderr = std::io::stderr();
        let mut h = stderr.lock();
        // Keep `breakpoint hit:` for explicit break hits (existing tests grep for
        // it); a pure step-induced pause is labelled `stopped at:`. A LINE break
        // hit is labelled `breakpoint hit: <file>:<line>` (span-arc step5) so the
        // launcher/annotator and DAP can read which line paused; a NAME hit keeps
        // the `breakpoint hit: <fn>` form.
        if is_break_hit {
            match line_hit {
                Some(ln) if !is_name_hit => {
                    let file = break_file.as_deref().unwrap_or("");
                    if file.is_empty() {
                        let _ = writeln!(h, "breakpoint hit: {ln}");
                    } else {
                        let _ = writeln!(h, "breakpoint hit: {file}:{ln}");
                    }
                }
                _ => {
                    let _ = writeln!(h, "breakpoint hit: {entering}");
                }
            }
        } else {
            let _ = writeln!(h, "stopped at: {entering}");
        }
        if let Some(line) = &args_line {
            let _ = writeln!(h, "  args: {line}");
        }
        for f in &frames {
            let _ = writeln!(h, "  at {f}");
        }
        let _ = h.flush();
    }
    dbg_apply_command(&mut caller, depth)
}

// Shared pause epilogue for both the function-entry (`vibe::dbg_break`) and
// line-granularity (`vibe::dbg_line`) hooks: honour VIBE_BREAK_AUTO, else read
// ONE debugger command from stdin and set the step mode accordingly. `depth` is
// the current call depth, recorded as pause_depth for StepOver/StepOut.
fn dbg_apply_command(caller: &mut Caller<'_, HostState>, depth: usize) -> Result<()> {
    let auto = caller.data().break_auto;
    if auto {
        // VIBE_BREAK_AUTO: continue without reading stdin (preserves existing
        // auto tests). A step mode could only have been set interactively, so in
        // auto mode this stays Continue throughout.
        return Ok(());
    }
    // Interactive (or scripted-stdin): read one debugger command. We read whether
    // or not stdin is a TTY — this is what enables scripted step tests. The hook
    // only exists in break builds, so a non-break run never reaches here.
    use std::io::BufRead;
    let mut line = String::new();
    let stdin = std::io::stdin();
    let n = stdin.lock().read_line(&mut line).unwrap_or(0);
    if n == 0 {
        // EOF on stdin: continue and don't block again (drop to Continue mode so
        // no later entry tries to read from the now-closed stdin).
        caller.data_mut().step_mode = StepMode::Continue;
        return Ok(());
    }
    let cmd = line.trim();
    match cmd {
        "q" | "quit" => return Err(BreakAbort.into()),
        "s" | "step" | "stepi" => {
            caller.data_mut().step_mode = StepMode::StepInto;
        }
        "n" | "next" => {
            let host = caller.data_mut();
            host.step_mode = StepMode::StepOver;
            host.pause_depth = depth;
        }
        "o" | "out" | "finish" => {
            let host = caller.data_mut();
            host.step_mode = StepMode::StepOut;
            host.pause_depth = depth;
        }
        // `c` / `continue` / empty (and anything unrecognised) => continue.
        _ => {
            caller.data_mut().step_mode = StepMode::Continue;
        }
    }
    Ok(())
}

// Interior-line breakpoint hook (span-arc step5). The break-mode codegen emits
// `call vibe::dbg_line (i32 line)` at each statement boundary, passing the 1-based
// source line of that statement. We pause when `line` is in the line-break-set
// (file matched against break_file when the spec carries one) or when a step mode
// says so, reusing the same pause/step epilogue as the function-entry hook. A
// no-op when nothing can pause (empty line set + Continue) so non-break runs and
// unmatched lines pay only an early return.
fn vibe_dbg_line(mut caller: Caller<'_, HostState>, file_id: i32, line: i32) -> Result<()> {
    // tier 4: take an allocation sample at this statement boundary too (see
    // alloc_account) so post-call allocation in a caller is charged to the caller.
    alloc_account(&mut caller);
    let line_break_set = Arc::clone(&caller.data().line_break_set);
    let step_mode = caller.data().step_mode;
    if line_break_set.is_empty() && step_mode == StepMode::Continue {
        return Ok(());
    }
    let cur: u32 = if line < 0 { return Ok(()) } else { line as u32 };
    // Resolve this statement's source file basename from the dbgfiles table; a
    // `--break <file>:<line>` spec matches only when its file equals that basename
    // (bare-line specs match any file).
    let dbgfiles = Arc::clone(&caller.data().dbgfiles);
    let cur_file: Option<&str> = if file_id >= 0 {
        dbgfiles.get(file_id as usize).map(|s| s.as_str())
    } else {
        None
    };
    let is_line_hit = line_break_set.iter().any(|(file, l)| {
        *l == cur
            && match file {
                Some(f) => cur_file == Some(f.as_str()),
                None => true,
            }
    });
    let frames = dbg_break_frames(&caller);
    let depth = frames.len();
    let step_pause = match step_mode {
        StepMode::Continue => false,
        StepMode::StepInto => true,
        StepMode::StepOver => depth <= caller.data().pause_depth,
        StepMode::StepOut => depth < caller.data().pause_depth,
    };
    if !is_line_hit && !step_pause {
        return Ok(());
    }
    {
        let stderr = std::io::stderr();
        let mut h = stderr.lock();
        let file = cur_file.unwrap_or("");
        // An explicit line hit keeps `breakpoint hit:` (tests/DAP grep for it); a
        // pure step pause is `stopped at:`. Both carry `<file>:<line>` so the
        // annotator/DAP can read the paused line.
        let label = if is_line_hit {
            "breakpoint hit"
        } else {
            "stopped at"
        };
        if file.is_empty() {
            let _ = writeln!(h, "{label}: {cur}");
        } else {
            let _ = writeln!(h, "{label}: {file}:{cur}");
        }
        for f in &frames {
            let _ = writeln!(h, "  at {f}");
        }
        let _ = h.flush();
    }
    dbg_apply_command(&mut caller, depth)
}

fn register_imports(linker: &mut Linker<HostState>) -> Result<()> {
    register_vibe_imports(linker)?;
    // Selfhost codegen emits WASI Preview1 fd_write for stdout/stderr (the
    // same import shape the original moon `--target wasm` output used).
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
    // `Profiler::heap_bytes` — the guest's current bump-heap pointer (a
    // monotonic allocation counter; see caller_heap_ptr). The allocation
    // analog of profile-now-us for per-phase memory attribution. The legacy
    // tagged-lane `Profiler/HeapBytes` import tags like its NowUs sibling;
    // the selfhost raw-ABI `vibe/profile-heap-bytes` import returns the RAW
    // integer — raw host imports speak untagged values (the JS runner's raw
    // encodeHostInt path, and compile_call's RC shim tags raw results
    // itself), so tagging here would inflate readings 4x under wasmtime and
    // break node/wasmtime profiling parity (PR #803 review).
    linker.func_wrap(
        "Profiler",
        "HeapBytes",
        |mut caller: Caller<'_, HostState>, _env: i32| -> i64 {
            encode_tagged_int(caller_heap_ptr(&mut caller).unwrap_or(0) as i64)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "profile-heap-bytes",
        |mut caller: Caller<'_, HostState>| -> i64 {
            caller_heap_ptr(&mut caller).unwrap_or(0) as i64
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

// Read a LEB128 unsigned integer at `bytes[*pos..]`, advancing `*pos`.
fn read_leb_u32(bytes: &[u8], pos: &mut usize) -> Option<u32> {
    let mut result: u32 = 0;
    let mut shift = 0u32;
    loop {
        let b = *bytes.get(*pos)?;
        *pos += 1;
        result |= ((b & 0x7f) as u32) << shift;
        if b & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
        if shift >= 32 {
            return None;
        }
    }
}

// Locate a wasm custom section by name and return its content bytes (after the
// section's name field). Scans the section list directly from the raw module
// bytes (the trace launcher always passes a fresh `.wasm`, not a cwasm).
fn find_custom_section(wasm: &[u8], want_name: &str) -> Option<Vec<u8>> {
    if wasm.len() < 8 || &wasm[0..4] != b"\0asm" {
        return None;
    }
    let mut pos = 8usize;
    while pos < wasm.len() {
        let id = *wasm.get(pos)?;
        pos += 1;
        let size = read_leb_u32(wasm, &mut pos)? as usize;
        let body_start = pos;
        let body_end = body_start.checked_add(size)?;
        if body_end > wasm.len() {
            return None;
        }
        if id == 0 {
            // custom section: LEB name-len, name bytes, then content
            let mut npos = body_start;
            let name_len = read_leb_u32(wasm, &mut npos)? as usize;
            let name_end = npos.checked_add(name_len)?;
            if name_end <= body_end {
                let name = &wasm[npos..name_end];
                if name == want_name.as_bytes() {
                    return Some(wasm[name_end..body_end].to_vec());
                }
            }
        }
        pos = body_end;
    }
    None
}

fn read_u32_le(bytes: &[u8], off: usize) -> Option<u32> {
    let b = bytes.get(off..off + 4)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

// span-arc step5: parse a single VIBE_BREAK entry as a LINE breakpoint spec.
// Accepts `<file>:<line>` (e.g. `prog.vibe:5`) -> (Some("prog.vibe"), 5), or a
// bare all-digit `<line>` (e.g. `5`) -> (None, 5). Returns None when the spec is
// not a line spec (a function name), leaving it for the function-name break_set.
// The file part keeps its basename only so a spec with a directory prefix still
// matches VIBE_BREAK_FILE (which is a basename).
fn parse_line_break_spec(spec: &str) -> Option<(Option<String>, u32)> {
    if !spec.is_empty() && spec.bytes().all(|b| b.is_ascii_digit()) {
        return spec.parse::<u32>().ok().map(|n| (None, n));
    }
    // `<file>:<line>` — split on the LAST colon so Windows-ish paths still work.
    let idx = spec.rfind(':')?;
    let (file, rest) = (&spec[..idx], &spec[idx + 1..]);
    if file.is_empty() || rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let line = rest.parse::<u32>().ok()?;
    let base = std::path::Path::new(file)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(file)
        .to_string();
    Some((Some(base), line))
}

// span-arc step5: parse a `.funcmap` sidecar (one `name<TAB>declLine` per line,
// as written by the selfhost `build_funcmap_from_source`) into name -> line.
fn parse_funcmap(text: &str) -> std::collections::HashMap<String, u32> {
    let mut map = std::collections::HashMap::new();
    for line in text.split('\n') {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.splitn(2, '\t');
        let name = match fields.next() {
            Some(n) if !n.is_empty() => n,
            _ => continue,
        };
        if let Some(num) = fields.next() {
            if let Ok(n) = num.trim().parse::<u32>() {
                map.insert(name.to_string(), n);
            }
        }
    }
    map
}

// DAP P4: parse the `vibe.dbgnames` custom-section content into a function-name
// -> parameter-names map. Records are newline (\n) delimited; within a record
// fields are tab (\t) delimited, the first field being the function name and the
// remaining fields the parameter names (in declaration order). Empty/garbled
// records are skipped. Robust to trailing newline and missing-param functions.
// Interior-line breakpoints (span-arc step5): parse the `vibe.dbgfiles` section
// (source-file basenames, one per line in file-id order) into a Vec indexed by
// file id. `vibe::dbg_line(file_id, line)` uses the id to look up the basename.
fn parse_dbgfiles(section: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(section)
        .split('\n')
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect()
}

// #644: parse the `vibe.linemap` custom section into a (wasm func index ->
// sorted (code offset, file id, line) list) map. The section is a flat run of
// 16-byte little-endian records (func_index, offset, file_id, line); a
// trailing partial record (a corrupt/truncated section) is ignored rather
// than panicking. Entries are grouped by func_index and sorted by offset so
// `resolve_linemap` below can binary-search each function's list. Absent
// section / non-debug-break build => empty map => resolution always misses,
// callers fall back to their existing (coarser) behavior.
fn parse_linemap(section: &[u8]) -> std::collections::HashMap<u32, Vec<(u32, u32, u32)>> {
    let mut by_func: std::collections::HashMap<u32, Vec<(u32, u32, u32)>> =
        std::collections::HashMap::new();
    let mut pos = 0usize;
    while pos + 16 <= section.len() {
        let func_idx = read_u32_le(section, pos).unwrap_or(0);
        let offset = read_u32_le(section, pos + 4).unwrap_or(0);
        let file_id = read_u32_le(section, pos + 8).unwrap_or(0);
        let line = read_u32_le(section, pos + 12).unwrap_or(0);
        by_func.entry(func_idx).or_default().push((offset, file_id, line));
        pos += 16;
    }
    for entries in by_func.values_mut() {
        entries.sort_by_key(|e| e.0);
    }
    by_func
}

// #644: resolve a live (func_index, code_offset) pair -- as reported by
// wasmtime's `FrameInfo::func_index()`/`func_offset()` on a captured
// WasmBacktrace frame -- to the nearest known (file_id, line) at or before
// that offset. A line-table entry covers every offset from itself up to (but
// not including) the next entry for the same function, so this is a
// last-entry-with-offset-<=-target binary search (partition_point), not an
// exact match. None when the function has no linemap entries at all, or the
// offset falls before its first recorded entry (e.g. still in the locals
// header / function prologue).
fn resolve_linemap(
    linemap: &std::collections::HashMap<u32, Vec<(u32, u32, u32)>>,
    func_idx: u32,
    offset: u32,
) -> Option<(u32, u32)> {
    let entries = linemap.get(&func_idx)?;
    let idx = entries.partition_point(|e| e.0 <= offset);
    if idx == 0 {
        return None;
    }
    let (_, file_id, line) = entries[idx - 1];
    Some((file_id, line))
}

fn parse_dbgnames(section: &[u8]) -> std::collections::HashMap<String, Vec<String>> {
    let mut map = std::collections::HashMap::new();
    let text = String::from_utf8_lossy(section);
    for line in text.split('\n') {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split('\t');
        let fname = match fields.next() {
            Some(f) if !f.is_empty() => f.to_string(),
            _ => continue,
        };
        let params: Vec<String> = fields.map(|p| p.to_string()).collect();
        map.insert(fname, params);
    }
    map
}

// Dump the function-call execution trace recorded in the guest's in-memory
// trace log. Layout of the `vibe.trace` custom section: i32 LE counter_addr,
// i32 LE log_base, i32 LE cap, then the user-function names (one per line, in
// user-index order). After the program finishes, memory[counter_addr] holds the
// number of recorded entries; each entry is a user-function index stored as i32
// at log_base + i*4. Prints one `trace: <name>` line per entry to stderr.
fn dump_trace(wasm_path: &str, instance: &wasmtime::Instance, store: &mut Store<HostState>) {
    let wasm = match std::fs::read(wasm_path) {
        Ok(b) => b,
        Err(_) => return,
    };
    let section = match find_custom_section(&wasm, "vibe.trace") {
        Some(s) => s,
        None => return,
    };
    let counter_addr = match read_u32_le(&section, 0) {
        Some(v) => v as usize,
        None => return,
    };
    let log_base = match read_u32_le(&section, 4) {
        Some(v) => v as usize,
        None => return,
    };
    let cap = match read_u32_le(&section, 8) {
        Some(v) => v as usize,
        None => return,
    };
    // Names: newline-separated, in user-index order, starting after the 12-byte
    // header.
    let names: Vec<String> = section
        .get(12..)
        .map(|rest| {
            String::from_utf8_lossy(rest)
                .split('\n')
                .map(|s| s.to_string())
                .collect()
        })
        .unwrap_or_default();
    let memory = match instance
        .get_export(&mut *store, "memory")
        .and_then(|e| e.into_memory())
    {
        Some(m) => m,
        None => return,
    };
    let mut counter_buf = [0u8; 4];
    if memory
        .read(&*store, counter_addr, &mut counter_buf)
        .is_err()
    {
        return;
    }
    let count = u32::from_le_bytes(counter_buf) as usize;
    let count = count.min(cap);
    let stderr = std::io::stderr();
    let mut h = stderr.lock();
    let mut i = 0usize;
    while i < count {
        let mut entry_buf = [0u8; 4];
        if memory
            .read(&*store, log_base + i * 4, &mut entry_buf)
            .is_err()
        {
            break;
        }
        let idx = u32::from_le_bytes(entry_buf) as usize;
        let name = names.get(idx).map(|s| s.as_str()).unwrap_or("?");
        let _ = writeln!(h, "trace: {name}");
        i += 1;
    }
}

fn main() {
    // Re-launch onto a worker thread whose native stack comfortably exceeds
    // the configured wasm stack (see wasm_stack_bytes): wasm frames live on
    // the executing thread's stack, and the OS default (typically 8 MiB)
    // would be blown by the enlarged max_wasm_stack before wasmtime could
    // raise its own graceful trap.
    let stack = wasm_stack_bytes() + 8 * 1024 * 1024;
    let handle = std::thread::Builder::new()
        .name("viberun".to_string())
        .stack_size(stack)
        .spawn(real_main)
        .expect("spawn main thread");
    match handle.join() {
        Ok(()) => {}
        Err(_) => std::process::exit(1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_fs_scope_sidecar_is_versioned_and_has_only_host_import_counters() {
        let scope = HostFsScope {
            output: PathBuf::from("unused.json"),
            nonce: "run-1".to_string(),
            counters: HostFsScopeCounters {
                read_file_calls: 2,
                read_file_returned_bytes: 7,
                read_bytes_calls: 3,
                read_bytes_returned_bytes: 11,
                stat_token_calls: 5,
                exists_calls: 13,
            },
        };
        let value: serde_json::Value =
            serde_json::from_slice(&host_fs_scope_json(&scope).unwrap()).unwrap();
        assert_eq!(value["schema"], "host_fs_scope");
        assert_eq!(value["version"], 1);
        assert_eq!(value["nonce"], "run-1");
        assert_eq!(value["read_file_calls"], 2);
        assert_eq!(value["read_file_returned_bytes"], 7);
        assert_eq!(value["read_bytes_calls"], 3);
        assert_eq!(value["read_bytes_returned_bytes"], 11);
        assert_eq!(value["stat_token_calls"], 5);
        assert_eq!(value["exists_calls"], 13);
        assert_eq!(value.as_object().unwrap().len(), 9);
    }
}

fn real_main() {
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
            eprintln!("viberun: dump-imports failed: {e:?}");
            std::process::exit(1);
        }
        return;
    }
    // #644: introspection for the `vibe.linemap` custom section -- lets
    // scripts/tests verify the static (func index, code offset) -> (file,
    // line) table a debug-break build carries, without spinning up a full
    // interactive `--break` session. Not part of the run/annotate pipeline,
    // so it cannot interact with runtime/vibe's stderr annotator.
    if args.first().map(|s| s.as_str()) == Some("--dump-linemap") {
        let input = match args.get(1) {
            Some(s) => s.clone(),
            None => {
                eprintln!("--dump-linemap: missing <input.wasm>");
                std::process::exit(2);
            }
        };
        if args.len() > 2 {
            eprintln!("--dump-linemap: unexpected extra args");
            std::process::exit(2);
        }
        if let Err(e) = dump_linemap(&input) {
            eprintln!("viberun: dump-linemap failed: {e:?}");
            std::process::exit(1);
        }
        return;
    }
    if args.first().map(|s| s.as_str()) == Some("--daemon") {
        let daemon_args: Vec<String> = args.iter().skip(1).cloned().collect();
        match daemon(daemon_args) {
            Ok(code) => std::process::exit(code),
            Err(e) => {
                eprintln!("viberun: daemon failed: {e:?}");
                std::process::exit(1);
            }
        }
    }
    if args.first().map(|s| s.as_str()) == Some("--bench") {
        let bench_args: Vec<String> = args.iter().skip(1).cloned().collect();
        match bench(bench_args) {
            Ok(code) => std::process::exit(code),
            Err(e) => {
                eprintln!("viberun: {e}");
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
            eprintln!("viberun: precompile failed: {e:?}");
            std::process::exit(1);
        }
        return;
    }
    match run(args) {
        Ok(code) => std::process::exit(code),
        Err(e) => {
            eprintln!("viberun: {e:?}");
            std::process::exit(1);
        }
    }
}
