// ADR-0089 Part B step 1 probe (#1218): pass a future<u32> *value* across
// the component boundary and read it in the guest, to observe the literal
// future.* canonical-ABI built-ins (future.read / future.drop-readable ...)
// that the bare-async-func probes elide (their wait folds into
// [async-lower]; see ../../README.md). The captured wire names are what
// component_codegen.vibe must emit when vibe's Future[T] materializes
// (docs/wasip3-effect-alignment.md Part B item 2).
wit_bindgen::generate!({
    path: "../wit",
    world: "future-value-probe",
    async: true,
});

struct MyGuest;

impl Guest for MyGuest {
    async fn run() -> u32 {
        // Under `async: true` even the sync-declared import lowers
        // async, so the first await obtains the RawFutureReader handle;
        // the second await (IntoFuture on the reader) is the explicit
        // future.read, yielding the payload directly.
        let fut = get_future().await;
        fut.await
    }
}

export!(MyGuest);
