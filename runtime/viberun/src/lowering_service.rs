//! Synchronous CPU service: preserve the parent Store and pull/consume one
//! module at a time. Vibe TaskGroup still owns each bounded worker wave.
use super::host_imports::{vibe_alloc_packed_str, vibe_memory, vibe_read_packed_bytes};
use super::source_overlay::source_overlay_read;
use super::HostState;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Instant;
use wasmtime::{bail, format_err, Caller, Result, Val, ValType};

const INPUT_LIMIT: usize = 64 * 1024 * 1024;
const PRODUCT_LIMIT: usize = 256 * 1024 * 1024;
const SLOT_JOBS: usize = 16;
const CONTEXT_VERIFY_CHUNK: usize = 64 * 1024;

// Verification finishes before product callbacks and retains no context-sized
// host allocation while the parent decodes and merges the worker products.
fn verify_shared_context(
    reader: impl Read,
    expected_bytes: usize,
    expected_hash: [u8; 32],
) -> Result<()> {
    if expected_bytes == 0 || expected_bytes > INPUT_LIMIT {
        bail!("lowering: shared context changed after preparation");
    }
    let mut reader = reader.take(INPUT_LIMIT as u64 + 1);
    let mut buffer = [0_u8; CONTEXT_VERIFY_CHUNK];
    let mut hash = Sha256::new();
    let mut bytes = 0;
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        hash.update(&buffer[..count]);
        bytes += count;
    }
    if bytes != expected_bytes || <[u8; 32]>::from(hash.finalize()) != expected_hash {
        bail!("lowering: shared context changed after preparation");
    }
    Ok(())
}

#[derive(Default)]
pub(super) struct InputSnapshot {
    files: BTreeMap<PathBuf, [u8; 32]>,
    directories: BTreeMap<PathBuf, Vec<String>>,
    probes: BTreeMap<(PathBuf, u8), bool>,
    kinds: BTreeMap<PathBuf, Option<u8>>,
    inconsistent: bool,
}

fn absolute(path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir().unwrap().join(path)
    }
}

fn cache_path(path: &Path) -> bool {
    if matches!(
        path.extension().and_then(|s| s.to_str()),
        Some("vibe" | "vpkg")
    ) {
        return false;
    }
    path.starts_with(configured_cache_root(
        std::env::var("VIBE_BUILD_CACHE_DIR").ok(),
    ))
}

fn configured_cache_root(setting: Option<String>) -> PathBuf {
    absolute(
        &setting
            .filter(|root| !root.is_empty())
            .unwrap_or_else(|| ".vibe/build/cache".into()),
    )
}

fn source_kind(path: &Path) -> Option<u8> {
    std::fs::symlink_metadata(path).ok().map(|metadata| {
        let kind = metadata.file_type();
        if kind.is_symlink() {
            1
        } else if kind.is_file() {
            2
        } else if kind.is_dir() {
            3
        } else {
            4
        }
    })
}

impl InputSnapshot {
    fn record_kind(&mut self, path: &Path) {
        let kind = source_kind(path);
        if self
            .kinds
            .insert(path.to_path_buf(), kind)
            .is_some_and(|old| old != kind)
        {
            self.inconsistent = true;
        }
    }

    pub(super) fn stat_file(&mut self, path: &str) {
        let absolute = absolute(path);
        if !cache_path(&absolute) {
            self.record_kind(&absolute);
            if Path::new(path).is_file() {
                if let Ok(bytes) = source_overlay_read(path) {
                    self.file(path, &bytes);
                }
            }
        }
    }
    pub(super) fn file(&mut self, path: &str, data: &[u8]) {
        let path = absolute(path);
        if cache_path(&path) {
            return;
        }
        self.record_kind(&path);
        let digest: [u8; 32] = Sha256::digest(data).into();
        if self
            .files
            .insert(path, digest)
            .is_some_and(|old| old != digest)
        {
            self.inconsistent = true;
        }
    }

    pub(super) fn directory(&mut self, path: &str, names: &[String]) {
        let path = absolute(path);
        if cache_path(&path) {
            return;
        }
        let names: Vec<_> = names
            .iter()
            .filter(|name| !cache_path(&path.join(name)))
            .cloned()
            .collect();
        if self
            .directories
            .insert(path, names.clone())
            .is_some_and(|old| old != names)
        {
            self.inconsistent = true;
        }
    }

    pub(super) fn probe(&mut self, path: &str, kind: u8, answer: bool) {
        let path = absolute(path);
        if cache_path(&path) {
            return;
        }
        if self
            .probes
            .insert((path, kind), answer)
            .is_some_and(|old| old != answer)
        {
            self.inconsistent = true;
        }
    }

    pub(super) fn verify(&self) -> Result<()> {
        let changed = || format_err!("lowering: build inputs changed after preparation; rebuild");
        if self.inconsistent {
            return Err(changed());
        }
        for (path, expected) in &self.kinds {
            if source_kind(path) != *expected {
                return Err(changed());
            }
        }
        for (path, expected) in &self.files {
            let bytes =
                source_overlay_read(&path.to_string_lossy()).map_err(|_| changed())?;
            let actual: [u8; 32] = Sha256::digest(&bytes).into();
            if actual != *expected {
                return Err(changed());
            }
        }
        for (path, expected) in &self.directories {
            let mut names: Vec<String> = std::fs::read_dir(path)
                .map_err(|_| changed())?
                .map(|entry| entry.map(|e| e.file_name().to_string_lossy().into_owned()))
                .collect::<std::io::Result<_>>()
                .map_err(|_| changed())?;
            names.sort();
            names.retain(|name| !cache_path(&path.join(name)));
            if names != *expected {
                return Err(changed());
            }
        }
        for ((path, kind), expected) in &self.probes {
            let actual = match kind {
                0 => path.exists(),
                1 => path.is_file(),
                _ => path.is_dir(),
            };
            if actual != *expected {
                return Err(changed());
            }
        }
        Ok(())
    }
}

fn callback(caller: &mut Caller<'_, HostState>, name: &str, args: &[i64]) -> Result<i64> {
    let function = caller
        .get_export(name)
        .and_then(|e| e.into_func())
        .ok_or_else(|| format_err!("lowering: missing parent callback {name}"))?;
    let ty = function.ty(&*caller);
    let params: Vec<_> = ty.params().collect();
    if !params.iter().all(|t| matches!(t, ValType::I64))
        || ty.results().len() != 1
        || !matches!(ty.results().next(), Some(ValType::I64))
    {
        bail!("lowering: invalid parent callback ABI {name}");
    }
    let mut values: Vec<Val> = args.iter().copied().map(Val::I64).collect();
    if params.len() == values.len() + 1 {
        values.push(Val::I64(0));
    }
    if params.len() != values.len() {
        bail!("lowering: invalid callback arity {name}");
    }
    let mut result = [Val::I64(0)];
    function.call(&mut *caller, &values, &mut result)?;
    Ok(result[0].i64().unwrap())
}

fn config_path(v: &serde_json::Value, key: &str) -> Result<PathBuf> {
    let path = v[key]
        .as_str()
        .ok_or_else(|| format_err!("lowering: missing {key}"))?;
    if !Path::new(path).is_absolute() || path.contains(['\n', '\r']) {
        bail!("lowering: {key} must be an absolute UTF-8 path without line breaks");
    }
    Ok(Path::new(path).canonicalize()?)
}

fn read_product(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take((PRODUCT_LIMIT + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() > PRODUCT_LIMIT {
        bail!("lowering: invalid product size");
    }
    Ok(bytes)
}

fn product_storage(
    caller: &mut Caller<'_, HostState>,
    pointer: i64,
    length: usize,
) -> Result<usize> {
    let base = u32::try_from(pointer)
        .map_err(|_| format_err!("lowering: invalid product allocation pointer"))?
        as usize;
    let memory = vibe_memory(caller)?;
    let mut header = [0_u8; 12];
    memory.read(&*caller, base, &mut header)?;
    let capacity = i32::from_le_bytes(header[..4].try_into().unwrap());
    let current_length = u32::from_le_bytes(header[4..8].try_into().unwrap());
    let data = u32::from_le_bytes(header[8..].try_into().unwrap()) as usize;
    if capacity >= 0
        || (capacity.unsigned_abs() as usize) < length
        || current_length != 0
        || data
            .checked_add(length)
            .is_none_or(|end| end > memory.data_size(&*caller))
    {
        bail!("lowering: invalid product allocation capacity or bounds");
    }
    Ok(data)
}

pub(super) fn run(caller: &mut Caller<'_, HostState>, count: i64) -> Result<i64> {
    if !(1..=65536).contains(&count) || caller.data().lowering_service_used {
        bail!("lowering: invalid or repeated native service invocation");
    }
    let config = std::env::var("VIBE_LOWERING_SERVICE_CONFIG")
        .map_err(|_| format_err!("lowering: native CPU service is not configured"))?;
    if std::env::var("VIBE_UNSTABLE").as_deref() != Ok("1")
        || std::env::var("VIBE_RC").as_deref() != Ok("1")
    {
        bail!("lowering: native CPU service requires unstable RC mode");
    }
    let config: serde_json::Value = serde_json::from_slice(&std::fs::read(config)?)?;
    if config["version"].as_u64() != Some(1) || config.as_object().map(|o| o.len()) != Some(7) {
        bail!("lowering: unsupported native service configuration");
    }
    let worker = config_path(&config, "worker")?;
    let runner = config_path(&config, "runner")?;
    let coordinator = config_path(&config, "coordinator")?;
    let cwd = config_path(&config, "cwd")?;
    let directory = config_path(&config, "directory")?;
    let slots = config["jobs"]
        .as_u64()
        .ok_or_else(|| format_err!("lowering: invalid worker count"))? as usize;
    if ![1, 2, 4].contains(&slots) || !cwd.is_dir() || !directory.is_dir() {
        bail!("lowering: invalid worker count or directories");
    }
    caller.data_mut().lowering_service_used = true;
    let started = caller.data().start_instant.elapsed().as_secs_f64() * 1000.0;
    let service_start = Instant::now();
    let pointer = callback(caller, "lowering_shared_context", &[])?;
    let context = vibe_read_packed_bytes(caller, pointer)?;
    if context.is_empty() || context.len() > INPUT_LIMIT {
        bail!("lowering: shared context exceeds 64 MiB input limit");
    }
    let context_bytes = context.len();
    let context_hash: [u8; 32] = Sha256::digest(&context).into();
    let context_path = directory.join("shared.context");
    std::fs::write(&context_path, context)?;
    callback(caller, "lowering_input_release", &[])?;
    let mut waves = Vec::new();
    let mut next = 0_usize;
    let mut peak_jobs = 0;
    let mut peak_bytes = 0;
    let mut pending = None;
    while next < count as usize {
        let mut queues: Vec<Vec<PathBuf>> = vec![vec![]; 4];
        let mut weights = [0_usize; 4];
        let mut indices = Vec::new();
        let mut total = 0_usize;
        while next < count as usize {
            let pointer = match pending.take() {
                Some(p) => p,
                None => callback(caller, "lowering_job_input", &[(next as i64) << 1])?,
            };
            let input_base = u32::try_from(pointer)
                .map_err(|_| format_err!("lowering: invalid job buffer pointer"))?
                as usize;
            let memory = vibe_memory(caller)?;
            let mut length = [0_u8; 4];
            memory.read(&*caller, input_base + 4, &mut length)?;
            let size = u32::from_le_bytes(length) as usize;
            if size == 0 || size > INPUT_LIMIT {
                bail!("lowering: job exceeds 64 MiB input limit");
            }
            let available = (0..slots)
                .filter(|&s| queues[s].len() < SLOT_JOBS)
                .min_by_key(|&s| weights[s]);
            if available.is_none() || total + size > INPUT_LIMIT {
                pending = Some(pointer);
                break;
            }
            let slot = available.unwrap();
            let path = directory.join(format!("{next}.job"));
            std::fs::write(&path, vibe_read_packed_bytes(caller, pointer)?)?;
            callback(caller, "lowering_input_release", &[])?;
            queues[slot].push(path);
            weights[slot] += size;
            indices.push(next);
            total += size;
            next += 1;
        }
        let wave = directory.join(format!("wave-{}.json", waves.len()));
        std::fs::write(
            &wave,
            serde_json::to_vec(&serde_json::json!({
                "version":2, "wasm":worker, "cwd":cwd, "queues":queues, "context":context_path,
            }))?,
        )?;
        let before = Instant::now();
        let mut child = super::checker_workers::CheckerProcess::start_coordinator(
            &runner,
            &coordinator,
            &cwd,
            &wave,
        )?;
        let exit = child.wait_blocking()?;
        if exit != 0 {
            bail!(
                "lowering: coordinator exited {exit}: {}",
                child.failure_detail()
            );
        }
        caller
            .data()
            .lowering_inputs
            .as_ref()
            .ok_or_else(|| format_err!("lowering: missing input snapshot"))?
            .verify()?;
        verify_shared_context(
            std::fs::File::open(&context_path)?,
            context_bytes,
            context_hash,
        )?;
        for index in &indices {
            let job = directory.join(format!("{index}.job"));
            let product = read_product(&directory.join(format!("{index}.job.product")))?;
            let receipt =
                std::fs::read_to_string(directory.join(format!("{index}.job.product.receipt")))?;
            let receipt: Vec<_> = receipt.split('\t').collect();
            if receipt.len() != 2
                || receipt
                    .iter()
                    .any(|s| s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()))
            {
                bail!("lowering: malformed product receipt");
            }
            let pointer = callback(
                caller,
                "lowering_product_allocate",
                &[(*index as i64) << 1, (product.len() as i64) << 1],
            )?;
            let data = product_storage(caller, pointer, product.len())?;
            let memory = vibe_memory(caller)?;
            memory.write(&mut *caller, data, &product)?;
            memory.write(
                &mut *caller,
                pointer as usize + 4,
                &(product.len() as u32).to_le_bytes(),
            )?;
            let input = vibe_alloc_packed_str(caller, receipt[0])?;
            let digest = vibe_alloc_packed_str(caller, receipt[1])?;
            callback(
                caller,
                "lowering_product_consume",
                &[(*index as i64) << 1, input, digest],
            )?;
            std::fs::remove_file(job)?;
            std::fs::remove_file(directory.join(format!("{index}.job.product")))?;
        }
        peak_jobs = peak_jobs.max(indices.len());
        peak_bytes = peak_bytes.max(total);
        waves.push(serde_json::json!({"jobs":indices.len(),"input_bytes":total,"wall_ms":before.elapsed().as_secs_f64()*1000.0}));
    }
    let report = serde_json::json!({"modules":count,"workers":slots,"peak_queued_jobs":peak_jobs,
        "peak_queued_input_bytes":peak_bytes,"shared_context_bytes":context_bytes,"context_serialization_count":1,"prepare_ms":started,"worker_ms":service_start.elapsed().as_secs_f64()*1000.0,
        "replay_ms":0,"preparation_count":1,"waves":waves,
        "phase_scope":"prepare: one parent preparation; worker: encoding, bounded TaskGroup waves, decoding and merging; finalize: global passes, codegen, source verification and private output write"});
    let report_path = directory.join("service-report.json");
    std::fs::write(&report_path, serde_json::to_vec(&report)?)?;
    caller.data_mut().lowering_finalize = Some((Instant::now(), report_path));
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_verification_checks_all_raw_bytes_and_length() {
        let bytes: Vec<u8> = (0..CONTEXT_VERIFY_CHUNK * 3 + 17)
            .map(|i| (i % 256) as u8)
            .collect();
        let expected = Sha256::digest(&bytes).into();
        verify_shared_context(bytes.as_slice(), bytes.len(), expected).unwrap();
        for position in [0, CONTEXT_VERIFY_CHUNK, bytes.len() - 1] {
            let mut changed = bytes.clone();
            changed[position] ^= 1;
            let error =
                verify_shared_context(changed.as_slice(), bytes.len(), expected).unwrap_err();
            assert_eq!(
                error.to_string(),
                "lowering: shared context changed after preparation"
            );
        }
        assert!(verify_shared_context(&bytes[..bytes.len() - 1], bytes.len(), expected).is_err());
        let mut extra = bytes.clone();
        extra.push(0);
        assert!(verify_shared_context(extra.as_slice(), bytes.len(), expected).is_err());
        assert!(verify_shared_context(bytes.as_slice(), 0, expected).is_err());
        assert!(verify_shared_context(bytes.as_slice(), INPUT_LIMIT + 1, expected).is_err());
    }

    // A generated stream checks actual Read requests and the total input bound
    // independently of the verifier's hash loop. read_to_end grows its request
    // beyond this budget and must fail this test, even if it drops its Vec early.
    struct ContextReader {
        remaining: usize,
        read_bytes: usize,
        largest_request: usize,
        short_read: usize,
        interrupt_next: bool,
        fail_after: Option<usize>,
    }

    impl ContextReader {
        fn new(bytes: usize) -> Self {
            Self {
                remaining: bytes,
                read_bytes: 0,
                largest_request: 0,
                short_read: usize::MAX,
                interrupt_next: false,
                fail_after: None,
            }
        }
    }

    impl Read for ContextReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.largest_request = self.largest_request.max(buffer.len());
            if buffer.len() > CONTEXT_VERIFY_CHUNK {
                return Err(std::io::Error::other("context read request exceeds 64 KiB"));
            }
            if self.interrupt_next {
                self.interrupt_next = false;
                return Err(std::io::ErrorKind::Interrupted.into());
            }
            if self.fail_after.is_some_and(|end| self.read_bytes >= end) {
                return Err(std::io::Error::other("injected context read failure"));
            }
            let count = self.remaining.min(buffer.len()).min(self.short_read);
            buffer[..count].fill(0xa5);
            self.remaining -= count;
            self.read_bytes += count;
            if self.short_read != usize::MAX && count != 0 {
                self.interrupt_next = true;
            }
            Ok(count)
        }
    }

    #[test]
    fn context_verification_has_bounded_read_requests() {
        let bytes = vec![0xa5; CONTEXT_VERIFY_CHUNK * 4 + 19];
        let mut reader = ContextReader::new(bytes.len());
        verify_shared_context(&mut reader, bytes.len(), Sha256::digest(&bytes).into()).unwrap();
        assert_eq!(reader.read_bytes, bytes.len());
        assert!(reader.largest_request <= CONTEXT_VERIFY_CHUNK);
    }

    #[test]
    fn context_verification_retries_interrupted_and_short_reads() {
        let bytes = vec![0xa5; CONTEXT_VERIFY_CHUNK + 11];
        let mut reader = ContextReader::new(bytes.len());
        reader.short_read = 7;
        reader.interrupt_next = true;
        verify_shared_context(&mut reader, bytes.len(), Sha256::digest(&bytes).into()).unwrap();
        assert_eq!(reader.read_bytes, bytes.len());
    }

    #[test]
    fn context_verification_propagates_partial_io_failure() {
        let mut reader = ContextReader::new(CONTEXT_VERIFY_CHUNK * 4);
        reader.fail_after = Some(CONTEXT_VERIFY_CHUNK);
        let error =
            verify_shared_context(&mut reader, CONTEXT_VERIFY_CHUNK * 4, [0; 32]).unwrap_err();
        assert_eq!(error.to_string(), "injected context read failure");
        assert_eq!(reader.read_bytes, CONTEXT_VERIFY_CHUNK);
    }

    #[test]
    fn context_verification_bounds_untrusted_input() {
        let mut hash = Sha256::new();
        for _ in 0..INPUT_LIMIT / 1024 {
            hash.update([0xa5; 1024]);
        }
        let mut exact = ContextReader::new(INPUT_LIMIT);
        verify_shared_context(&mut exact, INPUT_LIMIT, hash.finalize().into()).unwrap();
        assert_eq!(exact.read_bytes, INPUT_LIMIT);
        let mut reader = ContextReader::new(INPUT_LIMIT * 2);
        assert!(verify_shared_context(&mut reader, INPUT_LIMIT, [0; 32]).is_err());
        assert_eq!(reader.read_bytes, INPUT_LIMIT + 1);
        assert!(reader.largest_request <= CONTEXT_VERIFY_CHUNK);
        let mut reader = ContextReader::new(INPUT_LIMIT + 1);
        assert!(verify_shared_context(&mut reader, INPUT_LIMIT + 1, [0; 32]).is_err());
        assert_eq!(reader.read_bytes, 0);
    }

    #[test]
    fn empty_cache_setting_uses_default_namespace() {
        assert_eq!(
            configured_cache_root(Some(String::new())),
            absolute(".vibe/build/cache")
        );
    }

    #[test]
    fn parent_callback_keeps_arguments_before_trailing_environment() {
        let engine = wasmtime::Engine::default();
        let module = wasmtime::Module::new(
            &engine,
            r#"
            (module
              (import "test" "invoke" (func $invoke (result i64)))
              (func (export "parent") (param i64 i64 i64) (result i64)
                local.get 0 local.get 1 i64.sub local.get 2 i64.add)
              (func (export "run") (result i64) call $invoke))
        "#,
        )
        .unwrap();
        let mut linker = wasmtime::Linker::new(&engine);
        linker
            .func_wrap("test", "invoke", |mut caller: Caller<'_, HostState>| {
                callback(&mut caller, "parent", &[18, 6])
            })
            .unwrap();
        let limits = wasmtime::StoreLimitsBuilder::new().build();
        let host = HostState::new(vec![], super::super::MemLimiter::new(limits));
        let mut store = wasmtime::Store::new(&engine, host);
        let instance = linker.instantiate(&mut store, &module).unwrap();
        let run = instance
            .get_typed_func::<(), i64>(&mut store, "run")
            .unwrap();
        assert_eq!(run.call(&mut store, ()).unwrap(), 12);
    }

    // Exercise contents, not just mtimes: a same-length edit must refuse.
    #[test]
    fn snapshot_refuses_source_and_contract_changes() {
        let directory =
            std::env::temp_dir().join(format!("vibe-lowering-snapshot-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        for name in ["module.vibe", "index.vpkg"] {
            let path = directory.join(name);
            std::fs::write(&path, b"first").unwrap();
            let mut snapshot = InputSnapshot::default();
            snapshot.file(path.to_str().unwrap(), b"first");
            snapshot.verify().unwrap();
            std::fs::write(&path, b"other").unwrap();
            assert!(snapshot
                .verify()
                .unwrap_err()
                .to_string()
                .contains("inputs changed after preparation"));
        }
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn snapshot_refuses_inconsistent_reads() {
        let mut snapshot = InputSnapshot::default();
        snapshot.file("snapshot-read.vibe", b"first");
        snapshot.file("snapshot-read.vibe", b"other");
        assert!(snapshot.verify().is_err());
    }

    #[cfg(unix)]
    #[test]
    fn snapshot_refuses_identical_symlink_replacement() {
        use std::os::unix::fs::symlink;
        let directory =
            std::env::temp_dir().join(format!("vibe-lowering-source-kind-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        for name in ["module.vibe", "index.vpkg"] {
            let path = directory.join(name);
            let target = directory.join(format!("{name}.target"));
            std::fs::write(&path, b"same source").unwrap();
            std::fs::write(&target, b"same source").unwrap();
            let mut snapshot = InputSnapshot::default();
            snapshot.stat_file(path.to_str().unwrap());
            snapshot.file(path.to_str().unwrap(), b"same source");
            snapshot.verify().unwrap();
            std::fs::remove_file(&path).unwrap();
            symlink(&target, &path).unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), b"same source");
            assert!(snapshot.verify().is_err(), "{name} became a symlink");
        }
        std::fs::remove_dir_all(directory).unwrap();
    }
}
