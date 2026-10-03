//! Component runtime.

use super::*;

// #1230 M1b-3c-2: default suspend for the placeholder `get-async` import
// below. Matches tools/wasip3_component_probe/'s 300ms so the gate can assert
// that the guest genuinely suspended and resumed (a trivially-ready import
// would pass a value check while proving nothing about the wait machinery).
pub(super) const ASYNC_COMPONENT_GET_DELAY_MS: u64 = 300;
pub(super) const ASYNC_COMPONENT_GET_VALUE: u32 = 42;

/// #1230 M1b-3c-2: run an async Component Model binary of the shape
/// `component_codegen.vibe`'s `comp_emit_component_wasm_async_spawned_future`
/// emits -- imports `get-async: async func() -> u32`, exports
/// `run: async func() -> u32` -- and print the returned value (matching what
/// `wasmtime --invoke run` prints, which is what the async component gates
/// already assert against).
///
/// Before this, nothing in the project could drive such a component: bare
/// `wasmtime --invoke` deadlock-traps on a component importing a
/// `func_wrap_concurrent` host function, so
/// scripts/test_spawned_future_component_gate.sh had to shell out to a
/// dedicated Rust host binary under tools/wasip3_component_probe/ (needing a
/// Rust toolchain and crates.io access at gate time). This is that driver,
/// moved into the real runtime.
///
/// Two non-obvious constraints, both found the hard way by the probe and
/// documented in tools/wasip3_component_probe/stackful/README.md:
///
///  1. **Driving API pairing.** A `func_wrap_concurrent` import must be driven
///     via `Store::run_concurrent` + `TypedFunc::call_concurrent`. The
///     "plain" `TypedFunc::call_async(&mut store, ...)` pattern -- correct for
///     `func_wrap`/`func_wrap_async` -- traps with "deadlock detected: event
///     loop cannot make further progress" the moment the concurrent import
///     resolves.
///  2. **Its own Engine, but derived from `engine_config()`.** The
///     component/concurrency options below are additive on top of the shared
///     config, so this path keeps `max_wasm_stack`
///     (`MOONRUN_WT_WASM_STACK_MB`, 64 MiB by default) and the rest of the
///     wasm feature set. #1242 review: starting from a bare `Config::new()`
///     silently reverted to wasmtime's small default wasm stack, which is
///     exactly what `engine_config()` exists to raise -- deeply recursive
///     guest code would have traped with call-stack exhaustion here while
///     working fine on the core-module path.
///
/// The store carries the same `MOONRUN_WT_MEMORY_MB` limiter every other
/// store here does (#1242 review: it previously had none, so a component
/// with an embedded core memory could grow unbounded despite `--help`
/// documenting the cap). `MemLimiter`'s growth-event recording is a
/// core-module profiling feature (`VIBE_MEM`) with no component-path
/// equivalent, so it stays off; only the size cap matters.
///
/// Scope: `get-async` is the async host-import surface the emitter currently
/// produces -- a probe-shaped placeholder, not yet a real WASI interface. It
/// is implemented here with a genuinely-suspending timer (a `tokio::time`
/// sleep, i.e. the same thing a `wasi:clocks` backing would do), NOT a
/// blocking `std::thread::sleep`, which would defeat the point. As the
/// emitter grows real `wasi:clocks`/`wasi:http` imports, this linker grows
/// with it; the driving machinery above does not change.
/// ADR-0089 Decision 3 (#1218): a `stream<u8>` producer that delivers ONE
/// byte per `delay` tick. wasmtime's own `Vec<u8>` producer hands the whole
/// buffer to the pipe on its first poll, after which every guest read
/// completes inline -- correct, but it never exercises the reader's
/// BLOCKED -> waitable-park path and gives a gate nothing to measure. This
/// producer returns `Poll::Pending` from a real `tokio::time::Sleep` before
/// each byte, so each `stream.read` genuinely blocks and the wall clock of
/// a full drain is bounded below by `bytes * delay` -- the same
/// "concurrency must be observable" discipline as VIBE_ASYNC_FUTURES'
/// per-entry delays.
/// #2066: the `response` record of a WIT response import --
/// `record { status: s32, body: stream<u8> }` -- the result of the
/// `async func` the import declares (#3131: returned by the call itself).
#[derive(
    wasmtime::component::ComponentType, wasmtime::component::Lower, wasmtime::component::Lift,
)]
#[component(record)]
pub(super) struct HostResponse {
    pub(super) status: i32,
    pub(super) body: wasmtime::component::StreamReader<u8>,
}

pub(super) struct DelayedByteStreamProducer {
    bytes: Vec<u8>,
    idx: usize,
    delay: std::time::Duration,
    sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
}

impl<D> wasmtime::component::StreamProducer<D> for DelayedByteStreamProducer {
    type Item = u8;
    type Buffer = wasmtime::component::VecBuffer<u8>;

    fn poll_produce<'a>(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        _store: wasmtime::StoreContextMut<'a, D>,
        mut dst: wasmtime::component::Destination<'a, Self::Item, Self::Buffer>,
        finish: bool,
    ) -> std::task::Poll<Result<wasmtime::component::StreamResult>> {
        use std::future::Future;
        use std::task::Poll;
        use wasmtime::component::StreamResult;
        let this = self.get_mut();
        if this.idx >= this.bytes.len() {
            return Poll::Ready(Ok(StreamResult::Dropped));
        }
        let sleep = this
            .sleep
            .get_or_insert_with(|| Box::pin(tokio::time::sleep(this.delay)));
        match sleep.as_mut().poll(cx) {
            Poll::Pending => {
                if finish {
                    // Asked to wrap up early: complete the pending read with
                    // nothing written; the stream itself stays open.
                    return Poll::Ready(Ok(StreamResult::Cancelled));
                }
                Poll::Pending
            }
            Poll::Ready(()) => {
                this.sleep = None;
                let b = this.bytes[this.idx];
                this.idx += 1;
                dst.set_buffer(vec![b].into());
                Poll::Ready(Ok(if this.idx >= this.bytes.len() {
                    StreamResult::Dropped
                } else {
                    StreamResult::Completed
                }))
            }
        }
    }
}

/// A named root future's producer: `value` after `ms`. Unlike an `async`
/// block, it answers a cancelled read (`finish`) at once rather than running
/// its delay out, so a guest that cancels a pending `future.cancel-read` is
/// not held for the rest of the delay (Codex on #3091: a group whose body
/// throws cancels its parked children's reads).
pub(super) struct DelayedValue {
    value: u32,
    sleep: Option<std::pin::Pin<Box<tokio::time::Sleep>>>,
}

impl DelayedValue {
    fn new(value: u32, ms: u64) -> Self {
        let sleep = if ms > 0 {
            Some(Box::pin(tokio::time::sleep(
                std::time::Duration::from_millis(ms),
            )))
        } else {
            None
        };
        DelayedValue { value, sleep }
    }
}

impl<D: 'static> wasmtime::component::FutureProducer<D> for DelayedValue {
    type Item = u32;

    fn poll_produce(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        _store: wasmtime::StoreContextMut<D>,
        finish: bool,
    ) -> std::task::Poll<Result<Option<u32>>> {
        use std::future::Future;
        use std::task::Poll;
        let this = self.get_mut();
        let ready = match this.sleep.as_mut() {
            Some(sleep) => sleep.as_mut().poll(cx).is_ready(),
            None => true,
        };
        if ready {
            Poll::Ready(Ok(Some(this.value)))
        } else if finish {
            Poll::Ready(Ok(None))
        } else {
            Poll::Pending
        }
    }
}

/// #2066: a REAL response provider. `VIBE_ASYNC_RESPONSES="<addr>=0:0:http"`
/// links `func: async func(url: string) -> response` to an HTTP GET of the
/// argument: the request runs on a blocking thread (ureq, like the core
/// runner's Http imports), so several fetches are in flight together, and the
/// call returns the server's own status -- a non-2xx status is a response,
/// not an error -- and its body bytes streamed. A transport failure (no
/// connection, bad URL) fails the call, which traps the guest's await.
/// The whole request, connect through the last body byte, is bounded
/// (`VIBE_HTTP_TIMEOUT_MS`, default 30s): a blocking thread cannot be aborted
/// once it runs, and the runtime waits for it at shutdown, so a stalled server
/// would otherwise hold the runner open after the component finished.
pub(super) const HTTP_PROVIDER_TIMEOUT_MS: u64 = 30_000;
/// The body is buffered before the future lands, so it is capped
/// (`VIBE_HTTP_BODY_LIMIT`, default 16 MiB) rather than letting an endpoint
/// grow host memory past what `StoreLimits` governs. A larger body fails the
/// future with a message naming the limit; it is never silently truncated.
pub(super) const HTTP_PROVIDER_BODY_LIMIT: u64 = 16 * 1024 * 1024;

pub(super) fn http_env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

pub(super) fn http_get_blocking(url: &str) -> Result<(i32, Vec<u8>)> {
    let timeout = std::time::Duration::from_millis(http_env_u64(
        "VIBE_HTTP_TIMEOUT_MS",
        HTTP_PROVIDER_TIMEOUT_MS,
    ));
    let limit = http_env_u64("VIBE_HTTP_BODY_LIMIT", HTTP_PROVIDER_BODY_LIMIT);
    let agent = ureq::AgentBuilder::new().timeout(timeout).build();
    let resp = match agent.get(url).call() {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => return Err(format_err!("http provider: GET {url}: {e}")),
    };
    let status = i32::from(resp.status());
    let mut bytes = Vec::new();
    resp.into_reader()
        .take(limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|e| format_err!("http provider: GET {url}: reading the body: {e}"))?;
    if bytes.len() as u64 > limit {
        return Err(format_err!(
            "http provider: GET {url}: the body is larger than {limit} bytes; raise VIBE_HTTP_BODY_LIMIT to accept it"
        ));
    }
    Ok((status, bytes))
}

pub(super) fn run_async_component(path: &str) -> Result<i32> {
    use wasmtime::component::{Accessor, Component, Linker as ComponentLinker};

    let delay_ms: u64 = std::env::var("VIBE_ASYNC_GET_DELAY_MS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(ASYNC_COMPONENT_GET_DELAY_MS);
    // Percentage applied to every suspend below. `get-after`'s delays come
    // from the GUEST (baked into the probe components), so unlike
    // VIBE_ASYNC_GET_DELAY_MS there is otherwise no way to scale them from
    // outside -- and a gate that only needs to warm the JIT would sit through
    // the probe's full timings for nothing. Scaling here keeps every ratio
    // intact, so completion ORDER, and therefore what the probes assert, is
    // unchanged. Raise it above 100 on a loaded machine to widen the margins.
    let delay_scale_pct: u64 = std::env::var("VIBE_ASYNC_DELAY_SCALE_PCT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(100);
    // A nonzero request must stay nonzero: an async-lowered call that
    // completes eagerly takes a different path through the guest (no subtask
    // is created), which several probes deliberately reject with an
    // `unreachable`. Scaling must not silently turn a blocking call into an
    // eager one.
    let scale = move |ms: u64| -> u64 {
        if ms == 0 {
            0
        } else {
            std::cmp::max(1, ms.saturating_mul(delay_scale_pct) / 100)
        }
    };

    let mut cfg = engine_config();
    cfg.wasm_component_model(true);
    cfg.wasm_component_model_async(true);
    cfg.wasm_component_model_async_stackful(true);
    cfg.concurrency_support(true);
    let engine = Engine::new(&cfg)?;

    let bytes = fs::read(path).map_err(|e| format_err!("read {path}: {e}"))?;
    let component = Component::from_binary(&engine, &bytes)
        .map_err(|e| format_err!("component from_binary {path}: {e}"))?;

    let mut linker: ComponentLinker<StoreLimits> = ComponentLinker::new(&engine);
    linker
        .root()
        .func_wrap_concurrent(
            "get-async",
            move |_acc: &Accessor<StoreLimits>, _params: ()| {
                Box::pin(async move {
                    let ms = scale(delay_ms);
                    if ms > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                    }
                    Ok((ASYNC_COMPONENT_GET_VALUE,))
                })
            },
        )
        .map_err(|e| format_err!("link get-async: {e}"))?;
    // #1230 M1b-3c-1c: same thing with a caller-chosen delay, returned as the
    // value. `get-async`'s single fixed delay makes every in-flight call
    // resolve at the same moment, which is enough to show that calls OVERLAP
    // (M1b-3c-3) but cannot show anything about the ORDER continuations run
    // in -- completion order and start order coincide. A per-call delay makes
    // them differ observably, which is what the interleaving probe needs.
    // Echoing `ms` back also lets the guest identify a completion by value,
    // independently of the waitable handle.
    linker
        .root()
        .func_wrap_concurrent(
            "get-after",
            move |_acc: &Accessor<StoreLimits>, (ms,): (u32,)| {
                Box::pin(async move {
                    // The value echoed back is the guest's ORIGINAL request,
                    // not the scaled sleep -- probes identify a completion by
                    // it, so scaling must stay invisible to the guest.
                    let slept = scale(ms as u64);
                    if slept > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(slept)).await;
                    }
                    Ok((ms,))
                })
            },
        )
        .map_err(|e| format_err!("link get-after: {e}"))?;
    // #1342: the timer behind a REAL program's `sleep(ms)`. Same shape as
    // `get-after` -- an async func, so the wait folds into the guest's
    // [async-lower] call and the adapter parks on the resulting subtask --
    // but a separate name because this one appears in the WIT of components
    // people actually build, where `get-after` would say nothing about what
    // the import is for. Genuinely async (a tokio timer, never a blocking
    // thread sleep): a blocking one would make the component's other
    // in-flight host operations stop with it, which is the very thing
    // `with Async` promises not to do.
    linker
        .root()
        .func_wrap_concurrent(
            "sleep-for",
            move |_acc: &Accessor<StoreLimits>, (ms,): (u32,)| {
                Box::pin(async move {
                    let slept = scale(ms as u64);
                    if slept > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(slept)).await;
                    }
                    Ok((ms,))
                })
            },
        )
        .map_err(|e| format_err!("link sleep-for: {e}"))?;
    // ADR-0089 D2 / step 4 (#1218): a host-supplied `future<u32>` VALUE --
    // `get-future: func() -> future<u32>`. Unlike `get-async` (an async func
    // whose wait folds into the [async-lower] call itself), this returns an
    // explicit future handle the guest must `future.read` and park on: the
    // read comes back BLOCKED, the guest joins it into a waitable set, and
    // `waitable-set.wait` suspends the task until this producer's timer
    // fires -- the completion-order wake path the host_future_value probe
    // and comp_emit_component_wasm_host_future_value measure. Creating the
    // pair is synchronous (the import call itself completes eagerly); only
    // the PRODUCER suspends, on the same genuinely-async tokio timer as
    // `get-async` (a `FutureReader::new` producer future is polled by
    // wasmtime's event loop once a read is pending -- pull-based, but
    // observably identical to a writer writing after a delay).
    linker
        .root()
        .func_wrap_concurrent(
            "get-future",
            move |acc: &Accessor<StoreLimits>, _params: ()| {
                Box::pin(async move {
                    let ms = scale(delay_ms);
                    let reader = acc.with(|mut access| {
                        wasmtime::component::FutureReader::<u32>::new(&mut access, async move {
                            if ms > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                            }
                            Ok::<u32, wasmtime::Error>(ASYNC_COMPONENT_GET_VALUE)
                        })
                    })?;
                    Ok((reader,))
                })
            },
        )
        .map_err(|e| format_err!("link get-future: {e}"))?;
    // ADR-0089 (c) (#1218): GENERALIZED named host futures. Every entry in
    // VIBE_ASYNC_FUTURES="name=value:delay_ms,name2=value2:delay_ms2" links an
    // additional root import `name: func() -> future<u32>` with its own
    // producer value and delay -- the WIT-derived-import generalization of the
    // fixed `get-future` above, which stays as the unnamed default. Per-entry
    // values and delays are what make concurrency OBSERVABLE: two futures
    // fetched before either is awaited must finish in delay order, not in
    // call order, and the total wall clock must be the max of the two delays
    // rather than their sum. The delay is scaled like every other suspend
    // here, so VIBE_ASYNC_DELAY_SCALE_PCT keeps working.
    // #2064: WIT-addressed entries, grouped by interface so each versioned
    // instance is linked once with all of its functions.
    let mut wit_futures: std::collections::BTreeMap<String, Vec<(&'static str, i64, u64)>> =
        std::collections::BTreeMap::new();
    if let Ok(spec) = std::env::var("VIBE_ASYNC_FUTURES") {
        for ent in spec.split(',').filter(|s| !s.trim().is_empty()) {
            let (name, rest) = ent.split_once('=').ok_or_else(|| {
                format_err!("VIBE_ASYNC_FUTURES entry '{ent}': expected name=value:delay_ms")
            })?;
            let (val_s, delay_s) = rest.split_once(':').ok_or_else(|| {
                format_err!("VIBE_ASYNC_FUTURES entry '{ent}': expected name=value:delay_ms")
            })?;
            let name = name.trim().to_string();
            // #2064: a WIT function address (`example:prices/api@1.0.0#get-price`)
            // is linked inside that versioned INTERFACE instance, as the
            // `async func() -> s64` the WIT declares (#3131), instead of as a
            // root `future<u32>` function.
            if let Some((iface, func)) = name.split_once('#') {
                let value: i64 = val_s
                    .trim()
                    .parse()
                    .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad value: {e}"))?;
                let entry_delay: u64 = delay_s
                    .trim()
                    .parse()
                    .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad delay: {e}"))?;
                let func_name: &'static str = Box::leak(func.to_string().into_boxed_str());
                wit_futures
                    .entry(iface.to_string())
                    .or_insert_with(Vec::new)
                    .push((func_name, value, entry_delay));
                continue;
            }
            // #1337 Codex review: `get-future` / `get-async` / `get-after` are
            // already registered unconditionally above, and the component
            // linker has shadowing disabled -- registering one of them here
            // fails with "map entry `get-future` defined twice" before the
            // component is even instantiated (measured). They are valid
            // component labels, so `host_future_named("get-future")` can ask
            // for one; say so plainly instead of surfacing a linker error.
            if matches!(
                name.as_str(),
                "get-future" | "get-async" | "get-after" | "sleep-for"
            ) {
                bail!(
                    "VIBE_ASYNC_FUTURES '{name}': that name is one of the runner's \
                     built-in imports (get-future, get-async, get-after, sleep-for) and \
                     cannot be redefined -- rename the host future"
                );
            }
            let value: u32 = val_s
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad value: {e}"))?;
            let entry_delay: u64 = delay_s
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_FUTURES '{name}': bad delay: {e}"))?;
            // `func_wrap_concurrent` takes a `&'static str`; the spec is read
            // once at startup and every linked name lives as long as the
            // process, so leaking these few strings is the cheap way to get
            // there (they are bounded by the component's import count).
            let link_name: &'static str = Box::leak(name.clone().into_boxed_str());
            linker
                .root()
                .func_wrap_concurrent(
                    link_name,
                    move |acc: &Accessor<StoreLimits>, _params: ()| {
                        let ms = scale(entry_delay);
                        Box::pin(async move {
                            let reader = acc.with(|mut access| {
                                wasmtime::component::FutureReader::<u32>::new(
                                    &mut access,
                                    DelayedValue::new(value, ms),
                                )
                            })?;
                            Ok((reader,))
                        })
                    },
                )
                .map_err(|e| format_err!("link {name}: {e}"))?;
        }
    }
    super::checker_workers::link(&mut linker)?;
    // #2066: WIT responses. VIBE_ASYNC_RESPONSES="iface#func=status:delay_ms:
    // b1|b2|b3" links `func: async func() -> response` inside `iface`,
    // returning a future that resolves after `delay_ms` to `{ status, body }`
    // with the body streaming those bytes then EOS. The body stream is
    // created when the call is made and handed over inside the record, so
    // it is the guest's readable end from the moment the response lands.
    // (func, status, delay, body, echo): `echo` in place of the body bytes
    // links `func: async func(<label>: string) -> response` whose body is the
    // argument's own bytes (#2066 request parameters).
    // `http` in place of the body links the real provider above.
    let mut responses: std::collections::BTreeMap<
        String,
        Vec<(String, i32, u64, Vec<u8>, bool, bool)>,
    > = std::collections::BTreeMap::new();
    if let Ok(spec) = std::env::var("VIBE_ASYNC_RESPONSES") {
        for ent in spec.split(',').filter(|s| !s.trim().is_empty()) {
            let (addr, rest) = ent.split_once('=').ok_or_else(|| {
                format_err!(
                    "VIBE_ASYNC_RESPONSES entry '{ent}': expected iface#func=status:delay_ms:b1|b2"
                )
            })?;
            let (iface, func) = addr.trim().split_once('#').ok_or_else(|| {
                format_err!("VIBE_ASYNC_RESPONSES '{addr}': expected a WIT address iface#func")
            })?;
            let mut parts = rest.splitn(3, ':');
            let status: i32 = parts
                .next()
                .unwrap_or("")
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_RESPONSES '{addr}': bad status: {e}"))?;
            let delay: u64 = parts
                .next()
                .ok_or_else(|| format_err!("VIBE_ASYNC_RESPONSES '{addr}': missing delay_ms"))?
                .trim()
                .parse()
                .map_err(|e| format_err!("VIBE_ASYNC_RESPONSES '{addr}': bad delay: {e}"))?;
            let body_spec = parts.next().unwrap_or("").trim();
            let echo = body_spec == "echo";
            let http = body_spec == "http";
            let mut body: Vec<u8> = Vec::new();
            for b in body_spec
                .split('|')
                .filter(|s| !s.trim().is_empty() && !echo && !http)
            {
                body.push(
                    b.trim()
                        .parse()
                        .map_err(|e| format_err!("VIBE_ASYNC_RESPONSES '{addr}': bad byte: {e}"))?,
                );
            }
            responses.entry(iface.to_string()).or_default().push((
                func.to_string(),
                status,
                delay,
                body,
                echo,
                http,
            ));
        }
    }
    // One linker instance per WIT interface, carrying its scalar futures AND
    // its responses: an interface may declare both, and the linker refuses to
    // define the same instance twice (Codex on #3059).
    let mut wit_ifaces: std::collections::BTreeSet<String> = wit_futures.keys().cloned().collect();
    wit_ifaces.extend(responses.keys().cloned());
    for iface in wit_ifaces {
        let mut inst = linker
            .instance(&iface)
            .map_err(|e| format_err!("link instance {iface}: {e}"))?;
        let funcs = wit_futures.remove(&iface).unwrap_or_default();
        for (func_name, value, entry_delay) in funcs {
            inst.func_wrap_concurrent(
                func_name,
                move |acc: &Accessor<StoreLimits>, _params: ()| {
                    let ms = scale(entry_delay);
                    // #3131: `async func() -> s64` as the WIT writes it -- the
                    // call itself is the subtask, and its result is the value.
                    let _ = acc;
                    Box::pin(async move {
                        if ms > 0 {
                            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                        }
                        Ok((value,))
                    })
                },
            )
            .map_err(|e| format_err!("link {iface}#{func_name}: {e}"))?;
        }
        let funcs = responses.remove(&iface).unwrap_or_default();
        for (func_name, status, entry_delay, body, echo, http) in funcs {
            if http {
                inst.func_wrap_concurrent(
                    &func_name,
                    move |acc: &Accessor<StoreLimits>, (url,): (String,)| {
                        Box::pin(async move {
                            let (status, bytes) =
                                tokio::task::spawn_blocking(move || http_get_blocking(&url))
                                    .await
                                    .map_err(|e| {
                                        format_err!("http provider: request thread: {e}")
                                    })??;
                            let body = acc.with(|mut access| {
                                wasmtime::component::StreamReader::<u8>::new(&mut access, bytes)
                            })?;
                            Ok((HostResponse { status, body },))
                        })
                    },
                )
                .map_err(|e| format_err!("link {iface}#{func_name}: {e}"))?;
                continue;
            }
            if echo {
                inst.func_wrap_concurrent(
                    &func_name,
                    move |acc: &Accessor<StoreLimits>, (arg,): (String,)| {
                        let ms = scale(entry_delay);
                        let items = arg.into_bytes();
                        Box::pin(async move {
                            if ms > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                            }
                            let body = acc.with(|mut access| {
                                wasmtime::component::StreamReader::<u8>::new(&mut access, items)
                            })?;
                            Ok((HostResponse { status, body },))
                        })
                    },
                )
                .map_err(|e| format_err!("link {iface}#{func_name}: {e}"))?;
                continue;
            }
            inst.func_wrap_concurrent(
                &func_name,
                move |acc: &Accessor<StoreLimits>, _params: ()| {
                    let ms = scale(entry_delay);
                    let items = body.clone();
                    Box::pin(async move {
                        if ms > 0 {
                            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                        }
                        let body = acc.with(|mut access| {
                            wasmtime::component::StreamReader::<u8>::new(&mut access, items)
                        })?;
                        Ok((HostResponse { status, body },))
                    })
                },
            )
            .map_err(|e| format_err!("link {iface}#{func_name}: {e}"))?;
        }
    }
    // ADR-0089 Decision 3 (#1218): host-supplied `stream<u8>`. Every entry
    // in VIBE_ASYNC_STREAMS="name=b1|b2|b3[@delay_ms]" links a root import
    // `name: func() -> stream<u8>` whose producer is exactly those bytes,
    // then end-of-stream. Born as the D3 terminal probe's host half (what
    // does `stream.read` report at EOS under wasmtime 47? -- measured:
    // amount 0 / code 1, inline) and now also the host side of the
    // `host_stream_named` guest surface.
    //
    // Without `@delay_ms` the producer is wasmtime's own `Vec<u8>`
    // StreamProducer impl (everything delivered on the first poll -- the
    // probe deliberately measures the RUNTIME's behavior, so keep it
    // unhosted). With `@delay_ms` each byte is preceded by that delay via
    // the custom producer below, which is what makes PARKING observable: a
    // reader that never suspends would still get the right sum, but the
    // wall clock could not reach bytes*delay. The delay is scaled like
    // every other suspend here (VIBE_ASYNC_DELAY_SCALE_PCT).
    if let Ok(spec) = std::env::var("VIBE_ASYNC_STREAMS") {
        for ent in spec.split(',').filter(|s| !s.trim().is_empty()) {
            let (name, rest) = ent.split_once('=').ok_or_else(|| {
                format_err!("VIBE_ASYNC_STREAMS entry '{ent}': expected name=b1|b2|b3[@delay_ms]")
            })?;
            let name = name.trim().to_string();
            // Same reserved set as VIBE_ASYNC_FUTURES: these root imports are
            // registered unconditionally above and the linker rejects
            // shadowing (measured on the future side, #1337 Codex review).
            if matches!(
                name.as_str(),
                "get-future" | "get-async" | "get-after" | "sleep-for"
            ) {
                bail!(
                    "VIBE_ASYNC_STREAMS '{name}': that name is one of the runner's \
                     built-in imports (get-future, get-async, get-after, sleep-for) and \
                     cannot be redefined -- rename the host stream"
                );
            }
            let (bytes_s, delay_s) = match rest.split_once('@') {
                Some((b, d)) => (b, Some(d)),
                None => (rest, None),
            };
            let mut bytes: Vec<u8> = Vec::new();
            for b in bytes_s.split('|').filter(|s| !s.trim().is_empty()) {
                bytes.push(
                    b.trim()
                        .parse()
                        .map_err(|e| format_err!("VIBE_ASYNC_STREAMS '{name}': bad byte: {e}"))?,
                );
            }
            let per_byte_delay: u64 = match delay_s {
                Some(d) => d
                    .trim()
                    .parse()
                    .map_err(|e| format_err!("VIBE_ASYNC_STREAMS '{name}': bad delay: {e}"))?,
                None => 0,
            };
            // Leaked for the same reason as the named-future link above.
            let link_name: &'static str = Box::leak(name.clone().into_boxed_str());
            let scaled_delay = scale(per_byte_delay);
            linker
                .root()
                .func_wrap_concurrent(
                    link_name,
                    move |acc: &Accessor<StoreLimits>, _params: ()| {
                        let items = bytes.clone();
                        Box::pin(async move {
                            let reader = acc.with(|mut access| {
                                if scaled_delay > 0 {
                                    wasmtime::component::StreamReader::<u8>::new(
                                        &mut access,
                                        DelayedByteStreamProducer {
                                            bytes: items,
                                            idx: 0,
                                            delay: std::time::Duration::from_millis(scaled_delay),
                                            sleep: None,
                                        },
                                    )
                                } else {
                                    wasmtime::component::StreamReader::<u8>::new(&mut access, items)
                                }
                            })?;
                            Ok((reader,))
                        })
                    },
                )
                .map_err(|e| format_err!("link {name}: {e}"))?;
        }
    }

    // A current-thread runtime is enough (and keeps this off the thread pool):
    // the only await points are this timer and wasmtime's own event loop.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .map_err(|e| format_err!("tokio runtime: {e}"))?;

    let result: u32 = rt.block_on(async {
        let mut store = Store::new(&engine, store_mem_limits());
        store.limiter(|s| s);
        let instance = linker.instantiate_async(&mut store, &component).await?;
        let run = instance.get_typed_func::<(), (u32,)>(&mut store, "run")?;
        let (value,) = store
            .run_concurrent(async move |accessor| run.call_concurrent(accessor, ()).await)
            .await??;
        Ok::<u32, wasmtime::Error>(value)
    })?;

    println!("{result}");
    Ok(0)
}

pub(super) fn load_module(engine: &Engine, path: &str) -> Result<Module> {
    if path.ends_with(".cwasm") {
        // SAFETY: cwasm produced by `viberun --precompile` uses the same
        // engine config above, so deserializing here is sound. Loading a
        // cwasm built with a different wasmtime version / config is UB —
        // don't share cwasm files across toolchain versions.
        unsafe { Module::deserialize_file(engine, path) }
            .map_err(|e| format_err!("deserialize cwasm: {e}"))
    } else {
        Module::from_file(engine, path).map_err(|e| format_err!("from_file: {e}"))
    }
}

// #1230 M1b-3c-2: a Component Model binary and a core module share the
// `\0asm` magic and differ only in the 4 bytes after it -- core modules carry
// version 1 / layer 0 (`01 00 00 00`), components carry version 13 / layer 1
// (`0d 00 01 00`). Everything this runtime did before M1b-3c-2 assumed the
// core-module shape, so a component reached `Module::from_file` and died with
// an opaque parse error. Sniff the header instead and route components to the
// async path. Deliberately byte-level rather than via wasmparser: this is the
// only place the distinction matters and the header is fixed-width.
pub(super) fn is_component_file(path: &str) -> bool {
    // A precompiled .cwasm is always a core module (--precompile only accepts
    // one), and reading it here would just be wasted IO.
    if path.ends_with(".cwasm") {
        return false;
    }
    let mut buf = [0u8; 8];
    let Ok(mut f) = fs::File::open(path) else {
        return false;
    };
    if f.read_exact(&mut buf).is_err() {
        return false;
    }
    buf == [0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00]
}

// Engine configuration for the lazy command lane. Deliberately
// `engine_config()` plus component support and NOTHING else: a `.cwasm`
// produced by `--precompile-component` is only loadable by an engine with a
// matching configuration, so every knob added here invalidates every image
// already on disk. The async/concurrency options `run_async_component` sets
// stay out for the same reason -- command components are synchronous lifts.
pub(super) fn command_engine_config() -> Config {
    let mut cfg = engine_config();
    cfg.wasm_component_model(true);
    cfg
}
