///|
let vbundle_bench_root : String = "/tmp/vibe_vbundle_read_bench"

///|
let fragmented_dir : String = vbundle_bench_root + "/fragmented"

///|
let heavy_dir : String = vbundle_bench_root + "/heavy"

///|
let fragmented_case_count : Int = 256

///|
let fragmented_refs_per_file : Int = 16

///|
let heavy_ref_multiplier : Int = 8

///|
let heavy_total_refs : Int = fragmented_case_count *
  fragmented_refs_per_file *
  heavy_ref_multiplier

///|
fn ensure_dir(path : String) -> Unit {
  if @io.path_exists(path) {
    return
  }
  match @io.create_dir(path) {
    Ok(_) => ()
    Err(err) =>
      if not(@io.path_exists(path)) {
        abort("vbundle bench: create dir failed: " + path + " (" + err + ")")
      }
  }
}

///|
fn lock_to_vbundle_path(lock_path : String) -> String {
  let suffix = "index.lock"
  if lock_path.has_suffix(suffix) && lock_path.length() >= suffix.length() {
    lock_path.unsafe_substring(
      start=0,
      end=lock_path.length() - suffix.length(),
    ) +
    "index.vbundle"
  } else {
    lock_path + ".vbundle"
  }
}

///|
fn prepare_root_dirs() -> Unit {
  ensure_dir(vbundle_bench_root)
  ensure_dir(fragmented_dir)
  ensure_dir(heavy_dir)
}

///|
fn write_lock_or_abort(
  lock_path : String,
  path_refs : Map[String, String],
) -> Unit {
  let lock = @codebase.LockData::new(path_refs, {}, {})
  match @codebase.write_lock_data(lock_path, lock) {
    Ok(_) => ()
    Err(err) => abort("vbundle bench: write lock failed: " + err)
  }
}

///|
fn fragmented_lock_paths() -> Array[String] {
  let paths : Array[String] = []
  for i in 0..<fragmented_case_count {
    paths.push(fragmented_dir + "/case-" + i.to_string() + "/index.lock")
  }
  paths
}

///|
fn setup_fragmented_case() -> Array[String] {
  prepare_root_dirs()
  let marker = fragmented_dir +
    "/.ready-" +
    fragmented_case_count.to_string() +
    "-" +
    fragmented_refs_per_file.to_string()
  let lock_paths = fragmented_lock_paths()
  if @io.path_exists(marker) {
    return lock_paths
  }
  for i in 0..<fragmented_case_count {
    let case_dir = fragmented_dir + "/case-" + i.to_string()
    ensure_dir(case_dir)
    let lock_path = case_dir + "/index.lock"
    let path_refs : Map[String, String] = {}
    for j in 0..<fragmented_refs_per_file {
      let rel_path = "./m" + j.to_string() + ".vibe"
      let hash = @core.git_blob_hash_string(
        "fragmented/" + i.to_string() + "/" + j.to_string(),
      )
      path_refs[rel_path] = hash
    }
    write_lock_or_abort(lock_path, path_refs)
  }
  match @io.write_string(marker, "ok\n") {
    Ok(_) => ()
    Err(err) => abort("vbundle bench: write marker failed: " + err)
  }
  lock_paths
}

///|
fn setup_heavy_case() -> String {
  prepare_root_dirs()
  let lock_path = heavy_dir + "/index.lock"
  let marker = heavy_dir + "/.ready-" + heavy_total_refs.to_string()
  if @io.path_exists(marker) {
    return lock_path
  }
  let path_refs : Map[String, String] = {}
  for i in 0..<heavy_total_refs {
    let rel_path = "./chunk/" + i.to_string() + ".vibe"
    let hash = @core.git_blob_hash_string("heavy/" + i.to_string())
    path_refs[rel_path] = hash
  }
  write_lock_or_abort(lock_path, path_refs)
  match @io.write_string(marker, "ok\n") {
    Ok(_) => ()
    Err(err) => abort("vbundle bench: write marker failed: " + err)
  }
  lock_path
}

///|
fn load_lock_or_abort(lock_path : String) -> @codebase.LockData {
  match @codebase.load_lock_data(lock_path) {
    Ok(lock) => lock
    Err(err) => abort("vbundle bench: load lock failed: " + err)
  }
}

///|
fn read_file_len_or_abort(path : String) -> Int {
  match @io.read_string(path) {
    Ok(content) => content.length()
    Err(err) =>
      abort("vbundle bench: read file failed: " + path + " (" + err + ")")
  }
}

///|
test "bench: vbundle.read.fragmented_many_files" (b : @bench.T) {
  let lock_paths = setup_fragmented_case()
  let mut total_bytes = 0
  for lock_path in lock_paths {
    total_bytes += read_file_len_or_abort(lock_to_vbundle_path(lock_path))
  }
  println(
    "vbundle fragmented fixture: files=" +
    lock_paths.length().to_string() +
    " refs_per_file=" +
    fragmented_refs_per_file.to_string() +
    " total_bytes=" +
    total_bytes.to_string(),
  )
  b.bench(fn() {
    let mut total_refs = 0
    for lock_path in lock_paths {
      let lock = load_lock_or_abort(lock_path)
      total_refs += lock.path_refs.length()
    }
    b.keep(total_refs)
  })
}

///|
test "bench: vbundle.read.single_heavy_file" (b : @bench.T) {
  let lock_path = setup_heavy_case()
  let vbundle_path = lock_to_vbundle_path(lock_path)
  let vbundle_bytes = read_file_len_or_abort(vbundle_path)
  println(
    "vbundle heavy fixture: refs=" +
    heavy_total_refs.to_string() +
    " bytes=" +
    vbundle_bytes.to_string(),
  )
  b.bench(fn() {
    let lock = load_lock_or_abort(lock_path)
    b.keep(lock.path_refs.length())
  })
}
