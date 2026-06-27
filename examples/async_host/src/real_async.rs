// Real async host (docs/spec/wasi-p3-async.md §2.3, host async imports).
//
// Proves that real blocking `await` works on wasmtime 45 when the async SOURCE
// is the host: the guest imports `host.get_async() -> i64`, which the host
// implements as an ASYNC function that returns Pending on its first poll —
// genuinely SUSPENDING the guest fiber — and Ready(42) afterwards. The guest
// `run()` simply calls the import (no state-machine codegen needed; wasmtime's
// async fiber drives suspend/resume). Self-contained component-model `future`
// blocking is impossible here (single-task `future.write` traps "cannot block a
// synchronous task" — it needs a concurrent producer), so the producer must be
// the host: this is that host.
use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::task::{Context, Poll};
use wasmtime::*;

static SUSPENDS: AtomicU32 = AtomicU32::new(0);
static RESUMES: AtomicU32 = AtomicU32::new(0);

// Pending on first poll (forces a real fiber suspend), Ready(val) after.
struct YieldOnce {
    polled: bool,
    val: i64,
}
impl Future for YieldOnce {
    type Output = i64;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<i64> {
        if self.polled {
            RESUMES.fetch_add(1, Ordering::SeqCst);
            Poll::Ready(self.val)
        } else {
            self.polled = true;
            SUSPENDS.fetch_add(1, Ordering::SeqCst);
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

fn main() -> Result<()> {
    let wasm_path = std::env::args().nth(1).expect("usage: <wasm_file>");
    let engine = Engine::new(Config::new().async_support(true))?;
    let mut store = Store::new(&engine, ());
    let module = Module::new(&engine, &std::fs::read(&wasm_path)?)?;

    let mut linker = Linker::new(&engine);
    linker.func_wrap_async("host", "get_async", |_caller: Caller<'_, ()>, _params: ()| {
        Box::new(async move {
            println!("[host] get_async: Pending (guest suspends)");
            let v = YieldOnce { polled: false, val: 42 }.await;
            println!("[host] get_async: Ready, resuming guest with {}", v);
            Ok((v,))
        })
    })?;

    let instance = futures::executor::block_on(linker.instantiate_async(&mut store, &module))?;
    let run = instance.get_typed_func::<(), i64>(&mut store, "run")?;
    println!("[host] calling run() via call_async");
    let result = futures::executor::block_on(run.call_async(&mut store, ()))?;
    let s = SUSPENDS.load(Ordering::SeqCst);
    let r = RESUMES.load(Ordering::SeqCst);
    println!("[host] run() = {}; suspends={} resumes={}", result, s, r);
    // Require the right value AND a genuine suspend+resume (proves real async).
    std::process::exit(if result == 42 && s >= 1 && r >= 1 { 0 } else { 1 });
}
