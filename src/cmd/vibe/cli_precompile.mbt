///|
struct PrecompileOptions {
  dirs : Array[String]
  out_dir : String
  wasm_js_string : Bool
  opt_level : String?
} derive(Show, Eq)

///|
fn parse_precompile_cmd_args(
  args : Array[String],
) -> Result[PrecompileOptions, String] {
  let dirs : Array[String] = []
  let mut out_dir = "dist"
  let mut wasm_js_string = false
  let mut opt_level : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--out-dir" {
      i += 1
      if i >= args.length() {
        return Err("precompile: --out-dir requires argument")
      }
      out_dir = args[i]
    } else if arg == "--wasm-js-string" {
      wasm_js_string = true
    } else if arg == "--wasm" {
      wasm_js_string = false
    } else if arg.has_prefix("-O") {
      let buf = StringBuilder::new()
      for j, c in arg {
        if j >= 2 {
          buf.write_char(c)
        }
      }
      opt_level = Some(buf.to_string())
    } else if arg.has_prefix("--") {
      return Err("precompile: unknown option " + arg)
    } else {
      dirs.push(arg)
    }
    i += 1
  }
  if dirs.length() == 0 {
    return Err("precompile: expected <dir...>")
  }
  Ok({ dirs, out_dir, wasm_js_string, opt_level })
}

///|
fn strip_first_path_component(path : String) -> String {
  let buf = StringBuilder::new()
  let mut found_slash = false
  for c in path {
    if found_slash {
      buf.write_char(c)
    } else if c == '/' {
      found_slash = true
    }
  }
  buf.to_string()
}

///|
fn precompile_cmd(args : Array[String]) -> Unit {
  let opts = match parse_precompile_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let fs = @io.default_fs_adapter()
  // Ensure output directory exists
  ensure_dir_recursive(opts.out_dir)
  let mut compiled = 0
  let mut total = 0
  let errors : Array[String] = []
  for dir in opts.dirs {
    let entries = match @io.read_dir_with(fs, dir) {
      Ok(v) => v
      Err(err) => {
        errors.push("precompile: read_dir " + dir + ": " + err)
        continue
      }
    }
    // Compute output subdirectory: strip first path component from dir
    // e.g. "vibe/std" -> "std", "vibe/std/path" -> "std/path"
    let dir_suffix = strip_first_path_component(dir)
    let file_out_dir = if dir_suffix.length() > 0 {
      opts.out_dir + "/" + dir_suffix
    } else {
      opts.out_dir
    }
    ensure_dir_recursive(file_out_dir)
    for entry in entries {
      if not(entry.has_suffix(".vibe")) {
        continue
      }
      // Skip entries that are too short to be valid filenames (e.g. ".vibe" artifacts)
      if entry.length() <= 5 {
        continue
      }
      if entry.has_suffix("_test.vibe") || entry.has_suffix("_bench.vibe") {
        continue
      }
      let path = dir + "/" + entry
      total += 1
      match
        precompile_one_file(
          fs,
          path,
          file_out_dir,
          opts.wasm_js_string,
          opts.opt_level,
        ) {
        Ok(out_path) => {
          println("  compiled: " + path + " -> " + out_path)
          compiled += 1
        }
        Err(err) => {
          println("  error: " + path + ": " + err)
          errors.push(path + ": " + err)
        }
      }
    }
  }
  println(
    "precompile: \{compiled}/\{total} modules compiled to \{opts.out_dir}",
  )
  if errors.length() > 0 {
    println("errors:")
    for err in errors {
      println("  - " + err)
    }
    abort("precompile: \{errors.length()} error(s)")
  }
}

///|
fn precompile_one_file(
  fs : &@io.FileSystemAdapter,
  path : String,
  out_dir : String,
  wasm_js_string : Bool,
  opt_level : String?,
) -> Result[String, String] {
  let (db, entry) = match @loader.load_db_with_fs(path, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let wasm_bytes = if wasm_js_string {
    @runtime.compile_module_wasm_js_string_with_opt_level(db, entry, opt_level~) catch {
      e => return Err(e.user_message())
    }
  } else {
    @runtime.compile_module_wasm_with_opt_level(db, entry, opt_level~) catch {
      e => return Err(e.user_message())
    }
  }
  let basename = get_basename(path)
  let out_path = out_dir + "/" + basename + ".wasm"
  match @io.write_bytes_with(fs, out_path, wasm_bytes) {
    Ok(_) => Ok(out_path)
    Err(err) => Err("write: " + err)
  }
}
