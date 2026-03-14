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
    let engine_start = Instant::now();
    let engine = Engine::new(&config)?;
    let engine_elapsed = engine_start.elapsed();

    let module_start = Instant::now();
    let module = Module::from_file(&engine, &wasm_path)
        .with_context(|| format!("failed to load {wasm_path}"))?;
    let module_elapsed = module_start.elapsed();

    let mut linker = Linker::new(&engine);
    // Provide no-op imports for vibe.path / vibe.sh when present
    linker.func_wrap("vibe", "path", |x: i32| -> i32 { x })?;
    linker.func_wrap("vibe", "sh", |_x: i32| -> i32 { 0 })?;

    let mut store = Store::new(&engine, ());
    let instantiate_start = Instant::now();
    let instance = linker
        .instantiate(&mut store, &module)
        .context("failed to instantiate module")?;
    let instantiate_elapsed = instantiate_start.elapsed();

    let lookup_start = Instant::now();
    let run_i32 = instance.get_typed_func::<(), i32>(&mut store, "run");
    let run_i64 = instance.get_typed_func::<(), i64>(&mut store, "run");
    let run_unit = instance.get_typed_func::<(), ()>(&mut store, "run");
    let lookup_elapsed = lookup_start.elapsed();

    enum RunFn {
        I32(TypedFunc<(), i32>),
        I64(TypedFunc<(), i64>),
        Unit(TypedFunc<(), ()>),
    }

    let run = if let Ok(func) = run_i32 {
        RunFn::I32(func)
    } else if let Ok(func) = run_i64 {
        RunFn::I64(func)
    } else if let Ok(func) = run_unit {
        RunFn::Unit(func)
    } else {
        bail!("exported function 'run' must be () -> i32, () -> i64, or () -> ()");
    };

    let first_call_start = Instant::now();
    match run {
        RunFn::I32(ref f) => {
            let _ = f.call(&mut store, ())?;
        }
        RunFn::I64(ref f) => {
            let _ = f.call(&mut store, ())?;
        }
        RunFn::Unit(ref f) => {
            f.call(&mut store, ())?;
        }
    }
    let first_call_elapsed = first_call_start.elapsed();

    for _ in 0..warmup {
        match run {
            RunFn::I32(ref f) => {
                let _ = f.call(&mut store, ())?;
            }
            RunFn::I64(ref f) => {
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
            RunFn::I64(ref f) => {
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
    let engine_ms = engine_elapsed.as_secs_f64() * 1000.0;
    let module_ms = module_elapsed.as_secs_f64() * 1000.0;
    let instantiate_ms = instantiate_elapsed.as_secs_f64() * 1000.0;
    let lookup_ms = lookup_elapsed.as_secs_f64() * 1000.0;
    let first_call_ms = first_call_elapsed.as_secs_f64() * 1000.0;
    let setup_ms = engine_ms + module_ms + instantiate_ms + lookup_ms + first_call_ms;

    if total_ms == 0.0 {
        eprintln!("bench: elapsed_ms=0; increase --n for measurable time");
    }

    println!(
        "startup: wasm={} engine_ms={} module_ms={} instantiate_ms={} lookup_ms={} first_call_ms={} setup_ms={}",
        wasm_path, engine_ms, module_ms, instantiate_ms, lookup_ms, first_call_ms, setup_ms
    );
    println!(
        "bench: wasm={} count={} total_ms={} per_us={}",
        wasm_path, count, total_ms, per_us
    );

    Ok(())
}
