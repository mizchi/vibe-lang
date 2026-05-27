// Persistent on-disk cache for the parsed prelude AST.
//
// `vibe build` / `vibe check` / `vibe run` etc. are one-shot
// processes, so the in-process `cached_prelude_ast` Ref always starts
// empty and every cold invocation re-parses the ~357-line prelude
// (≈5ms). That 5ms is a fixed tax on every CLI call — 57% of total
// build time on a small file (see profile output below).
//
// Now uses the binary ABI v1 (see `docs/ast_binary_abi.md`). Same
// ABI is implemented by the selfhost compiler at
// `vibe/compiler/ast_binary.vibe`, so caches written by either side
// can be read by the other (parity gated by a roundtrip test).
//
// Profile (examples/perform_handle.vibe, 84 lines, before cache):
//
//   type/prelude_functions   8293us  57.64%  (cum)
//   ├── type/prelude_parse    5439us
//   └── type/prelude_typecheck 2848us
//
// JSON v0 (deprecated) was a wash: 56KB blob, 3.3ms deserialize +
// 2.0ms file read ≈ parse cost. Replaced with binary ABI v1 (see
// `docs/ast_binary_abi.md`) which uses tagged varints and a single
// pass; expected to be substantially faster, measured at use sites.
//
// Cache key = `content_address_hash_string(prelude_source)`. If the
// prelude is ever modified, the hash changes and we re-parse +
// re-write. Multiple Vibe versions can coexist in the same cache
// directory; stale entries are harmless and small.
//
// Falls back to fresh parse on ANY cache error (missing dir, parse
// error, IO error, deserialize error). The cache is a pure speedup
// — never a correctness requirement.

///|
/// Disk cache is on by default (binary ABI v1 measured ~30% faster
/// per CLI invocation on a small program). Set
/// `VIBE_PRELUDE_CACHE=0` to disable for benchmarking or when
/// diagnosing a corrupted cache.
fn prelude_disk_cache_enabled() -> Bool {
  match @sys.get_env_var("VIBE_PRELUDE_CACHE") {
    Some(v) if v == "0" || v == "false" => false
    _ => true
  }
}

///|
/// Build the path where the prelude JSON should live for the current
/// prelude source. Returns `None` if `$HOME` can't be resolved (rare
/// — would only happen in sandboxes that strip env vars).
fn prelude_cache_path() -> String? {
  let home = match @sys.get_env_var("XDG_CACHE_HOME") {
    Some(dir) if dir.length() > 0 => dir
    _ =>
      match @sys.get_env_var("HOME") {
        Some(dir) if dir.length() > 0 => dir + "/.cache"
        _ => return None
      }
  }
  let key = @core.content_address_hash_string(prelude_source)
  // Embed wire version in the filename so a future ABI bump doesn't
  // try to read older blobs. `.bin` = binary ABI v1; the JSON path is
  // retired.
  Some(
    home +
    "/vibe/prelude-" +
    key +
    "-v" +
    @core.AST_BINARY_VERSION.to_string() +
    ".bin",
  )
}

///|
/// Best-effort `mkdir -p` for the parent of `path`. Errors are
/// swallowed — if directory creation fails the subsequent write will
/// fail too and we fall back to the no-cache path.
fn ensure_parent_dir(path : String) -> Unit {
  // Find the last `/` and create everything up to it. We walk the
  // string from left to right creating each intermediate component;
  // `create_dir` errors on already-existing dirs so we ignore those.
  let last_slash = match path.rev_find("/") {
    Some(i) => i
    None => return
  }
  if last_slash <= 0 {
    return
  }
  let parent = path.substring(start=0, end=last_slash)
  // Walk parents from short to long, calling create_dir on each. We
  // can't rely on a recursive mkdir helper being present.
  let parts = parent.split("/")
  let mut acc = ""
  for part in parts {
    let s = part.to_string()
    if s.length() == 0 {
      acc = acc + "/"
      continue
    }
    acc = acc + s
    try @os_fs.create_dir(acc) catch {
      _ => ()
    }
    acc = acc + "/"
  }
}

///|
/// Try to load a previously-cached prelude AST. Returns `None` if
/// the cache is missing, unreadable, or the on-disk format doesn't
/// deserialize cleanly (e.g. format changed between vibe versions).
fn try_load_prelude_ast_from_disk() -> @core.Module? {
  if !prelude_disk_cache_enabled() {
    return None
  }
  let path = match prelude_cache_path() {
    Some(p) => p
    None => return None
  }
  if !@os_fs.path_exists(path) {
    return None
  }
  @profiler.profiler_enter("type/prelude_cache_load")
  @profiler.profiler_enter("type/prelude_cache_read_file")
  let bytes = try @os_fs.read_file_to_bytes(path) catch {
    _ => {
      @profiler.profiler_leave() // read_file
      @profiler.profiler_leave() // cache_load
      return None
    }
  }
  @profiler.profiler_leave() // read_file
  @profiler.profiler_enter("type/prelude_cache_deserialize")
  let result = try @core.deserialize_module_binary(bytes) catch {
    _ => {
      @profiler.profiler_leave() // deserialize
      @profiler.profiler_leave() // cache_load
      return None
    }
  }
  @profiler.profiler_leave() // deserialize
  @profiler.profiler_leave() // cache_load
  Some(result)
}

///|
/// Persist `ast` to the prelude cache. Silently no-ops on any IO
/// error — a failed save just means the next invocation re-parses.
fn save_prelude_ast_to_disk(ast : @core.Module) -> Unit {
  if !prelude_disk_cache_enabled() {
    return
  }
  let path = match prelude_cache_path() {
    Some(p) => p
    None => return
  }
  ensure_parent_dir(path)
  @profiler.profiler_enter("type/prelude_cache_save")
  let bytes = @core.serialize_module_binary(ast)
  try @os_fs.write_bytes_to_file(path, bytes) catch {
    _ => ()
  }
  @profiler.profiler_leave()
}
