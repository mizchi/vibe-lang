//! Diagnostics.

use super::*;

// Capture frame names from the wasm backtrace, innermost first. Frame 0 is the
// `vibe::dbg_break` import call site (the entering user function). Unnamed
// frames are skipped. Returns the named frame list (e.g. ["helper", "main"]).
pub(super) fn dbg_break_frames(caller: &Caller<'_, HostState>) -> Vec<String> {
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
pub(super) struct BreakAbort;

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
pub(super) fn dbg_read_args(caller: &mut Caller<'_, HostState>, entering: &str) -> Option<String> {
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
pub(super) fn caller_heap_ptr(caller: &mut Caller<'_, HostState>) -> Option<u64> {
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
pub(super) fn alloc_account(caller: &mut Caller<'_, HostState>) {
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

pub(super) fn vibe_dbg_break(mut caller: Caller<'_, HostState>) -> Result<()> {
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
pub(super) fn dbg_apply_command(caller: &mut Caller<'_, HostState>, depth: usize) -> Result<()> {
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
pub(super) fn vibe_dbg_line(
    mut caller: Caller<'_, HostState>,
    file_id: i32,
    line: i32,
) -> Result<()> {
    // tier 4: take an allocation sample at this statement boundary too (see
    // alloc_account) so post-call allocation in a caller is charged to the caller.
    alloc_account(&mut caller);
    let line_break_set = Arc::clone(&caller.data().line_break_set);
    let step_mode = caller.data().step_mode;
    if line_break_set.is_empty() && step_mode == StepMode::Continue {
        return Ok(());
    }
    let cur: u32 = if line < 0 { return Ok(()) } else { line as u32 };
    // Resolve this statement's source file from the dbgfiles table, then take
    // its BASENAME: the table carries the path the compiler opened (#2199, so a
    // trap prints something editable), while `parse_line_break_spec` reduces a
    // `--break <file>:<line>` spec to a basename. Both sides of the comparison
    // are basenames, so a spec matches exactly the files it matched before the
    // table held paths (bare-line specs match any file).
    let dbgfiles = Arc::clone(&caller.data().dbgfiles);
    let cur_file: Option<&str> = if file_id >= 0 {
        dbgfiles
            .get(file_id as usize)
            .map(|s| path_basename(s.as_str()))
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

// #2825 step 1 -- the not-granted stub
// (docs/internal/design/capability-host-contract.md).
//
// ADR-0088's 2026-09-15 amendment makes `perform?` an instantiate-time branch,
// so an emitted module declares the ungranted arm's host import whether or not
// the build granted it. A host then has to be able to WITHHOLD a capability:
// link something of the right type so the module still instantiates, and trap
// if the program ever calls it.
//
// This runner could not express that either, but for the opposite reason to
// `scripts/wasm_vibe_host_runner.js`. There, an unimplemented `vibe.*` field
// answers `0` and the capability lies. Here, an import `register_imports` does
// not define makes the whole module fail to instantiate before user code runs
// -- which is the right answer for a REQUIRED capability and the wrong one for
// an optional capability whose `NotGranted` arm is exactly what the program
// asked for.
//
// The stub's type comes from the module's own import section rather than from
// a table here, so it matches by construction and no list can drift from the
// 59 fields the emitter can produce. A name in `VIBE_HOST_WITHHOLD` that this
// module does not import is a no-op: withholding a capability a program never
// asked for is not an error.
/// One spelling, shared by the stub that produces the refusal and the callers
/// below that have to find it again in an error chain.
pub(super) const CAPABILITY_WITHHELD_PREFIX: &str = "vibe capability withheld: ";

/// The withheld-capability refusal carried somewhere in this error's chain, if
/// there is one.
///
/// Every caller needs it for the same reason: wasmtime wraps a host function's
/// error as "error while executing at wasm backtrace: ...", and Display shows
/// only that outermost message. So a path that renders with `{e}` -- or worse,
/// `bail!`s a NEW error whose message embeds `{e}` and whose chain is
/// therefore gone -- loses which capability was withheld, and the diagnostic
/// stops naming the edit that fixes it (Codex on #2844, P2: the bench path did
/// exactly that, twice).
pub(super) fn withheld_capability_refusal(error: &wasmtime::Error) -> Option<String> {
    error
        .chain()
        .map(|cause| cause.to_string())
        .find(|text| text.starts_with(CAPABILITY_WITHHELD_PREFIX))
}

pub(super) fn withheld_capabilities() -> std::collections::BTreeSet<String> {
    std::env::var("VIBE_HOST_WITHHOLD")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(str::to_string)
        .collect()
}

pub(super) fn withhold_capability_imports(
    linker: &mut Linker<HostState>,
    module: &Module,
) -> Result<usize> {
    let withheld = withheld_capabilities();
    if withheld.is_empty() {
        return Ok(0);
    }
    let mut stubbed = 0;
    // `register_imports` has already defined the real implementation, so the
    // stub REPLACES one; shadowing is turned back off immediately so nothing
    // else in this process gains the ability to redefine an import silently.
    linker.allow_shadowing(true);
    for import in module.imports() {
        if import.module() != "vibe" || !withheld.contains(import.name()) {
            continue;
        }
        let ExternType::Func(ty) = import.ty() else {
            continue;
        };
        let name = import.name().to_string();
        // The message is built here and MOVED into the closure; `name` stays
        // put so it can still be borrowed for the import's own field name.
        let refusal = format!("{CAPABILITY_WITHHELD_PREFIX}{name}");
        linker.func_new("vibe", &name, ty, move |_caller, _args, _results| {
            bail!("{refusal}")
        })?;
        stubbed += 1;
    }
    linker.allow_shadowing(false);
    Ok(stubbed)
}

pub(super) fn register_imports(linker: &mut Linker<HostState>) -> Result<()> {
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
pub(super) fn read_leb_u32(bytes: &[u8], pos: &mut usize) -> Option<u32> {
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
pub(super) fn find_custom_section(wasm: &[u8], want_name: &str) -> Option<Vec<u8>> {
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

pub(super) fn read_u32_le(bytes: &[u8], off: usize) -> Option<u32> {
    let b = bytes.get(off..off + 4)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

/// The last path component, which is what a `vibe.dbgfiles` entry and a
/// `--break <file>:<line>` spec are compared as. The table itself carries the
/// compiler's own path so a trap can print a location the reader can open;
/// breakpoint matching predates that and stays basename-based.
///
/// `Path::file_name`, the same call `parse_line_break_spec` reduces the spec
/// with -- one rule, so the two sides cannot disagree about what a component
/// is.
pub(super) fn path_basename(p: &str) -> &str {
    std::path::Path::new(p)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(p)
}

// span-arc step5: parse a single VIBE_BREAK entry as a LINE breakpoint spec.
// Accepts `<file>:<line>` (e.g. `prog.vibe:5`) -> (Some("prog.vibe"), 5), or a
// bare all-digit `<line>` (e.g. `5`) -> (None, 5). Returns None when the spec is
// not a line spec (a function name), leaving it for the function-name break_set.
// The file part keeps its basename only so a spec with a directory prefix still
// matches VIBE_BREAK_FILE (which is a basename).
pub(super) fn parse_line_break_spec(spec: &str) -> Option<(Option<String>, u32)> {
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
pub(super) fn parse_funcmap(text: &str) -> std::collections::HashMap<String, u32> {
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
// (source paths, one per line in file-id order) into a Vec indexed by file id.
// `vibe::dbg_line(file_id, line)` uses the id to look up the file; breakpoint
// matching then compares basenames (`path_basename`), a trap prints the path.
pub(super) fn parse_dbgfiles(section: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(section)
        .split('\n')
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect()
}

// #644 / #2199: parse the `vibe.linemap` custom section into a (wasm func
// index -> sorted (code offset, file id, line) list) map. Compact encoding:
// the 4-byte marker `VLM1`, then a run of four unsigned LEBs per unique
// (func, offset) —
// (func_delta, offset_delta, file_id, line). func_delta is relative to the
// previous func (absolute for the first record); when it is zero, offset
// is relative to the previous offset, otherwise absolute. A trailing
// partial record is ignored rather than panicking. Entries are grouped by
// func_index and sorted by offset so `resolve_linemap` can binary-search.
// Absent / stripped section => empty map => no fabricated location.
//
// The marker is REQUIRED. #644's table under this same name held 16-byte
// little-endian records, and those bytes decode as LEB quadruples without
// erroring — a module from any compiler older than #2199 (the committed
// seed among them) would otherwise annotate traps with fabricated
// functions, offsets, files and lines. An unmarked table is one this
// reader cannot read, and reads as empty.
pub(super) const LINEMAP_MAGIC: &[u8; 4] = b"VLM1";

pub(super) fn parse_linemap(
    section: &[u8],
) -> std::collections::HashMap<u32, Vec<(u32, u32, u32)>> {
    let mut by_func: std::collections::HashMap<u32, Vec<(u32, u32, u32)>> =
        std::collections::HashMap::new();
    if section.len() < LINEMAP_MAGIC.len() || &section[..LINEMAP_MAGIC.len()] != LINEMAP_MAGIC {
        return by_func;
    }
    let mut pos = LINEMAP_MAGIC.len();
    let mut func: u32 = 0;
    let mut offset: u32 = 0;
    let mut have = false;
    while pos < section.len() {
        let fd = match read_leb_u32(section, &mut pos) {
            Some(v) => v,
            None => break,
        };
        let od = match read_leb_u32(section, &mut pos) {
            Some(v) => v,
            None => break,
        };
        let file_id = match read_leb_u32(section, &mut pos) {
            Some(v) => v,
            None => break,
        };
        let line = match read_leb_u32(section, &mut pos) {
            Some(v) => v,
            None => break,
        };
        if have && fd == 0 {
            offset = offset.saturating_add(od);
        } else {
            func = if have { func.saturating_add(fd) } else { fd };
            offset = od;
            have = true;
        }
        by_func
            .entry(func)
            .or_default()
            .push((offset, file_id, line));
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
pub(super) fn resolve_linemap(
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

pub(super) fn parse_dbgnames(section: &[u8]) -> std::collections::HashMap<String, Vec<String>> {
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
pub(super) fn dump_trace(
    wasm_path: &str,
    instance: &wasmtime::Instance,
    store: &mut Store<HostState>,
) {
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
