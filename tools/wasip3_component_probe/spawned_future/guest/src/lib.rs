// M1b-3c-1b probe (Phase A): does a guest-internal "spawn a writer, await its
// result through a self-contained channel" pattern touch the canonical-ABI
// future.new/.read/.write built-ins at all, or does it stay entirely inside
// wit-bindgen's own guest-side futures-rs executor (spawn_local +
// FuturesUnordered) with zero additional canon machinery beyond whatever the
// writer's own blocking primitive already needs?
//
// `run` does NOT call `get_async()` directly. It spawns a writer task (via
// `wit_bindgen::spawn_local`) that awaits the async host import and forwards
// the result through a oneshot channel; `run` itself only awaits that
// channel. This is the "self-contained future produced by a spawned writer
// subtask" shape docs/spec/wasi-p3-async.md §3.7 describes.
wit_bindgen::generate!({
    path: "../wit",
    world: "spawn-probe",
    async: true,
});

use futures::channel::oneshot;

struct MyGuest;

impl Guest for MyGuest {
    async fn run() -> u32 {
        let (tx, rx) = oneshot::channel();
        wit_bindgen::spawn_local(async move {
            let v = get_async().await;
            let _ = tx.send(v);
        });
        rx.await.unwrap()
    }
}

export!(MyGuest);
