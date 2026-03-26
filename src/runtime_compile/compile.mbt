///|
/// vibe compile + run pipeline (prototype)
suberror CompileError {
  MissingSource(String)
  Parse(@parser.ParseError)
  TypeDiag(@core.Diagnostic)
} derive(Show, Eq)

///|
suberror WasmCompileError {
  Compile(CompileError)
  Gen(@codegen.WasmGenError)
  Optimize(String)
} derive(Show, Eq)

///|
pub fn WasmCompileError::user_message(self : WasmCompileError) -> String {
  match self {
    Compile(MissingSource(path)) => "missing source: " + path
    Compile(Parse(e)) => "parse error: " + e.to_string()
    Compile(TypeDiag(d)) => "type error: " + d.to_string()
    Gen(e) => e.format_message()
    Optimize(msg) => "optimize: " + msg
  }
}

///|
pub enum WasmCoveragePointKind {
  Line
  BranchIfThen
  BranchIfElse
  BranchMatchArm
} derive(Show, Eq)

///|
pub struct WasmCoveragePoint {
  id : Int
  kind : WasmCoveragePointKind
  span : @core.Span
} derive(Show, Eq)

///|
pub struct WasmCoverageArtifact {
  bytes : Bytes
  counter_base : Int
  counter_count : Int
  points : Array[WasmCoveragePoint]
} derive(Show, Eq)

///|
pub struct WasmCompileStageProfile {
  module_us : Int
  bundle_us : Int
  emit_us : Int
  optimize_us : Int
  total_us : Int
} derive(Show, Eq)

///|
pub struct CompiledModule {
  path : String
  ir : String
  ir_hash : String
  module_ref : String
  imports : Array[String]
  aliases : Map[String, @core.Ref]
  ast : @core.Module
  type_env : @checker.TypeEnv
  instantiations : Map[String, Int]
}

///|
let compile_module_cache : Ref[Map[String, CompiledModule]] = @ref.new({})

///|
let wasm_artifact_cache : Ref[Map[String, Bytes]] = @ref.new({})

///|
fn elapsed_us_from(start : @bench.Timestamp) -> Int {
  @bench.monotonic_clock_end(start).to_int()
}

///|
fn compile_module_cache_key(
  path : String,
  source : String,
  imports : Array[@runtime.ImportSpec],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(path)
  buf.write_char('\n')
  buf.write_string(@core.git_blob_hash_string(source))
  for imp in imports {
    buf.write_char('\n')
    buf.write_string(imp.path)
    buf.write_char('|')
    match imp.hash {
      Some(hash) => buf.write_string(hash)
      None => buf.write_char('-')
    }
    buf.write_char('|')
    match imp.source_hash {
      Some(source_hash) => buf.write_string(source_hash)
      None => buf.write_char('-')
    }
  }
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn wasm_artifact_cache_key(
  bundled : @core.Module,
  import_aliases : Map[String, @core.Ref],
  cache_namespace : String,
  opt_level : String?,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(cache_namespace)
  buf.write_char('\n')
  match opt_level {
    Some(level) => buf.write_string(level)
    None => buf.write_string("none")
  }
  buf.write_char('\n')
  buf.write_string(
    @runtime.module_to_sexp(bundled, build_alias_map(bundled, import_aliases)),
  )
  @core.git_blob_hash_string(buf.to_string())
}

///|
fn wasm_artifact_cache_namespace(
  bundler_kind : String,
  debug_errors : Bool,
  http_host_imports : Bool,
  force_cabi_realloc : Bool,
  library_mode : Bool,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(bundler_kind)
  buf.write_char('\n')
  buf.write_string(debug_errors.to_string())
  buf.write_char('\n')
  buf.write_string(http_host_imports.to_string())
  buf.write_char('\n')
  buf.write_string(force_cabi_realloc.to_string())
  buf.write_char('\n')
  buf.write_string(library_mode.to_string())
  buf.to_string()
}

///|
fn compile_module_import_aliases(
  imports : Array[@runtime.ImportSpec],
) -> Map[String, @core.Ref] {
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  aliases
}

///|
fn wasm_coverage_kind_from_codegen(
  kind : @codegen.WasmCoveragePointKind,
) -> WasmCoveragePointKind {
  match kind {
    @codegen.WasmCoveragePointKind::Line => WasmCoveragePointKind::Line
    @codegen.WasmCoveragePointKind::BranchIfThen =>
      WasmCoveragePointKind::BranchIfThen
    @codegen.WasmCoveragePointKind::BranchIfElse =>
      WasmCoveragePointKind::BranchIfElse
    @codegen.WasmCoveragePointKind::BranchMatchArm =>
      WasmCoveragePointKind::BranchMatchArm
  }
}

///|
fn wasm_coverage_artifact_from_codegen(
  artifact : @codegen.WasmCoverageArtifact,
) -> WasmCoverageArtifact {
  let points : Array[WasmCoveragePoint] = []
  for point in artifact.points {
    points.push({
      id: point.id,
      kind: wasm_coverage_kind_from_codegen(point.kind),
      span: point.span,
    })
  }
  {
    bytes: artifact.bytes,
    counter_base: artifact.counter_base,
    counter_count: artifact.counter_count,
    points,
  }
}

///|
/// Compile a module from the database (WASM target: wasm-gc + js builtin).
pub fn compile_module(
  db : @runtime.VibeDb,
  path : String,
) -> CompiledModule raise CompileError {
  let source = match db.get_source(path) {
    Some(s) => s
    None => raise CompileError::MissingSource(path)
  }
  let imports = db.imports(path)
  let cache_key = compile_module_cache_key(path, source, imports)
  match compile_module_cache.val.get(cache_key) {
    Some(cached) => return cached
    None => ()
  }
  // Trigger parse/import/type queries once and reuse their cached results below.
  let env = db.types(path)
  let diags = db.diagnostics(path)
  for diag in diags {
    if diag.stage == "parse" {
      // Preserve CompileError::Parse API without reparsing on the success path.
      let _ = @parser.parse_ast(source) catch {
        e => raise CompileError::Parse(e)
      }
      raise CompileError::TypeDiag(diag)
    }
    if diag.stage == "type" || diag.stage == "import" {
      raise CompileError::TypeDiag(diag)
    }
  }
  let raw_ast = db.ast(path)
  let aliases = build_alias_map(raw_ast, compile_module_import_aliases(imports))
  let desugared = @frontend.desugar_method_calls(raw_ast, aliases)
  let ast = @frontend.rewrite_effect_handles(desugared)
  let mono = @frontend.monoify_module(ast, env)
  let rewritten = @frontend.rewrite_string_add(mono.ast, env)
  let resolved_ast = db.rewrite_imports_to_hash(path, rewritten)
  let ir = @runtime.module_to_sexp(resolved_ast, aliases)
  let ir_hash = @core.git_blob_hash_string(ir)
  let module_ref = @core.module_ref_from_hash(ir_hash)
  let module_refs : Array[String] = []
  for imp in imports {
    match imp.module_ref {
      Some(r) => module_refs.push(r)
      None => ()
    }
  }
  let compiled = {
    path,
    ir,
    ir_hash,
    module_ref,
    imports: module_refs,
    aliases,
    ast: resolved_ast,
    type_env: env,
    instantiations: mono.instantiations,
  }
  compile_module_cache.val[cache_key] = compiled
  compiled
}

///|
/// Execute compiled module using the vibe runtime (interpreter).
pub fn run_compiled(
  rt : @runtime.Runtime,
  compiled : CompiledModule,
) -> @runtime.EvalResult raise @runtime.EvalError {
  rt.set_type_env(compiled.type_env)
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  rt.eval_module(compiled.ast)
}

///|
/// Internal helper for compile_module_wasm_* functions
fn compile_module_wasm_with(
  db : @runtime.VibeDb,
  path : String,
  bundler : (@runtime.VibeDb, String, @core.Module) -> @core.Module,
  emitter : (@core.Module) -> Bytes raise @codegen.WasmGenError,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundler(db, path, compiled.ast)
  emitter(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
}

///|
fn wasm_emit_options(
  debug_errors : Bool,
  http_host_imports? : Bool = false,
  http_component_wasi_shim? : Bool = false,
) -> @codegen.WasmEmitOptions {
  @codegen.wasm_emit_options(
    embed_error_strings=debug_errors,
    http_host_imports~,
    http_component_wasi_shim~,
  )
}

///|
fn compile_module_wasm_coverage_with(
  db : @runtime.VibeDb,
  path : String,
  bundler : (@runtime.VibeDb, String, @core.Module) -> @core.Module,
  emitter : (@core.Module) -> @codegen.WasmCoverageArtifact raise @codegen.WasmGenError,
  run_tests? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundler(db, path, compiled.ast)
  let lowered = if run_tests {
    lower_top_level_tests_to_exprs(bundled)
  } else {
    bundled
  }
  let coverage = emitter(lowered) catch { e => raise WasmCompileError::Gen(e) }
  wasm_coverage_artifact_from_codegen(coverage)
}

///|
fn lower_top_level_tests_to_exprs(ast : @core.Module) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  let mut test_i = 0
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Test(body~, span~, ..)
      | @core.Stmt::Bench(body~, span~, ..) => {
        let wrapper_name = "__vibe_cov_test_" + test_i.to_string()
        let fn_body_stmts : Array[@core.Stmt] = []
        for body_stmt in body.stmts {
          fn_body_stmts.push(body_stmt)
        }
        fn_body_stmts.push(
          @core.Stmt::Expr(expr=@core.Expr::Int(value=0L, span~), span~),
        )
        stmts.push(
          @core.Stmt::Let(
            rec=false,
            name=wrapper_name,
            expr=@core.Expr::Fn(
              type_params=[],
              type_bounds={},
              params=[],
              ret=Some(@core.Type::Int),
              effects=[],
              body=@core.Module::{ stmts: fn_body_stmts },
              span~,
            ),
            span~,
          ),
        )
        stmts.push(
          @core.Stmt::Expr(
            expr=@core.Expr::Call(
              name=wrapper_name,
              type_args=[],
              args=[],
              span~,
            ),
            span~,
          ),
        )
        test_i += 1
      }
      _ => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
}

///|
fn optimize_wasm_bytes_with_opt_level(
  bytes : Bytes,
  opt_level : String?,
) -> Bytes raise WasmCompileError {
  match opt_level {
    None => bytes
    Some(level) => {
      let config = match @wite.optimize_config_from_opt_level(level) {
        Some(v) => v
        None =>
          raise WasmCompileError::Optimize(
            "unsupported wite optimize level " +
            level +
            " (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
          )
      }
      match @wite.optimize_binary_for_size(bytes, config~) {
        Ok(result) => result.bytes
        Err(msg) =>
          raise WasmCompileError::Optimize("wite optimize failed: " + msg)
      }
    }
  }
}

///|
fn optimize_wasm_coverage_with_opt_level(
  coverage : WasmCoverageArtifact,
  opt_level : String?,
) -> WasmCoverageArtifact raise WasmCompileError {
  let optimized = optimize_wasm_bytes_with_opt_level(coverage.bytes, opt_level)
  {
    bytes: optimized,
    counter_base: coverage.counter_base,
    counter_count: coverage.counter_count,
    points: coverage.points,
  }
}

///|
fn compile_module_wasm_profiled_with(
  db : @runtime.VibeDb,
  path : String,
  bundler : (@runtime.VibeDb, String, @core.Module) -> @core.Module,
  emitter : (@core.Module) -> Bytes raise @codegen.WasmGenError,
  cache_namespace : String,
  opt_level : String?,
) -> (Bytes, WasmCompileStageProfile) raise WasmCompileError {
  let start_total = @bench.monotonic_clock_start()
  @profiler.profiler_enter("compile/module")
  let start_module = @bench.monotonic_clock_start()
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let module_us = elapsed_us_from(start_module)
  @profiler.profiler_leave()
  @profiler.profiler_enter("compile/bundle")
  let start_bundle = @bench.monotonic_clock_start()
  let bundled = bundler(db, path, compiled.ast)
  let cache_key = wasm_artifact_cache_key(
    bundled,
    compiled.aliases,
    cache_namespace,
    opt_level,
  )
  let bundle_us = elapsed_us_from(start_bundle)
  @profiler.profiler_leave()
  match wasm_artifact_cache.val.get(cache_key) {
    Some(cached) => {
      let total_us = elapsed_us_from(start_total)
      return (
        cached,
        { module_us, bundle_us, emit_us: 0, optimize_us: 0, total_us },
      )
    }
    None => ()
  }
  @profiler.profiler_enter("compile/emit")
  let start_emit = @bench.monotonic_clock_start()
  let wasm = emitter(bundled) catch { e => raise WasmCompileError::Gen(e) }
  let emit_us = elapsed_us_from(start_emit)
  @profiler.profiler_leave()
  @profiler.profiler_enter("compile/optimize")
  let start_optimize = @bench.monotonic_clock_start()
  let optimized = optimize_wasm_bytes_with_opt_level(wasm, opt_level)
  let optimize_us = elapsed_us_from(start_optimize)
  @profiler.profiler_leave()
  wasm_artifact_cache.val[cache_key] = optimized
  let total_us = elapsed_us_from(start_total)
  (optimized, { module_us, bundle_us, emit_us, optimize_us, total_us })
}

///|
/// Compile a module to WASM (wasm-gc compatible, minimal MVP).
pub fn compile_module_wasm(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, @runtime.bundle_for_wasm, ast => {
    @codegen.emit_module_wasm_with_options(
      ast,
      @codegen.wasm_emit_options(
        embed_error_strings=debug_errors,
        http_host_imports~,
        force_cabi_realloc~,
      ),
    )
  })
}

///|
pub fn compile_module_wasm_with_codegen_options(
  db : @runtime.VibeDb,
  path : String,
  options : @codegen.WasmEmitOptions,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, @runtime.bundle_for_wasm, ast => {
    @codegen.emit_module_wasm_with_options(ast, options)
  })
}

///|
pub fn compile_module_wasm_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
) -> Bytes raise WasmCompileError {
  let (wasm, _) = compile_module_wasm_with_opt_level_profiled(
    db,
    path,
    no_dce~,
    opt_level~,
    debug_errors~,
    http_host_imports~,
    force_cabi_realloc~,
    library_mode~,
  )
  wasm
}

///|
pub fn compile_module_wasm_with_opt_level_profiled(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
  library_mode? : Bool = false,
) -> (Bytes, WasmCompileStageProfile) raise WasmCompileError {
  let cache_namespace = wasm_artifact_cache_namespace(
    if no_dce {
      "no_dce"
    } else {
      "default"
    },
    debug_errors,
    http_host_imports,
    force_cabi_realloc,
    library_mode,
  )
  if no_dce {
    compile_module_wasm_profiled_with(
      db,
      path,
      @runtime.bundle_for_wasm_no_dce,
      ast => {
        @codegen.emit_module_wasm_with_options(
          ast,
          @codegen.wasm_emit_options(
            embed_error_strings=debug_errors,
            http_host_imports~,
            force_cabi_realloc~,
            library_mode~,
          ),
        )
      },
      cache_namespace,
      opt_level,
    )
  } else {
    compile_module_wasm_profiled_with(
      db,
      path,
      @runtime.bundle_for_wasm,
      ast => {
        @codegen.emit_module_wasm_with_options(
          ast,
          @codegen.wasm_emit_options(
            embed_error_strings=debug_errors,
            http_host_imports~,
            force_cabi_realloc~,
            library_mode~,
          ),
        )
      },
      cache_namespace,
      opt_level,
    )
  }
}

///|
pub fn compile_module_wasm_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let coverage = if no_dce {
    compile_module_wasm_no_dce_with_coverage(
      db,
      path,
      run_tests~,
      debug_errors~,
      http_host_imports~,
    )
  } else if run_tests {
    compile_module_wasm_coverage_with(
      db,
      path,
      @runtime.bundle_for_wasm_test_coverage,
      ast => {
        @codegen.emit_module_wasm_with_coverage_options(
          ast,
          wasm_emit_options(debug_errors, http_host_imports~),
        )
      },
      run_tests=true,
    )
  } else {
    compile_module_wasm_coverage_with(db, path, @runtime.bundle_for_wasm, ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors, http_host_imports~),
      )
    })
  }
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
fn compile_module_wasm_no_dce_with_coverage(
  db : @runtime.VibeDb,
  path : String,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  compile_module_wasm_coverage_with(
    db,
    path,
    @runtime.bundle_for_wasm_no_dce,
    ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors, http_host_imports~),
      )
    },
    run_tests~,
  )
}

///|
/// Compile a module to WASM using wasm js-string builtins.
pub fn compile_module_wasm_js_string(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, @runtime.bundle_for_wasm, ast => {
    @codegen.emit_module_wasm_js_string_with_options(
      ast,
      wasm_emit_options(debug_errors),
    )
  })
}

///|
/// Compile a module to WASM using wasm-gc opcodes (fixture-focused).
pub fn compile_module_wasm_gc(
  db : @runtime.VibeDb,
  path : String,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(
    db, path, @runtime.bundle_for_wasm_gc, @codegen.emit_module_wasm_gc,
  )
}

///|
/// Compile a module to WASM without DCE (for benchmarking).
pub fn compile_module_wasm_no_dce(
  db : @runtime.VibeDb,
  path : String,
  debug_errors? : Bool = false,
  http_host_imports? : Bool = false,
  force_cabi_realloc? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, @runtime.bundle_for_wasm_no_dce, ast => {
    @codegen.emit_module_wasm_with_options(
      ast,
      @codegen.wasm_emit_options(
        embed_error_strings=debug_errors,
        http_host_imports~,
        force_cabi_realloc~,
      ),
    )
  })
}

///|
/// Compile a module to Component Model WASM (for wkg/wa.dev compatibility).
/// Uses Canon lift to properly expose the run function as a component export.
pub fn compile_module_component(
  db : @runtime.VibeDb,
  path : String,
  http_host_imports? : Bool = false,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = @runtime.bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    wasm_emit_options(
      false,
      http_host_imports~,
      http_component_wasi_shim=http_host_imports,
    ),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  @codegen.emit_component_wasm_with_lift(core_wasm, "run")
}

///|
/// Auto-detect exported function with string params and compile to Component
/// with string lift trampoline. Scans AST for the first ExportLet with Fn
/// whose params include Type::String.
pub fn compile_module_component_string_lift_auto(
  db : @runtime.VibeDb,
  path : String,
  opt_level? : String? = None,
  is_async? : Bool = false,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  // Check for incompatible server builtins (listen/accept model is not supported in P3 handler mode)
  let incompatible = check_incompatible_server_builtins(compiled.ast)
  if incompatible.length() > 0 {
    raise WasmCompileError::Optimize(
      "P3 handler mode is incompatible with server builtins: " +
      incompatible
      .iter()
      .fold(init="", fn(acc, s) { if acc == "" { s } else { acc + ", " + s } }) +
      ". Use `export let handler = (method: String, url: String) -> Int` pattern instead.",
    )
  }
  // Find first exported function with string params
  let mut target_func_name : String? = None
  let mut string_param_count = 0
  let string_param_names : Array[String] = []
  let mut string_result = false
  for stmt in compiled.ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        match expr {
          @core.Expr::Fn(params~, ret~, ..) => {
            for p in params {
              if p.ty == @core.Type::String ||
                p.ty == @core.Type::Named(name="String", args=[]) {
                string_param_names.push(p.name)
              }
            }
            if string_param_names.length() > 0 {
              target_func_name = Some(name)
              string_param_count = string_param_names.length()
              string_result = ret == Some(@core.Type::String) ||
                ret == Some(@core.Type::Named(name="String", args=[]))
              break
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  let func_name = match target_func_name {
    Some(n) => n
    None =>
      raise WasmCompileError::Optimize(
        "no exported function with string params found",
      )
  }
  let bundled = @runtime.bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm_with_options(
    bundled,
    @codegen.wasm_emit_options(force_cabi_realloc=true),
  ) catch {
    e => raise WasmCompileError::Gen(e)
  }
  let component = @codegen.emit_component_wasm_with_string_lift(
    core_wasm,
    func_name,
    func_name,
    string_param_count,
    param_names=string_param_names,
    is_async~,
    string_result~,
  )
  optimize_wasm_bytes_with_opt_level(component, opt_level)
}

///|
/// Check if AST uses server builtins incompatible with P3 handler mode.
fn check_incompatible_server_builtins(ast : @core.Module) -> Array[String] {
  let found : Array[String] = []
  let incompatible_names = [
    "Http::listen", "Http::accept", "Http::request_method", "Http::request_url",
    "Http::request_header", "Http::request_body", "Http::respond",
  ]
  scan_server_builtins_block(ast, incompatible_names, found)
  found
}

///|
fn scan_server_builtins_block(
  block : @core.Module,
  names : Array[String],
  found : Array[String],
) -> Unit {
  for stmt in block.stmts {
    match stmt {
      @core.Stmt::Let(expr~, ..)
      | @core.Stmt::ExportLet(expr~, ..)
      | @core.Stmt::Expr(expr~, ..)
      | @core.Stmt::LetMut(expr~, ..)
      | @core.Stmt::Assign(expr~, ..) =>
        scan_server_builtins_expr(expr, names, found)
      _ => ()
    }
  }
}

///|
fn scan_server_builtins_expr(
  expr : @core.Expr,
  names : Array[String],
  found : Array[String],
) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      for n in names {
        if name == n && not(found.contains(n)) {
          found.push(n)
        }
      }
      for arg in args {
        scan_server_builtins_expr(arg.expr, names, found)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      scan_server_builtins_expr(cond, names, found)
      scan_server_builtins_block(then_body, names, found)
      scan_server_builtins_block(else_body, names, found)
    }
    @core.Expr::Block(body~, ..) =>
      scan_server_builtins_block(body, names, found)
    @core.Expr::Fn(body~, ..) => scan_server_builtins_block(body, names, found)
    _ => ()
  }
}

///|
pub fn compile_module_component_with_opt_level(
  db : @runtime.VibeDb,
  path : String,
  opt_level? : String? = None,
  http_host_imports? : Bool = false,
) -> Bytes raise WasmCompileError {
  let component = compile_module_component(db, path, http_host_imports~)
  optimize_wasm_bytes_with_opt_level(component, opt_level)
}

///|
/// Generate WIT world for component embedding (`wasm-tools component embed/new`).
/// Uses bundled AST so builtins used through imports are reflected in the interface.
pub fn generate_module_component_wit(
  db : @runtime.VibeDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = @runtime.bundle_for_wasm(db, path, compiled.ast)
  @codegen.generate_component_wit(bundled, package_name, world_name)
}

///|
/// Build module alias map from imports only.
fn build_alias_map(
  ast : @core.Module,
  import_aliases : Map[String, @core.Ref],
) -> Map[String, @core.Ref] {
  let _ = ast
  import_aliases
}
