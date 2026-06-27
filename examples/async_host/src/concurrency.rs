// Concurrency proof for real async (docs/spec/wasi-p3-async.md §2.3).
//
// Runs the SAME vibe `sleep` program (examples/wasm/sleep_async.vibe, compiled
// by the selfhost) in TWO guest instances CONCURRENTLY via `futures::join!`.
// Each `sleep(..)` returns Pending once (the guest fiber suspends); the host's
// `vibe.sleep` import logs a global ordered event. If the two tasks really run
// concurrently, BOTH suspend before EITHER resumes — event order
// [A susp, B susp, A res, B res] — which a fake/blocking implementation
// (sequential: [A susp, A res, B susp, B res]) cannot produce.
use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex;
use std::task::{Context, Poll};
use wasmtime::*;

static LOG: Mutex<Vec<String>> = Mutex::new(Vec::new());
fn log(s: String) { LOG.lock().unwrap().push(s); }

struct YieldOnce(bool);
impl Future for YieldOnce {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 { Poll::Ready(()) } else { self.0 = true; cx.waker().wake_by_ref(); Poll::Pending }
    }
}

fn prepare(engine: &Engine, module: &Module, task: &'static str) -> Result<(Store<()>, TypedFunc<(i64,), i64>)> {
    let mut store = Store::new(engine, ());
    let mut linker = Linker::new(engine);
    linker.func_wrap("wasi_snapshot_preview1", "fd_write",
        |_c: Caller<'_, ()>, _a: i32, _b: i32, _n: i32, _w: i32| -> i32 { 0 })?;
    linker.func_wrap_async("vibe", "sleep", move |_c: Caller<'_, ()>, (_ms,): (i64,)| {
        Box::new(async move {
            log(format!("{} suspend", task));
            YieldOnce(false).await;
            log(format!("{} resume", task));
            Ok(())
        })
    })?;
    let instance = futures::executor::block_on(linker.instantiate_async(&mut store, module))?;
    let run = instance.get_typed_func::<(i64,), i64>(&mut store, "run")?;
    Ok((store, run))
}

fn main() -> Result<()> {
    let wasm_path = std::env::args().nth(1).expect("usage: <wasm_file>");
    let mut config = Config::new();
    config.async_support(true);
    config.wasm_exceptions(true);
    let engine = Engine::new(&config)?;
    let module = Module::new(&engine, &std::fs::read(&wasm_path)?)?;

    let (mut sa, ra) = prepare(&engine, &module, "A")?;
    let (mut sb, rb) = prepare(&engine, &module, "B")?;

    let (va, vb) = futures::executor::block_on(async {
        futures::join!(ra.call_async(&mut sa, (0,)), rb.call_async(&mut sb, (0,)))
    });
    let va = va?;
    let vb = vb?;

    let events = LOG.lock().unwrap().clone();
    println!("[concurrency] events: {:?}", events);
    println!("[concurrency] A.run()={} B.run()={}", va, vb);
    // Real concurrency: both suspend before either resumes.
    let interleaved = events == ["A suspend", "B suspend", "A resume", "B resume"];
    let ok = va == 42 && vb == 42 && interleaved;
    println!("[concurrency] interleaved={} -> {}", interleaved, if ok { "REAL concurrency" } else { "FAIL" });
    std::process::exit(if ok { 0 } else { 1 });
}
