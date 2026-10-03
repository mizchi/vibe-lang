//! Experimental CPU workers behind named futures. TaskGroup owns the waits;
//! each future owns one independent checker process and reaps it on cancellation.
//! The coordinator prepares immutable job directories and consumes products.

use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};
use wasmtime::component::{Accessor, FutureProducer, FutureReader, Linker};
use wasmtime::{bail, format_err, Result, StoreContextMut, StoreLimits};

const LABELS: [&str; 4] = ["checker-0", "checker-1", "checker-2", "checker-3"];
const BATCH_SIZE: usize = 16;

struct Slot {
    queue: Mutex<VecDeque<PathBuf>>,
    active: Arc<AtomicBool>,
}

impl Slot {
    fn take(&self, slot: usize, limit: usize) -> Result<(SlotPermit, Vec<PathBuf>)> {
        if self
            .active
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            bail!("checker-{slot}: previous worker is still owned by its future");
        }
        let permit = SlotPermit(self.active.clone());
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| format_err!("checker queue poisoned"))?;
        if queue.is_empty() {
            bail!("checker-{slot}: queue exhausted");
        }
        let count = limit.min(queue.len());
        Ok((permit, queue.drain(..count).collect()))
    }
}

struct Plan {
    wasm: PathBuf,
    cwd: PathBuf,
    queues: Vec<VecDeque<PathBuf>>,
}

fn absolute_path(value: &serde_json::Value, field: &str) -> Result<PathBuf> {
    let path = PathBuf::from(
        value
            .as_str()
            .ok_or_else(|| format_err!("{field}: expected path"))?,
    );
    if !path.is_absolute() {
        bail!("{field}: expected absolute path");
    }
    path.canonicalize().map_err(|e| format_err!("{field}: {e}"))
}

impl Plan {
    fn parse(text: &str) -> Result<Self> {
        let value: serde_json::Value = serde_json::from_str(text)?;
        let object = value
            .as_object()
            .ok_or_else(|| format_err!("worker plan: expected object"))?;
        if object.len() != 4
            || object
                .keys()
                .any(|key| !["version", "wasm", "cwd", "queues"].contains(&key.as_str()))
        {
            bail!("worker plan: expected only version, wasm, cwd and queues");
        }
        if value["version"].as_u64() != Some(1) {
            bail!("worker plan: expected version 1");
        }
        let wasm = absolute_path(&value["wasm"], "wasm")?;
        // A manifest cannot implicitly authorize unsafe native-code loading.
        // Use ordinary Wasm and the runner's validated native compilation cache.
        let bytes = std::fs::read(&wasm)?;
        if bytes.get(..8) != Some(b"\0asm\x01\0\0\0") {
            bail!("worker plan: wasm must be a core Wasm module");
        }
        let cwd = absolute_path(&value["cwd"], "cwd")?;
        if !cwd.is_dir() {
            bail!("worker plan: cwd must be a directory");
        }
        let rows = value["queues"]
            .as_array()
            .ok_or_else(|| format_err!("queues: expected array"))?;
        if rows.len() != LABELS.len() {
            bail!("worker plan: expected four slot queues (unused slots have empty queues)");
        }
        let mut seen = HashSet::new();
        let mut queues = Vec::new();
        for row in rows {
            let jobs = row
                .as_array()
                .ok_or_else(|| format_err!("queue: expected array"))?;
            let mut queue = VecDeque::new();
            for job in jobs {
                let dir = absolute_path(job, "job directory")?;
                if !dir.is_dir()
                    || !dir.join("job.txt").is_file()
                    || !dir.join("source.vibe").is_file()
                {
                    bail!(
                        "worker plan: {} is not a prepared job directory",
                        dir.display()
                    );
                }
                if dir.join("outcome.txt").exists() || !seen.insert(dir.clone()) {
                    bail!("worker plan: {} is stale or listed twice", dir.display());
                }
                queue.push_back(dir);
            }
            queues.push(queue);
        }
        Ok(Self { wasm, cwd, queues })
    }
}

struct CheckerProcess {
    child: Option<Child>,
    sleep: Option<Pin<Box<tokio::time::Sleep>>>,
    slot: usize,
    started: Instant,
    stderr: PathBuf,
    trace: bool,
    permit: Option<SlotPermit>,
}

struct SlotPermit(Arc<AtomicBool>);
impl Drop for SlotPermit {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl CheckerProcess {
    fn start(wasm: &Path, cwd: &Path, job: &Path, slot: usize, permit: SlotPermit) -> Result<Self> {
        Self::start_mode(wasm, cwd, job, slot, permit, false)
    }

    fn start_mode(
        wasm: &Path,
        cwd: &Path,
        job: &Path,
        slot: usize,
        permit: SlotPermit,
        batch: bool,
    ) -> Result<Self> {
        let stderr = std::fs::File::create(job.join("runner.stderr"))?;
        let mut command = Command::new(std::env::current_exe()?);
        command
            .arg(wasm)
            .arg(job)
            .arg(job.join("worker.out"))
            .arg("__no_entry__")
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(stderr)
            .env("VIBE_MODULE_JOB_DIR", "1")
            .env("VIBE_IMPORT_ABI", "raw")
            .env("VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE", "1");
        for name in [
            "VIBE_CHECKER_WORKERS",
            "VIBE_CHECKER_WORKER_TRACE",
            "VIBE_CHECKER_BATCH",
            "VIBE_FS_COMPILE",
            "VIBE_DIAGNOSTICS",
            "VIBE_TYPE_AT",
            "VIBE_BINDING_AT",
            "VIBE_SYMBOLS",
            "VIBE_NORMALIZE",
            "VIBE_COVERAGE",
            "VIBE_DEBUG",
            "VIBE_DEBUG_BREAK",
            "VIBE_EMIT_MODULE_SOURCE",
            "VIBE_GUEST_PROFILE",
            "VIBE_MEM",
            "VIBE_MEM_SAMPLE_MS",
        ] {
            command.env_remove(name);
        }
        if batch {
            command.env("VIBE_CHECKER_BATCH", "1");
        }
        if std::env::var("VIBE_CHECKER_WORKER_MEM").as_deref() == Ok("1") {
            command.env("VIBE_MEM", "1");
        }
        let child = command.spawn()?;
        let trace = std::env::var("VIBE_CHECKER_WORKER_TRACE").as_deref() == Ok("1");
        let this = Self {
            child: Some(child),
            sleep: None,
            slot,
            started: Instant::now(),
            stderr: job.join("runner.stderr"),
            trace,
            permit: Some(permit),
        };
        this.event("started", None);
        Ok(this)
    }

    fn event(&self, event: &str, status: Option<u32>) {
        if self.trace {
            eprintln!(
                "vibe-checker-worker {}",
                serde_json::json!({
                    "event": event, "slot": self.slot, "pid": self.child.as_ref().map(Child::id),
                    "elapsed_us": self.started.elapsed().as_micros(), "status": status,
                    "memory": if event == "finished" { self.memory_report() } else { None }
                })
            );
        }
    }

    // Bound failure output before the frontend removes its private job files.
    fn failure_detail(&self) -> String {
        let mut bytes = Vec::new();
        let read = (|| -> std::io::Result<()> {
            let mut file = std::fs::File::open(&self.stderr)?;
            let length = file.metadata()?.len();
            file.seek(SeekFrom::Start(length.saturating_sub(65536)))?;
            file.take(65536).read_to_end(&mut bytes)?;
            Ok(())
        })();
        match read {
            Ok(()) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(error) => format!("could not read worker stderr: {error}"),
        }
    }

    fn memory_report(&self) -> Option<serde_json::Value> {
        let mut bytes = Vec::new();
        std::fs::File::open(&self.stderr)
            .ok()?
            .take(65536)
            .read_to_end(&mut bytes)
            .ok()?;
        let text = String::from_utf8_lossy(&bytes);
        let line = text
            .lines()
            .find_map(|line| line.strip_prefix("vibe::mem "))?;
        let mut fields = serde_json::Map::new();
        for field in line.split_whitespace() {
            let (name, value) = field.split_once('=')?;
            fields.insert(
                name.to_owned(),
                serde_json::Value::from(value.parse::<u64>().ok()?),
            );
        }
        Some(serde_json::Value::Object(fields))
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // Keep ownership through wait even when kill races with normal exit.
            let _ = child.kill();
            let _ = child.wait();
        }
        self.permit = None;
    }

    async fn wait(&mut self) -> Result<u32> {
        loop {
            match self
                .child
                .as_mut()
                .ok_or_else(|| format_err!("checker child already released"))?
                .try_wait()?
            {
                Some(status) => {
                    let code = status
                        .code()
                        .and_then(|n| u32::try_from(n).ok())
                        .unwrap_or(1);
                    self.event("finished", Some(code));
                    self.child = None;
                    self.permit = None;
                    return Ok(code);
                }
                None => tokio::time::sleep(Duration::from_millis(10)).await,
            }
        }
    }

    fn start_batch(
        wasm: &Path,
        cwd: &Path,
        jobs: &[PathBuf],
        slot: usize,
        permit: SlotPermit,
    ) -> Result<Self> {
        let dir = jobs[0].join("batch-input");
        std::fs::create_dir(&dir)?;
        let mut text = String::from("checked-worker-batch\t1\n");
        for job in jobs {
            let path = job
                .to_str()
                .ok_or_else(|| format_err!("batch job path must be UTF-8"))?;
            if path.contains(['\n', '\r']) {
                bail!("batch job path contains a line break");
            }
            text.push_str(path);
            text.push('\n');
        }
        std::fs::write(dir.join("jobs.list"), text)?;
        // Keep the same supervised child path; the batch flag selects only a
        // bounded list of the already prepared immutable jobs.
        Self::start_mode(wasm, cwd, &dir, slot, permit, true)
    }
}

impl Drop for CheckerProcess {
    fn drop(&mut self) {
        if self.child.is_some() {
            self.event("dropped", None);
        }
        self.stop();
    }
}

impl<D: 'static> FutureProducer<D> for CheckerProcess {
    type Item = u32;
    fn poll_produce(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        _store: StoreContextMut<D>,
        finish: bool,
    ) -> Poll<Result<Option<u32>>> {
        let this = self.get_mut();
        if finish {
            this.event("cancelled", None);
            this.stop();
            return Poll::Ready(Ok(None));
        }
        let Some(child) = this.child.as_mut() else {
            return Poll::Ready(Ok(None));
        };
        match child.try_wait() {
            Ok(Some(status)) => {
                // Signals and failures remain failures; only normal exit 0 succeeds.
                let code = status
                    .code()
                    .and_then(|n| u32::try_from(n).ok())
                    .unwrap_or(1);
                this.event("finished", Some(code));
                this.child = None;
                this.permit = None;
                Poll::Ready(Ok(Some(code)))
            }
            Err(error) => {
                this.stop();
                Poll::Ready(Err(error.into()))
            }
            Ok(None) => {
                let sleep = this
                    .sleep
                    .get_or_insert_with(|| Box::pin(tokio::time::sleep(Duration::from_millis(10))));
                if sleep.as_mut().poll(cx).is_ready() {
                    this.sleep = None;
                    cx.waker().wake_by_ref();
                }
                Poll::Pending
            }
        }
    }
}

pub(super) fn link(linker: &mut Linker<StoreLimits>) -> Result<()> {
    let Some(path) = std::env::var_os("VIBE_CHECKER_WORKERS") else {
        return Ok(());
    };
    let plan = Plan::parse(&std::fs::read_to_string(path)?)?;
    let counts: Vec<usize> = plan
        .queues
        .iter()
        .map(|q| q.len().div_ceil(BATCH_SIZE))
        .collect();
    let slots: Arc<Vec<Slot>> = Arc::new(
        plan.queues
            .into_iter()
            .map(|queue| Slot {
                queue: Mutex::new(queue),
                active: Arc::new(AtomicBool::new(false)),
            })
            .collect(),
    );
    for slot in 0..LABELS.len() {
        let slots = slots.clone();
        let wasm = plan.wasm.clone();
        let cwd = plan.cwd.clone();
        linker.root().func_wrap_concurrent(
            LABELS[slot],
            move |acc: &Accessor<StoreLimits>, _: ()| {
                let slots = slots.clone();
                let wasm = wasm.clone();
                let cwd = cwd.clone();
                Box::pin(async move {
                    let (permit, jobs) = slots[slot].take(slot, 1)?;
                    let producer = CheckerProcess::start(&wasm, &cwd, &jobs[0], slot, permit)?;
                    let reader =
                        acc.with(|mut access| FutureReader::<u32>::new(&mut access, producer))?;
                    Ok((reader,))
                })
            },
        )?;
    }
    let mut interface = linker.instance("vibe:checker/worker@0.0.1")?;
    let info = format!("1,{},{},{},{}", counts[0], counts[1], counts[2], counts[3]).into_bytes();
    interface.func_wrap_concurrent("load-plan", move |acc: &Accessor<StoreLimits>, _: ()| {
        let info = info.clone();
        Box::pin(async move {
            let body = acc.with(|mut access| {
                wasmtime::component::StreamReader::<u8>::new(&mut access, info)
            })?;
            Ok((super::component_runtime::HostResponse { status: 0, body },))
        })
    })?;
    interface.func_wrap_concurrent(
        "check",
        move |acc: &Accessor<StoreLimits>, (slot_text,): (String,)| {
            let slots = slots.clone();
            let wasm = plan.wasm.clone();
            let cwd = plan.cwd.clone();
            Box::pin(async move {
                let slot = slot_text.parse::<usize>()?;
                if slot >= slots.len() {
                    bail!("checker: unknown slot {slot}");
                }
                let (permit, jobs) = slots[slot].take(slot, BATCH_SIZE)?;
                let mut process = CheckerProcess::start_batch(&wasm, &cwd, &jobs, slot, permit)?;
                let code = process.wait().await?;
                if code != 0 {
                    bail!(
                        "checker-{slot}: batch exited {code}: {}",
                        process.failure_detail()
                    );
                }
                let mut diagnosed = 0;
                for job in jobs {
                    match std::fs::read_to_string(job.join("outcome.txt"))?.trim() {
                        "ok" => (),
                        "diag" => diagnosed += 1,
                        other => bail!("checker-{slot}: invalid committed outcome {other:?}"),
                    }
                }
                let body = acc.with(|mut access| {
                    wasmtime::component::StreamReader::<u8>::new(&mut access, Vec::<u8>::new())
                })?;
                Ok((super::component_runtime::HostResponse {
                    status: diagnosed,
                    body,
                },))
            })
        },
    )?;
    Ok(())
}
