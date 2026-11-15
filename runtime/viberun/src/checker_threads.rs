//! Experimental checker batches on host threads, using the existing TaskGroup
//! dispatch. A wave shares compiled code; each batch owns a fresh guest Store.

use super::checker_workers::{write_batch, SlotPermit, WORKER_ENV_REMOVALS};
use super::diagnostics::{register_imports, withhold_capability_imports};
use super::{
    engine_config, read_heap_ptr, store_mem_limits, wasm_stack_bytes, ExitTrap, HostState,
    MemLimiter,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use wasmtime::{bail, format_err, Engine, Linker, Module, Result, Store, UpdateDeadline};

pub(super) struct BatchImage {
    engine: Engine,
    module: Module,
    env: Arc<HashMap<String, String>>,
    started: Instant,
    trace: bool,
}

impl BatchImage {
    pub(super) fn load(wasm: &Path, cwd: &Path) -> Result<Self> {
        // The process backend can change the child's current directory. The
        // threaded checker uses the coordinator's existing directory.
        if std::env::current_dir()?.canonicalize()? != cwd {
            bail!("threaded checker requires the coordinator's working directory");
        }
        let mut config = engine_config();
        config.epoch_interruption(true);
        let engine = Engine::new(&config)?;
        let module = Module::from_file(&engine, wasm)?;
        for import in module.imports() {
            let allowed = match import.module() {
                "vibe" => matches!(
                    import.name(),
                    "args-get"
                        | "args-len"
                        | "env-get"
                        | "fs_exists"
                        | "fs_is_dir"
                        | "fs_read_bytes"
                        | "fs_read_dir_nul"
                        | "fs_read_file"
                        | "fs_stat_token"
                        | "fs_write_bytes"
                        | "fs_write_file"
                        | "process_exit"
                        | "stderr_write_stream"
                        | "stdout_write_char"
                        | "stdout_write_stream"
                ),
                "wasi_snapshot_preview1" => import.name() == "fd_write",
                _ => false,
            };
            if !allowed {
                bail!(
                    "unsupported threaded checker import: {}::{}",
                    import.module(),
                    import.name()
                );
            }
        }
        let mut env: HashMap<String, String> = std::env::vars_os()
            .filter_map(|(name, value)| Some((name.into_string().ok()?, value.into_string().ok()?)))
            .collect();
        for name in WORKER_ENV_REMOVALS {
            env.remove(name);
        }
        for (name, value) in [
            ("VIBE_MODULE_JOB_DIR", "1"),
            ("VIBE_CHECKER_BATCH", "1"),
            ("VIBE_IMPORT_ABI", "raw"),
            ("VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE", "1"),
        ] {
            env.insert(name.to_owned(), value.to_owned());
        }
        if std::env::var("VIBE_CHECKER_WORKER_MEM").as_deref() == Ok("1") {
            env.insert("VIBE_MEM".to_owned(), "1".to_owned());
        }
        Ok(Self {
            engine,
            module,
            env: Arc::new(env),
            started: Instant::now(),
            trace: std::env::var("VIBE_CHECKER_WORKER_TRACE").as_deref() == Ok("1"),
        })
    }

    pub(super) fn start(
        self: &Arc<Self>,
        jobs: &[PathBuf],
        slot: usize,
        permit: SlotPermit,
    ) -> Result<ThreadBatch> {
        let dir = write_batch(jobs)?;
        let image = self.clone();
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel_in_thread = cancelled.clone();
        let handle = thread::Builder::new()
            .name(format!("vibe-checker-{slot}"))
            .stack_size(wasm_stack_bytes() + 8 * 1024 * 1024)
            .spawn(move || {
                let started = Instant::now();
                image.event("started", slot, started, None, None);
                let result = image.run(&dir, cancel_in_thread.clone());
                let status = if result.is_ok() { 0 } else { 1 };
                let event = if result.is_err() && cancel_in_thread.load(Ordering::Acquire) {
                    "cancelled"
                } else {
                    "finished"
                };
                image.event(
                    event,
                    slot,
                    started,
                    Some(status),
                    result.as_ref().ok().and_then(|m| m.as_ref()),
                );
                result.map(|_| ())
            })?;
        Ok(ThreadBatch {
            handle: Some(handle),
            cancelled,
            engine: self.engine.clone(),
            _permit: permit,
        })
    }

    fn run(&self, dir: &Path, cancelled: Arc<AtomicBool>) -> Result<Option<serde_json::Value>> {
        let dir = dir
            .to_str()
            .ok_or_else(|| format_err!("checker batch path must be UTF-8"))?;
        let args = vec![
            "viberun".to_owned(),
            dir.to_owned(),
            format!("{dir}/worker.out"),
            "__no_entry__".to_owned(),
        ];
        let mut state = HostState::new(args, MemLimiter::new(store_mem_limits()));
        state.guest_env = Some(self.env.clone());
        state.discard_stdout = true;
        state.lowering_inputs = None;
        let mut store = Store::new(&self.engine, state);
        store.limiter(|s| &mut s.mem);
        store.set_epoch_deadline(1);
        let cancel_at_checkpoint = cancelled.clone();
        store.epoch_deadline_callback(move |_| {
            if cancel_at_checkpoint.load(Ordering::Acquire) {
                bail!("threaded checker batch cancelled");
            }
            Ok(UpdateDeadline::Continue(1))
        });
        let mut linker = Linker::new(&self.engine);
        register_imports(&mut linker)?;
        withhold_capability_imports(&mut linker, &self.module)?;
        if cancelled.load(Ordering::Acquire) {
            bail!("threaded checker batch cancelled");
        }
        let instance = linker.instantiate(&mut store, &self.module)?;
        let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;
        let heap_base = if self
            .env
            .get("VIBE_MEM")
            .is_some_and(|setting| setting == "1")
        {
            read_heap_ptr(&instance, &mut store)
        } else {
            None
        };
        if let Err(error) = start.call(&mut store, ()) {
            if !error
                .downcast_ref::<ExitTrap>()
                .is_some_and(|trap| trap.0 == 0)
            {
                return Err(error);
            }
        }
        let memory = if let Some(base) = heap_base {
            let peak = read_heap_ptr(&instance, &mut store);
            let committed = instance
                .get_memory(&mut store, "memory")
                .map(|memory| memory.data_size(&store));
            peak.map(|peak| serde_json::json!({
                "heap_base": base, "heap_peak": peak, "allocated": peak.saturating_sub(base), "committed": committed
            }))
        } else {
            None
        };
        Ok(memory)
    }

    fn event(
        &self,
        event: &str,
        slot: usize,
        started: Instant,
        status: Option<u32>,
        memory: Option<&serde_json::Value>,
    ) {
        if self.trace {
            eprintln!(
                "vibe-checker-worker {}",
                serde_json::json!({
                    "event": event, "slot": slot, "pid": std::process::id(),
                    "thread": format!("{:?}", thread::current().id()),
                    "at_us": self.started.elapsed().as_micros(),
                    "elapsed_us": started.elapsed().as_micros(), "status": status,
                    "cpu_ticks": thread_cpu_ticks(), "memory": memory
                })
            );
        }
    }
}

// Linux exposes CPU time for the calling OS thread, including both user and
// system time. Traces use elapsed overlap plus real CPU ticks to distinguish
// concurrent guest checking from several parked TaskGroup children.
fn thread_cpu_ticks() -> Option<u64> {
    let stat = std::fs::read_to_string("/proc/thread-self/stat").ok()?;
    let (_, fields) = stat.rsplit_once(") ")?;
    let mut fields = fields.split_whitespace().skip(11);
    let user = fields.next()?.parse::<u64>().ok()?;
    let system = fields.next()?.parse::<u64>().ok()?;
    Some(user + system)
}

pub(super) struct ThreadBatch {
    handle: Option<JoinHandle<Result<()>>>,
    cancelled: Arc<AtomicBool>,
    engine: Engine,
    _permit: SlotPermit,
}

impl ThreadBatch {
    pub(super) async fn wait(&mut self) -> Result<()> {
        let Some(handle) = self.handle.as_ref() else {
            bail!("checker thread already joined");
        };
        while !handle.is_finished() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.handle
            .take()
            .unwrap()
            .join()
            .map_err(|_| format_err!("checker thread panicked"))?
    }
}

impl Drop for ThreadBatch {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            self.cancelled.store(true, Ordering::Release);
            self.engine.increment_epoch();
            let _ = handle.join();
        }
    }
}
