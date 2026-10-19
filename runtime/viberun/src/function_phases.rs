//! Returning preparation -> dropped Store -> CPU wave -> fresh owned finisher.
//! Engine/module code may be shared. Invocation and receipt values contain no
//! Store-bound handles; the ordinary run_core cleanup owns every guest lifetime.
use super::*;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};

const INPUT_LIMIT: usize = 64 * 1024 * 1024;
const PRODUCT_LIMIT: usize = 256 * 1024 * 1024;
const RECEIPT_LIMIT: usize = 1024;
const ABI: &str = "vibe-function-phases-1-init-only-bump";

#[derive(Default)]
pub(super) struct SharedRuntime {
    pub(super) path: Option<String>,
    pub(super) loaded: Option<(Engine, Module)>,
}

pub(super) struct StoreLifetime(Arc<AtomicBool>);
impl Drop for StoreLifetime {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[derive(Clone)]
pub(super) struct ArtifactReads {
    paths: BTreeMap<PathBuf, usize>,
    products: BTreeSet<PathBuf>,
    remaining: Arc<std::sync::Mutex<usize>>,
    denied: Arc<AtomicBool>,
}

impl ArtifactReads {
    fn new(paths: BTreeMap<PathBuf, usize>) -> Self {
        Self {
            paths,
            products: BTreeSet::new(),
            remaining: Arc::new(std::sync::Mutex::new(PRODUCT_LIMIT)),
            denied: Arc::new(AtomicBool::new(false)),
        }
    }
}

// The finisher has no reason to probe a source, list a module directory, write
// a file, resolve imports or recursively enter the old synchronous CPU service.
pub(super) fn restrict_finisher(
    linker: &mut Linker<HostState>,
    module: &Module,
    scope: &ArtifactReads,
) -> Result<()> {
    linker.allow_shadowing(true);
    for import in module.imports() {
        let name = import.name();
        let refused = match import.module() {
            "vibe" => {
                (name.starts_with("fs_") && name != "fs_read_file" && name != "fs_read_bytes")
                    || name == "resolve_path"
                    || name == "compiler_lowering_run"
            }
            "__moonbit_fs_unstable" => true,
            "wasi_snapshot_preview1" => !matches!(
                name,
                "fd_write"
                    | "args_get"
                    | "args_sizes_get"
                    | "environ_get"
                    | "environ_sizes_get"
                    | "proc_exit"
                    | "clock_time_get"
            ),
            _ => false,
        };
        if !refused {
            continue;
        }
        let ExternType::Func(ty) = import.ty() else {
            continue;
        };
        let denied = Arc::clone(&scope.denied);
        let message = format!("function finisher cannot use source or output capability {name}");
        linker.func_new(
            import.module(),
            name,
            ty,
            move |_caller, _args, _results| {
                denied.store(true, Ordering::SeqCst);
                bail!("{message}")
            },
        )?;
    }
    linker.allow_shadowing(false);
    Ok(())
}

pub(super) fn read_input(scope: Option<&ArtifactReads>, path: &str) -> io::Result<Vec<u8>> {
    let Some(scope) = scope else {
        return source_overlay::source_overlay_read(path);
    };
    let result = (|| -> io::Result<Vec<u8>> {
        let canonical = fs::canonicalize(path)?;
        let limit = scope.paths.get(&canonical).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                "function finisher may only read its admitted owned artifacts",
            )
        })?;
        // Charge actual returned bytes, including repeated reads. The streamed
        // preflight alone cannot bound a file replaced before the guest reads.
        let mut remaining = if scope.products.contains(&canonical) {
            Some(
                scope
                    .remaining
                    .lock()
                    .map_err(|_| io::Error::other("function product budget lock poisoned"))?,
            )
        } else {
            None
        };
        let allowed = remaining.as_ref().map_or(*limit, |n| (*limit).min(**n));
        let mut bytes = Vec::new();
        fs::File::open(canonical)?
            .take((allowed as u64) + 1)
            .read_to_end(&mut bytes)?;
        if bytes.is_empty() || bytes.len() > allowed {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "function phase artifact exceeds its byte limit",
            ));
        }
        if let Some(remaining) = remaining.as_mut() {
            **remaining -= bytes.len();
        }
        Ok(bytes)
    })();
    if result.is_err() {
        scope.denied.store(true, Ordering::SeqCst);
    }
    result
}

/// Only plain owned bytes, observations and counters escape run_core.
pub(super) struct Invocation {
    export: &'static str,
    request: Vec<u8>,
    pub(super) reads: Option<ArtifactReads>,
    response: Vec<u8>,
    inputs: Option<lowering_service::InputSnapshot>,
    scope: Option<HostFsScope>,
    live: Arc<AtomicBool>,
    heap_end: Option<u64>,
    memory_bytes: Option<usize>,
}

fn call_i64(
    instance: &Instance,
    store: &mut Store<HostState>,
    name: &str,
    args: &[i64],
) -> Result<i64> {
    let function = instance
        .get_func(&mut *store, name)
        .ok_or_else(|| format_err!("missing returning phase export {name}"))?;
    let ty = function.ty(&*store);
    let params: Vec<_> = ty.params().collect();
    if !params.iter().all(|t| matches!(t, ValType::I64))
        || ty.results().len() != 1
        || !matches!(ty.results().next(), Some(ValType::I64))
    {
        bail!("invalid returning phase ABI for {name}");
    }
    let mut values: Vec<_> = args.iter().copied().map(Val::I64).collect();
    if params.len() == values.len() + 1 {
        values.push(Val::I64(0));
    }
    if params.len() != values.len() {
        bail!("invalid phase arity for {name}");
    }
    let mut result = [Val::I64(0)];
    function.call(&mut *store, &values, &mut result)?;
    Ok(result[0].i64().unwrap())
}

fn call_phase(
    instance: &Instance,
    store: &mut Store<HostState>,
    name: &str,
    args: &[i64],
) -> Result<i64> {
    match call_i64(instance, store, name, args) {
        Ok(value) => Ok(value),
        Err(error) => {
            // The failed invocation has returned: querying diagnostic data is
            // a new normal call, not reentry through an active Caller.
            let message = (|| -> Result<String> {
                if instance
                    .get_func(&mut *store, "function_phase_error")
                    .is_none()
                {
                    return Ok(String::new());
                }
                let packed = call_i64(instance, store, "function_phase_error", &[])? as u64;
                let n = (packed & 0xffff_ffff) as usize;
                if n > 65536 {
                    return Ok(String::new());
                }
                let at = (packed >> 32) as usize;
                let mut bytes = vec![0; n];
                memory(instance, store)?.read(&*store, at, &mut bytes)?;
                Ok(String::from_utf8(bytes).unwrap_or_default())
            })()
            .unwrap_or_default();
            if message.is_empty() {
                Err(error)
            } else {
                Err(error.context(format!("function phase {name}: {message}")))
            }
        }
    }
}

fn memory(instance: &Instance, store: &mut Store<HostState>) -> Result<wasmtime::Memory> {
    instance
        .get_memory(store, "memory")
        .ok_or_else(|| format_err!("phase has no memory"))
}

fn returned_bytes(
    instance: &Instance,
    store: &mut Store<HostState>,
    pointer: i64,
    limit: usize,
) -> Result<Vec<u8>> {
    let base =
        u32::try_from(pointer).map_err(|_| format_err!("invalid phase byte pointer"))? as usize;
    let mem = memory(instance, store)?;
    let mut header = [0u8; 12];
    mem.read(&*store, base, &mut header)?;
    let n = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    let at = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
    if n == 0
        || n > limit
        || at
            .checked_add(n)
            .is_none_or(|end| end > mem.data_size(&*store))
    {
        bail!("invalid phase result size or bounds");
    }
    let mut result = vec![0u8; n];
    mem.read(&*store, at, &mut result)?;
    Ok(result)
}

impl Invocation {
    pub(super) fn profile_path(&self, path: String) -> String {
        format!("{path}.{}", self.export)
    }
    fn new(export: &'static str, request: Vec<u8>, reads: Option<ArtifactReads>) -> Self {
        Self {
            export,
            request,
            reads,
            response: vec![],
            inputs: None,
            scope: None,
            live: Arc::new(AtomicBool::new(false)),
            heap_end: None,
            memory_bytes: None,
        }
    }
    pub(super) fn store_lifetime(&self) -> Result<StoreLifetime> {
        if self.live.swap(true, Ordering::SeqCst) {
            bail!("phase Store already live");
        }
        Ok(StoreLifetime(Arc::clone(&self.live)))
    }
    pub(super) fn before_start(
        &self,
        instance: &Instance,
        store: &mut Store<HostState>,
    ) -> Result<()> {
        let packed = call_i64(instance, store, "function_phase_abi", &[])? as u64;
        let n = (packed & 0xffff_ffff) as usize;
        let at = (packed >> 32) as usize;
        if n != ABI.len() {
            bail!("unsupported returning phase marker");
        }
        let mut value = vec![0; n];
        memory(instance, store)?.read(&*store, at, &mut value)?;
        if value != ABI.as_bytes() {
            bail!("unsupported returning phase marker");
        }
        Ok(())
    }
    pub(super) fn after_start(
        &mut self,
        instance: &Instance,
        store: &mut Store<HostState>,
    ) -> Result<()> {
        if !store
            .data()
            .lowering_inputs
            .as_ref()
            .is_some_and(|inputs| inputs.is_empty())
        {
            bail!("returning phase _start must only initialize; it read source inputs");
        }
        let mut args = vec![];
        if !self.request.is_empty() {
            if self.request.len() > RECEIPT_LIMIT {
                bail!("phase receipt exceeds limit");
            }
            let pointer = call_i64(
                instance,
                store,
                "function_phase_allocate",
                &[(self.request.len() as i64) << 1],
            )?;
            let base = u32::try_from(pointer)
                .map_err(|_| format_err!("invalid phase request pointer"))?
                as usize;
            let mem = memory(instance, store)?;
            let mut header = [0u8; 12];
            mem.read(&*store, base, &mut header)?;
            let cap = i32::from_le_bytes(header[..4].try_into().unwrap());
            let n = u32::from_le_bytes(header[4..8].try_into().unwrap());
            let at = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
            if cap >= 0
                || (cap.unsigned_abs() as usize) < self.request.len()
                || n != 0
                || at
                    .checked_add(self.request.len())
                    .is_none_or(|end| end > mem.data_size(&*store))
            {
                bail!("invalid phase request allocation");
            }
            mem.write(&mut *store, at, &self.request)?;
            mem.write(
                &mut *store,
                base + 4,
                &(self.request.len() as u32).to_le_bytes(),
            )?;
            args.push(pointer);
        }
        let value = call_phase(instance, store, self.export, &args).map_err(|error| {
            if self
                .reads
                .as_ref()
                .is_some_and(|scope| scope.denied.load(Ordering::SeqCst))
            {
                let display = error.to_string();
                let reason = if display.starts_with("function phase ") {
                    display
                } else {
                    error.root_cause().to_string()
                };
                error.context(format!("function finisher refused access: {reason}"))
            } else {
                error
            }
        })?;
        if self
            .reads
            .as_ref()
            .is_some_and(|scope| scope.denied.load(Ordering::SeqCst))
        {
            bail!("function finisher suppressed an admitted-artifact refusal");
        }
        let limit = if self.export == "function_phase_prepare" {
            RECEIPT_LIMIT
        } else {
            PRODUCT_LIMIT
        };
        self.response = returned_bytes(instance, store, value, limit)?;
        self.heap_end = read_heap_ptr(instance, store);
        self.memory_bytes = Some(memory(instance, store)?.data_size(&*store));
        self.inputs = store.data_mut().lowering_inputs.take();
        self.scope = store.data_mut().host_fs_scope.take();
        Ok(())
    }
    fn execute(&mut self, path: &str, runtime: &mut SharedRuntime) -> Result<()> {
        let code = super::run_core(vec![path.to_owned()], Some(runtime), Some(self))?;
        // run_core has returned through its sampler/profiler/diagnostic cleanup.
        // Its local Store and Instance have been destroyed before this check.
        if self.live.load(Ordering::SeqCst) {
            bail!("phase Store escaped its invocation");
        }
        if code != 0 || self.response.is_empty() {
            bail!("returning phase {} failed ({code})", self.export);
        }
        self.inputs
            .as_ref()
            .ok_or_else(|| format_err!("missing phase observations"))?
            .verify()?;
        Ok(())
    }
}

#[derive(Debug)]
struct Receipt {
    functions: u32,
    lambdas: u32,
    jobs: usize,
}
fn parse_receipt(bytes: &[u8]) -> Result<Receipt> {
    fn varint(bytes: &[u8], at: &mut usize) -> Result<u32> {
        let mut value = 0u32;
        for shift in (0..35).step_by(7) {
            let b = *bytes
                .get(*at)
                .ok_or_else(|| format_err!("short original phase receipt"))?;
            *at += 1;
            if shift == 28 && b > 15 {
                bail!("phase receipt integer overflow");
            }
            value |= u32::from(b & 127) << shift;
            if b & 128 == 0 {
                return Ok(value);
            }
        }
        bail!("phase receipt integer overflow")
    }
    fn text<'a>(bytes: &'a [u8], at: &mut usize) -> Result<&'a [u8]> {
        let n = varint(bytes, at)? as usize;
        let end = at
            .checked_add(n)
            .ok_or_else(|| format_err!("receipt span overflow"))?;
        let value = bytes
            .get(*at..end)
            .ok_or_else(|| format_err!("short receipt string"))?;
        *at = end;
        Ok(value)
    }
    if bytes.len() > RECEIPT_LIMIT {
        bail!("original phase receipt exceeds limit");
    }
    let mut at = 0;
    if text(bytes, &mut at)? != b"vibe-function-phases-1" {
        bail!("unsupported phase receipt");
    }
    let functions = varint(bytes, &mut at)?;
    let lambdas = varint(bytes, &mut at)?;
    let jobs = varint(bytes, &mut at)? as usize;
    if functions == 0 || ![1, 2, 4].contains(&jobs) {
        bail!("invalid original phase counts");
    }
    for _ in 0..jobs + 2 {
        let value = text(bytes, &mut at)?;
        if value.len() != 64
            || !value
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        {
            bail!("invalid original phase digest");
        }
    }
    if at != bytes.len() {
        bail!("trailing original phase receipt bytes");
    }
    Ok(Receipt {
        functions,
        lambdas,
        jobs,
    })
}

fn configured_path(config: &serde_json::Value, name: &str) -> Result<PathBuf> {
    let value = config[name]
        .as_str()
        .ok_or_else(|| format_err!("missing phase {name}"))?;
    if !PathBuf::from(value).is_absolute() || value.contains(['\r', '\n']) {
        bail!("phase {name} must be an absolute path without line breaks");
    }
    Ok(fs::canonicalize(value)?)
}
fn hash_file(path: &PathBuf, limit: usize) -> Result<(usize, [u8; 32])> {
    let mut file = fs::File::open(path)?.take(limit as u64 + 1);
    let mut buf = [0u8; 64 * 1024];
    let mut hash = Sha256::new();
    let mut total = 0usize;
    loop {
        let n = match file.read(&mut buf) {
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        if n == 0 {
            break;
        }
        total += n;
        hash.update(&buf[..n]);
    }
    if total == 0 || total > limit {
        bail!("phase artifact exceeds its byte limit: {}", path.display());
    }
    Ok((total, hash.finalize().into()))
}

type ArtifactSnapshot = (PathBuf, usize, (usize, [u8; 32]));

// Run after original source/context checks, before any finisher Store exists.
// Stream every product with fixed scratch; keep identities, never product Vecs.
fn capture_products(
    directory: &PathBuf,
    slots: usize,
    limit: usize,
) -> Result<(Vec<ArtifactSnapshot>, usize)> {
    let mut snapshots = Vec::new();
    let mut total = 0usize;
    for index in 0..slots {
        let path = directory.join(format!("{index}.job.product"));
        let identity = hash_file(&path, limit.saturating_sub(total)).map_err(|error| {
            error.context("completed phase products exceed256MiB or are unreadable")
        })?;
        total = total
            .checked_add(identity.0)
            .ok_or_else(|| format_err!("completed phase product byte count overflow"))?;
        if total > limit {
            bail!("completed phase products exceed256MiB");
        }
        snapshots.push((path, PRODUCT_LIMIT, identity));
        let path = directory.join(format!("{index}.job.product.receipt"));
        let identity = hash_file(&path, 129)?;
        snapshots.push((path, 129, identity));
    }
    Ok((snapshots, total))
}

fn merge_scope(total: &mut Option<HostFsScope>, next: Option<HostFsScope>) {
    if let Some(next) = next {
        if let Some(total) = total {
            total.counters.read_file_calls += next.counters.read_file_calls;
            total.counters.read_file_returned_bytes += next.counters.read_file_returned_bytes;
            total.counters.read_bytes_calls += next.counters.read_bytes_calls;
            total.counters.read_bytes_returned_bytes += next.counters.read_bytes_returned_bytes;
            total.counters.stat_token_calls += next.counters.stat_token_calls;
            total.counters.exists_calls += next.counters.exists_calls;
        } else {
            *total = Some(next);
        }
    }
}

pub(super) fn run(args: Vec<String>) -> Result<i32> {
    if args.len() != 1 {
        bail!("--function-phases expects one matching core image");
    }
    let path = &args[0];
    let config: serde_json::Value = serde_json::from_slice(&fs::read(
        std::env::var("VIBE_LOWERING_SERVICE_CONFIG")
            .map_err(|_| format_err!("missing phase service config"))?,
    )?)?;
    if config["version"].as_u64() != Some(1) || config.as_object().map(|o| o.len()) != Some(7) {
        bail!("unsupported phase service config");
    }
    let worker = configured_path(&config, "worker")?;
    let runner = configured_path(&config, "runner")?;
    let coordinator = configured_path(&config, "coordinator")?;
    let cwd = configured_path(&config, "cwd")?;
    let directory = configured_path(&config, "directory")?;
    let slots = config["jobs"]
        .as_u64()
        .ok_or_else(|| format_err!("missing phase jobs"))? as usize;
    if ![1, 2, 4].contains(&slots)
        || !cwd.is_dir()
        || !directory.is_dir()
        || fs::canonicalize(std::env::current_dir()?)? != cwd
        || fs::canonicalize(std::env::var("VIBE_LOWERING_DIRECTORY")?)? != directory
        || std::env::var("VIBE_FUNCTION_JOBS")? != slots.to_string()
    {
        bail!("phase directories or worker selection differ");
    }
    let mode = std::env::var("VIBE_LOWERING_MODE")?;
    if mode != "single" && mode != "serial" {
        bail!("expected explicit single or serial phase mode");
    }
    let mut runtime = SharedRuntime::default();
    let started = Instant::now();
    let mut scope = None;
    if mode == "serial" {
        let mut serial = Invocation::new("function_phase_serial", vec![], None);
        serial.execute(path, &mut runtime)?;
        host_imports::vibe_atomic_write(&std::env::var("VIBE_LOWERING_OUTPUT")?, &serial.response)?;
        merge_scope(&mut scope, serial.scope.take());
        if let Some(scope) = scope.as_ref() {
            publish_host_fs_scope(scope)?;
        }
        return Ok(0);
    }
    let mut prepare = Invocation::new("function_phase_prepare", vec![], None);
    prepare.execute(path, &mut runtime)?;
    let prepare_ms = started.elapsed().as_secs_f64() * 1000.0;
    let receipt = parse_receipt(&prepare.response)?;
    if receipt.jobs != slots {
        bail!("original phase worker count differs");
    }
    // Only the original returned bytes (not a mutable file) authorize finishing.
    let receipt_hash = format!("{:x}", Sha256::digest(&prepare.response));
    let mut snapshots = Vec::new();
    let mut admitted = BTreeMap::new();
    let context = directory.join("shared.context");
    let assembly = directory.join("function.assembly");
    let context_bytes = hash_file(&context, INPUT_LIMIT)?.0;
    for path in [&context, &assembly] {
        let identity = hash_file(path, INPUT_LIMIT)?;
        snapshots.push((path.clone(), INPUT_LIMIT, identity));
        admitted.insert(path.clone(), INPUT_LIMIT);
    }
    let mut queues: Vec<Vec<PathBuf>> = vec![vec![]; 4];
    let mut input_bytes = 0;
    for index in 0..slots {
        let job = directory.join(format!("{index}.job"));
        let identity = hash_file(&job, INPUT_LIMIT)?;
        input_bytes += identity.0;
        if input_bytes > INPUT_LIMIT {
            bail!("outstanding phase jobs exceed64MiB");
        }
        snapshots.push((job.clone(), INPUT_LIMIT, identity));
        queues[index].push(job);
        admitted.insert(
            directory.join(format!("{index}.job.product")),
            PRODUCT_LIMIT,
        );
        admitted.insert(directory.join(format!("{index}.job.product.receipt")), 129);
    }
    let wave = directory.join("phase-wave.json");
    fs::write(
        &wave,
        serde_json::to_vec(&serde_json::json!({
            "version":2, "wasm":worker, "cwd":cwd, "queues":queues, "context":context
        }))?,
    )?;
    let worker_started = Instant::now();
    // No live preparation Store can overlap this child/TaskGroup interval.
    if prepare.live.load(Ordering::SeqCst) {
        bail!("preparation Store remains live before workers");
    }
    let mut child =
        checker_workers::CheckerProcess::start_coordinator(&runner, &coordinator, &cwd, &wave)?;
    let exit = child.wait_blocking()?;
    if exit != 0 {
        bail!(
            "phase coordinator exited {exit}: {}",
            child.failure_detail()
        );
    }
    let worker_ms = worker_started.elapsed().as_secs_f64() * 1000.0;
    prepare.inputs.as_ref().unwrap().verify()?;
    for (path, limit, expected) in &snapshots {
        if hash_file(path, *limit)? != *expected {
            if path == &context {
                bail!("lowering: shared context changed after preparation");
            }
            bail!("phase input changed after preparation: {}", path.display());
        }
    }
    let (products, completed_product_bytes) = capture_products(&directory, slots, PRODUCT_LIMIT)?;
    let product_paths = products
        .iter()
        .filter(|(_, limit, _)| *limit == PRODUCT_LIMIT)
        .map(|(path, _, _)| path.clone())
        .collect();
    snapshots.extend(products);
    let mut reads = ArtifactReads::new(admitted);
    reads.products = product_paths;
    let finish_started = Instant::now();
    let mut finish = Invocation::new(
        "function_phase_finish",
        std::mem::take(&mut prepare.response),
        Some(reads),
    );
    finish.execute(path, &mut runtime)?;
    prepare.inputs.as_ref().unwrap().verify()?;
    for (path, limit, expected) in &snapshots {
        if hash_file(path, *limit)? != *expected {
            bail!("phase input changed before publication: {}", path.display());
        }
    }
    host_imports::vibe_atomic_write(&std::env::var("VIBE_LOWERING_OUTPUT")?, &finish.response)?;
    let report = serde_json::json!({
        "modules":slots, "workers":slots, "preparation_count":1,
        "functions":receipt.functions,"lambdas":receipt.lambdas,
        "prepare_ms":prepare_ms,"worker_ms":worker_ms,
        "finalize_ms":finish_started.elapsed().as_secs_f64()*1000.0,
        "peak_queued_jobs":slots,"peak_queued_input_bytes":input_bytes,
        "shared_context_bytes":context_bytes,"context_serialization_count":1,
        "completed_product_bytes":completed_product_bytes,
        "preparation_store_dropped_before_workers":true,"finisher_store_fresh":true,"finisher_source_reads":0,
        "original_phase_receipt_sha256":receipt_hash,
        "prepare_heap_end":prepare.heap_end,"prepare_memory_bytes":prepare.memory_bytes,
        "finish_heap_end":finish.heap_end,"finish_memory_bytes":finish.memory_bytes,
        "phase_scope":"prepare returns owned receipt and releases its Store; worker uses isolated TaskGroup processes; fresh finisher reads only admitted artifacts and validates original buffers"
    });
    fs::write(
        directory.join("service-report.json"),
        serde_json::to_vec(&report)?,
    )?;
    fs::write(
        directory.join("function-plan.json"),
        serde_json::to_vec(&serde_json::json!({
            "functions":receipt.functions,"lambdas":receipt.lambdas
        }))?,
    )?;
    merge_scope(&mut scope, prepare.scope.take());
    merge_scope(&mut scope, finish.scope.take());
    if let Some(scope) = scope.as_ref() {
        publish_host_fs_scope(scope)?;
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "vibe-function-phase-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn core_image(path: &PathBuf, marker: bool) {
        let export = if marker {
            format!(
                "(func (export \"function_phase_abi\") (result i64) i64.const {})",
                ABI.len()
            )
        } else {
            String::new()
        };
        let wat = format!(
            r#"(module
            (memory (export "memory") 2)
            (global (export "__heap_ptr") (mut i32) (i32.const 4096))
            (global $starts (mut i32) (i32.const 0))
            (data (i32.const 0) "{ABI}")
            (data (i32.const 128) "\fc\ff\ff\ff\04\00\00\00\8c\00\00\00life")
            (data (i32.const 1536) "\00\fc\ff\ff\00\00\00\00\00\08\00\00")
            {export}
            (func (export "_start")
              global.get $starts i32.const 1 i32.add global.set $starts
              global.get $starts i32.const 1 i32.ne if unreachable end)
            (func (export "function_phase_prepare") (result i64) i64.const 128)
            (func (export "function_phase_allocate") (param i64) (result i64) i64.const 1536)
            (func (export "function_phase_finish") (param $request i64) (result i64) local.get $request)
        )"#
        );
        fs::write(path, wat).unwrap();
    }

    #[test]
    fn phases_return_owned_data_and_drop_each_store_with_one_shared_module() {
        let scratch = Scratch::new();
        let path = scratch.0.join("phases.wat");
        core_image(&path, true);
        let mut runtime = SharedRuntime::default();
        let mut prepare = Invocation::new("function_phase_prepare", vec![], None);
        prepare
            .execute(path.to_str().unwrap(), &mut runtime)
            .unwrap();
        assert_eq!(prepare.response, b"life");
        assert!(!prepare.live.load(Ordering::SeqCst));
        assert!(prepare.inputs.as_ref().unwrap().is_empty());
        assert!(runtime.loaded.is_some());
        let mut finish = Invocation::new(
            "function_phase_finish",
            b"owned original receipt".to_vec(),
            None,
        );
        finish
            .execute(path.to_str().unwrap(), &mut runtime)
            .unwrap();
        assert_eq!(finish.response, b"owned original receipt");
        assert!(!finish.live.load(Ordering::SeqCst));
        assert_eq!(prepare.response, b"life");
    }

    #[test]
    fn failed_abi_still_drops_the_instantiated_store() {
        let scratch = Scratch::new();
        let path = scratch.0.join("wrong.wat");
        core_image(&path, false);
        let mut invocation = Invocation::new("function_phase_prepare", vec![], None);
        assert!(invocation
            .execute(path.to_str().unwrap(), &mut SharedRuntime::default())
            .is_err());
        assert!(!invocation.live.load(Ordering::SeqCst));
        assert!(invocation.response.is_empty());
    }

    #[test]
    fn finisher_reads_are_bounded_and_refuse_unadmitted_sources() {
        let scratch = Scratch::new();
        let admitted = scratch.0.join("context");
        let source = scratch.0.join("source.vibe");
        fs::write(&admitted, b"abc").unwrap();
        fs::write(&source, b"source").unwrap();
        let scope = ArtifactReads::new(BTreeMap::from([(admitted.clone(), 3)]));
        assert_eq!(
            read_input(Some(&scope), admitted.to_str().unwrap()).unwrap(),
            b"abc"
        );
        assert!(read_input(Some(&scope), source.to_str().unwrap()).is_err());
        fs::write(&admitted, b"abcd").unwrap();
        assert!(read_input(Some(&scope), admitted.to_str().unwrap()).is_err());
        assert_eq!(
            read_input(None, source.to_str().unwrap()).unwrap(),
            b"source"
        );
    }

    #[test]
    fn aggregate_product_admission_and_actual_reads_share_a_total_byte_bound() {
        let scratch = Scratch::new();
        let mut paths = BTreeMap::new();
        let mut products = BTreeSet::new();
        for i in 0..2 {
            let path = scratch.0.join(format!("{i}.job.product"));
            fs::write(&path, b"abc").unwrap();
            fs::write(
                scratch.0.join(format!("{i}.job.product.receipt")),
                b"receipt",
            )
            .unwrap();
            paths.insert(path.clone(), 4);
            products.insert(path);
        }
        let (identities, total) = capture_products(&scratch.0, 2, 6).unwrap();
        assert_eq!(total, 6);
        assert_eq!(identities.len(), 4);
        assert!(capture_products(&scratch.0, 2, 5).is_err());
        let mut scope = ArtifactReads::new(paths);
        scope.products = products;
        *scope.remaining.lock().unwrap() = 6;
        for i in 0..2 {
            let path = scratch.0.join(format!("{i}.job.product"));
            assert_eq!(
                read_input(Some(&scope), path.to_str().unwrap()).unwrap(),
                b"abc"
            );
        }
        // A second read is another live copy, not an exemption for the same path.
        let path = scratch.0.join("0.job.product");
        assert!(read_input(Some(&scope), path.to_str().unwrap()).is_err());
        assert!(scope.denied.load(Ordering::SeqCst));
        // Admission followed by a larger actual file must also fail at read time.
        *scope.remaining.lock().unwrap() = 3;
        fs::write(&path, b"abcd").unwrap();
        assert!(read_input(Some(&scope), path.to_str().unwrap()).is_err());
    }

    #[test]
    fn finisher_source_probe_is_refused_before_the_host_filesystem_call() {
        let scratch = Scratch::new();
        let path = scratch.0.join("probe.wat");
        core_image(&path, true);
        let source = scratch
            .0
            .join("not-created.vibe")
            .to_string_lossy()
            .to_string();
        let wat = fs::read_to_string(&path).unwrap();
        let wat = wat.replacen(
            "(module",
            r#"(module (import "vibe" "fs_exists" (func $probe (param i64) (result i64)))"#,
            1,
        );
        let (body, _) = wat.rsplit_once(')').unwrap();
        fs::write(&path, format!(r#"{body} (data (i32.const 512) "{source}") (func (export "function_phase_probe") (result i64) i64.const {} call $probe drop i64.const 128))"#, (512_u64 << 32) | source.len() as u64)).unwrap();
        let mut runtime = SharedRuntime::default();
        let mut control = Invocation::new("function_phase_probe", vec![], None);
        control
            .execute(path.to_str().unwrap(), &mut runtime)
            .unwrap();
        assert_eq!(control.response, b"life");
        let reads = ArtifactReads::new(BTreeMap::new());
        let mut refused = Invocation::new("function_phase_probe", vec![], Some(reads.clone()));
        assert!(refused
            .execute(path.to_str().unwrap(), &mut runtime)
            .is_err());
        assert!(reads.denied.load(Ordering::SeqCst));
        assert!(!refused.live.load(Ordering::SeqCst));
    }

    #[test]
    fn returned_phase_diagnostic_keeps_the_original_trap_classification() {
        let message = "original phase diagnostic";
        let engine = Engine::new(&engine_config()).unwrap();
        let module = Module::new(
            &engine,
            format!(
                r#"(module
            (memory (export "memory") 1)
            (data (i32.const 0) "{message}")
            (func (export "function_phase_error") (result i64) i64.const {})
            (func (export "phase_fail") (result i64) unreachable)
        )"#,
                message.len()
            ),
        )
        .unwrap();
        let mut linker = Linker::new(&engine);
        register_imports(&mut linker).unwrap();
        let mut store = Store::new(
            &engine,
            HostState::new(vec![], MemLimiter::new(store_mem_limits())),
        );
        let instance = linker.instantiate(&mut store, &module).unwrap();
        let error = call_phase(&instance, &mut store, "phase_fail", &[]).unwrap_err();
        assert!(error.to_string().contains(message));
        assert!(error.downcast_ref::<Trap>().is_some());
    }

    fn receipt_fixture(jobs: u8) -> Vec<u8> {
        let magic = b"vibe-function-phases-1";
        let mut bytes = vec![magic.len() as u8];
        bytes.extend_from_slice(magic);
        bytes.extend_from_slice(&[3, 2, jobs]);
        for _ in 0..jobs + 2 {
            bytes.push(64);
            bytes.extend_from_slice(&[b'a'; 64]);
        }
        bytes
    }
    #[test]
    fn original_receipts_refuse_count_digest_truncation_trailing_and_size_mutations() {
        for jobs in [1, 2, 4] {
            let bytes = receipt_fixture(jobs);
            let parsed = parse_receipt(&bytes).unwrap();
            assert_eq!(
                (parsed.functions, parsed.lambdas, parsed.jobs),
                (3, 2, jobs as usize)
            );
            for at in [0, 1, bytes.len() - 1] {
                assert!(parse_receipt(&bytes[..at]).is_err());
            }
            let mut trailing = bytes.clone();
            trailing.push(0);
            assert!(parse_receipt(&trailing).is_err());
            let mut digest = bytes.clone();
            *digest.last_mut().unwrap() = b'g';
            assert!(parse_receipt(&digest).is_err());
        }
        assert!(parse_receipt(&receipt_fixture(3)).is_err());
        assert!(parse_receipt(&vec![0; RECEIPT_LIMIT + 1]).is_err());
    }
}
