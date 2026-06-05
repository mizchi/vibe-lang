///|
fn load_entry_db_for_compile_with_features(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[(@runtime.VibeDb, String), String] {
  let (db, entry) = match @loader.load_db_with_fs(entry_path, fs) {
    Err(err) => return Err(err)
    Ok(v) => v
  }
  match require_unstable_threads_for_db_entry(db, entry, features) {
    Some(err) => Err(err)
    None => Ok((db, entry))
  }
}

///|
fn compile_lite_cmd(
  args : Array[String],
  features? : @runtime.RuntimeFeatureFlags = @runtime.RuntimeFeatureFlags::stable(),
) -> Unit {
  let (compile_args, profile_tsv, profile_callstack, in_memory) = match
    split_compile_lite_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let opts = match parse_compile_cmd_args(compile_args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  match compile_lite_validate_opts(opts, in_memory) {
    Ok(_) => ()
    Err(msg) => abort(msg)
  }
  if profile_callstack is Some(_) {
    @profiler.profiler_set_enabled(true)
    @profiler.profiler_reset()
  }
  let fs = @io.default_fs_adapter()
  let out_path = match opts.out_path {
    Some(path) => path
    None => ""
  }
  @runtime_compile.init_hooks()
  let start_total = @bench.monotonic_clock_start()
  @profiler.profiler_enter("load")
  let start_load = @bench.monotonic_clock_start()
  match load_entry_db_for_compile_with_features(opts.entry_path, fs, features) {
    Err(err) => abort("compile-lite: " + err)
    Ok((db, entry)) => {
      let load_us = elapsed_us_from(start_load)
      @profiler.profiler_leave()
      @profiler.profiler_enter("type")
      let start_type = @bench.monotonic_clock_start()
      let _ = db.types(entry)
      let type_us = elapsed_us_from(start_type)
      @profiler.profiler_leave()
      let (wasm_bytes, compile_profile) = if opts.mode == CompileMode::WasmGc {
        @runtime_compile.compile_module_wasm_gc_with_opt_level_profiled(
          db,
          entry,
          no_dce=opts.no_dce,
          opt_level=opts.opt_level,
        ) catch {
          e => abort("compile-lite: " + e.user_message())
        }
      } else {
        @runtime_compile.compile_module_wasm_with_opt_level_profiled(
          db,
          entry,
          no_dce=opts.no_dce,
          opt_level=opts.opt_level,
          debug_errors=false,
          http_host_imports=false,
          force_cabi_realloc=false,
        ) catch {
          e => abort("compile-lite: " + e.user_message())
        }
      }
      let mut write_us = 0
      if !in_memory {
        @profiler.profiler_enter("write")
        let start_write = @bench.monotonic_clock_start()
        match @io.write_bytes_with(fs, out_path, wasm_bytes) {
          Ok(_) => ()
          Err(err) => abort("compile-lite: " + err)
        }
        write_us = elapsed_us_from(start_write)
        @profiler.profiler_leave()
      }
      let total_us = elapsed_us_from(start_total)
      match profile_tsv {
        Some(path) => {
          let content = @runtime_compile.wasm_compile_profile_tsv(
            load_us, type_us, compile_profile, write_us, total_us,
          )
          match @io.write_string_with(fs, path, content) {
            Ok(_) => ()
            Err(err) =>
              abort("compile-lite: failed to write profile tsv: " + err)
          }
        }
        None => ()
      }
      match profile_callstack {
        Some(path) => {
          let content = @profiler.profiler_report_tsv()
          match @io.write_string_with(fs, path, content) {
            Ok(_) => ()
            Err(err) =>
              abort("compile-lite: failed to write callstack profile: " + err)
          }
        }
        None => ()
      }
    }
  }
}

///|
fn compile_cmd(
  args : Array[String],
  features? : @runtime.RuntimeFeatureFlags = @runtime.RuntimeFeatureFlags::stable(),
) -> Unit {
  if has_help_flag(args) {
    print_compile_help()
    return
  }
  let opts = match parse_compile_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  match
    ensure_compile_coverage_allowed(
      opts.coverage,
      compile_coverage_test_mode_enabled(),
    ) {
    Ok(_) => ()
    Err(msg) => abort(msg)
  }
  let fs = @io.default_fs_adapter()
  if opts.mode == CompileMode::Wac {
    let resolved_out = match opts.out_path {
      Some(path) => path
      None => {
        ensure_dist_dir_with(fs)
        default_output_path(opts.entry_path, opts.mode)
      }
    }
    let synced_count = match
      sync_wac_dependencies_if_configured(opts.entry_path, fs) {
      Ok(v) => v
      Err(msg) => abort("compile: wac deps sync failed: " + msg)
    }
    if synced_count > 0U {
      println("materialized wac deps: " + synced_count.to_string())
    }
    let component = match
      @wite_bundle.compose_wac_file(opts.entry_path, dce=true) {
      Ok(bytes) => bytes
      Err(msg) => abort("compile: wac compose failed: " + msg)
    }
    let optimized = match
      optimize_wasm_bytes_with_opt_level_for_cli(component, opts.opt_level) {
      Ok(bytes) => bytes
      Err(msg) => abort(msg)
    }
    match @io.write_bytes_with(fs, resolved_out, optimized) {
      Ok(_) => ()
      Err(err) => abort("compile: " + err)
    }
    println("wrote " + resolved_out)
    return
  }
  match load_entry_db_for_compile_with_features(opts.entry_path, fs, features) {
    Err(err) => abort("compile: " + err)
    Ok((db, entry)) => {
      // Resolve output path with default to dist/
      let resolved_out = match opts.out_path {
        Some(path) => path
        None => {
          ensure_dist_dir_with(fs)
          default_output_path(opts.entry_path, opts.mode)
        }
      }
      match opts.mode {
        CompileMode::Ir => {
          let compiled = @runtime_compile.compile_module(db, entry) catch {
            e => abort("compile: " + e.to_string())
          }
          match @io.write_string_with(fs, resolved_out, compiled.ir) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Wasm =>
          if opts.coverage {
            let coverage = @runtime_compile.compile_module_wasm_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
              http_host_imports=opts.http_host_imports,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, coverage.bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
            let source = match db.get_source(entry) {
              Some(s) => s
              None => ""
            }
            write_wasm_coverage_sidecar_with(
              fs,
              resolved_out,
              opts.entry_path,
              source,
              coverage,
            )
          } else {
            let wasm_bytes = @runtime_compile.compile_module_wasm_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
              http_host_imports=opts.http_host_imports,
              fs_host_imports=opts.http_host_imports,
              force_cabi_realloc=opts.force_cabi_realloc,
              library_mode=opts.library_mode,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmJsString =>
          if opts.coverage {
            let coverage = @runtime_compile.compile_module_wasm_js_string_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, coverage.bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
            let source = match db.get_source(entry) {
              Some(s) => s
              None => ""
            }
            write_wasm_coverage_sidecar_with(
              fs,
              resolved_out,
              opts.entry_path,
              source,
              coverage,
            )
          } else {
            let wasm_bytes = @runtime_compile.compile_module_wasm_js_string_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmGc =>
          if opts.coverage {
            // Issue #417: coverage path for wasm-gc — emits counter
            // memory + cov_base/cov_count exports + .wasm.cov.json
            // sidecar in the same format the linear backend uses.
            let coverage = @runtime_compile.compile_module_wasm_gc_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, coverage.bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
            let source = match db.get_source(entry) {
              Some(s) => s
              None => ""
            }
            write_wasm_coverage_sidecar_with(
              fs,
              resolved_out,
              opts.entry_path,
              source,
              coverage,
            )
          } else {
            let wasm_bytes = @runtime_compile.compile_module_wasm_gc_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::Component => {
          let wasm_bytes = @runtime_compile.compile_module_component_with_opt_level(
            db,
            entry,
            opt_level=opts.opt_level,
            http_host_imports=opts.http_host_imports,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::ComponentStringLift => {
          let wasm_bytes = @runtime_compile.compile_module_component_string_lift_auto(
            db,
            entry,
            opt_level=opts.opt_level,
            is_async=opts.is_async,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::ComposeP3 => {
          let adapter_path = match opts.adapter_path {
            Some(p) => p
            None => abort("compile: --compose-p3 requires --adapter")
          }
          // Step 1: Compile vibe → sync component (adapter handles async wrapping)
          let app_bytes = @runtime_compile.compile_module_component_string_lift_auto(
            db,
            entry,
            opt_level=opts.opt_level,
            is_async=false,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          // Step 2: Compose with P3 adapter via mwac.plug_components (in-process)
          let adapter_bytes = @os_fs.read_file_to_bytes(adapter_path) catch {
            e => abort("compile: failed to read adapter: " + e.to_string())
          }
          let composed = @runtime_compile.compose_p3_component(
            app_bytes, adapter_bytes,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match ensure_parent_dir_for_file(resolved_out, "compile") {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          @os_fs.write_bytes_to_file(resolved_out, composed) catch {
            e => abort("compile: failed to write output: " + e.to_string())
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Wac =>
          abort(
            "compile: internal error: --wac should bypass vibe source compilation",
          )
        CompileMode::Wit => {
          // Generate WIT with default package/world names derived from filename
          let basename = get_basename(entry)
          let package_name = "local:" + basename
          let world_name = basename
          let wit_str = @runtime_compile.generate_module_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_string_with(fs, resolved_out, wit_str) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::WitComponent => {
          let basename = get_basename(entry)
          let wit_ident = sanitize_wit_ident(basename)
          let package_name = "local:" + wit_ident
          let world_name = wit_ident
          let wit_str = @runtime_compile.generate_module_component_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_string_with(fs, resolved_out, wit_str) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
      }
    }
  }
}

///|
fn[T] die(msg : String) -> T {
  println(msg)
  c_exit(1)
  abort("unreachable")
}

///|
/// `vibe build [--debug|--release] <file.vibe> [-o <out.wasm>] [--profile <path>]`
///
/// --debug:   linked build (pre-compile imports as library .wasm, cache in .vibe/debug/)
/// --release: monolithic build (default, same as `compile --wasm`)
/// --profile: write a pprof / folded / TSV profile to `<path>`
///            (format chosen by extension).
fn build_cmd(
  args : Array[String],
  features? : @runtime.RuntimeFeatureFlags = @runtime.RuntimeFeatureFlags::stable(),
) -> Unit {
  if has_help_flag(args) {
    print_build_help()
    return
  }
  let (args, profile_path) = match extract_profile_flag(args) {
    Ok(v) => v
    Err(msg) => abort("build: " + msg)
  }
  let mut debug_mode = false
  let mut entry_path : String? = None
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--debug" => {
        debug_mode = true
        i += 1
      }
      "--release" => {
        debug_mode = false
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          abort("build: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          abort("build: too many input files")
        }
        i += 1
      }
    }
  }
  let entry = match entry_path {
    Some(p) => p
    None => abort("build: missing <file.vibe>")
  }
  with_profile(profile_path, fn() {
    if debug_mode {
      build_cmd_debug(entry, out_path, features~)
    } else {
      build_cmd_release(entry, out_path, features~)
    }
  })
}

///|
fn build_cmd_release(
  entry : String,
  out_path : String?,
  features? : @runtime.RuntimeFeatureFlags = @runtime.RuntimeFeatureFlags::stable(),
) -> Unit {
  let resolved_out = match out_path {
    Some(p) => p
    None => {
      let base = if entry.has_suffix(".vibe") {
        entry.unsafe_substring(start=0, end=entry.length() - 5)
      } else {
        entry
      }
      base + ".wasm"
    }
  }
  let fs = @io.default_fs_adapter()
  let (db, resolved_entry) = match
    load_entry_db_for_compile_with_features(entry, fs, features) {
    Ok(v) => v
    Err(err) => abort("build: " + err)
  }
  // Try -Oz optimization; fall back to unoptimized if wite doesn't support
  // the generated opcodes (e.g., exceptions/try_table).
  let optimized : Result[Bytes, _] = try? @runtime_compile.compile_module_wasm_with_opt_level(
    db,
    resolved_entry,
    opt_level=Some("-Oz"),
  )
  let wasm_bytes = match optimized {
    Ok(bytes) => bytes
    Err(_) =>
      @runtime_compile.compile_module_wasm_with_opt_level(db, resolved_entry) catch {
        e => abort("build: " + e.user_message())
      }
  }
  @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
    e => abort("build: write failed: " + e.to_string())
  }
  let size = wasm_bytes.length()
  println(
    "build --release: wrote " +
    resolved_out +
    " (" +
    size.to_string() +
    " bytes)",
  )
}

///|
fn build_cmd_debug(
  entry : String,
  out_path : String?,
  features? : @runtime.RuntimeFeatureFlags = @runtime.RuntimeFeatureFlags::stable(),
) -> Unit {
  let resolved_out = match out_path {
    Some(p) => p
    None => {
      let base = if entry.has_suffix(".vibe") {
        entry.unsafe_substring(start=0, end=entry.length() - 5)
      } else {
        entry
      }
      base + ".wasm"
    }
  }
  // In debug linked mode, try fast path: load only user file (skip import I/O).
  let resolved_entry_for_parent = @loader.resolve_entry_path(entry)
  // Hoist .vibe/debug cache to nearest parent .vibe directory.
  // Cache key = relative path from .vibe root to avoid collisions.
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved_entry_for_parent)
  let cache_dir = vibe_root + "/debug/" + cache_key
  let imports_cache_path = cache_dir + "/linked_imports.txt"
  // Check cache validity: imports cache + library .wasm + source hashes
  let hash_cache_path = cache_dir + "/source_hashes.txt"
  let has_cache = if @os_fs.path_exists(imports_cache_path) {
    let cached_text = @os_fs.read_file_to_string(imports_cache_path) catch {
      _ => ""
    }
    let cached = parse_linked_imports_cache(cached_text)
    let module_names : Map[String, Bool] = {}
    let mut all_valid = cached.length() > 0
    // Check library .wasm files exist
    for li in cached {
      if !module_names.contains(li.module_name) {
        module_names[li.module_name] = true
        let lib_path = cache_dir + "/" + li.module_name + ".wasm"
        if !@os_fs.path_exists(lib_path) {
          all_valid = false
        }
      }
    }
    // Check source hashes haven't changed. Older caches without source hash
    // metadata cannot prove imported sources are thread-free, so reload them.
    if all_valid {
      if @os_fs.path_exists(hash_cache_path) {
        let hash_text = @os_fs.read_file_to_string(hash_cache_path) catch {
          _ => ""
        }
        let saved_hashes = parse_source_hash_cache(hash_text)
        for path, saved_hash in saved_hashes {
          let current_source = @os_fs.read_file_to_string(path) catch {
            _ => ""
          }
          if current_source.length() > 0 {
            let current_hash = @vibe_core.content_address_hash_string(
              current_source,
            )
            if current_hash != saved_hash {
              all_valid = false
            }
            if all_valid && !features.is_unstable_threads_enabled() {
              match source_uses_threads_builtins(current_source) {
                Ok(true) => all_valid = false
                Ok(false) => ()
                Err(_) => all_valid = false
              }
            }
          }
        }
      } else {
        all_valid = false
      }
    }
    all_valid
  } else {
    false
  }
  let (wasm_bytes, linked_imports) = if has_cache {
    // Fast path: read cached linked imports, compile user file only
    let resolved = @loader.resolve_entry_path(entry)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("build: " + e.to_string())
    }
    let db = @runtime.VibeDb::new()
    db.set_source(resolved, source)
    // Parse cached linked imports
    let cached_text = @os_fs.read_file_to_string(imports_cache_path) catch {
      _ => ""
    }
    let cached_imports = parse_linked_imports_cache(cached_text)
    let codegen_linked : Array[(String, String, Int, Int)] = []
    for li in cached_imports {
      codegen_linked.push(
        (li.module_name, li.func_name, li.param_count, li.return_count),
      )
    }
    // Parse + desugar + codegen (no import resolution, no typecheck)
    let raw_ast = @parser.parse_ast(source) catch {
      e => abort("build --debug: parse error: " + e.to_string())
    }
    let desugared = @frontend.desugar_method_calls(raw_ast, {})
    let ast = @frontend.rewrite_effect_handles(desugared)
    match require_unstable_threads_for_module(ast, features) {
      Some(err) => abort("build: " + err)
      None => ()
    }
    // Resolve type definitions from entry's ReExport chains (standalone, no db)
    let extra_type_stmts = collect_reexport_type_stmts_standalone(
      resolved, raw_ast,
    )
    let (bundled, _) = @runtime_compile.bundle_for_wasm_linked_with_imports(
      ast,
      cached_imports,
      extra_type_stmts~,
    )
    let maybe_wasm = Some(
      @runtime_compile.emit_wasm_with_linked_imports(bundled, codegen_linked),
    ) catch {
      _ => None
    }
    match maybe_wasm {
      Some(wasm) => (wasm, cached_imports)
      None => {
        // Some deps are intentionally inlined for linked debug builds
        // (e.g. preload-unsafe WASI users). The cache fast path only stores
        // linked imports, so it cannot always reconstruct those inlined defs.
        // Fall back to the full path instead of failing the cached build.
        let fs = @io.default_fs_adapter()
        let (db, resolved_entry) = match
          load_entry_db_for_compile_with_features(entry, fs, features) {
          Ok(v) => v
          Err(err) => abort("build: " + err)
        }
        let (wasm, imports) = @runtime_compile.compile_module_wasm_linked(
          db,
          resolved_entry,
          debug_errors=true,
        ) catch {
          e => abort("build --debug: " + e.user_message())
        }
        let cache_text = serialize_linked_imports_cache(imports)
        @os_fs.write_string_to_file(imports_cache_path, cache_text) catch {
          _ => ()
        }
        (wasm, imports)
      }
    }
  } else {
    // First time: full load for library compilation
    let fs = @io.default_fs_adapter()
    let (db, resolved_entry) = match
      load_entry_db_for_compile_with_features(entry, fs, features) {
      Ok(v) => v
      Err(err) => abort("build: " + err)
    }
    let (wasm, imports) = @runtime_compile.compile_module_wasm_linked(
      db,
      resolved_entry,
      debug_errors=true,
    ) catch {
      e => abort("build --debug: " + e.user_message())
    }
    // Save linked imports cache
    if !@os_fs.path_exists(cache_dir) {
      let _ = c_system(
        system_command_bytes("mkdir -p " + shell_quote_command_arg(cache_dir)),
      )
    }
    let cache_text = serialize_linked_imports_cache(imports)
    @os_fs.write_string_to_file(imports_cache_path, cache_text) catch {
      _ => ()
    }
    // Compile library modules and save source hashes
    save_library_modules(db, resolved_entry, imports, cache_dir)
    save_source_hashes(db, resolved_entry, cache_dir, hash_cache_path)
    (wasm, imports)
  }
  @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
    e => abort("build: write failed: " + e.to_string())
  }
  // Print preload instructions
  println("build --debug: wrote " + resolved_out)
  let preload_parts : Array[String] = []
  let module_names : Map[String, Bool] = {}
  for li in linked_imports {
    if !module_names.contains(li.module_name) {
      module_names[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      preload_parts.push("--preload " + li.module_name + "=" + lib_path)
    }
  }
  if preload_parts.length() > 0 {
    let preload_str = preload_parts
      .iter()
      .fold(init="", fn(acc, s) {
        if acc.length() > 0 {
          acc + " " + s
        } else {
          s
        }
      })
    println("  run: wasmtime " + preload_str + " " + resolved_out)
  }
}

///|
fn save_library_modules(
  db : @runtime.VibeDb,
  entry : String,
  imports : Array[@runtime_compile.LinkedImport],
  cache_dir : String,
) -> Unit {
  let module_names : Map[String, Bool] = {}
  for li in imports {
    module_names[li.module_name] = true
  }
  if module_names.contains(@runtime_compile.prelude_core_module_name()) {
    let mod_name = @runtime_compile.prelude_core_module_name()
    let lib_wasm_path = cache_dir + "/" + mod_name + ".wasm"
    let maybe_lib_bytes = Some(
      @runtime_compile.emit_library_module_wasm(
        @runtime_compile.prelude_core_library_module(),
        debug_errors=true,
      ),
    ) catch {
      e => {
        println(
          "build --debug: warning: library compile failed for " +
          mod_name +
          ": " +
          e.user_message(),
        )
        None
      }
    }
    match maybe_lib_bytes {
      Some(lib_bytes) =>
        @os_fs.write_bytes_to_file(lib_wasm_path, lib_bytes) catch {
          e =>
            println(
              "build --debug: warning: write failed for " +
              mod_name +
              ": " +
              e.to_string(),
            )
        }
      None => ()
    }
  }
  let db_imports = db.imports(entry)
  for imp in db_imports {
    let mod_name = @runtime_compile.linked_module_name(imp.path)
    if !module_names.contains(mod_name) {
      continue
    }
    let lib_wasm_path = cache_dir + "/" + mod_name + ".wasm"
    let lib_bytes = @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      imp.path,
      no_dce=true,
      library_mode=true,
      debug_errors=true,
    ) catch {
      e => {
        println(
          "build --debug: warning: library compile failed for " +
          mod_name +
          ": " +
          e.user_message(),
        )
        continue
      }
    }
    @os_fs.write_bytes_to_file(lib_wasm_path, lib_bytes) catch {
      e => {
        println(
          "build --debug: warning: write failed for " +
          mod_name +
          ": " +
          e.to_string(),
        )
        continue
      }
    }
  }
}

///|
/// Collect type definitions (enum, type alias, struct) from ReExport chains
/// by reading and parsing source files directly (no VibeDb needed).
fn collect_reexport_type_stmts_standalone(
  entry_path : String,
  ast : @vibe_core.Module,
) -> Array[@vibe_core.Stmt] {
  let result : Array[@vibe_core.Stmt] = []
  let found : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ReExport(spec~, source~, ..) => {
        let wanted : Map[String, Bool] = {}
        for item in spec.items {
          wanted[item.name] = true
        }
        collect_reexport_types_recursive(
          entry_path, source, wanted, result, found, 0,
        )
      }
      _ => ()
    }
  }
  result
}

///|
fn collect_reexport_types_recursive(
  referrer_path : String,
  source : @vibe_core.ModuleRef,
  wanted : Map[String, Bool],
  result : Array[@vibe_core.Stmt],
  found : Map[String, Bool],
  depth : Int,
) -> Unit {
  if depth > 10 {
    return
  }
  let base_dir = @vibe_fs.parent_path(referrer_path)
  let source_path = match source {
    @vibe_core.ModuleRef::Path(path~) =>
      @loader.resolve_entry_path(
        if path.has_prefix("/") {
          path
        } else {
          base_dir + "/" + path
        },
      )
    @vibe_core.ModuleRef::PinnedPath(path~, ..) =>
      @loader.resolve_entry_path(
        if path.has_prefix("/") {
          path
        } else {
          base_dir + "/" + path
        },
      )
    _ => return
  }
  let source_text = @os_fs.read_file_to_string(source_path) catch {
    _ => return
  }
  let source_ast = @parser.parse_ast(source_text) catch { _ => return }
  for stmt in source_ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if wanted.contains(name) && !found.contains(name) {
          found[name] = true
          result.push(@vibe_core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @vibe_core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if wanted.contains(name) && !found.contains(name) {
          found[name] = true
          result.push(
            @vibe_core.Stmt::TypeAlias(name~, params~, target~, span~),
          )
        }
      @vibe_core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        if wanted.contains(name) && !found.contains(name) {
          found[name] = true
          result.push(
            @vibe_core.Stmt::StructDef(name~, params~, fields~, span~),
          )
        }
      @vibe_core.Stmt::ReExport(spec=inner_spec, source=inner_source, ..) => {
        let inner_wanted : Map[String, Bool] = {}
        for item in inner_spec.items {
          if wanted.contains(item.name) && !found.contains(item.name) {
            inner_wanted[item.name] = true
          }
        }
        if inner_wanted.length() > 0 {
          collect_reexport_types_recursive(
            source_path,
            inner_source,
            inner_wanted,
            result,
            found,
            depth + 1,
          )
        }
      }
      _ => ()
    }
  }
}

///|
fn serialize_linked_imports_cache(
  imports : Array[@runtime_compile.LinkedImport],
) -> String {
  let buf = StringBuilder::new()
  for li in imports {
    buf.write_string(li.module_name)
    buf.write_char('\t')
    buf.write_string(li.func_name)
    buf.write_char('\t')
    buf.write_string(li.param_count.to_string())
    buf.write_char('\t')
    buf.write_string(li.return_count.to_string())
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
/// Find the nearest parent .vibe directory for cache hoisting.
/// Returns (vibe_dir_path, cache_key) where cache_key is the relative path
/// from the .vibe parent to the entry file (slug-ified for directory name).
///
/// Example: entry = "/repo/vibe/wasm/wasm_runtime/foo.vibe"
///   - Found: /repo/vibe/.vibe
///   - vibe_dir = "/repo/vibe/.vibe"
///   - cache_key = "wasm_wasm_runtime_foo"
///
/// If no .vibe found, falls back to entry's parent directory.

///|
/// `vibe clean [path]` — remove debug linked build cache.
/// If path is given, clean cache for that file. Otherwise clean all debug cache.
fn clean_cmd(args : Array[String]) -> Unit {
  if args.length() > 0 {
    // Clean cache for specific file
    let entry = args[0]
    let resolved = @loader.resolve_entry_path(entry)
    let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
    let cache_dir = vibe_root + "/debug/" + cache_key
    if @os_fs.path_exists(cache_dir) {
      let _ = c_system(
        system_command_bytes("rm -rf " + shell_quote_command_arg(cache_dir)),
      )
      println("clean: removed " + cache_dir)
    } else {
      println("clean: no cache for " + entry)
    }
  } else {
    // Clean all debug cache: find nearest .vibe with cache.json
    let cwd = @io.current_dir_or_root()
    let mut dir = cwd
    for _ in 0..<20 {
      let vibe_dir = dir + "/.vibe"
      if @os_fs.path_exists(vibe_dir) &&
        @os_fs.path_exists(vibe_dir + "/cache.json") {
        let debug_dir = vibe_dir + "/debug"
        if @os_fs.path_exists(debug_dir) {
          let _ = c_system(
            system_command_bytes("rm -rf " + shell_quote_command_arg(debug_dir)),
          )
          println("clean: removed " + debug_dir)
        } else {
          println("clean: no debug cache in " + vibe_dir)
        }
        return
      }
      let parent = @vibe_fs.parent_path(dir)
      if parent == dir || parent.length() == 0 {
        break
      }
      dir = parent
    }
    println("clean: no .vibe directory found")
  }
}
