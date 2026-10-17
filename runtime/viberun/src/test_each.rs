//! `viberun --test-each <wasm>`: run every `test` block on its own.
//!
//! A `__no_entry__` build's `_start` runs every block in sequence in ONE
//! instance, so the first failure hides every block after it and the verdict
//! is per file. Mutation testing needs it per block: which tests kill which
//! mutant is the whole output. Each `__test_<name>` export gets a fresh Store
//! and Instance (the `--bench` shape, #747), so one block's heap or global
//! state cannot decide another's verdict.
//!
//! A mutant can turn a terminating loop into an infinite one, so every block
//! runs under a wall-clock deadline (`VIBE_TEST_TIMEOUT_MS`, default 10000)
//! enforced with epoch interruption, and -- for a block stuck inside a
//! blocking host import, which an epoch cannot interrupt -- by a watchdog
//! that reports it and ends the run with a row for every block.
//!
//! Output: first `vibe::tests<TAB><count>`, the number of blocks the module
//! declares (whatever VIBE_TEST_EACH_FROM says), then one line per block on
//! stdout, tab separated:
//!   vibe::test<TAB>ok<TAB><name>
//!   vibe::test<TAB>fail<TAB><name><TAB><reason>
//!   vibe::test<TAB>timeout<TAB><name>
//!   vibe::test<TAB>skip<TAB><name>
//! `skip` means NOT RUN: the watchdog ended the process at an earlier block.
//! It is not a verdict about the block; re-run from it with
//! `VIBE_TEST_EACH_FROM=<index of its block>` (rows come in block order).
//! The blocks are the names in the module's `vibe_tests` custom section, which
//! the compiler writes for every test build: a program may export its own
//! `__test_helper`, so the prefix is not authoritative. A module without the
//! section (an older compiler) falls back to every `__test_*` export.
//!
//! `<name>` and `<reason>` escape `\` `\t` `\n` `\r` `\0` as two-character
//! sequences so every row splits into the same fields. The block's own stdout
//! is discarded on every path, unbuffered. Exit status: 0 when every block passed, 1 when
//! any did not, 2 on a usage or load error.

use super::*;

fn escape_field(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\0' => out.push_str("\\0"),
            _ => out.push(c),
        }
    }
    out
}

/// The entries of the `vibe_tests` custom section as (export name, callable),
/// or None when the module has none. `callable` is false when another
/// function shares the export name, so the export may not be the block. A
/// plain section walk: magic + version, then `id, size, payload` records; a
/// custom section's payload starts with its name.
fn declared_tests(bytes: &[u8]) -> Option<Vec<(String, bool)>> {
    fn leb(bytes: &[u8], pos: &mut usize) -> Option<usize> {
        let mut value: usize = 0;
        let mut shift = 0;
        loop {
            let b = *bytes.get(*pos)?;
            *pos += 1;
            value |= ((b & 0x7f) as usize) << shift;
            if b & 0x80 == 0 {
                return Some(value);
            }
            shift += 7;
            if shift > 35 {
                return None;
            }
        }
    }
    if bytes.len() < 8 || &bytes[0..4] != b"\0asm" {
        return None;
    }
    let mut pos = 8;
    while pos < bytes.len() {
        let id = bytes[pos];
        pos += 1;
        let size = leb(bytes, &mut pos)?;
        let end = pos.checked_add(size)?;
        if end > bytes.len() {
            return None;
        }
        if id == 0 {
            let mut p = pos;
            let name_len = leb(bytes, &mut p)?;
            let name_end = p.checked_add(name_len)?;
            if name_end <= end && &bytes[p..name_end] == b"vibe_tests" {
                // Each entry: a LEB128 byte length, the name's bytes, a flag.
                let mut names = Vec::new();
                let mut q = name_end;
                while q < end {
                    let len = leb(bytes, &mut q)?;
                    let stop = q.checked_add(len)?;
                    if stop >= end {
                        return None;
                    }
                    let name = String::from_utf8_lossy(&bytes[q..stop]).into_owned();
                    names.push((name, bytes[stop] == 1));
                    q = stop + 1;
                }
                return Some(names);
            }
        }
        pos = end;
    }
    None
}

/// The first line of an error, which is the trap message; the backtrace
/// that follows is noise in a one-line row.
fn first_line(e: &wasmtime::Error) -> String {
    // The outermost context is wasmtime's "error while executing at wasm
    // backtrace:" banner; the cause underneath is the trap that says why.
    let text = format!("{}", e.root_cause());
    text.lines().next().unwrap_or("").to_string()
}

pub(super) fn test_each(args: Vec<String>) -> Result<i32> {
    if args.len() != 1 {
        bail!("--test-each: expected exactly one <wasm> argument");
    }
    let wasm_path = &args[0];
    if wasm_path.ends_with(".cwasm") {
        bail!(
            "--test-each needs a fresh .wasm; a precompiled .cwasm has no epoch checkpoints for the deadline"
        );
    }
    let timeout_ms: u64 = std::env::var("VIBE_TEST_TIMEOUT_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|n| *n > 0)
        .unwrap_or(10_000);
    let mut cfg = engine_config();
    cfg.epoch_interruption(true);
    let engine = Engine::new(&cfg)?;
    let module = load_module(&engine, wasm_path)?;
    let mut linker = Linker::new(&engine);
    register_imports(&mut linker)?;
    withhold_capability_imports(&mut linker, &module)?;

    let declared: Vec<(String, bool)> = match declared_tests(&std::fs::read(wasm_path)?) {
        Some(declared) => declared,
        None => module
            .exports()
            .filter(|e| e.name().starts_with("__test_"))
            .map(|e| (e.name().to_string(), true))
            .collect(),
    };
    let callable: Vec<bool> = declared.iter().map(|(_, c)| *c).collect();
    let names: Vec<String> = declared.into_iter().map(|(n, _)| n).collect();

    // One tick per millisecond; a block's deadline is `timeout_ms` ticks
    // after its own start.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ticker = {
        let engine = engine.clone();
        let stop = stop.clone();
        std::thread::spawn(move || run_epoch_ticker(engine, stop, Duration::from_millis(1)))
    };

    // The epoch deadline interrupts guest code, not a host import: a mutant
    // that blocks in one (a `sleep` a flipped branch now reaches, a read)
    // would hold the run for as long as the import blocks. A watchdog thread
    // owns that case. Every row is written under `watch`, so when a block
    // overruns its deadline by WATCHDOG_GRACE the watchdog reports it as a
    // timeout, reports every block after it as `skip` (not run), and ends the
    // process -- one row per block either way, and the caller resumes at the
    // first `skip` (VIBE_TEST_EACH_FROM).
    const WATCHDOG_GRACE: Duration = Duration::from_millis(2_000);
    let names = Arc::new(names);
    let watch: Arc<Mutex<Option<(usize, Instant)>>> = Arc::new(Mutex::new(None));
    let watchdog = {
        let names = names.clone();
        let watch = watch.clone();
        let stop = stop.clone();
        let limit = Duration::from_millis(timeout_ms) + WATCHDOG_GRACE;
        std::thread::spawn(move || {
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(20));
                let running = watch.lock().unwrap();
                if let Some((i, started)) = *running {
                    if started.elapsed() > limit {
                        let mut out = io::stdout().lock();
                        let row = |n: &String| escape_field(n.strip_prefix("__test_").unwrap_or(n));
                        let _ = writeln!(out, "vibe::test\ttimeout\t{}", row(&names[i]));
                        for rest in &names[i + 1..] {
                            let _ = writeln!(out, "vibe::test\tskip\t{}", row(rest));
                        }
                        let _ = out.flush();
                        std::process::exit(1);
                    }
                }
            }
        })
    };
    let emit = |line: String| -> Result<()> {
        let mut running = watch.lock().unwrap();
        *running = None;
        let mut out = io::stdout().lock();
        writeln!(out, "{line}")?;
        out.flush()?;
        Ok(())
    };

    // VIBE_TEST_EACH_FROM resumes after a watchdog stop: the caller re-runs
    // from the first `skip` row, so every block still gets its own verdict.
    let from: usize = std::env::var("VIBE_TEST_EACH_FROM")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    // The block count comes first, so a caller can tell a complete report
    // from a runner that died part way (a host panic, an OOM kill).
    emit(format!("vibe::tests\t{}", names.len()))?;
    let mut all_ok = true;
    for (index, full) in names.iter().enumerate().skip(from) {
        let name = escape_field(full.strip_prefix("__test_").unwrap_or(full));
        // Two blocks with one title share one export, so only one of them is
        // callable: running it twice would report the other block's verdict
        // without ever running it. Each copy fails instead, saying why.
        if names.iter().filter(|n| *n == full).count() > 1 {
            all_ok = false;
            emit(format!(
                "vibe::test\tfail\t{name}\tduplicate test title: rename one of the blocks, only one of them can be run on its own"
            ))?;
            continue;
        }
        // Another function shares this block's export name (a program
        // `fn {full}`): the export may be that function, so calling it would
        // report its verdict as this block's.
        if !callable[index] {
            all_ok = false;
            emit(format!(
                "vibe::test\tfail\t{name}\ta function named `{}` shares this test's export name: rename the function or the test",
                escape_field(full)
            ))?;
            continue;
        }
        let mut state = HostState::new(
            vec!["viberun".to_string()],
            MemLimiter::new(store_mem_limits()),
        );
        state.discard_stdout = true;
        let mut store = Store::new(&engine, state);
        store.limiter(|s| &mut s.mem);
        store.set_epoch_deadline(timeout_ms);
        *watch.lock().unwrap() = Some((index, Instant::now()));
        let verdict: std::result::Result<(), (bool, String)> = (|| {
            let instance = linker
                .instantiate(&mut store, &module)
                .map_err(|e| (false, first_line(&e)))?;
            let func: TypedFunc<i64, i64> = instance
                .get_typed_func(&mut store, full)
                .map_err(|e| (false, first_line(&e)))?;
            match func.call(&mut store, 0) {
                Ok(_) => Ok(()),
                Err(e) => match e.downcast_ref::<ExitTrap>() {
                    Some(ExitTrap(0)) => Ok(()),
                    Some(ExitTrap(code)) => Err((false, format!("exit({code})"))),
                    None => {
                        if e.downcast_ref::<Trap>() == Some(&Trap::Interrupt) {
                            Err((true, String::new()))
                        } else {
                            match withheld_capability_refusal(&e) {
                                Some(refusal) => {
                                    Err((false, format!("{} ({refusal})", first_line(&e))))
                                }
                                None => Err((false, first_line(&e))),
                            }
                        }
                    }
                },
            }
        })();
        match verdict {
            Ok(()) => emit(format!("vibe::test\tok\t{name}"))?,
            Err((true, _)) => {
                all_ok = false;
                emit(format!("vibe::test\ttimeout\t{name}"))?
            }
            Err((false, reason)) => {
                all_ok = false;
                emit(format!("vibe::test\tfail\t{name}\t{}", escape_field(&reason)))?
            }
        }
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = ticker.join();
    let _ = watchdog.join();
    Ok(if all_ok { 0 } else { 1 })
}
