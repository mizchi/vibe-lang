// Real async for an actual VIBE program (docs/spec/wasi-p3-async.md §2.3).
// A vibe `() -> Int with { Async }` program calling `sleep(ms)` compiles (via
// the selfhost) to a core module importing `vibe.sleep (i64) -> ()`. This host
// implements that import as ASYNC — Pending on first poll (the guest fiber
// genuinely SUSPENDS), Ready after — so `sleep` is real blocking await, not a
// thread block. Proves end-to-end real async for a vibe program on wasmtime 45.
use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::task::{Context, Poll};
use wasmtime::*;

static SUSPENDS: AtomicU32 = AtomicU32::new(0);
static RESUMES: AtomicU32 = AtomicU32::new(0);

struct YieldOnce(bool);
impl Future for YieldOnce {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 {
            RESUMES.fetch_add(1, Ordering::SeqCst);
            Poll::Ready(())
        } else {
            self.0 = true;
            SUSPENDS.fetch_add(1, Ordering::SeqCst);
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

fn main() -> Result<()> {
    let wasm_path = std::env::args().nth(1).expect("usage: <wasm_file>");
    let mut config = Config::new();
    config.async_support(true);
    config.wasm_exceptions(true);
    let engine = Engine::new(&config)?;
    let mut store = Store::new(&engine, ());
    let module = Module::new(&engine, &std::fs::read(&wasm_path)?)?;

    let mut linker = Linker::new(&engine);
    // The wasi module always imports fd_write (unused here) — provide a stub.
    linker.func_wrap("wasi_snapshot_preview1", "fd_write",
        |_c: Caller<'_, ()>, _fd: i32, _iovs: i32, _n: i32, _nw: i32| -> i32 { 0 })?;
    // vibe.sleep(i64) : async — suspends the guest fiber (linear backend ints are raw i64).
    linker.func_wrap_async("vibe", "sleep", |_c: Caller<'_, ()>, (tagged,): (i64,)| {
        Box::new(async move {
            println!("[host] sleep({}ms): guest suspends (Pending)", tagged);
            YieldOnce(false).await;
            println!("[host] sleep: guest resumes");
            Ok(())
        })
    })?;

    let instance = futures::executor::block_on(linker.instantiate_async(&mut store, &module))?;
    let run = instance.get_typed_func::<(i64,), i64>(&mut store, "run")?;
    println!("[host] calling run() (async)");
    let tagged = futures::executor::block_on(run.call_async(&mut store, (0,)))?;
    let val = tagged;
    let s = SUSPENDS.load(Ordering::SeqCst);
    let r = RESUMES.load(Ordering::SeqCst);
    println!("[host] run() = {}; suspends={} resumes={}", val, s, r);
    std::process::exit(if val == 42 && s >= 1 && r >= 1 { 0 } else { 1 });
}
