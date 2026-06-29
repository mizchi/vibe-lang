// Real async DATA read for a vibe program (docs/spec/wasi-p3-async.md §2.3).
// A vibe `Stdin::read_char()` compiles (via the selfhost) to a value-returning
// `vibe.stdin_read_char () -> i64` host import. This host implements it as an
// ASYNC function that SUSPENDS the guest once per char (as a real async source
// would) and then delivers the next value. The data-consuming analog of sleep:
// the shape of reading an HTTP body byte / stdin char asynchronously.
use anyhow::Result;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::task::{Context, Poll};
use wasmtime::*;

static SUSPENDS: AtomicU32 = AtomicU32::new(0);
static POS: AtomicUsize = AtomicUsize::new(0);

struct YieldOnce(bool);
impl Future for YieldOnce {
    type Output = ();
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.0 { Poll::Ready(()) } else { self.0 = true; cx.waker().wake_by_ref(); Poll::Pending }
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
    linker.func_wrap("wasi_snapshot_preview1", "fd_write",
        |_c: Caller<'_, ()>, _a: i32, _b: i32, _n: i32, _w: i32| -> i32 { 0 })?;

    // The async source yields these values, one per read, suspending each time.
    const DATA: [i64; 3] = [10, 14, 18];
    linker.func_wrap_async("vibe", "stdin_read_char", |_c: Caller<'_, ()>, _p: ()| {
        Box::new(async move {
            let i = POS.fetch_add(1, Ordering::SeqCst);
            println!("[host] stdin_read_char #{}: guest suspends (Pending)", i);
            YieldOnce(false).await;
            SUSPENDS.fetch_add(1, Ordering::SeqCst);
            let v = if i < DATA.len() { DATA[i] } else { -1 };
            println!("[host] stdin_read_char #{}: resume -> {}", i, v);
            Ok((v,))
        })
    })?;

    let instance = futures::executor::block_on(linker.instantiate_async(&mut store, &module))?;
    let run = instance.get_typed_func::<(i64,), i64>(&mut store, "run")?;
    println!("[host] calling run() (async)");
    let result = futures::executor::block_on(run.call_async(&mut store, (0,)))?;
    let s = SUSPENDS.load(Ordering::SeqCst);
    println!("[host] run() = {}; suspends={}", result, s);
    std::process::exit(if result == 42 && s == 3 { 0 } else { 1 });
}
