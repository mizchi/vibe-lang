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
//! enforced with epoch interruption.
//!
//! Output, one line per block on stdout, tab separated:
//!   vibe::test<TAB>ok<TAB><name>
//!   vibe::test<TAB>fail<TAB><name><TAB><reason>
//!   vibe::test<TAB>timeout<TAB><name>
//! The blocks are the names in the module's `vibe_tests` custom section, which
//! the compiler writes for every test build: a program may export its own
//! `__test_helper`, so the prefix is not authoritative. A module without the
//! section (an older compiler) falls back to every `__test_*` export.
//!
//! `<name>` and `<reason>` escape `\` `\t` `\n` `\r` as two-character
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
            _ => out.push(c),
        }
    }
    out
}

/// The names in the `vibe_tests` custom section, or None when the module has
/// none. A plain section walk: magic + version, then `id, size, payload`
/// records; a custom section's payload starts with its name.
fn declared_tests(bytes: &[u8]) -> Option<Vec<String>> {
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
                let payload = &bytes[name_end..end];
                return Some(
                    payload
                        .split(|b| *b == 0)
                        .filter(|n| !n.is_empty())
                        .map(|n| String::from_utf8_lossy(n).into_owned())
                        .collect(),
                );
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

    let names: Vec<String> = match declared_tests(&std::fs::read(wasm_path)?) {
        Some(declared) => declared,
        None => module
            .exports()
            .filter(|e| e.name().starts_with("__test_"))
            .map(|e| e.name().to_string())
            .collect(),
    };

    // One tick per millisecond; a block's deadline is `timeout_ms` ticks
    // after its own start.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let ticker = {
        let engine = engine.clone();
        let stop = stop.clone();
        std::thread::spawn(move || run_epoch_ticker(engine, stop, Duration::from_millis(1)))
    };

    let mut all_ok = true;
    let mut out = io::stdout().lock();
    for full in &names {
        let name = escape_field(full.strip_prefix("__test_").unwrap_or(full));
        // Two blocks with one title share one export, so only one of them is
        // callable: running it twice would report the other block's verdict
        // without ever running it. Each copy fails instead, saying why.
        if names.iter().filter(|n| *n == full).count() > 1 {
            all_ok = false;
            writeln!(
                out,
                "vibe::test\tfail\t{name}\tduplicate test title: rename one of the blocks, only one of them can be run on its own"
            )?;
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
            Ok(()) => writeln!(out, "vibe::test\tok\t{name}")?,
            Err((true, _)) => {
                all_ok = false;
                writeln!(out, "vibe::test\ttimeout\t{name}")?
            }
            Err((false, reason)) => {
                all_ok = false;
                writeln!(out, "vibe::test\tfail\t{name}\t{}", escape_field(&reason))?
            }
        }
        out.flush()?;
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let _ = ticker.join();
    Ok(if all_ok { 0 } else { 1 })
}
