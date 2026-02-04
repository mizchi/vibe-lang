use anyhow::{bail, Context, Result};
use std::time::Instant;
use wasmtime::{Config, Engine, Linker, Module, Store, TypedFunc};

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let wasm_path = match args.next() {
        Some(p) => p,
        None => {
            eprintln!("usage: wasmtime_bench <wasm> [--n N] [--warmup N]");
            std::process::exit(1);
        }
    };

    let mut count: usize = 5_000_000;
    let mut warmup: usize = 1_000;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--n" | "-n" => {
                let v = args.next().context("missing value for --n")?;
                count = v.parse().context("invalid --n")?;
            }
            "--warmup" => {
                let v = args.next().context("missing value for --warmup")?;
                warmup = v.parse().context("invalid --warmup")?;
            }
            other => bail!("unknown arg: {other}"),
        }
    }

    if count == 0 {
        bail!("--n must be > 0");
    }

    let config = Config::new();
    let engine = Engine::new(&config)?;
    let module = Module::from_file(&engine, &wasm_path)
        .with_context(|| format!("failed to load {wasm_path}"))?;

    let mut linker = Linker::new(&engine);
    // Provide no-op imports for xsh.path / xsh.sh when present
    linker.func_wrap("xsh", "path", |x: i32| -> i32 { x })?;
    linker.func_wrap("xsh", "sh", |_x: i32| -> i32 { 0 })?;

    let mut store = Store::new(&engine, ());
    let instance = linker
        .instantiate(&mut store, &module)
        .context("failed to instantiate module")?;

    let run_i32 = instance.get_typed_func::<(), i32>(&mut store, "run");
    let run_unit = instance.get_typed_func::<(), ()>(&mut store, "run");

    enum RunFn {
        I32(TypedFunc<(), i32>),
        Unit(TypedFunc<(), ()>),
    }

    let run = if let Ok(func) = run_i32 {
        RunFn::I32(func)
    } else if let Ok(func) = run_unit {
        RunFn::Unit(func)
    } else {
        bail!("exported function 'run' must be () -> i32 or () -> ()");
    };

    for _ in 0..warmup {
        match run {
            RunFn::I32(ref f) => {
                let _ = f.call(&mut store, ())?;
            }
            RunFn::Unit(ref f) => {
                f.call(&mut store, ())?;
            }
        }
    }

    let start = Instant::now();
    for _ in 0..count {
        match run {
            RunFn::I32(ref f) => {
                let _ = f.call(&mut store, ())?;
            }
            RunFn::Unit(ref f) => {
                f.call(&mut store, ())?;
            }
        }
    }
    let elapsed = start.elapsed();
    let total_ns = elapsed.as_nanos() as f64;
    let per_us = total_ns / 1000.0 / count as f64;
    let total_ms = total_ns / 1_000_000.0;

    if total_ms == 0.0 {
        eprintln!("bench: elapsed_ms=0; increase --n for measurable time");
    }

    println!(
        "bench: wasm={} count={} total_ms={} per_us={}",
        wasm_path, count, total_ms, per_us
    );

    Ok(())
}
