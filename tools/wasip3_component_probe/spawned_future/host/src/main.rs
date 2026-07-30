// M1b-3c-1b probe (Phase B) host driver -- structurally identical to
// stackful/host/src/main.rs (same wasmtime config, same driving API
// (Store::run_concurrent + TypedFunc::call_concurrent, NOT call_async --
// see stackful/README.md bug #1), same 300ms host-side suspend to prove a
// genuinely blocking wait, not a trivially-ready one). The only difference
// is the component under test (component.wat in this directory) splits its
// guest-side logic into a $writer function ("spawned writer subtask") called
// from $run ("self-contained future" consumer) instead of doing everything
// inline in $run -- see this directory's canon-imports-exports.wit-abi.txt
// for why that split needs no additional canon built-ins.
use std::time::{Duration, Instant};
use wasmtime::component::{Accessor, Component, Linker};
use wasmtime::{Config, Engine, Store};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    env_logger::init();
    let path = std::env::args().nth(1).expect("path to component.wasm");
    let bytes = std::fs::read(&path)?;

    let mut config = Config::new();
    config.wasm_component_model(true);
    config.wasm_component_model_async(true);
    config.wasm_component_model_async_stackful(true);
    config.concurrency_support(true);
    let engine = Engine::new(&config)?;

    let component = Component::from_binary(&engine, &bytes)?;

    let mut linker: Linker<()> = Linker::new(&engine);
    linker.root().func_wrap_concurrent(
        "get-async",
        |_accessor: &Accessor<()>, _params: ()| {
            Box::pin(async move {
                println!("[host] get-async: suspending for 300ms");
                tokio::time::sleep(Duration::from_millis(300)).await;
                println!("[host] get-async: resolved with 42");
                Ok((42u32,))
            })
        },
    )?;

    let mut store = Store::new(&engine, ());
    let instance = linker.instantiate_async(&mut store, &component).await?;
    let run = instance.get_typed_func::<(), (u32,)>(&mut store, "run")?;

    let start = Instant::now();
    let (result,) = store
        .run_concurrent(async move |accessor| run.call_concurrent(accessor, ()).await)
        .await??;
    let elapsed = start.elapsed();

    println!("[host] run() = {result} (elapsed {elapsed:?}) [spawned-writer-subtask fixture]");
    assert_eq!(result, 42);
    Ok(())
}
