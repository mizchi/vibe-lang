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
use std::time::{Duration, Instant};

use wasmtime::{
    bail, format_err, AsContext, AsContextMut, CallHook, Caller, Config, Engine, ExnRef, ExnRefPre,
    ExnType, ExternRef, ExternType, GuestProfiler, Instance, Linker, Module, ResourceLimiter,
    Result, Rooted, Store, StoreLimits, StoreLimitsBuilder, Strategy, Trap, TypedFunc, Val,
    ValType,
};

mod commands;
mod native_cache;

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
// of docs/internal/design/profiling.md). Recording is gated (`record`) so non-profiling runs
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
    // Opt-in Wasmtime guest CPU profiler. Kept in Store data so epoch and call
    // hooks can temporarily take it out while also borrowing the Store context.
    guest_profiler: Option<GuestProfiler>,
    guest_cpu_clock: Option<GuestCpuClock>,
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
    // interior-line breakpoints (span-arc step5, multi-file) and #2199 trap
    // provenance: the SOURCE PATHS indexed by file id, parsed from the
    // `vibe.dbgfiles` custom section. `vibe::dbg_line(file_id, line)` passes the
    // file id; we index this to recover the file, take its basename, and match a
    // `--break <file>:<line>` spec's file against that. A trap annotation prints
    // the whole path. Empty => bare-line specs still match.
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
            guest_profiler: None,
            guest_cpu_clock: None,
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
           viberun --commands [--trust-precompiled] <manifest> <verb> [args...]\n\
           viberun --precompile-component <input.component.wasm> [-o <out.cwasm>]\n\
           viberun --help\n\
         \n\
         A Component Model binary is detected from its header and run through\n\
         the async component path instead (#1230 M1b-3c-2): its `run` export is\n\
         driven to completion and the returned value printed.\n\
         \n\
         --commands is the LAZY dispatch lane: the manifest (a\n\
         `vibe-commands-v1` TSV of `<verb>\\t<artifact>` rows) maps each verb to\n\
         its own component, and only the invoked verb's artifact is read,\n\
         compiled and instantiated. Each artifact exports\n\
         `run: func(args: string) -> string`, takes argv joined by NUL, and\n\
         returns `vibe-command-result-v1\\t<exit>` then its output.\n\
         \n\
         A manifest row may name a `.cwasm` from --precompile-component to skip\n\
         Cranelift, but only with --trust-precompiled: loading a precompiled\n\
         image runs native code that no wasm sandbox contains, and a manifest\n\
         is data. The flag is the invoker vouching for what it names, the same\n\
         way naming a .cwasm path directly already is.\n\
         \n\
         ENV:\n\
           MOONRUN_WT_MEMORY_MB      soft cap on linear memory (default 8192)\n\
           VIBE_ASYNC_GET_DELAY_MS   async component path: suspend applied by the\n\
                                     `get-async` host import (default 300)\n\
           VIBE_ASYNC_FUTURES        async component path: comma-separated\n\
                                     name=value:delay_ms list; each entry links a\n\
                                     `name: func() -> future<u32>` host import\n\
                                     resolving to `value` after `delay_ms`\n\
           VIBE_ASYNC_RESPONSES      async component path: comma-separated\n\
                                     iface#func=status:delay_ms:b1|b2 list; each\n\
                                     links `func: async func() -> response`\n\
                                     (record status: s32, body: stream<u8>) in\n\
                                     that interface, resolving after delay_ms\n\
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
    cfg.cache(native_cache::from_environment());
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
// (func_index, offset). `<file>` is the source path from `vibe.dbgfiles` when
// present, else the raw file id. Missing/empty/stripped section => no output
// (exit 0), including a `vibe build` artifact whose mapping was dropped with
// the name section and a compile that recorded zero sites.
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

// `viberun --commands <manifest> <verb> [args...]`
//
// The native bootstrap half of lazy dispatch: read the manifest, resolve the
// verb, and load ONLY that artifact. What the verb's component returns is
// framed (`vibe-command-result-v1`), so a component that returns nonsense
// fails loudly here instead of exiting 0 with partial output.
fn run_commands(args: Vec<String>) -> Result<i32> {
    let mut iter = args.into_iter().peekable();
    // Options are read BEFORE the manifest, because everything from the verb
    // onwards belongs to the command. An unrecognized one is refused rather
    // than taken for the manifest path -- the same discipline `runtime/vibe`'s
    // `build` arm now applies, and for the same reason: a flag quietly read as
    // a path is a wrong answer reported as success.
    let mut precompiled = commands::PrecompiledPolicy::Refuse;
    while let Some(arg) = iter.peek() {
        match arg.as_str() {
            "--trust-precompiled" => {
                precompiled = commands::PrecompiledPolicy::Trust;
                iter.next();
            }
            other if other.starts_with("--") => {
                bail!("--commands: unknown option `{other}` (options come before <manifest>)")
            }
            _ => break,
        }
    }
    let Some(manifest_path) = iter.next() else {
        bail!("--commands: missing <manifest>");
    };
    let Some(verb) = iter.next() else {
        bail!("--commands: missing <verb> (usage: viberun --commands [--trust-precompiled] <manifest> <verb> [args...])");
    };
    let argv: Vec<String> = std::iter::once(verb.clone()).chain(iter).collect();

    let manifest = commands::CommandManifest::read(std::path::Path::new(&manifest_path))?;
    let engine = Engine::new(&command_engine_config())?;
    let mut registry = commands::CommandRegistry::new(engine.clone(), manifest, precompiled);
    let component = registry.load(&verb)?.clone();
    let result = commands::invoke_command(
        &engine,
        &component,
        &argv,
        store_mem_limits(),
        vibe_stat_token,
    )?;
    // Written, not `println!`ed: the payload carries its own trailing newline
    // (or deliberately does not), and a command that prints nothing must
    // print nothing.
    let mut stdout = io::stdout();
    stdout.write_all(result.stdout.as_bytes())?;
    stdout.flush()?;
    Ok(result.exit)
}

fn parse_guest_profile_interval(value: Option<&str>) -> Result<Duration> {
    match value {
        None => Ok(Duration::from_millis(1)),
        Some(value) => {
            let micros = value.parse::<u64>().map_err(|_| {
                format_err!(
                    "VIBE_GUEST_PROFILE_INTERVAL_US must be a positive integer, got `{value}`"
                )
            })?;
            if micros == 0 {
                bail!("VIBE_GUEST_PROFILE_INTERVAL_US must be greater than zero");
            }
            Ok(Duration::from_micros(micros))
        }
    }
}

fn advance_epoch_deadline(mut deadline: Instant, interval: Duration, now: Instant) -> Instant {
    while deadline <= now {
        deadline += interval;
    }
    deadline
}

fn heap_sample_due(deadline: &mut Instant, interval: Duration, now: Instant) -> bool {
    if now < *deadline {
        return false;
    }
    *deadline = advance_epoch_deadline(*deadline, interval, now);
    true
}

#[derive(Debug, Clone)]
struct GuestCpuClock {
    accumulated_guest: Duration,
    guest_started_at: Option<Instant>,
}

impl GuestCpuClock {
    fn new() -> Self {
        Self {
            accumulated_guest: Duration::ZERO,
            // Profiling is armed while the harness still owns control. The
            // first CallingWasm hook starts guest accounting.
            guest_started_at: None,
        }
    }

    fn entering_host(&mut self, now: Instant) {
        if let Some(started_at) = self.guest_started_at.take() {
            self.accumulated_guest += now.duration_since(started_at);
        }
    }

    fn exiting_host(&mut self, now: Instant) {
        self.guest_started_at = Some(now);
    }

    fn sample_due(&mut self, now: Instant, interval: Duration) -> Option<Duration> {
        let running_guest = self
            .guest_started_at
            .map(|started_at| now.duration_since(started_at))
            .unwrap_or(Duration::ZERO);
        let elapsed_guest = self.accumulated_guest + running_guest;
        if elapsed_guest < interval {
            return None;
        }
        self.accumulated_guest = Duration::ZERO;
        if self.guest_started_at.is_some() {
            self.guest_started_at = Some(now);
        }
        Some(elapsed_guest)
    }
}

fn run_epoch_ticker(engine: Engine, stop: Arc<std::sync::atomic::AtomicBool>, interval: Duration) {
    let max_sleep = Duration::from_millis(10);
    let mut deadline = Instant::now() + interval;
    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        let now = Instant::now();
        if now >= deadline {
            engine.increment_epoch();
            deadline = advance_epoch_deadline(deadline, interval, now);
        } else {
            std::thread::sleep((deadline - now).min(max_sleep));
        }
    }
}

fn run(args: Vec<String>) -> Result<i32> {
    if args.is_empty() {
        print_help();
        bail!("missing wasm/cwasm argument");
    }
    let wasm_path = &args[0];
    let guest_profile_path = std::env::var("VIBE_GUEST_PROFILE")
        .ok()
        .filter(|path| !path.is_empty());
    let guest_profile_interval_value = std::env::var("VIBE_GUEST_PROFILE_INTERVAL_US").ok();
    let guest_profile_interval = if guest_profile_path.is_some() {
        parse_guest_profile_interval(guest_profile_interval_value.as_deref())?
    } else {
        Duration::from_millis(1)
    };
    if guest_profile_path.is_some() && wasm_path.ends_with(".cwasm") {
        bail!(
            "guest profiling needs a fresh .wasm; ordinary .cwasm files have no epoch checkpoints"
        );
    }
    let host_fs_scope = prepare_host_fs_scope()?;
    if is_component_file(wasm_path) {
        if guest_profile_path.is_some() {
            bail!("guest profiling for Component Model inputs is not implemented yet");
        }
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
    // Deterministic instruction-count proxy (perf pipeline): VIBE_FUEL=1 turns
    // on wasmtime fuel metering and reports the fuel a run consumed. Fuel is
    // charged per executed instruction from a static cost table, so for a
    // deterministic program the number is byte-stable across machines and
    // runs — unlike wall time it does not see CI runner speed at all. It IS a
    // function of the wasmtime version (cost table) — consumers comparing two
    // readings must pin/compare wasmtime versions (bench_metrics.sh records
    // it in the snapshot). Same `.cwasm` caveat as sampling above: a
    // precompiled image was serialized without fuel instrumentation and the
    // engine config must match, so metering only works on a fresh `.wasm`.
    let fuel_profile = std::env::var("VIBE_FUEL").as_deref() == Ok("1");
    let fuel_profile = if fuel_profile && wasm_path.ends_with(".cwasm") {
        eprintln!("vibe: VIBE_FUEL needs a fresh .wasm (a precompiled .cwasm has no fuel instrumentation); fuel metering disabled");
        false
    } else {
        fuel_profile
    };
    let mut cfg = engine_config();
    if sample_ms.is_some() || guest_profile_path.is_some() {
        cfg.epoch_interruption(true);
    }
    if fuel_profile {
        cfg.consume_fuel(true);
    }
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;

    let limits = store_mem_limits();

    let mut state = HostState::new(prog_args, MemLimiter::new(limits));
    if guest_profile_path.is_some() {
        state.guest_profiler = Some(GuestProfiler::new(
            &engine,
            wasm_path,
            guest_profile_interval,
            [(wasm_path.to_string(), module.clone())],
        )?);
    }
    state.host_fs_scope = host_fs_scope;
    let mut store = Store::new(&engine, state);
    store.limiter(|s| &mut s.mem);
    // Instantiation may execute guest start functions. Keep the default epoch
    // action from interrupting them before the shared sampler callback is armed.
    if sample_ms.is_some() || guest_profile_path.is_some() {
        store.set_epoch_deadline(1_000_000_000);
    }
    if guest_profile_path.is_some() {
        store.data_mut().guest_cpu_clock = Some(GuestCpuClock::new());
        store.call_hook(|mut ctx, kind| {
            let now = Instant::now();
            let mut profiler = ctx.data_mut().guest_profiler.take().unwrap();
            profiler.call_hook(ctx.as_context(), kind);
            ctx.data_mut().guest_profiler = Some(profiler);
            match kind {
                CallHook::CallingHost | CallHook::ReturningFromWasm => ctx
                    .data_mut()
                    .guest_cpu_clock
                    .as_mut()
                    .unwrap()
                    .entering_host(now),
                CallHook::ReturningFromHost | CallHook::CallingWasm => {
                    // Epochs can advance many times while a blocking host import
                    // runs. Rebase the deadline while preserving accumulated
                    // guest CPU time in the shared clock.
                    ctx.set_epoch_deadline(1);
                    ctx.data_mut()
                        .guest_cpu_clock
                        .as_mut()
                        .unwrap()
                        .exiting_host(now);
                }
            }
            Ok(())
        });
    }
    if fuel_profile {
        // Start from the full u64 budget; consumed = u64::MAX - remaining at
        // report time. No program gets anywhere near exhausting this, so
        // metering never turns into an execution limit here.
        store.set_fuel(u64::MAX)?;
    }

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
    withhold_capability_imports(&mut linker, &module)?;

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
    if sample_ms.is_some() || guest_profile_path.is_some() {
        let heap_interval = sample_ms.map(Duration::from_millis);
        let tick_interval = heap_interval
            .into_iter()
            .chain(guest_profile_path.as_ref().map(|_| guest_profile_interval))
            .min()
            .unwrap();
        if sample_ms.is_some() {
            if let Some(g) = instance.get_global(&mut store, "__heap_ptr") {
                {
                    let d = store.data_mut();
                    d.sample_global = Some(g);
                    d.sample_start = Instant::now();
                    d.samples.clear();
                }
            }
        }
        store.set_epoch_deadline(1);
        let mut next_heap_sample = heap_interval.map(|interval| Instant::now() + interval);
        store.epoch_deadline_callback(move |mut ctx| {
            let now = Instant::now();
            if heap_interval
                .zip(next_heap_sample.as_mut())
                .is_some_and(|(interval, deadline)| heap_sample_due(deadline, interval, now))
            {
                if let Some(g) = ctx.data().sample_global {
                    let v = match g.get(&mut ctx) {
                        Val::I32(x) => x as u32 as u64,
                        Val::I64(x) => x as u64,
                        _ => 0,
                    };
                    let t = ctx.data().sample_start.elapsed().as_nanos();
                    ctx.data_mut().samples.push((t, v));
                }
            }
            let guest_delta = ctx
                .data_mut()
                .guest_cpu_clock
                .as_mut()
                .and_then(|clock| clock.sample_due(now, guest_profile_interval));
            if let Some(delta) = guest_delta {
                let mut profiler = ctx.data_mut().guest_profiler.take().unwrap();
                profiler.sample(ctx.as_context(), delta);
                ctx.data_mut().guest_profiler = Some(profiler);
            }
            Ok(wasmtime::UpdateDeadline::Continue(1))
        });
        let eng = engine.clone();
        let stop = stop_flag.clone();
        let interval = tick_interval;
        sampler_thread = Some(std::thread::spawn(move || {
            run_epoch_ticker(eng, stop, interval)
        }));
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

    // Fuel report — after the run, success OR trap, mirroring the memory
    // report model. One machine-readable line on stderr.
    if fuel_profile {
        if let Ok(remaining) = store.get_fuel() {
            let consumed = u64::MAX - remaining;
            eprintln!("vibe::fuel consumed={consumed}");
        }
    }

    // tier 3 heap-sampling timeline.
    if sample_ms.is_some() {
        let samples = std::mem::take(&mut store.data_mut().samples);
        report_samples(&samples);
    }

    // Finish after success or trap so failed guests still leave an actionable
    // profile. The execution result is interpreted only after the file closes.
    if let Some(path) = guest_profile_path {
        let profiler = store.data_mut().guest_profiler.take().unwrap();
        let output =
            fs::File::create(&path).map_err(|e| format_err!("create guest profile {path}: {e}"))?;
        let mut output = io::BufWriter::new(output);
        profiler
            .finish(&mut output)
            .map_err(|e| format_err!("write guest profile {path}: {e}"))?;
        output
            .flush()
            .map_err(|e| format_err!("flush guest profile {path}: {e}"))?;
        eprintln!("vibe::guest-profile path={path}");
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
            // `handle {...} with Exception {...}` can intercept it -- it used to
            // surface here as an ordinary trap message, which `vibe
            // check`/`vibe diagnostics`'s `>/dev/null 2>&1 || true` wrapper
            // silently swallowed into "clean". Write a `.diag` sidecar where
            // the invoker names one so those commands report a real (if
            // unlocated) diagnostic instead.
            //
            // #2988: a stack overflow in the USER's program is not the
            // checker's. Only the compiler gets the type-checking message and
            // its `.diag` sidecar, and the compiler is what the launcher
            // vouches for with VIBE_CRASH_DIAG_OUT (`invoke_cli`, which every
            // compiling verb goes through). #3031: the export set cannot
            // stand in for that signal -- `run()` always enters through
            // `_start`, so a user module that also exports a `cli_main` and
            // no `main` was classified as the compiler and told to split its
            // declarations instead of being told it recursed.
            let running_compiler_sidecar = std::env::var("VIBE_CRASH_DIAG_OUT")
                .ok()
                .filter(|s| !s.is_empty())
                .filter(|_| matches!(e.downcast_ref::<Trap>(), Some(Trap::StackOverflow)));
            if matches!(e.downcast_ref::<Trap>(), Some(Trap::StackOverflow))
                && running_compiler_sidecar.is_none()
            {
                eprintln!(
                    "viberun: stack overflow while running `{wasm_path}`: the program recursed too deeply -- make the recursion a loop, or bound its depth"
                );
                return Ok(1);
            }
            if let Some(sidecar) = running_compiler_sidecar {
                // #2858: the launcher names the sidecar (VIBE_CRASH_DIAG_OUT,
                // read back by runtime/vibe's invoke_cli). Under the verb
                // protocol (`cli check <file>`) the positional args are the
                // verb's own words, so no sidecar is derived from them. A
                // direct adapter-protocol caller (`viberun compiler.wasm <in>
                // <out>`) vouches the same way, naming `<out>.diag`
                // (scripts/vibe_pkg.sh, scripts/parallel_warm_pool.sh):
                // nothing the module exports can say it is the compiler
                // (#3031, Codex on #3039).
                let _ = std::fs::write(
                    sidecar,
                    "expression too deeply nested (stack overflow while type-checking)\n",
                );
                eprintln!("viberun: stack overflow: expression too deeply nested");
                return Ok(1);
            }
            // A guest trap (e.g. an uncaught vibe `throw`/type error surfacing as
            // a Wasm exception) should read as a tool error, not a runner crash —
            // show only the message. Set VIBE_RUNNER_BACKTRACE=1 (or RUST_BACKTRACE)
            // for the full anyhow backtrace when debugging the runner itself.
            // Empty `VIBE_RUNNER_BACKTRACE=` is still "set" for var_os, and
            // `test_vibe_linemap.sh` uses that spelling to mean OFF. Treat
            // empty / "0" as unset so a plain `vibe run` still gets path:line.
            let runner_bt = match std::env::var_os("VIBE_RUNNER_BACKTRACE") {
                Some(v) => !v.is_empty() && v != "0",
                None => false,
            };
            let rust_bt = match std::env::var_os("RUST_BACKTRACE") {
                Some(v) => !v.is_empty() && v != "0",
                None => false,
            };
            if runner_bt || rust_bt {
                eprintln!("viberun: {e:?}");
            } else {
                eprintln!("viberun: {e}");
            }
            // #2825: the not-granted stub's refusal has to REACH the user.
            // wasmtime wraps a host-function error as "error while
            // executing at wasm backtrace: ...", and the branch above is
            // the only one that prints the chain -- so which capability
            // was withheld was visible only to someone who already knew to
            // set a debug variable. Measured: CI, with no RUST_BACKTRACE,
            // showed the wasm backtrace alone, while a dev shell that had
            // it set showed `Caused by: vibe capability withheld:
            // fs_read_file` and the gate passed for that reason and no
            // other (#2252: a test must not inherit the environment that
            // decides its answer). Narrow on purpose: every other guest
            // trap keeps rendering exactly as before.
            if let Some(refusal) = withheld_capability_refusal(&e) {
                eprintln!("viberun: {refusal}");
            }
            // #644 / #2199: a module with a non-empty `vibe.linemap`
            // (production trap provenance, and debug-break) that traps
            // mid-run -- not via an explicit `--break` pause -- still
            // deserves a precise per-frame source line, not just the bare
            // function name wasmtime's default Display already shows via
            // the name section. Independent of VIBE_RUNNER_BACKTRACE: a
            // test that unsets the debug dump still wants path:line.
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
            // linemap or nothing resolves.
            if !store.data().linemap.is_empty() {
                if let Some(bt) = e.downcast_ref::<wasmtime::WasmBacktrace>() {
                    let dbgfiles = Arc::clone(&store.data().dbgfiles);
                    let linemap = Arc::clone(&store.data().linemap);
                    for frame in bt.frames() {
                        let name = frame.func_name().unwrap_or("<unknown>");
                        match frame.func_offset().and_then(|off| {
                            resolve_linemap(&linemap, frame.func_index(), off as u32)
                        }) {
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

struct GuestProfileSampler {
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: std::thread::JoinHandle<()>,
}

fn spawn_epoch_ticker(engine: Engine, interval: Duration) -> GuestProfileSampler {
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread = std::thread::spawn(move || run_epoch_ticker(engine, thread_stop, interval));
    GuestProfileSampler { stop, thread }
}

fn arm_guest_profile(
    store: &mut Store<HostState>,
    module: &Module,
    name: &str,
    interval: Duration,
) -> Result<GuestProfileSampler> {
    store.data_mut().guest_profiler = Some(GuestProfiler::new(
        store.engine(),
        name,
        interval,
        [(name.to_string(), module.clone())],
    )?);
    store.data_mut().guest_cpu_clock = Some(GuestCpuClock::new());
    store.call_hook(|mut ctx, kind| {
        let now = Instant::now();
        let mut profiler = ctx.data_mut().guest_profiler.take().unwrap();
        profiler.call_hook(ctx.as_context(), kind);
        ctx.data_mut().guest_profiler = Some(profiler);
        match kind {
            CallHook::CallingHost | CallHook::ReturningFromWasm => ctx
                .data_mut()
                .guest_cpu_clock
                .as_mut()
                .unwrap()
                .entering_host(now),
            CallHook::ReturningFromHost | CallHook::CallingWasm => {
                ctx.set_epoch_deadline(1);
                ctx.data_mut()
                    .guest_cpu_clock
                    .as_mut()
                    .unwrap()
                    .exiting_host(now);
            }
        }
        Ok(())
    });
    store.set_epoch_deadline(1);
    store.epoch_deadline_callback(move |mut ctx| {
        let now = Instant::now();
        let delta = ctx
            .data_mut()
            .guest_cpu_clock
            .as_mut()
            .and_then(|clock| clock.sample_due(now, interval));
        if let Some(delta) = delta {
            let mut profiler = ctx.data_mut().guest_profiler.take().unwrap();
            profiler.sample(ctx.as_context(), delta);
            ctx.data_mut().guest_profiler = Some(profiler);
        }
        Ok(wasmtime::UpdateDeadline::Continue(1))
    });
    Ok(spawn_epoch_ticker(store.engine().clone(), interval))
}

fn finish_guest_profile(
    store: &mut Store<HostState>,
    sampler: GuestProfileSampler,
    path: &std::path::Path,
) -> Result<()> {
    sampler
        .stop
        .store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = sampler.thread.join();
    let profiler = store.data_mut().guest_profiler.take().unwrap();
    let output = fs::File::create(path)
        .map_err(|e| format_err!("create guest profile {}: {e}", path.display()))?;
    let mut output = io::BufWriter::new(output);
    profiler.finish(&mut output)?;
    output
        .flush()
        .map_err(|e| format_err!("flush guest profile {}: {e}", path.display()))?;
    eprintln!("vibe::guest-profile path={}", path.display());
    Ok(())
}

fn profile_filename(label: &str) -> String {
    let sanitized: String = label
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        // Leave ample room below common 255-byte component limits for the
        // separator, stable hash, and extension. Sanitization emits ASCII, so
        // this character bound is also a byte bound.
        .take(200)
        .collect();
    // Sanitizing is not injective (`a/b` and `a?b` both become `a_b`). Add a
    // deterministic FNV-1a suffix so distinct legal labels cannot overwrite
    // each other's profile within one benchmark invocation.
    let hash = label
        .as_bytes()
        .iter()
        .fold(0xcbf29ce484222325u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
        });
    format!("{sanitized}-{hash:016x}.json")
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
    let profile_dir = std::env::var("VIBE_BENCH_GUEST_PROFILE_DIR")
        .ok()
        .filter(|path| !path.is_empty())
        .map(PathBuf::from);
    let profile_interval_value = std::env::var("VIBE_GUEST_PROFILE_INTERVAL_US").ok();
    let profile_interval = if profile_dir.is_some() {
        parse_guest_profile_interval(profile_interval_value.as_deref())?
    } else {
        Duration::from_millis(1)
    };

    if profile_dir.is_some() && wasm_path.ends_with(".cwasm") {
        bail!("bench guest profiling needs a fresh .wasm; ordinary .cwasm files have no epoch checkpoints");
    }
    let mut cfg = engine_config();
    if profile_dir.is_some() {
        cfg.epoch_interruption(true);
    }
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;
    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;
    withhold_capability_imports(&mut linker, &module)?;

    // #747: one Store+Instance PER BENCH BLOCK. The linear backend never frees,
    // so on a shared instance an earlier block's bump-heap growth (e.g. an
    // O(N²) concat bench leaving a ~200MB high-water mark) inflated the blocks
    // after it 8-10×. A fresh instance gives every block the same pristine
    // heap; per-block warmup below still pays lazy module init before timing.
    let make_instance = |linker: &Linker<HostState>| -> Result<(Store<HostState>, Instance)> {
        let mut state = HostState::new(
            vec!["viberun".to_string()],
            MemLimiter::new(store_mem_limits()),
        );
        state.capture_stdout = true; // suppress per-iteration program output
        let mut store = Store::new(&engine, state);
        store.limiter(|s| &mut s.mem);
        // Epoch instrumentation is compiled in for profiled benches, but the
        // profiler is intentionally armed only after warmup. Keep warmup's
        // deadline out of reach so the default epoch action cannot trap it.
        if profile_dir.is_some() {
            store.set_epoch_deadline(1_000_000_000);
        }
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
        module: &Module,
        block_label: &str,
        warmup: u64,
        iters: u64,
        profile_path: Option<&std::path::Path>,
        profile_interval: Duration,
        mut invoke: impl FnMut(&mut Store<HostState>, &str) -> Result<()>,
    ) -> Result<()> {
        for _ in 0..warmup {
            invoke(store, "warmup")?;
        }
        let profiler = profile_path
            .map(|_| arm_guest_profile(store, module, block_label, profile_interval))
            .transpose()?;
        let heap_before = read_heap_ptr(instance, store);
        let mut samples: Vec<u128> = Vec::with_capacity(iters as usize);
        let measurement_result: Result<()> = (|| {
            for _ in 0..iters {
                let t0 = Instant::now();
                invoke(store, "measurement")?;
                samples.push(t0.elapsed().as_nanos());
            }
            Ok(())
        })();
        let heap_after = read_heap_ptr(instance, store);
        let finish_result = if let (Some(sampler), Some(path)) = (profiler, profile_path) {
            finish_guest_profile(store, sampler, path)
        } else {
            Ok(())
        };
        // Always stop/join/flush the profiler before propagating an invocation
        // failure. A trapping measurement is often the most useful profile.
        measurement_result?;
        finish_result?;

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
                &module,
                &block_label,
                warmup,
                iters,
                profile_dir
                    .as_ref()
                    .map(|dir| dir.join(profile_filename(&block_label)))
                    .as_deref(),
                profile_interval,
                |store, phase| {
                    store.data_mut().captured_stdout.clear();
                    match func.call(&mut *store, 0) {
                        Ok(_) => Ok(()),
                        Err(e) => match e.downcast_ref::<ExitTrap>() {
                            Some(ExitTrap(0)) => Ok(()),
                            Some(ExitTrap(code)) => {
                                bail!("bench `{block_label}`: exit({code}) during {phase}")
                            }
                            None => match withheld_capability_refusal(&e) {
                                Some(refusal) => bail!(
                                    "bench `{block_label}`: trap during {phase}: {e} ({refusal})"
                                ),
                                None => bail!("bench `{block_label}`: trap during {phase}: {e}"),
                            },
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
        &module,
        &label,
        warmup,
        iters,
        profile_dir
            .as_ref()
            .map(|dir| dir.join(profile_filename(&label)))
            .as_deref(),
        profile_interval,
        |store, phase| {
            store.data_mut().captured_stdout.clear();
            match start.call(&mut *store, ()) {
                Ok(()) => Ok(()),
                // A clean `proc_exit(0)` is fine; any other trap aborts the bench.
                Err(e) => match e.downcast_ref::<ExitTrap>() {
                    Some(ExitTrap(0)) => Ok(()),
                    Some(ExitTrap(code)) => bail!("bench `{label}`: exit({code}) during {phase}"),
                    None => match withheld_capability_refusal(&e) {
                        Some(refusal) => {
                            bail!("bench `{label}`: trap during {phase}: {e} ({refusal})")
                        }
                        None => bail!("bench `{label}`: trap during {phase}: {e}"),
                    },
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
    withhold_capability_imports(&mut linker, &module)?;

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

mod component_runtime;
mod diagnostics;
mod host_imports;

use component_runtime::*;
use diagnostics::*;
use host_imports::*;

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
    fn profile_filenames_disambiguate_sanitized_label_collisions() {
        let slash = profile_filename("bench::a/b");
        let question = profile_filename("bench::a?b");
        assert_ne!(slash, question);
        assert_eq!(slash, profile_filename("bench::a/b"));
        assert!(slash.ends_with(".json"));
    }

    #[test]
    fn profile_filenames_fit_common_component_limits() {
        let filename = profile_filename(&"a".repeat(1_000));
        assert!(
            filename.len() <= 255,
            "filename is {} bytes",
            filename.len()
        );
        assert!(filename.ends_with(".json"));
    }

    #[test]
    fn guest_profile_interval_rejects_invalid_explicit_values() {
        assert_eq!(
            parse_guest_profile_interval(None).unwrap(),
            Duration::from_millis(1)
        );
        assert_eq!(
            parse_guest_profile_interval(Some("250")).unwrap(),
            Duration::from_micros(250)
        );
        for invalid in ["0", "-1", "100O", ""] {
            assert!(
                parse_guest_profile_interval(Some(invalid)).is_err(),
                "accepted {invalid:?}"
            );
        }
    }

    #[test]
    fn epoch_deadline_preserves_sub_chunk_remainder() {
        let start = Instant::now();
        let interval = Duration::from_micros(10_001);
        let next = advance_epoch_deadline(
            start + interval,
            interval,
            start + Duration::from_millis(20),
        );
        assert_eq!(next.duration_since(start), Duration::from_micros(20_002));
    }

    #[test]
    fn heap_sample_deadline_preserves_phase_after_callback_jitter() {
        let start = Instant::now();
        let interval = Duration::from_millis(1);
        let mut deadline = start + interval;

        assert!(heap_sample_due(
            &mut deadline,
            interval,
            start + Duration::from_micros(1_100),
        ));
        assert_eq!(deadline, start + Duration::from_millis(2));
        assert!(heap_sample_due(
            &mut deadline,
            interval,
            start + Duration::from_millis(2),
        ));
        assert_eq!(deadline, start + Duration::from_millis(3));
    }

    #[test]
    fn guest_sample_clock_excludes_time_spent_in_host_calls() {
        let start = Instant::now();
        let interval = Duration::from_millis(1);
        let mut clock = GuestCpuClock::new();
        clock.exiting_host(start);
        clock.entering_host(start + Duration::from_micros(500));
        clock.exiting_host(start + Duration::from_secs(10));
        assert_eq!(
            clock.sample_due(
                start + Duration::from_secs(10) + Duration::from_micros(500),
                interval,
            ),
            Some(interval)
        );
    }

    #[test]
    fn guest_sample_clock_accumulates_short_bursts_across_host_calls() {
        let start = Instant::now();
        let interval = Duration::from_millis(1);
        let mut clock = GuestCpuClock::new();
        clock.exiting_host(start);
        clock.entering_host(start + Duration::from_micros(400));
        clock.exiting_host(start + Duration::from_secs(1));
        clock.entering_host(start + Duration::from_secs(1) + Duration::from_micros(400));
        clock.exiting_host(start + Duration::from_secs(2));
        assert_eq!(
            clock.sample_due(
                start + Duration::from_secs(2) + Duration::from_micros(300),
                interval,
            ),
            Some(Duration::from_micros(1_100))
        );
    }

    #[test]
    fn guest_sample_clock_excludes_setup_and_between_invocation_harness_time() {
        let start = Instant::now();
        let interval = Duration::from_millis(1);
        let mut clock = GuestCpuClock::new();
        assert_eq!(
            clock.sample_due(start + Duration::from_secs(10), interval),
            None
        );
        clock.exiting_host(start + Duration::from_secs(10));
        clock.entering_host(start + Duration::from_secs(10) + Duration::from_micros(400));
        clock.exiting_host(start + Duration::from_secs(20));
        assert_eq!(
            clock.sample_due(
                start + Duration::from_secs(20) + Duration::from_micros(600),
                interval,
            ),
            Some(interval)
        );
    }

    #[test]
    fn epoch_ticker_stops_promptly_for_a_large_profile_interval() {
        let engine = Engine::default();
        let sampler = spawn_epoch_ticker(engine, Duration::from_secs(60));
        let started = Instant::now();
        sampler
            .stop
            .store(true, std::sync::atomic::Ordering::Relaxed);
        sampler.thread.join().unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn publish_immutable_text_is_no_replace_and_byte_exact() {
        let dir = std::env::temp_dir().join(format!(
            "viberun-publish-immutable-test-{}-{}",
            std::process::id(),
            VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        let target = dir.join("published.txt");
        let target_text = target.to_string_lossy().into_owned();

        assert!(vibe_publish_immutable_text(
            &target_text,
            "hello ☃".as_bytes()
        ));
        assert!(vibe_publish_immutable_text(
            &target_text,
            "hello ☃".as_bytes()
        ));
        assert!(!vibe_publish_immutable_text(&target_text, b"different"));
        assert_eq!(fs::read(&target).unwrap(), "hello ☃".as_bytes());

        let equal_target = dir.join("equal.txt").to_string_lossy().into_owned();
        let equal_barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let equal_threads: Vec<_> = (0..8)
            .map(|_| {
                let path = equal_target.clone();
                let barrier = equal_barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    vibe_publish_immutable_text(&path, "same 日本語\n".as_bytes())
                })
            })
            .collect();
        assert!(equal_threads
            .into_iter()
            .all(|thread| thread.join().unwrap()));
        assert_eq!(fs::read(&equal_target).unwrap(), "same 日本語\n".as_bytes());

        let unequal_target = dir.join("unequal.txt").to_string_lossy().into_owned();
        let unequal_barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let unequal_threads: Vec<_> = [b"alpha\n".as_slice(), b"beta\n".as_slice()]
            .into_iter()
            .map(|data| {
                let path = unequal_target.clone();
                let barrier = unequal_barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    vibe_publish_immutable_text(&path, data)
                })
            })
            .collect();
        assert_eq!(
            unequal_threads
                .into_iter()
                .map(|thread| thread.join().unwrap())
                .filter(|won| *won)
                .count(),
            1
        );
        let unequal_bytes = fs::read(&unequal_target).unwrap();
        assert!(unequal_bytes == b"alpha\n" || unequal_bytes == b"beta\n");

        assert!(!vibe_publish_immutable_text(
            &dir.to_string_lossy(),
            b"not-a-file"
        ));
        #[cfg(unix)]
        {
            let symlink = dir.join("symlink.txt");
            std::os::unix::fs::symlink(&target, &symlink).unwrap();
            assert!(!vibe_publish_immutable_text(
                &symlink.to_string_lossy(),
                "hello ☃".as_bytes()
            ));
        }
        fs::remove_dir_all(dir).unwrap();
    }

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
    // FIRST, above the `--help` scan below: everything after the verb belongs
    // to the command, and that scan is an `any()` over the whole argv. Left
    // later, `viberun --commands m.tsv build --help` would print THIS help and
    // the command would never run -- a flag the guest owns, answered by the
    // host.
    if args.first().map(|s| s.as_str()) == Some("--commands") {
        let rest: Vec<String> = args.iter().skip(1).cloned().collect();
        match run_commands(rest) {
            Ok(code) => std::process::exit(code),
            Err(e) => {
                eprintln!("viberun: {e}");
                std::process::exit(1);
            }
        }
    }
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
    if args.first().map(|s| s.as_str()) == Some("--precompile-component") {
        let mut iter = args.iter().skip(1);
        let input = match iter.next() {
            Some(s) => s.clone(),
            None => {
                eprintln!("--precompile-component: missing <input.component.wasm>");
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
                    eprintln!("--precompile-component: unknown arg `{other}`");
                    std::process::exit(2);
                }
            }
        }
        match Engine::new(&command_engine_config())
            .and_then(|engine| commands::precompile_component(&engine, &input, output.as_deref()))
        {
            Ok(path) => {
                eprintln!("viberun: precompiled component -> {}", path.display());
                return;
            }
            Err(e) => {
                eprintln!("viberun: precompile-component failed: {e:?}");
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
