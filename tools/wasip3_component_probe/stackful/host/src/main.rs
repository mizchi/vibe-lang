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

    println!("[host] run() = {result} (elapsed {elapsed:?})");
    assert_eq!(result, 42);
    Ok(())
}
