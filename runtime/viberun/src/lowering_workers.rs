//! A bounded wave of independent lowering instances, owned by Vibe TaskGroup.
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use wasmtime::component::{Accessor, Linker, StreamReader};
use wasmtime::{bail, format_err, Result, StoreLimits};

use super::checker_workers::{CheckerProcess, SlotPermit};
use super::component_runtime::HostResponse;

const SLOTS: usize = 4;
const JOBS_PER_SLOT: usize = 16;
const INPUT_BYTES: u64 = 64 * 1024 * 1024;

struct Plan {
    wasm: PathBuf,
    cwd: PathBuf,
    context: Option<PathBuf>,
    queues: Vec<Vec<PathBuf>>,
}

fn path(value: &serde_json::Value) -> Result<PathBuf> {
    let p = Path::new(
        value
            .as_str()
            .ok_or_else(|| format_err!("lowering: expected path"))?,
    );
    if !p.is_absolute() {
        bail!("lowering: expected absolute path");
    }
    let p = p.canonicalize()?;
    if p.to_str().is_none_or(|s| s.contains(['\n', '\r'])) {
        bail!("lowering: paths must be UTF-8 without line breaks");
    }
    Ok(p)
}

impl Plan {
    fn parse(text: &str) -> Result<Self> {
        let v: serde_json::Value = serde_json::from_str(text)?;
        let obj = v
            .as_object()
            .ok_or_else(|| format_err!("lowering: expected plan object"))?;
        let shared = v["version"].as_u64() == Some(2);
        let expected = if shared { 5 } else { 4 };
        if obj.len() != expected
            || obj
                .keys()
                .any(|k| !["version", "wasm", "cwd", "queues", "context"].contains(&k.as_str()))
            || (!shared && (v["version"].as_u64() != Some(1) || obj.contains_key("context")))
        {
            bail!("lowering: unsupported wave plan");
        }
        let context = if shared {
            let context = path(&v["context"])?;
            if !context.is_file() || !(1..=INPUT_BYTES).contains(&context.metadata()?.len()) {
                bail!("lowering: shared context must be a nonempty file within 64 MiB");
            }
            Some(context)
        } else {
            None
        };
        let wasm = path(&v["wasm"])?;
        if std::fs::read(&wasm)?.get(..8) != Some(b"\0asm\x01\0\0\0") {
            bail!("lowering: worker must be a core Wasm module");
        }
        let cwd = path(&v["cwd"])?;
        if !cwd.is_dir() {
            bail!("lowering: cwd must be a directory");
        }
        let rows = v["queues"]
            .as_array()
            .ok_or_else(|| format_err!("lowering: expected queues"))?;
        if rows.len() != SLOTS {
            bail!("lowering: expected four slot queues");
        }
        let mut seen = HashSet::new();
        let mut bytes = 0_u64;
        let mut queues = Vec::new();
        for row in rows {
            let jobs = row
                .as_array()
                .ok_or_else(|| format_err!("lowering: expected job array"))?;
            if jobs.len() > JOBS_PER_SLOT {
                bail!("lowering: wave exceeds job limit");
            }
            let mut queue = Vec::new();
            for job in jobs {
                let job = path(job)?;
                if !job.is_file() || !seen.insert(job.clone()) || product_path(&job).exists() {
                    bail!("lowering: job is missing, duplicated or already has a product");
                }
                bytes = bytes
                    .checked_add(job.metadata()?.len())
                    .ok_or_else(|| format_err!("lowering: input size overflow"))?;
                if bytes > INPUT_BYTES {
                    bail!("lowering: wave exceeds 64 MiB input limit");
                }
                queue.push(job);
            }
            queues.push(queue);
        }
        Ok(Self {
            wasm,
            cwd,
            context,
            queues,
        })
    }
}

fn product_path(job: &Path) -> PathBuf {
    let mut name = job.as_os_str().to_os_string();
    name.push(".product");
    PathBuf::from(name)
}

pub(super) fn link(linker: &mut Linker<StoreLimits>) -> Result<()> {
    let Some(manifest) = std::env::var_os("VIBE_LOWERING_WORKERS") else {
        return Ok(());
    };
    let manifest = PathBuf::from(manifest).canonicalize()?;
    let plan = Arc::new(Plan::parse(&std::fs::read_to_string(&manifest)?)?);
    let info = format!(
        "1,{},{},{},{}",
        plan.queues[0].len(),
        plan.queues[1].len(),
        plan.queues[2].len(),
        plan.queues[3].len()
    )
    .into_bytes();
    let active: Arc<Vec<Arc<AtomicBool>>> = Arc::new(
        (0..SLOTS)
            .map(|_| Arc::new(AtomicBool::new(false)))
            .collect(),
    );
    let consumed: Arc<Vec<AtomicBool>> =
        Arc::new((0..SLOTS).map(|_| AtomicBool::new(false)).collect());
    let mut interface = linker.instance("vibe:lowering/worker@0.0.1")?;
    interface.func_wrap_concurrent("load-plan", move |acc: &Accessor<StoreLimits>, _: ()| {
        let info = info.clone();
        Box::pin(async move {
            let body = acc.with(|mut a| StreamReader::<u8>::new(&mut a, info))?;
            Ok((HostResponse { status: 0, body },))
        })
    })?;
    interface.func_wrap_concurrent(
        "lower",
        move |acc: &Accessor<StoreLimits>, (slot,): (String,)| {
            let plan = plan.clone();
            let active = active.clone();
            let consumed = consumed.clone();
            let manifest = manifest.clone();
            Box::pin(async move {
                let slot = slot.parse::<usize>()?;
                if slot >= SLOTS
                    || plan.queues[slot].is_empty()
                    || consumed[slot].swap(true, Ordering::AcqRel)
                {
                    bail!("lowering: slot is absent or was already consumed");
                }
                active[slot].store(true, Ordering::Release);
                let permit = SlotPermit(active[slot].clone());
                let list = manifest.with_extension(format!("slot-{slot}.list"));
                let text = plan.queues[slot]
                    .iter()
                    .map(|p| p.to_str().unwrap())
                    .collect::<Vec<_>>()
                    .join("\n");
                std::fs::write(&list, text)?;
                let mut child = CheckerProcess::start_lowering(
                    &plan.wasm,
                    &plan.cwd,
                    &list,
                    plan.context.as_deref(),
                    slot,
                    permit,
                )?;
                let code = child.wait().await?;
                if code != 0 {
                    bail!("lowering: worker exited {code}: {}", child.failure_detail());
                }
                for job in &plan.queues[slot] {
                    if product_path(job).metadata()?.len() == 0 {
                        bail!("lowering: missing product");
                    }
                }
                let body = acc.with(|mut a| StreamReader::<u8>::new(&mut a, Vec::<u8>::new()))?;
                Ok((HostResponse {
                    status: plan.queues[slot].len() as i32,
                    body,
                },))
            })
        },
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestDir(PathBuf);
    impl TestDir {
        fn new() -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            loop {
                let path = std::env::temp_dir().join(format!(
                    "vibe-lowering-plan-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
                match std::fs::create_dir(&path) {
                    Ok(()) => return Self(path),
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(e) => panic!("test directory: {e}"),
                }
            }
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn inputs() -> (TestDir, serde_json::Value) {
        let dir = TestDir::new();
        let wasm = dir.path().join("worker.wasm");
        std::fs::write(&wasm, b"\0asm\x01\0\0\0").unwrap();
        let job = dir.path().join("0.job");
        std::fs::write(&job, b"job").unwrap();
        let value = serde_json::json!({ "version": 1, "wasm": wasm,
            "cwd": dir.path(), "queues": [[job], [], [], []] });
        (dir, value)
    }

    #[test]
    fn shared_plan_requires_a_bounded_context_and_exact_version() {
        let (dir, mut value) = inputs();
        let context = dir.path().join("shared.context");
        std::fs::write(&context, b"context").unwrap();
        value["version"] = serde_json::json!(2);
        assert!(Plan::parse(&value.to_string()).is_err());
        value["context"] = serde_json::json!(context);
        assert_eq!(
            Plan::parse(&value.to_string()).unwrap().context,
            Some(context.clone())
        );
        value["version"] = serde_json::json!(1);
        assert!(Plan::parse(&value.to_string()).is_err());
        value["version"] = serde_json::json!(2);
        value["extra"] = serde_json::json!(true);
        assert!(Plan::parse(&value.to_string()).is_err());
        value.as_object_mut().unwrap().remove("extra");
        std::fs::write(&context, b"").unwrap();
        assert!(Plan::parse(&value.to_string()).is_err());
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(&context)
            .unwrap();
        file.set_len(INPUT_BYTES + 1).unwrap();
        assert!(Plan::parse(&value.to_string()).is_err());
        std::fs::remove_file(&context).unwrap();
        assert!(Plan::parse(&value.to_string()).is_err());
    }

    #[test]
    fn rejects_duplicate_and_stale_jobs() {
        let (dir, mut value) = inputs();
        assert!(Plan::parse(&value.to_string()).is_ok());
        value["queues"][1] = value["queues"][0].clone();
        assert!(Plan::parse(&value.to_string())
            .err()
            .unwrap()
            .to_string()
            .contains("duplicated"));
        value["queues"][1] = serde_json::json!([]);
        std::fs::write(dir.path().join("0.job.product"), b"old").unwrap();
        assert!(Plan::parse(&value.to_string()).is_err());
    }

    #[test]
    fn rejects_excess_payload_before_starting_children() {
        let (dir, value) = inputs();
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(dir.path().join("0.job"))
            .unwrap();
        file.set_len(INPUT_BYTES).unwrap();
        assert!(Plan::parse(&value.to_string()).is_ok());
        file.set_len(INPUT_BYTES + 1).unwrap();
        assert!(Plan::parse(&value.to_string())
            .err()
            .unwrap()
            .to_string()
            .contains("64 MiB"));
    }

    #[test]
    fn rejects_unbounded_slot_and_unknown_protocol() {
        let (_dir, mut value) = inputs();
        let job = value["queues"][0][0].clone();
        value["queues"][0] = serde_json::Value::Array(vec![job; JOBS_PER_SLOT + 1]);
        assert!(Plan::parse(&value.to_string())
            .err()
            .unwrap()
            .to_string()
            .contains("job limit"));
        value["version"] = serde_json::json!(2);
        assert!(Plan::parse(&value.to_string()).is_err());
    }
}
