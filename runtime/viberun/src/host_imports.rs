//! Host imports.

use super::*;

// Pull the MoonValue clone-bits we need without holding the Caller's
// immutable borrow across the next ExternRef::new mutable borrow.
pub(super) fn read_str(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
) -> Result<String> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::String(s) => Ok(s.clone()),
        MoonValue::StringWriter(cell) => Ok(cell.lock().unwrap().clone()),
        _ => bail!("expected String / StringWriter handle"),
    }
}

pub(super) fn read_bytes(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
) -> Result<Arc<Vec<u8>>> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::ByteArray(b) => Ok(b.clone()),
        MoonValue::ByteArrayWriter(cell) => Ok(Arc::new(cell.lock().unwrap().clone())),
        _ => bail!("expected ByteArray / ByteArrayWriter handle"),
    }
}

pub(super) fn read_string_array(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
) -> Result<Arc<Vec<String>>> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    match v {
        MoonValue::StringArray(a) => Ok(a.clone()),
        _ => bail!("expected StringArray handle"),
    }
}

// `with_value` runs `f` against a borrowed MoonValue without producing a new
// externref. Use this for handles whose only output is a primitive.
pub(super) fn with_value<R>(
    caller: &Caller<'_, HostState>,
    h: Option<Rooted<ExternRef>>,
    f: impl FnOnce(&MoonValue) -> Result<R>,
) -> Result<R> {
    let h = h.ok_or_else(|| format_err!("null externref"))?;
    let any: &(dyn Any + Send + Sync) = h
        .data(caller)?
        .ok_or_else(|| format_err!("externref data missing"))?;
    let v = any
        .downcast_ref::<MoonValue>()
        .ok_or_else(|| format_err!("externref not MoonValue"))?;
    f(v)
}

pub(super) fn read_wasi_u32(
    memory: &wasmtime::Memory,
    caller: &Caller<'_, HostState>,
    offset: usize,
) -> std::result::Result<u32, i32> {
    let mut buf = [0u8; 4];
    memory
        .read(caller, offset, &mut buf)
        .map_err(|_| WASI_ERRNO_FAULT)?;
    Ok(u32::from_le_bytes(buf))
}

pub(super) fn write_wasi_fd(host: &mut HostState, fd: i32, bytes: &[u8]) -> io::Result<()> {
    match fd {
        1 if host.capture_stdout => {
            host.captured_stdout.extend_from_slice(bytes);
            Ok(())
        }
        1 => {
            let stdout = std::io::stdout();
            stdout.lock().write_all(bytes)
        }
        2 => {
            let stderr = std::io::stderr();
            stderr.lock().write_all(bytes)
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported WASI fd",
        )),
    }
}

pub(super) fn wasi_fd_write(
    caller: &mut Caller<'_, HostState>,
    fd: i32,
    iovs: i32,
    iovs_len: i32,
    nwritten: i32,
) -> i32 {
    if fd != 1 && fd != 2 {
        return WASI_ERRNO_BADF;
    }
    if iovs < 0 || iovs_len < 0 || nwritten < 0 {
        return WASI_ERRNO_INVAL;
    }

    let memory = match caller
        .get_export("memory")
        .and_then(|ext| ext.into_memory())
    {
        Some(memory) => memory,
        None => return WASI_ERRNO_FAULT,
    };

    let mut written: u32 = 0;
    let iovs_base = iovs as usize;
    for index in 0..(iovs_len as usize) {
        let iov_offset = match iovs_base.checked_add(index.saturating_mul(8)) {
            Some(offset) => offset,
            None => return WASI_ERRNO_INVAL,
        };
        let ptr = match read_wasi_u32(&memory, caller, iov_offset) {
            Ok(ptr) => ptr as usize,
            Err(errno) => return errno,
        };
        let len = match read_wasi_u32(&memory, caller, iov_offset + 4) {
            Ok(len) => len as usize,
            Err(errno) => return errno,
        };
        let mut bytes = vec![0u8; len];
        if memory.read(&*caller, ptr, &mut bytes).is_err() {
            return WASI_ERRNO_FAULT;
        }
        if write_wasi_fd(caller.data_mut(), fd, &bytes).is_err() {
            return WASI_ERRNO_IO;
        }
        written = match written.checked_add(len as u32) {
            Some(total) => total,
            None => return WASI_ERRNO_INVAL,
        };
    }

    if memory
        .write(caller, nwritten as usize, &written.to_le_bytes())
        .is_err()
    {
        return WASI_ERRNO_FAULT;
    }
    WASI_ERRNO_SUCCESS
}

// ---- selfhost raw-ABI (`vibe::*`) host imports ----
//
// The selfhost CLI wasm (entry `cli_main`) talks to the host through `vibe::*`
// imports under the "raw" ABI (`VIBE_IMPORT_ABI=raw`). Strings cross
// the boundary packed into a single i64 = `(ptr << 32) | len` referencing the
// guest's exported linear `memory`. Host-produced strings are bump-allocated on
// the guest's exported `__heap_ptr` global. Ints/Bools are passed as raw i64.
// This mirrors the JS host (`scripts/wasm_vibe_host_runner.js`) so the Rust
// runner can run the same selfhost CLI artifacts as the production `vibe`
// command (`docs/internal/project/release-roadmap.md`, テーマ 1).

pub(super) fn vibe_memory(caller: &mut Caller<'_, HostState>) -> Result<wasmtime::Memory> {
    caller
        .get_export("memory")
        .and_then(|e| e.into_memory())
        .ok_or_else(|| format_err!("vibe host import: missing exported `memory`"))
}

pub(super) fn vibe_read_packed_str(
    caller: &mut Caller<'_, HostState>,
    packed: i64,
) -> Result<String> {
    let mem = vibe_memory(caller)?;
    let u = packed as u64;
    let ptr = (u >> 32) as usize;
    let len = (u & 0xffff_ffff) as usize;
    let mut buf = vec![0u8; len];
    mem.read(&*caller, ptr, &mut buf)
        .map_err(|e| format_err!("vibe host import: string read @{ptr}+{len}: {e}"))?;
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

// raw Bytes value is a pointer to a struct `{ _cap@0, len@4, data_ptr@8 }`.
pub(super) fn vibe_read_packed_bytes(
    caller: &mut Caller<'_, HostState>,
    value: i64,
) -> Result<Vec<u8>> {
    let mem = vibe_memory(caller)?;
    let base = (value as u64) as usize;
    let mut hdr = [0u8; 4];
    mem.read(&*caller, base + 4, &mut hdr)
        .map_err(|e| format_err!("vibe host import: bytes len read: {e}"))?;
    let len = u32::from_le_bytes(hdr) as usize;
    mem.read(&*caller, base + 8, &mut hdr)
        .map_err(|e| format_err!("vibe host import: bytes ptr read: {e}"))?;
    let data_ptr = u32::from_le_bytes(hdr) as usize;
    let mut buf = vec![0u8; len];
    mem.read(&*caller, data_ptr, &mut buf)
        .map_err(|e| format_err!("vibe host import: bytes data read: {e}"))?;
    Ok(buf)
}

// Bump-allocate `s` on the guest heap and return it packed as `(ptr << 32) | len`.
/// #2966: a fallible host operation raises the program's OWN vibe exception
/// (the `__exception_throw_tag` export, the message as its payload) -- what
/// the node runner's `throwVibeHostError` does -- so a `handle .. with
/// Exception` around the call catches it under both runners. It used to be a
/// host trap here, uncatchable, while node raised a catchable exception. A
/// module that exports no tag keeps the trap.
pub(super) fn vibe_host_error(caller: &mut Caller<'_, HostState>, msg: String) -> wasmtime::Error {
    let tag = match caller
        .get_export("__exception_throw_tag")
        .and_then(|e| e.into_tag())
    {
        Some(tag) => tag,
        None => return format_err!("{msg}"),
    };
    let payload = match vibe_alloc_packed_str(caller, &msg) {
        Ok(p) => p,
        Err(e) => return e,
    };
    let exn_ty = match ExnType::from_tag_type(&tag.ty(&*caller)) {
        Ok(t) => t,
        Err(e) => return e,
    };
    let pre = ExnRefPre::new(&mut *caller, exn_ty);
    match ExnRef::new(&mut *caller, &pre, &tag, &[Val::I64(payload)]) {
        Ok(exn) => match caller.as_context_mut().throw::<()>(exn) {
            Err(e) => e,
            Ok(()) => format_err!("{msg}"),
        },
        Err(e) => e,
    }
}

/// `Fs::readdir`'s entry names for the packed-string path argument, byte-sorted.
/// A missing directory is a guest-visible host error, matching `fs_read_file`.
pub(super) fn vibe_read_dir_names(
    caller: &mut Caller<'_, HostState>,
    path: i64,
) -> Result<Vec<String>> {
    let path = vibe_read_packed_str(caller, path)?;
    let entries = match fs::read_dir(&path) {
        Ok(it) => it,
        Err(e) => {
            return Err(vibe_host_error(
                caller,
                format!("fs_read_dir failed for '{path}': {e}"),
            ))
        }
    };
    let mut names: Vec<String> = entries
        .filter_map(|ent| ent.ok())
        .map(|ent| ent.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    Ok(names)
}

pub(super) fn vibe_alloc_packed_str(caller: &mut Caller<'_, HostState>, s: &str) -> Result<i64> {
    let bytes = s.as_bytes();
    let mem = vibe_memory(caller)?;
    let heap = caller
        .get_export("__heap_ptr")
        .and_then(|e| e.into_global())
        .ok_or_else(|| format_err!("vibe host import: missing `__heap_ptr` global"))?;
    let (cur, is_i64) = match heap.get(&mut *caller) {
        Val::I32(v) => (v as u32 as u64, false),
        Val::I64(v) => (v as u64, true),
        other => bail!("vibe host import: __heap_ptr unexpected type: {other:?}"),
    };
    let align = 8u64;
    let aligned = (cur + (align - 1)) & !(align - 1);
    let size = bytes.len() as u64;
    let next = (aligned + size + (align - 1)) & !(align - 1);
    let cur_size = mem.data_size(&*caller) as u64;
    if next > cur_size {
        let pages = (next - cur_size).div_ceil(65536);
        mem.grow(&mut *caller, pages)
            .map_err(|e| format_err!("vibe host import: memory.grow({pages}): {e}"))?;
    }
    mem.write(&mut *caller, aligned as usize, bytes)
        .map_err(|e| format_err!("vibe host import: string write @{aligned}: {e}"))?;
    let set = if is_i64 {
        Val::I64(next as i64)
    } else {
        Val::I32(next as i32)
    };
    heap.set(&mut *caller, set)
        .map_err(|e| format_err!("vibe host import: set __heap_ptr: {e}"))?;
    Ok(((aligned as i64) << 32) | (size as i64))
}

// Bump-allocate `data` as a raw Bytes value `{ -cap@0, len@4, data_ptr@8 }` with
// the bytes inline at +12, returning the (untagged) struct pointer — the inverse
// of vibe_read_packed_bytes. Capacity is stored negated (the guest reads
// `avail = 0 - cap`). #632 fs_read_bytes.
pub(super) fn vibe_alloc_packed_bytes(
    caller: &mut Caller<'_, HostState>,
    data: &[u8],
) -> Result<i64> {
    let mem = vibe_memory(caller)?;
    let heap = caller
        .get_export("__heap_ptr")
        .and_then(|e| e.into_global())
        .ok_or_else(|| format_err!("vibe host import: missing `__heap_ptr` global"))?;
    let (cur, is_i64) = match heap.get(&mut *caller) {
        Val::I32(v) => (v as u32 as u64, false),
        Val::I64(v) => (v as u64, true),
        other => bail!("vibe host import: __heap_ptr unexpected type: {other:?}"),
    };
    let align = 8u64;
    let aligned = (cur + (align - 1)) & !(align - 1);
    let len = data.len() as u64;
    let next = (aligned + 12 + len + (align - 1)) & !(align - 1);
    let cur_size = mem.data_size(&*caller) as u64;
    if next > cur_size {
        let pages = (next - cur_size).div_ceil(65536);
        mem.grow(&mut *caller, pages)
            .map_err(|e| format_err!("vibe host import: memory.grow({pages}): {e}"))?;
    }
    let base = aligned as usize;
    let neg_cap = 0u32.wrapping_sub(len as u32);
    mem.write(&mut *caller, base, &neg_cap.to_le_bytes())
        .map_err(|e| format_err!("vibe host import: bytes cap write @{base}: {e}"))?;
    mem.write(&mut *caller, base + 4, &(len as u32).to_le_bytes())
        .map_err(|e| format_err!("vibe host import: bytes len write: {e}"))?;
    mem.write(
        &mut *caller,
        base + 8,
        &((aligned + 12) as u32).to_le_bytes(),
    )
    .map_err(|e| format_err!("vibe host import: bytes ptr write: {e}"))?;
    mem.write(&mut *caller, base + 12, data)
        .map_err(|e| format_err!("vibe host import: bytes data write: {e}"))?;
    let set = if is_i64 {
        Val::I64(next as i64)
    } else {
        Val::I32(next as i32)
    };
    heap.set(&mut *caller, set)
        .map_err(|e| format_err!("vibe host import: set __heap_ptr: {e}"))?;
    Ok(aligned as i64)
}

pub(super) fn vibe_ensure_parent_dir(path: &std::path::Path) {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            let _ = fs::create_dir_all(dir);
        }
    }
}

// Guest Fs::write_file / Fs::write_bytes land here. Write via a same-dir temp
// file + rename so a concurrent reader never sees a truncated file -- mirrors
// scripts/wasm_vibe_host_runner.js's atomicWriteFileSync (same rationale: the
// persistent caches under _build/vibe_* are content-keyed and shared across
// concurrent compiler invocations -- parallel unit-test runs and #906's
// --jobs pre-warm publish path both write these hot keys from more than one
// process/worker -- and a plain fs::write opens with O_TRUNC, exposing a
// partial-file window a racing reader can observe as a corrupt cache row).
// rename() is atomic on POSIX; same-content racers simply last-write-win as
// complete files, which is safe because a cache path already encodes its
// content's own fingerprint (#906 acceptance criteria: partial cache writes
// must never be published).
pub(super) static VIBE_TMP_COUNTER: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

pub(super) fn vibe_atomic_write(path: &str, data: &[u8]) -> Result<()> {
    vibe_ensure_parent_dir(std::path::Path::new(path));
    let counter = VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = format!("{path}.tmp-{}-{counter}", std::process::id());
    let write_result = fs::write(&tmp, data);
    match write_result {
        Ok(()) => fs::rename(&tmp, path).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            format_err!("vibe atomic write rename '{tmp}' -> '{path}': {e}")
        }),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(format_err!("vibe atomic write '{tmp}': {e}"))
        }
    }
}

// Atomically publish UTF-8 text iff the final path is absent. A same-directory
// create_new temp plus hard_link is the portable no-replace operation available
// to this core-wasm runner: the winner links its complete temp; losers never
// overwrite and only succeed when the existing regular file has identical raw
// UTF-8 bytes. All I/O, unsupported-filesystem, symlink, and nonregular cases
// fail closed. Durability/fsync is deliberately outside this publication ABI.
pub(super) fn vibe_publish_immutable_text(path: &str, data: &[u8]) -> bool {
    let counter = VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = format!("{path}.immutable-tmp-{}-{counter}", std::process::id());
    let published = (|| {
        let mut temp = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .ok()?;
        temp.write_all(data).ok()?;
        drop(temp);
        match fs::hard_link(&tmp, path) {
            Ok(()) => Some(true),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                let metadata = fs::symlink_metadata(path).ok()?;
                if !metadata.file_type().is_file() {
                    return Some(false);
                }
                Some(
                    fs::read(path)
                        .map(|existing| existing == data)
                        .unwrap_or(false),
                )
            }
            Err(_) => Some(false),
        }
    })()
    .unwrap_or(false);
    let _ = fs::remove_file(&tmp);
    published
}

// Prepare the opt-in telemetry sidecar before the guest can run. A stale file
// is removed even when the nonce is invalid, so callers cannot accidentally
// accept an old observation after this invocation fails closed.
pub(super) fn prepare_host_fs_scope() -> Result<Option<HostFsScope>> {
    let Some(output) = std::env::var_os("VIBE_HOST_FS_SCOPE_OUT") else {
        return Ok(None);
    };
    if output.is_empty() {
        return Ok(None);
    }
    let output = PathBuf::from(output);
    match fs::remove_file(&output) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => bail!("host_fs_scope: remove stale '{}': {e}", output.display()),
    }
    let nonce = std::env::var("VIBE_HOST_FS_SCOPE_NONCE")
        .map_err(|_| format_err!("host_fs_scope: VIBE_HOST_FS_SCOPE_NONCE is required"))?;
    if nonce.is_empty() || nonce.chars().any(char::is_control) {
        bail!("host_fs_scope: VIBE_HOST_FS_SCOPE_NONCE must be non-empty and contain no control characters");
    }
    Ok(Some(HostFsScope {
        output,
        nonce,
        counters: HostFsScopeCounters::default(),
    }))
}

pub(super) fn host_fs_scope_json(scope: &HostFsScope) -> Result<Vec<u8>> {
    serde_json::to_vec(&serde_json::json!({
        "schema": "host_fs_scope",
        "version": 1,
        "nonce": scope.nonce,
        "read_file_calls": scope.counters.read_file_calls,
        "read_file_returned_bytes": scope.counters.read_file_returned_bytes,
        "read_bytes_calls": scope.counters.read_bytes_calls,
        "read_bytes_returned_bytes": scope.counters.read_bytes_returned_bytes,
        "stat_token_calls": scope.counters.stat_token_calls,
        "exists_calls": scope.counters.exists_calls,
    }))
    .map_err(|e| format_err!("host_fs_scope: serialize sidecar: {e}"))
}

// This is intentionally a host-side write after `_start` returns successfully,
// so it cannot itself show up as a guest filesystem-import counter.
pub(super) fn publish_host_fs_scope(scope: &HostFsScope) -> Result<()> {
    let json = host_fs_scope_json(scope)?;
    // `vibe_atomic_write` takes a UTF-8 guest ABI path. The host-side output
    // path may be a native non-UTF-8 path, so use the same atomic protocol
    // directly without lossy path conversion.
    vibe_ensure_parent_dir(&scope.output);
    let counter = VIBE_TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut tmp_name = scope.output.file_name().unwrap_or_default().to_os_string();
    tmp_name.push(format!(".tmp-{}-{counter}", std::process::id()));
    let tmp = scope.output.with_file_name(tmp_name);
    match fs::write(&tmp, &json) {
        Ok(()) => fs::rename(&tmp, &scope.output).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            format_err!("host_fs_scope: publish '{}': {e}", scope.output.display())
        }),
        Err(e) => {
            let _ = fs::remove_file(&tmp);
            Err(format_err!(
                "host_fs_scope: publish '{}': {e}",
                scope.output.display()
            ))
        }
    }
}

// Read the `__heap_ptr` bump-allocator pointer (an i32/i64 mut global) as bytes,
// or None when the module doesn't export it. Used by the `--mem` memory report.
pub(super) fn read_heap_ptr(
    instance: &wasmtime::Instance,
    store: &mut Store<HostState>,
) -> Option<u64> {
    let g = instance.get_global(&mut *store, "__heap_ptr")?;
    match g.get(&mut *store) {
        Val::I32(v) => Some(v as u32 as u64),
        Val::I64(v) => Some(v as u64),
        _ => None,
    }
}

// Human-readable byte size (binary units).
pub(super) fn human_bytes(n: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

// Print the `--mem` report to stderr: a machine-readable line + a human line.
// `allocated` = peak − base (everything the run bump-allocated; the linear
// backend never frees, so peak == total). `committed` = wasm memory pages.
pub(super) fn report_memory(
    base: Option<u64>,
    peak: Option<u64>,
    committed: Option<u64>,
    grow_events: &[(u128, u64, u64)],
) {
    match (base, peak) {
        (Some(b), Some(p)) => {
            let allocated = p.saturating_sub(b);
            let c = committed.unwrap_or(0);
            eprintln!("vibe::mem heap_base={b} heap_peak={p} allocated={allocated} committed={c} grow_events={}", grow_events.len());
            eprintln!(
                "vibe: memory — allocated {} ({allocated} B), peak heap {}, committed {}, {} growth event(s)",
                human_bytes(allocated),
                human_bytes(p),
                human_bytes(c),
                grow_events.len(),
            );
            // Growth timeline (tier 2): one machine-readable line per
            // `memory.grow`, with the time since run start and the page-commitment
            // jump. Empty for programs that stay within the module's initial
            // memory. A trailing human summary of the first/last event bounds the
            // timeline without flooding for allocation-heavy runs.
            for (elapsed_ns, from, to) in grow_events {
                let pages = to.saturating_sub(*from) / 65536;
                eprintln!(
                    "vibe::memgrow t_us={} from={from} to={to} pages=+{pages}",
                    elapsed_ns / 1_000
                );
            }
            if let (Some((t0, f0, _)), Some((t1, _, l1))) =
                (grow_events.first(), grow_events.last())
            {
                eprintln!(
                    "vibe:   growth {} -> {} across {} event(s), {} … {}",
                    human_bytes(*f0),
                    human_bytes(*l1),
                    grow_events.len(),
                    fmt_ns(*t0),
                    fmt_ns(*t1),
                );
            }
        }
        _ => eprintln!("vibe: memory — unavailable (module exports no `__heap_ptr` global)"),
    }
}

// Print the tier-3 heap-sampling timeline: one machine-readable line per sample
// (elapsed since run start + heap-pointer bytes) plus a human summary. Empty when
// the program ran faster than one sample interval.
pub(super) fn report_samples(samples: &[(u128, u64)]) {
    for (elapsed_ns, heap) in samples {
        eprintln!("vibe::memsample t_us={} heap={heap}", elapsed_ns / 1_000);
    }
    match (samples.first(), samples.last()) {
        (Some((t0, h0)), Some((t1, h1))) => eprintln!(
            "vibe: heap samples — {} over {} … {}, {} -> {} (peak {})",
            samples.len(),
            fmt_ns(*t0),
            fmt_ns(*t1),
            human_bytes(*h0),
            human_bytes(*h1),
            human_bytes(samples.iter().map(|(_, h)| *h).max().unwrap_or(0)),
        ),
        _ => eprintln!("vibe: heap samples — 0 (program ran faster than one sample interval)"),
    }
}

// Profiling tier 4: per-function allocation attribution. `sites` maps a function
// name to the bytes credited to it; `funcmap` resolves a name to its 1-based
// declaration line (empty => `line=?`). Emit one machine-readable `vibe::allocsite`
// line per function (top `limit` by bytes) plus a human summary, all to stderr
// (stdout stays the program's).
pub(super) fn report_alloc_sites(
    sites: &std::collections::HashMap<String, u64>,
    funcmap: &std::collections::HashMap<String, u32>,
    limit: usize,
) {
    let total: u64 = sites.values().sum();
    let mut rows: Vec<(&String, u64)> = sites.iter().map(|(k, v)| (k, *v)).collect();
    // Sort by bytes desc, then by name for a stable order on ties.
    rows.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    let shown = rows.len().min(limit);
    for (name, bytes) in rows.iter().take(shown) {
        let line = funcmap
            .get(*name)
            .map(|l| l.to_string())
            .unwrap_or_else(|| "?".to_string());
        eprintln!("vibe::allocsite fn={name} line={line} bytes={bytes}");
    }
    if rows.is_empty() {
        eprintln!("vibe: alloc sites — none (no allocations attributed; needs a --break-instrumented build)");
    } else {
        eprintln!(
            "vibe: alloc sites — {} function(s), {} attributed total, top {} shown",
            rows.len(),
            human_bytes(total),
            shown,
        );
    }
}

// fnv-ish stat token mixing size + mtime + ino; mirrors the JS host so
// cwasm/cache keys agree across runners. Only needs to change when the file
// changes. ino guards the "racy stat" window: a rename-in rewrite landing in
// the same kernel timestamp tick with the same size would otherwise keep the
// token identical (see buildFsMetadataHashParts in wasm_vibe_host_runner.js).
pub(super) fn vibe_stat_token(path: &str) -> i64 {
    if fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
    {
        return -1;
    }
    match fs::metadata(path) {
        Ok(meta) => {
            let size = meta.len();
            let mtime_ns = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0);
            #[cfg(unix)]
            let ino = {
                use std::os::unix::fs::MetadataExt;
                meta.ino()
            };
            #[cfg(not(unix))]
            let ino = 0u64;
            let lower = size.wrapping_mul(0x9e37_79b1_85eb_ca87)
                ^ mtime_ns
                ^ 0x243f_6a88_85a3_08d3
                ^ ino.wrapping_mul(0x1000_0000_01b3);
            let upper = (mtime_ns << 1) ^ (size << 17) ^ 0x1319_8a2e_0370_7344 ^ (ino << 7);
            ((lower ^ upper) & ((1u64 << 61) - 1)) as i64
        }
        Err(_) => 0,
    }
}

pub(super) fn register_vibe_imports(linker: &mut Linker<HostState>) -> Result<()> {
    linker.func_wrap(
        "vibe",
        "env-get",
        |mut caller: Caller<'_, HostState>, name: i64| -> Result<i64> {
            let name = vibe_read_packed_str(&mut caller, name)?;
            let val = std::env::var(&name).unwrap_or_default();
            vibe_alloc_packed_str(&mut caller, &val)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "args-get",
        |mut caller: Caller<'_, HostState>, index: i64| -> Result<i64> {
            // HostState.args[0] is the runner name; program args start at [1],
            // so `vibe args-get(0)` is the first user argument.
            let val = if index < 0 {
                String::new()
            } else {
                caller
                    .data()
                    .args
                    .get(index as usize + 1)
                    .cloned()
                    .unwrap_or_default()
            };
            vibe_alloc_packed_str(&mut caller, &val)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "args-len",
        // `Env::args_len` -> number of USER arguments. args[0] is the runner
        // name, so the user-visible count is args.len() - 1 (raw i64 per the raw
        // ABI). Without this import a program using Env::args_len fails to
        // instantiate with an unknown import before user code runs.
        |caller: Caller<'_, HostState>| -> i64 {
            (caller.data().args.len().saturating_sub(1)) as i64
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_read_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_file_calls += 1;
            }
            let content = match fs::read(&path) {
                Ok(c) => c,
                Err(e) => {
                    return Err(vibe_host_error(
                        &mut caller,
                        format!("fs_read_file failed for '{path}': {e}"),
                    ))
                }
            };
            let s = String::from_utf8_lossy(&content).into_owned();
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_file_returned_bytes += s.len() as u64;
            }
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_exists",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.exists_calls += 1;
            }
            Ok(i64::from(std::path::Path::new(&path).exists()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_stat_token",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.stat_token_calls += 1;
            }
            Ok(vibe_stat_token(&path))
        },
    )?;
    // #901: Fs::remove/is_dir/is_file -- like Stdout/Stderr/Process above,
    // present in the JS runner and the builtin registry but never ported
    // here, so scripts/cache_clean.vibex (which calls all three) failed to
    // instantiate under the real `vibe run`.
    linker.func_wrap(
        "vibe",
        "fs_remove",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Err(e) = fs::remove_file(&path) {
                return Err(vibe_host_error(
                    &mut caller,
                    format!("fs_remove failed for '{path}': {e}"),
                ));
            }
            Ok(())
        },
    )?;
    // #2738: Fs::remove_file -- the non-recursive remove, registered here for a
    // reason stronger than "a program might call it": the GC backend emits its
    // WHOLE host-import group as soon as any host builtin is used, so leaving
    // this unregistered makes every gc module that touches Env::/Fs:: at all
    // fail to instantiate, before a line of user code runs (Codex on #2756).
    //
    // The JS runner reaches this through an explicit lstat-then-unlink, because
    // its `fs_remove` is `rmSync(.., { recursive: true })` and needs the
    // distinction spelled out. Here the distinction is the std function itself:
    // `fs::remove_file` removes a file or a symlink and returns Err on a
    // directory. Note the consequence -- `fs_remove` ABOVE is already
    // non-recursive on this host, so the two runners have disagreed about
    // `Fs::remove` all along, and this builtin is what makes the intent
    // host-independent rather than an accident of which runner you used.
    //
    // A directory is a no-op here rather than an error, matching the JS side
    // and `fs_remove`'s swallow-on-failure posture; loudness belongs at the
    // call site (#2735).
    linker.func_wrap(
        "vibe",
        "fs_remove_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            match fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_dir() => Ok(()),
                Ok(_) => {
                    let _ = fs::remove_file(&path);
                    Ok(())
                }
                Err(_) => Ok(()),
            }
        },
    )?;
    // #2758: Fs::remove_tree -- the RECURSIVE remove, split out of `Fs::remove`.
    //
    // `Fs::remove` on this host has always been `fs::remove_file`, while the JS
    // runner's was `rmSync(.., { recursive: true, force: true })`, so one
    // declared builtin meant two different things depending on which runner
    // ran. The recursion moved here, under a name that asks for itself, and
    // `fs_remove` is now non-recursive on both hosts.
    //
    // `force` semantics, matching the JS `rmSync` this replaces: a missing path
    // is a no-op, not an error, so the callers that moved here from the old
    // recursive `Fs::remove` keep working unguarded. A FILE is removed too --
    // `rmSync` removes one, and a caller asking to clear a subtree should not
    // have to know whether the leaf is a directory.
    linker.func_wrap(
        "vibe",
        "fs_remove_tree",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let removed = match fs::symlink_metadata(&path) {
                Ok(meta) if meta.is_dir() => fs::remove_dir_all(&path),
                Ok(_) => fs::remove_file(&path),
                Err(e) => Err(e),
            };
            match removed {
                Ok(()) => {}
                // ONLY NotFound is swallowed, because that is all `force: true`
                // swallows on the JS side -- `rmSync` rethrows EACCES, EPERM
                // and I/O errors. A blanket `Err(_) => {}` here reintroduced
                // exactly the divergence this builtin exists to remove: an
                // unreadable parent directory made `Fs::remove_tree` report
                // success under viberun while throwing under the JS runner,
                // with the tree still standing in both (Codex on #2823).
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    return Err(vibe_host_error(
                        &mut caller,
                        format!("fs_remove_tree failed for '{path}': {e}"),
                    ))
                }
            }
            Ok(())
        },
    )?;
    // #1220: Fs::rename -- declared builtin with real call sites
    // (lib/@vibe/cli/coverage_local_merge.vibe, coverage_acc_tool.vibe's
    // tmp-write + rename atomic-write pattern) but, like fs_remove above,
    // present in the JS runner (scripts/wasm_vibe_host_runner.js's
    // fs.renameSync) and never ported here -- any compiled program calling
    // Fs::rename crashed the real `vibe run` with an unknown-import trap.
    linker.func_wrap(
        "vibe",
        "fs_rename",
        |mut caller: Caller<'_, HostState>, src: i64, dst: i64| -> Result<()> {
            let src = vibe_read_packed_str(&mut caller, src)?;
            let dst = vibe_read_packed_str(&mut caller, dst)?;
            fs::rename(&src, &dst)
                .map_err(|e| format_err!("vibe fs_rename '{src}' -> '{dst}': {e}"))?;
            Ok(())
        },
    )?;
    // #1220 follow-up: the rest of the JS runner's fs surface
    // (scripts/wasm_vibe_host_runner.js) that was never ported here either --
    // same unknown-import crash under the real `vibe run` as fs_rename above,
    // just not yet hit by a call site that runs through viberun. Declared
    // builtins with real call sites in lib/@vibex/shell/commands.vibe (a
    // general-purpose library any user program can import) and
    // scripts/vibe_md.vibex.
    linker.func_wrap(
        "vibe",
        "fs_mkdir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            fs::create_dir(&path).map_err(|e| format_err!("vibe fs_mkdir '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_mkdir_p",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            fs::create_dir_all(&path).map_err(|e| format_err!("vibe fs_mkdir_p '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_getcwd",
        |mut caller: Caller<'_, HostState>| -> Result<i64> {
            let cwd = std::env::current_dir().map_err(|e| format_err!("vibe fs_getcwd: {e}"))?;
            vibe_alloc_packed_str(&mut caller, &cwd.to_string_lossy())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_chdir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            std::env::set_current_dir(&path)
                .map_err(|e| format_err!("vibe fs_chdir '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_copy",
        |mut caller: Caller<'_, HostState>, src: i64, dst: i64| -> Result<()> {
            let src = vibe_read_packed_str(&mut caller, src)?;
            let dst = vibe_read_packed_str(&mut caller, dst)?;
            fs::copy(&src, &dst)
                .map_err(|e| format_err!("vibe fs_copy '{src}' -> '{dst}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_append",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            let mut f = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| format_err!("vibe fs_append '{path}': {e}"))?;
            f.write_all(content.as_bytes())
                .map_err(|e| format_err!("vibe fs_append '{path}': {e}"))?;
            Ok(())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_is_dir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(i64::from(std::path::Path::new(&path).is_dir()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_is_file",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            Ok(i64::from(std::path::Path::new(&path).is_file()))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_file",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            vibe_atomic_write(&path, content.as_bytes())
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_publish_immutable_text",
        |mut caller: Caller<'_, HostState>, path: i64, content: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let content = vibe_read_packed_str(&mut caller, content)?;
            Ok(i64::from(vibe_publish_immutable_text(
                &path,
                content.as_bytes(),
            )))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_write_bytes",
        |mut caller: Caller<'_, HostState>, path: i64, bytes: i64| -> Result<()> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            let data = vibe_read_packed_bytes(&mut caller, bytes)?;
            vibe_atomic_write(&path, &data)
        },
    )?;
    // #632: fs_read_bytes — binary-exact file read into a guest Bytes value (the
    // inverse of fs_write_bytes; unlike fs_read_file it does not lossily utf8).
    linker.func_wrap(
        "vibe",
        "fs_read_bytes",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let path = vibe_read_packed_str(&mut caller, path)?;
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_bytes_calls += 1;
            }
            let data = match fs::read(&path) {
                Ok(d) => d,
                Err(e) => {
                    return Err(vibe_host_error(
                        &mut caller,
                        format!("fs_read_bytes failed for '{path}': {e}"),
                    ))
                }
            };
            if let Some(counters) = caller.data_mut().host_fs_scope_mut() {
                counters.read_bytes_returned_bytes += data.len() as u64;
            }
            vibe_alloc_packed_bytes(&mut caller, &data)
        },
    )?;
    // #729/#730 + #2957: Fs::readdir — entry NAMES of a directory, byte-sorted
    // and joined into ONE packed string (same (i64)->i64 ABI as fs_read_file,
    // so no host-side array building and it works under RC and bump alike;
    // codegen splits guest-side). Empty dir -> "". Missing dir -> error,
    // matching fs_read_file.
    //
    // The separator is NUL, the one byte a POSIX name cannot contain. A name
    // MAY contain '\n', so the "\n"-joined `fs_read_dir` split such a name into
    // fake entries (#2957). `fs_read_dir` stays only for modules built by a
    // compiler from before #2957 (the committed seed and whatever it
    // compiles), which import it under that name and split on '\n'; delete it
    // once the seed emits `fs_read_dir_nul`. The node runner carries the same
    // pair.
    linker.func_wrap(
        "vibe",
        "fs_read_dir_nul",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let names = vibe_read_dir_names(&mut caller, path)?;
            vibe_alloc_packed_str(&mut caller, &names.join("\0"))
        },
    )?;
    linker.func_wrap(
        "vibe",
        "fs_read_dir",
        |mut caller: Caller<'_, HostState>, path: i64| -> Result<i64> {
            let names = vibe_read_dir_names(&mut caller, path)?;
            vibe_alloc_packed_str(&mut caller, &names.join("\n"))
        },
    )?;
    // #901: Stdout/Stderr stream builtins (lib/@vibe/io's Stdout::write_stream
    // / write_char and the new Stderr counterparts) -- previously only
    // implemented in scripts/wasm_vibe_host_runner.js (the JS runner used by
    // scripts/vibe_run.sh), never ported to this Rust runner (the one the
    // real `vibe run` CLI actually uses), so any program using them failed to
    // instantiate here with an unknown-import error. Writes immediately (no
    // buffering), matching the JS runner's semantics exactly -- the older,
    // buffered `spectest::print_char` above is a SEPARATE, legacy mechanism
    // for `print_int`/plain program output and is left untouched.
    linker.func_wrap(
        "vibe",
        "stdout_write_stream",
        |mut caller: Caller<'_, HostState>, s: i64| -> Result<()> {
            let s = vibe_read_packed_str(&mut caller, s)?;
            let stdout = io::stdout();
            let mut h = stdout.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stdout_write_stream: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    linker.func_wrap("vibe", "stdout_write_char", |code: i64| -> Result<()> {
        let cu = (code as u32 & 0xffff) as u16;
        let s = String::from_utf16_lossy(&[cu]);
        let stdout = io::stdout();
        let mut h = stdout.lock();
        h.write_all(s.as_bytes())
            .map_err(|e| format_err!("vibe stdout_write_char: {e}"))?;
        h.flush().ok();
        Ok(())
    })?;
    linker.func_wrap(
        "vibe",
        "stderr_write_stream",
        |mut caller: Caller<'_, HostState>, s: i64| -> Result<()> {
            let s = vibe_read_packed_str(&mut caller, s)?;
            let stderr = io::stderr();
            let mut h = stderr.lock();
            h.write_all(s.as_bytes())
                .map_err(|e| format_err!("vibe stderr_write_stream: {e}"))?;
            h.flush().ok();
            Ok(())
        },
    )?;
    linker.func_wrap("vibe", "stderr_write_char", |code: i64| -> Result<()> {
        let cu = (code as u32 & 0xffff) as u16;
        let s = String::from_utf16_lossy(&[cu]);
        let stderr = io::stderr();
        let mut h = stderr.lock();
        h.write_all(s.as_bytes())
            .map_err(|e| format_err!("vibe stderr_write_char: {e}"))?;
        h.flush().ok();
        Ok(())
    })?;
    // #lsp-selfhost: `Stdin` (lib/@vibe/io) -- same pre-existing-JS-only gap
    // as Stdout/Stderr above (#901), just never hit until a program that
    // actually READS stdin (rather than only writing it) was run under this
    // Rust runner: `scripts/wasm_vibe_host_runner.js`'s `stdin_read_char`/
    // `stdin_read_stream` only ever fed a FIXED, pre-buffered
    // `VIBE_STDIN_BYTES` env var set before the process starts (a testing
    // convenience for one-shot batch fixtures, see that file's own comment),
    // never a live incremental read from a real stdin pipe -- so any program
    // using `Stdin::read_char`/`read_stream` failed to instantiate here at
    // all (unknown import) and could never have worked interactively (e.g.
    // piped from a live editor process) under either runner. Blocking reads
    // straight off `std::io::stdin()`, matching Stdout/Stderr's write-
    // straight-through-no-buffering semantics: `read_char` blocks for
    // exactly one byte (-1 at EOF); `read_stream(n)` issues one blocking
    // `Read::read` for up to `n` bytes and returns whatever came back
    // (short reads preserved, "" at EOF) -- the "one bounded pull, cursor
    // advances across calls" contract lib/@vibe/io/io.vibe's own doc
    // comment documents. `.lock()` is re-acquired fresh each call (cheap,
    // and correct: the underlying buffered reader is process-global, no
    // state lives in the lock guard itself), matching every other stdio
    // host function here.
    // Length of the longest prefix of `buf` that ends on a complete UTF-8
    // sequence boundary -- i.e. everything past the returned index (if any)
    // is a lead byte whose continuation bytes haven't arrived yet. Used by
    // `stdin_read_stream` so a pipe read that splits a multi-byte character
    // across two `read()` calls doesn't get lossy-decoded (and thereby
    // corrupted) in the earlier call; the incomplete tail is held back and
    // prefixed onto the next read instead.
    fn utf8_complete_prefix_len(buf: &[u8]) -> usize {
        let len = buf.len();
        if len == 0 {
            return 0;
        }
        // Walk back over trailing continuation bytes (0x80..=0xBF, at most 3 --
        // a well-formed sequence is at most 4 bytes total) to find the start of
        // the last (possibly incomplete) sequence.
        let mut lead_pos = len;
        let mut back = 0;
        while back < 3 && lead_pos > 0 && (buf[lead_pos - 1] & 0xC0) == 0x80 {
            lead_pos -= 1;
            back += 1;
        }
        if lead_pos == 0 {
            // Nothing but continuation bytes within the lookback window and no
            // lead byte in view -- not a shape a real UTF-8 stream produces;
            // nothing sensible to hold back.
            return len;
        }
        let lead = buf[lead_pos - 1];
        let seq_len: usize = if (0xF0..=0xF7).contains(&lead) {
            4
        } else if (0xE0..=0xEF).contains(&lead) {
            3
        } else if (0xC2..=0xDF).contains(&lead) {
            2
        } else {
            // ASCII, or not a valid multi-byte lead byte -- nothing pending.
            return len;
        };
        if lead_pos - 1 + seq_len > len {
            lead_pos - 1
        } else {
            len
        }
    }

    // `sleep(Int) -> Unit with { Async }` -- codegen (linked_compile.vibe)
    // emits `vibe.sleep (i64) -> ()` whenever a program calls the builtin,
    // but neither this runner nor the Node dev runner ever registered it,
    // so any real caller (e.g. lib/@vibe/time's public `sleep_ms`,
    // lib/@vibex/shell's `sleep`) crashed the real `vibe run` at
    // instantiation with an unknown-import trap -- never reached `sleep`
    // actually running, let alone sleeping the wrong amount. A plain
    // blocking `thread::sleep` (matching tools/async_host/src/main.rs's own
    // reference impl) fixes the crash and is correct for the common case of
    // a single sequential caller; it does NOT give concurrently-`spawn`ed
    // tasks true interleaved sleep (each `sleep` blocks the whole wasm
    // instance) -- that needs wasmtime's async-fiber support
    // (tools/async_host/src/concurrency.rs's `func_wrap_async`, a much
    // larger change to how this store/linker are configured) and no known
    // caller needs it today.
    linker.func_wrap(
        "vibe",
        "sleep",
        |_caller: Caller<'_, HostState>, ms: i64| -> Result<()> {
            if ms > 0 {
                std::thread::sleep(std::time::Duration::from_millis(ms as u64));
            }
            Ok(())
        },
    )?;

    linker.func_wrap(
        "vibe",
        "stdin_read_char",
        |_caller: Caller<'_, HostState>| -> Result<i64> {
            let mut buf = [0u8; 1];
            let stdin = io::stdin();
            let mut h = stdin.lock();
            match h.read(&mut buf) {
                Ok(0) => Ok(-1),
                Ok(_) => Ok(buf[0] as i64),
                Err(e) => Err(format_err!("vibe stdin_read_char: {e}")),
            }
        },
    )?;
    linker.func_wrap(
        "vibe",
        "stdin_read_stream",
        |mut caller: Caller<'_, HostState>, n: i64| -> Result<i64> {
            if n <= 0 {
                return vibe_alloc_packed_str(&mut caller, "");
            }
            let mut buf = std::mem::take(&mut caller.data_mut().stdin_pending);
            let before_pending = buf.len();
            buf.resize(before_pending + n as usize, 0);
            let read = {
                let stdin = io::stdin();
                let mut h = stdin.lock();
                h.read(&mut buf[before_pending..])
                    .map_err(|e| format_err!("vibe stdin_read_stream: {e}"))?
            };
            buf.truncate(before_pending + read);
            // Hold back a trailing incomplete UTF-8 sequence (if any) for the
            // next call instead of lossy-decoding it now -- see this closure's
            // registration comment and utf8_complete_prefix_len's doc comment.
            // At EOF (read == 0 and nothing new arrived) there's nothing left
            // to wait for, so decode whatever's pending lossily rather than
            // holding it forever.
            let complete_len = if read == 0 {
                buf.len()
            } else {
                utf8_complete_prefix_len(&buf)
            };
            let pending = buf.split_off(complete_len);
            let s = String::from_utf8_lossy(&buf).into_owned();
            caller.data_mut().stdin_pending = pending;
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    // #901: `Process` effect (lib/@vibe/process) -- same pre-existing-JS-only
    // gap as Stdout/Stderr above. `sh` inherits stdio (so the child's own
    // output goes straight to the real terminal, matching a shell `$(...)`
    // running interactively) and throws (a host-call Err, which surfaces as a
    // wasm trap) on a non-zero exit -- there is no successful-but-failed
    // return value, mirroring wasm_vibe_host_runner.js's unconditional
    // `execSync(cmd, {stdio: "inherit"})` (which throws JS-side on failure).
    linker.func_wrap(
        "vibe",
        "sh",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let status = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .status()
                .map_err(|e| format_err!("vibe sh '{cmd}': {e}"))?;
            if !status.success() {
                bail!("vibe sh '{cmd}': exited with {status}");
            }
            Ok(0)
        },
    )?;
    // `sh_lines`: combined stdout+stderr (matching the JS runner's `execSync`
    // with piped stdio, which merges neither by default -- only stdout is
    // captured on success), trimmed of a trailing newline; on failure returns
    // an "error: "-prefixed string instead of throwing (the JS runner's
    // try/catch shape), since callers pattern-match this prefix rather than
    // branch on a real exit code (that's what `sh_capture` below is for).
    linker.func_wrap(
        "vibe",
        "sh_lines",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let output = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .output()
                .map_err(|e| format_err!("vibe sh_lines '{cmd}': {e}"))?;
            let result = if output.status.success() {
                String::from_utf8_lossy(&output.stdout)
                    .trim_end()
                    .to_string()
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let stderr = stderr.trim();
                if stderr.is_empty() {
                    format!("error: exited with {}", output.status)
                } else {
                    format!("error: {stderr}")
                }
            };
            vibe_alloc_packed_str(&mut caller, &result)
        },
    )?;
    // #901 (originally #865): structured subprocess result. `sh_capture` runs
    // the command ONCE via `output()` (which reports stdout/stderr/status
    // uniformly for both the success and failure case, unlike `sh`/`sh_lines`
    // above) and parks {exit_code, stdout, stderr} behind a handle so the 3
    // accessor imports below are cheap map reads, not re-execs -- same shape
    // as wasm_vibe_host_runner.js's `shCaptureResults` map.
    linker.func_wrap(
        "vibe",
        "sh_capture",
        |mut caller: Caller<'_, HostState>, cmd: i64| -> Result<i64> {
            let cmd = vibe_read_packed_str(&mut caller, cmd)?;
            let output = std::process::Command::new("/bin/bash")
                .arg("-c")
                .arg(&cmd)
                .output()
                .map_err(|e| format_err!("vibe sh_capture '{cmd}': {e}"))?;
            // On Unix a signal-killed child has no exit code; fall back to
            // 128 (the shell convention), matching wasm_vibe_host_runner.js's
            // signal-vs-status handling since Rust's ExitStatus doesn't
            // separately report "not exited yet" the way Node's does.
            let exit_code = output.status.code().unwrap_or(128);
            let host = caller.data_mut();
            let handle = host.next_sh_capture_handle;
            host.next_sh_capture_handle += 1;
            host.sh_capture_results.insert(
                handle,
                ShCaptureResult {
                    exit_code,
                    stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                    stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                },
            );
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_exit_code",
        |caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let entry = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_exit_code: unknown handle"))?;
            Ok(entry.exit_code as i64)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_stdout",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let s = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_stdout: unknown handle"))?
                .stdout
                .clone();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "sh_capture_stderr",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let s = caller
                .data()
                .sh_capture_results
                .get(&handle)
                .ok_or_else(|| format_err!("vibe sh_capture_stderr: unknown handle"))?
                .stderr
                .clone();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    // Tolerates unknown handles, like the JS runner's `sh_capture_close` --
    // a double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "sh_capture_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().sh_capture_results.remove(&handle);
            Ok(())
        },
    )?;
    // Socket::tcp_connect/tcp_read/tcp_write/tcp_close -- declared builtins
    // (checker/builtin_registry.vibe) with a real call site
    // (lib/@vibe/socket/tcp.vibe's low-level layer) but, like fs_rename
    // before #1220, never wired to a host import here, so any real caller
    // crashed `vibe run` with an unknown-import trap. Blocking `std::net`
    // calls, same synchronous-ABI convention as every other host import in
    // this file (see this file's `sleep` import for the same tradeoff
    // spelled out) -- handles are parked in `tcp_connections`, same
    // handle-map shape as `sh_capture_results` above (a TcpStream itself
    // can't cross the wasm ABI).
    linker.func_wrap(
        "vibe",
        "tcp_connect",
        |mut caller: Caller<'_, HostState>, host: i64, port: i64| -> Result<i64> {
            let host = vibe_read_packed_str(&mut caller, host)?;
            let port = u16::try_from(port)
                .map_err(|_| format_err!("vibe tcp_connect: invalid port {port}"))?;
            let stream = std::net::TcpStream::connect((host.as_str(), port))
                .map_err(|e| format_err!("vibe tcp_connect '{host}:{port}': {e}"))?;
            let host_state = caller.data_mut();
            let handle = host_state.next_tcp_handle;
            host_state.next_tcp_handle += 1;
            host_state.tcp_connections.insert(handle, stream);
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "tcp_read",
        |mut caller: Caller<'_, HostState>, handle: i64, max_bytes: i64| -> Result<i64> {
            let max_bytes = usize::try_from(max_bytes.max(0))
                .map_err(|_| format_err!("vibe tcp_read: invalid max_bytes {max_bytes}"))?;
            let mut buf = vec![0u8; max_bytes];
            let read = {
                let stream = caller
                    .data_mut()
                    .tcp_connections
                    .get_mut(&handle)
                    .ok_or_else(|| format_err!("vibe tcp_read: unknown handle"))?;
                stream
                    .read(&mut buf)
                    .map_err(|e| format_err!("vibe tcp_read: {e}"))?
            };
            buf.truncate(read);
            let s = String::from_utf8_lossy(&buf).into_owned();
            vibe_alloc_packed_str(&mut caller, &s)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "tcp_write",
        |mut caller: Caller<'_, HostState>, handle: i64, data: i64| -> Result<()> {
            let data = vibe_read_packed_str(&mut caller, data)?;
            let stream = caller
                .data_mut()
                .tcp_connections
                .get_mut(&handle)
                .ok_or_else(|| format_err!("vibe tcp_write: unknown handle"))?;
            stream
                .write_all(data.as_bytes())
                .map_err(|e| format_err!("vibe tcp_write: {e}"))?;
            Ok(())
        },
    )?;
    // Tolerates unknown handles, like sh_capture_close above -- a
    // double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "tcp_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().tcp_connections.remove(&handle);
            Ok(())
        },
    )?;
    // #1226: Http::request/response_status/response_header/response_body/close
    // -- declared builtins (checker/builtin_registry.vibe) with real call
    // sites (lib/@vibe/http/http.vibe's client-side raw dunder calls, #794)
    // but no host-import registration anywhere, so any real caller crashed
    // `vibe run` with an unknown-import trap. `headers` is a "name:
    // value\n"-joined string (lib/@vibe/http/high_level.vibe's
    // `headers_to_wire`), matching what a caller building on the low-level
    // `request()` already produces.
    linker.func_wrap(
        "vibe",
        "http_request",
        |mut caller: Caller<'_, HostState>,
         method: i64,
         url: i64,
         headers: i64,
         body: i64|
         -> Result<i64> {
            let method = vibe_read_packed_str(&mut caller, method)?;
            let url = vibe_read_packed_str(&mut caller, url)?;
            let headers = vibe_read_packed_str(&mut caller, headers)?;
            let body = vibe_read_packed_str(&mut caller, body)?;
            let mut req = ureq::request(&method, &url);
            for line in headers.split('\n') {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                if let Some((name, value)) = line.split_once(':') {
                    req = req.set(name.trim(), value.trim());
                }
            }
            let result = if body.is_empty() {
                req.call()
            } else {
                req.send_string(&body)
            };
            let response = match result {
                Ok(resp) => resp,
                // ureq treats a 4xx/5xx response as Err by default -- it's
                // still a real, well-formed response (do_404 in
                // http_e2e_test.vibe expects to read a 404 status, not a
                // trap), so unwrap it the same way as the Ok case. Only a
                // genuine transport failure (DNS, connect refused, TLS)
                // falls through to the trap below.
                Err(ureq::Error::Status(_, resp)) => resp,
                Err(e) => return Err(format_err!("vibe http_request '{method} {url}': {e}")),
            };
            let status = response.status() as i64;
            let resp_headers: Vec<(String, String)> = response
                .headers_names()
                .into_iter()
                .filter_map(|name| {
                    let value = response.header(&name)?.to_string();
                    Some((name.to_lowercase(), value))
                })
                .collect();
            let resp_body = response.into_string().map_err(|e| {
                format_err!("vibe http_request '{method} {url}': reading body: {e}")
            })?;
            let host_state = caller.data_mut();
            let handle = host_state.next_http_handle;
            host_state.next_http_handle += 1;
            host_state.http_responses.insert(
                handle,
                HttpResponseData {
                    status,
                    headers: resp_headers,
                    body: resp_body,
                },
            );
            Ok(handle)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_status",
        |caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let entry = caller
                .data()
                .http_responses
                .get(&handle)
                .ok_or_else(|| format_err!("vibe http_response_status: unknown handle"))?;
            Ok(entry.status)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_header",
        |mut caller: Caller<'_, HostState>, handle: i64, name: i64| -> Result<i64> {
            let name = vibe_read_packed_str(&mut caller, name)?;
            let name_lower = name.to_lowercase();
            let value = {
                let entry = caller
                    .data()
                    .http_responses
                    .get(&handle)
                    .ok_or_else(|| format_err!("vibe http_response_header: unknown handle"))?;
                entry
                    .headers
                    .iter()
                    .find(|(hn, _)| *hn == name_lower)
                    .map(|(_, v)| v.clone())
                    .unwrap_or_default()
            };
            vibe_alloc_packed_str(&mut caller, &value)
        },
    )?;
    linker.func_wrap(
        "vibe",
        "http_response_body",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<i64> {
            let body = caller
                .data()
                .http_responses
                .get(&handle)
                .ok_or_else(|| format_err!("vibe http_response_body: unknown handle"))?
                .body
                .clone();
            vibe_alloc_packed_str(&mut caller, &body)
        },
    )?;
    // Tolerates unknown handles, like sh_capture_close/tcp_close above -- a
    // double-close must not kill the guest.
    linker.func_wrap(
        "vibe",
        "http_close",
        |mut caller: Caller<'_, HostState>, handle: i64| -> Result<()> {
            caller.data_mut().http_responses.remove(&handle);
            Ok(())
        },
    )?;
    // #903/#865: `Process::exit(code)` -- propagates a guest-chosen code to
    // the real OS exit status by reusing the SAME trap mechanism the legacy
    // `__moonbit_sys_unstable::exit` import already relies on (see `run()`'s
    // ExitTrap downcast below): trapping here unwinds straight out of the
    // wasm call, and the caller recovers the code and exits the process
    // with it instead of treating the trap as a real error.
    linker.func_wrap(
        "vibe",
        "process_exit",
        |_caller: Caller<'_, HostState>, code: i64| -> Result<()> {
            Err(ExitTrap(code as i32).into())
        },
    )?;
    // debugger breakpoint (DAP P1): the break-mode codegen emits a bare
    // `call vibe::dbg_break` at each user function entry. We capture the wasm
    // backtrace, name the entering function (the innermost user frame via the
    // name section), and pause when it is in the VIBE_BREAK set, printing the
    // call stack, then continue. Always registered (harmless no-op when the
    // module doesn't import it, or when VIBE_BREAK is empty).
    linker.func_wrap(
        "vibe",
        "dbg_break",
        |caller: Caller<'_, HostState>| -> Result<()> { vibe_dbg_break(caller) },
    )?;
    // Interior-line breakpoint (span-arc step5): the break-mode codegen emits
    // `call vibe::dbg_line (i32 line)` at each statement boundary. Pauses on a
    // line-break-set match or step. Always registered (harmless no-op when the
    // module doesn't import it, or when no line breakpoints / step are active).
    linker.func_wrap(
        "vibe",
        "dbg_line",
        |caller: Caller<'_, HostState>, file_id: i32, line: i32| -> Result<()> {
            vibe_dbg_line(caller, file_id, line)
        },
    )?;
    Ok(())
}
