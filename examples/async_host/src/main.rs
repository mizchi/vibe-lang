use anyhow::Result;
use std::thread;
use std::time::Duration;
use wasmtime::*;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <wasm_file>", args[0]);
        std::process::exit(1);
    }
    let wasm_path = &args[1];

    // Create engine with WASM features
    let engine = Engine::default();
    let mut store = Store::new(&engine, ());

    // Load WASM module
    let wasm_bytes = std::fs::read(wasm_path)?;
    let module = Module::new(&engine, &wasm_bytes)?;

    // Create linker and define host functions
    let mut linker = Linker::new(&engine);

    // Define xsh.sleep import function
    // xsh tagged integers: actual_value = tagged_value >> 2
    linker.func_wrap("xsh", "sleep", |tagged_ms: i32| {
        let ms = (tagged_ms >> 2) as u64;
        println!("[host] sleeping for {}ms", ms);
        thread::sleep(Duration::from_millis(ms));
        println!("[host] woke up");
    })?;

    // Instantiate and run
    let instance = linker.instantiate(&mut store, &module)?;

    // Get and call the run function
    let run = instance.get_typed_func::<(), i32>(&mut store, "run")?;

    println!("[host] calling run()");
    let start = std::time::Instant::now();
    let result = run.call(&mut store, ())?;
    let elapsed = start.elapsed();

    // xsh tagged integer: actual_value = result >> 2
    let untagged = result >> 2;
    println!("[host] run() returned: {} (tagged: {})", untagged, result);
    println!("[host] elapsed time: {:?}", elapsed);

    Ok(())
}
