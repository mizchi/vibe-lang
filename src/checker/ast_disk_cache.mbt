///|
/// Issue #427: best-effort disk cache for pre-parsed prelude / builtin AST.
///
/// The prelude (`prelude_source`, ~542 lines) and the 12 builtin module
/// sources (`builtin_module_sources`) are static strings embedded in the
/// compiler binary. Parsing them is the dominant fixed cost of the `type`
/// stage on a fresh process (~66% of the compile-path type-stage startup;
/// measured ~67ms total parse in native debug across prelude + builtins).
///
/// Deserializing a binary AST written by `@core.serialize_module_binary` is
/// ~10x faster than re-tokenizing + re-parsing the source (measured: prelude
/// 14.6ms -> 1.5ms, builtins 52.8ms -> 5.7ms). This cache parses each source
/// once, persists the serialized AST under `.vibe/ast/`, and deserializes it
/// on subsequent processes.
///
/// The cache key is `content_hash(source) + AST_BINARY_VERSION`, so it
/// auto-invalidates when either the embedded source or the binary serializer
/// format changes. Every operation is best-effort: any miss, fs error,
/// version skew, or corrupt blob falls back to parsing the source, so the
/// cache never affects correctness or compiler output.

///|
/// Master switch. Defaults on; callers (tests / benches) may flip it via
/// `set_ast_disk_cache_enabled` to measure with vs. without the cache. We do
/// not read an env var here so the checker stays portable across the native
/// CLI and the wasm (WASI) selfhost entrypoints.
let ast_disk_cache_enabled : Ref[Bool] = @ref.new(true)

///|
pub fn set_ast_disk_cache_enabled(enabled : Bool) -> Unit {
  ast_disk_cache_enabled.val = enabled
}

///|
/// Directory holding the serialized AST blobs. Kept relative to the current
/// working directory so it resolves under the wasmtime/moonrun preopens that
/// host the selfhost wasm (which only see cwd, not an absolute `~/.cache`).
let ast_disk_cache_dir : Ref[String] = @ref.new(".vibe/ast")

///|
pub fn set_ast_disk_cache_dir(dir : String) -> Unit {
  ast_disk_cache_dir.val = dir
}

///|
/// Tracks whether the cache directory has been ensured this process, so we
/// only pay the path_exists / create_dir probes once.
let ast_disk_cache_dir_ready : Ref[Bool] = @ref.new(false)

///|
fn ensure_ast_disk_cache_dir() -> Bool {
  if ast_disk_cache_dir_ready.val {
    return true
  }
  let dir = ast_disk_cache_dir.val
  if @os_fs.path_exists(dir) {
    ast_disk_cache_dir_ready.val = true
    return true
  }
  // Create the parent (".vibe") first; `create_dir` is not guaranteed to be
  // recursive. Both steps are best-effort.
  match split_parent(dir) {
    Some(parent) =>
      if !@os_fs.path_exists(parent) {
        @os_fs.create_dir(parent) catch {
          _ => ()
        }
      }
    None => ()
  }
  @os_fs.create_dir(dir) catch {
    _ => ()
  }
  let ok = @os_fs.path_exists(dir)
  ast_disk_cache_dir_ready.val = ok
  ok
}

///|
/// Return everything before the last '/' in `path`, or None if there is none.
fn split_parent(path : String) -> String? {
  let mut idx = -1
  let chars = path.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      idx = i
    }
  }
  if idx <= 0 {
    None
  } else {
    Some(path.substring(start=0, end=idx))
  }
}

///|
/// Parser/desugar semantics version, independent of the binary wire format
/// (`AST_BINARY_VERSION`). `AST_BINARY_VERSION` only changes when the
/// serializer's *encoding* changes; it does NOT change when `@parser.parse_ast`
/// / desugar start producing a *different AST* for the same source. Without a
/// separate knob, a parser-only fix would silently reuse a stale blob parsed by
/// the old parser (the prelude/builtin source string is unchanged), until
/// `.vibe/ast` is deleted by hand.
///
/// **Bump this whenever a parser/desugar change alters the AST produced for
/// unchanged prelude/builtin source** so the cache key invalidates old blobs.
const AST_CACHE_PARSER_VERSION : Int = 1

///|
fn ast_disk_cache_path(source : String) -> String {
  ast_disk_cache_dir.val +
  "/" +
  @core.content_address_hash_string(source) +
  ".v" +
  @core.AST_BINARY_VERSION.to_string() +
  "-p" +
  AST_CACHE_PARSER_VERSION.to_string() +
  ".vast"
}

///|
/// Read and deserialize a cached blob, or None on any fs / decode failure.
fn load_cached_ast(path : String) -> @core.Module? {
  if !@os_fs.path_exists(path) {
    return None
  }
  let bytes = @os_fs.read_file_to_bytes(path) catch { _ => return None }
  Some(@core.deserialize_module_binary(bytes)) catch {
    _ => None
  }
}

///|
/// Parse `source` into a Module, using the on-disk AST cache when enabled.
/// Mirrors `@parser.parse_ast`'s raising contract: a genuine parse error on a
/// cache miss still propagates so call sites keep their existing handling.
pub fn parse_ast_cached(
  source : String,
) -> @core.Module raise @parser.ParseError {
  if !ast_disk_cache_enabled.val {
    return @parser.parse_ast(source)
  }
  let path = ast_disk_cache_path(source)
  match load_cached_ast(path) {
    Some(m) => m
    None => {
      // Miss / corrupt / version skew: parse, then persist best-effort.
      let m = @parser.parse_ast(source)
      if ensure_ast_disk_cache_dir() {
        let blob = @core.serialize_module_binary(m)
        @os_fs.write_bytes_to_file(path, blob) catch {
          _ => ()
        }
      }
      m
    }
  }
}
