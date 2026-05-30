///|
/// Issue #402: disk snapshot of the prelude value-stmt partition.
///
/// `prelude_partition_value_stmts` builds a dependency graph + runs a fixpoint
/// over the prelude value defs to split them into "core" vs "builtin-dependent"
/// (~0.8ms native / ~2-4ms selfhost-wasm). #479 memoized it per-process, but a
/// fresh selfhost process (one compile per invocation) re-pays it every time.
///
/// The split is fully determined by which value names are builtin-dependent, so
/// we snapshot just that name set to disk (reusing the #427/#476 `.vibe/ast`
/// plumbing). A fresh process loads the names and re-splits `prelude_ast()` by
/// name — an O(stmts) pass with no graph/fixpoint. Bit-for-bit equivalent to
/// the computed partition (same value-stmt order, same classification).
///
/// All best-effort: any disabled cache / miss / fs error / version skew falls
/// back to computing the partition. Bump `PARTITION_SNAPSHOT_VERSION` if the
/// partition *logic* changes so stale name sets invalidate.

///|
const PARTITION_SNAPSHOT_VERSION : Int = 1

///|
fn partition_snapshot_path() -> String {
  ast_disk_cache_dir.val +
  "/prelude-partition." +
  @core.content_address_hash_string(prelude_source) +
  ".v" +
  PARTITION_SNAPSHOT_VERSION.to_string() +
  ".names"
}

///|
/// Encode the builtin-dependent name set as a length-prefixed string list.
fn encode_partition_names(names : Array[String]) -> Bytes {
  let w = @core.TypeBinWriter::new()
  w.uint(names.length())
  for n in names {
    w.str(n)
  }
  w.to_bytes()
}

///|
fn decode_partition_names(
  bytes : Bytes,
) -> Array[String] raise @core.BinaryDeserializeError {
  let r = @core.TypeBinReader::new(bytes)
  let n = r.uint()
  let names : Array[String] = []
  for _i in 0..<n {
    names.push(r.str())
  }
  names
}

///|
/// Re-split the prelude value stmts by a known builtin-dependent name set,
/// reproducing `prelude_partition_value_stmts`'s output without the graph.
fn split_prelude_value_stmts(
  ast : @core.Module,
  builtin_names : Map[String, Bool],
) -> (Array[@core.Stmt], Array[@core.Stmt]) {
  let core_stmts : Array[@core.Stmt] = []
  let builtin_stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) =>
        if builtin_names.contains(name) {
          builtin_stmts.push(stmt)
        } else {
          core_stmts.push(stmt)
        }
      None => ()
    }
  }
  (core_stmts, builtin_stmts)
}

///|
fn builtin_names_of(builtin_stmts : Array[@core.Stmt]) -> Array[String] {
  let names : Array[String] = []
  for stmt in builtin_stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) => names.push(name)
      None => ()
    }
  }
  names
}

///|
/// Try to load the partition from disk and re-split. None on
/// disabled/miss/fs-error/version-skew/corrupt.
fn try_load_prelude_partition(
  ast : @core.Module,
) -> (Array[@core.Stmt], Array[@core.Stmt])? {
  if !ast_disk_cache_enabled.val {
    return None
  }
  let path = partition_snapshot_path()
  if !@os_fs.path_exists(path) {
    return None
  }
  let bytes = @os_fs.read_file_to_bytes(path) catch { _ => return None }
  let names = decode_partition_names(bytes) catch { _ => return None }
  let set : Map[String, Bool] = {}
  for n in names {
    set[n] = true
  }
  Some(split_prelude_value_stmts(ast, set))
}

///|
fn save_prelude_partition(builtin_stmts : Array[@core.Stmt]) -> Unit {
  if !ast_disk_cache_enabled.val {
    return
  }
  if !ensure_ast_disk_cache_dir() {
    return
  }
  let bytes = encode_partition_names(builtin_names_of(builtin_stmts))
  @os_fs.write_bytes_to_file(partition_snapshot_path(), bytes) catch {
    _ => ()
  }
}
