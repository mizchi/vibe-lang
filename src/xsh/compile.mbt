///|
/// xsh compile + run pipeline (prototype)
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
  db : XshDb,
  path : String,
) -> CompiledModule raise CompileError {
  let source = match db.get_source(path) {
    Some(s) => s
    None => raise CompileError::MissingSource(path)
  }
  let raw_ast = @parser.parse_ast(source) catch {
    e => raise CompileError::Parse(e)
  }
  let aliases = build_alias_map(raw_ast, db.import_aliases(path))
  let ast = desugar_method_calls(raw_ast, aliases)
  // Use db.types() which handles import type resolution (including imported symbols)
  let env = db.types(path)
  // Check for any type errors that were collected as diagnostics
  let diags = db.diagnostics(path)
  for diag in diags {
    if diag.stage == "type" || diag.stage == "import" {
      raise CompileError::TypeDiag(diag)
    }
  }
  let mono = monoify_module(ast, env)
  let resolved_ast = db.rewrite_imports_to_hash(path, mono.ast)
  let ir = module_to_sexp(resolved_ast, aliases)
  let ir_hash = @core.git_blob_hash_string(ir)
  let module_ref = @core.module_ref_from_hash(ir_hash)
  let imports : Array[String] = []
  for imp in db.imports(path) {
    match imp.module_ref {
      Some(r) => imports.push(r)
      None => ()
    }
  }
  {
    path,
    ir,
    ir_hash,
    module_ref,
    imports,
    aliases,
    ast: resolved_ast,
    type_env: env,
    instantiations: mono.instantiations,
  }
}

///|
/// Execute compiled module using the xsh runtime (interpreter).
pub fn Runtime::run_compiled(
  self : Runtime,
  compiled : CompiledModule,
) -> EvalResult raise XshError {
  self.set_type_env(compiled.type_env)
  for name, target in compiled.aliases {
    self.set_alias(name, target)
  }
  self.eval_module(compiled.ast) catch {
    e => raise XshError::Eval(e)
  }
}

///|
/// Internal helper for compile_module_wasm_* functions
fn compile_module_wasm_with(
  db : XshDb,
  path : String,
  bundler : (XshDb, String, @core.Module) -> @core.Module,
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
fn wasm_emit_options(debug_errors : Bool) -> @codegen.WasmEmitOptions {
  @codegen.wasm_emit_options(embed_error_strings=debug_errors)
}

///|
fn compile_module_wasm_coverage_with(
  db : XshDb,
  path : String,
  bundler : (XshDb, String, @core.Module) -> @core.Module,
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
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        stmts.push(
          @core.Stmt::Expr(expr=@core.Expr::Block(body~, span~), span~),
        )
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
            " (expected: -O0|-O1|-O2|-O3|-Os|-Oz)",
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
/// Compile a module to WASM (wasm-gc compatible, minimal MVP).
pub fn compile_module_wasm(
  db : XshDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, bundle_for_wasm, ast => {
    @codegen.emit_module_wasm_with_options(ast, wasm_emit_options(debug_errors))
  })
}

///|
pub fn compile_module_wasm_with_opt_level(
  db : XshDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  let wasm = if no_dce {
    compile_module_wasm_no_dce(db, path, debug_errors~)
  } else {
    compile_module_wasm(db, path, debug_errors~)
  }
  optimize_wasm_bytes_with_opt_level(wasm, opt_level)
}

///|
pub fn compile_module_wasm_with_coverage(
  db : XshDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let coverage = if no_dce {
    compile_module_wasm_no_dce_with_coverage(
      db,
      path,
      run_tests~,
      debug_errors~,
    )
  } else if run_tests {
    compile_module_wasm_coverage_with(
      db,
      path,
      bundle_for_wasm_test_coverage,
      ast => {
        @codegen.emit_module_wasm_with_coverage_options(
          ast,
          wasm_emit_options(debug_errors),
        )
      },
      run_tests=true,
    )
  } else {
    compile_module_wasm_coverage_with(db, path, bundle_for_wasm, ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    })
  }
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
fn compile_module_wasm_no_dce_with_coverage(
  db : XshDb,
  path : String,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  compile_module_wasm_coverage_with(
    db,
    path,
    bundle_for_wasm_no_dce,
    ast => {
      @codegen.emit_module_wasm_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    },
    run_tests~,
  )
}

///|
/// Compile a module to WASM using wasm js-string builtins.
pub fn compile_module_wasm_js_string(
  db : XshDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, bundle_for_wasm, ast => {
    @codegen.emit_module_wasm_js_string_with_options(
      ast,
      wasm_emit_options(debug_errors),
    )
  })
}

///|
pub fn compile_module_wasm_js_string_with_opt_level(
  db : XshDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  let wasm = if no_dce {
    compile_module_wasm_js_string_no_dce(db, path, debug_errors~)
  } else {
    compile_module_wasm_js_string(db, path, debug_errors~)
  }
  optimize_wasm_bytes_with_opt_level(wasm, opt_level)
}

///|
pub fn compile_module_wasm_js_string_with_coverage(
  db : XshDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  let coverage = if no_dce {
    compile_module_wasm_js_string_no_dce_with_coverage(
      db,
      path,
      run_tests~,
      debug_errors~,
    )
  } else if run_tests {
    compile_module_wasm_coverage_with(
      db,
      path,
      bundle_for_wasm_test_coverage,
      ast => {
        @codegen.emit_module_wasm_js_string_with_coverage_options(
          ast,
          wasm_emit_options(debug_errors),
        )
      },
      run_tests=true,
    )
  } else {
    compile_module_wasm_coverage_with(db, path, bundle_for_wasm, ast => {
      @codegen.emit_module_wasm_js_string_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    })
  }
  optimize_wasm_coverage_with_opt_level(coverage, opt_level)
}

///|
fn compile_module_wasm_js_string_no_dce_with_coverage(
  db : XshDb,
  path : String,
  run_tests? : Bool = false,
  debug_errors? : Bool = false,
) -> WasmCoverageArtifact raise WasmCompileError {
  compile_module_wasm_coverage_with(
    db,
    path,
    bundle_for_wasm_no_dce,
    ast => {
      @codegen.emit_module_wasm_js_string_with_coverage_options(
        ast,
        wasm_emit_options(debug_errors),
      )
    },
    run_tests~,
  )
}

///|
/// Compile a module to WASM using wasm js-string builtins without DCE.
pub fn compile_module_wasm_js_string_no_dce(
  db : XshDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, bundle_for_wasm_no_dce, ast => {
    @codegen.emit_module_wasm_js_string_with_options(
      ast,
      wasm_emit_options(debug_errors),
    )
  })
}

///|
/// Compile a module to WASM using wasm-gc opcodes (fixture-focused).
pub fn compile_module_wasm_gc(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(
    db, path, bundle_for_wasm, @codegen.emit_module_wasm_gc,
  )
}

///|
pub fn compile_module_wasm_gc_with_opt_level(
  db : XshDb,
  path : String,
  no_dce? : Bool = false,
  opt_level? : String? = None,
) -> Bytes raise WasmCompileError {
  let wasm = if no_dce {
    compile_module_wasm_gc_no_dce(db, path)
  } else {
    compile_module_wasm_gc(db, path)
  }
  optimize_wasm_bytes_with_opt_level(wasm, opt_level)
}

///|
/// Compile a module to WASM using wasm-gc opcodes without DCE.
pub fn compile_module_wasm_gc_no_dce(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(
    db, path, bundle_for_wasm_no_dce, @codegen.emit_module_wasm_gc,
  )
}

///|
/// Compile a module to WASM without DCE (for benchmarking).
pub fn compile_module_wasm_no_dce(
  db : XshDb,
  path : String,
  debug_errors? : Bool = false,
) -> Bytes raise WasmCompileError {
  compile_module_wasm_with(db, path, bundle_for_wasm_no_dce, ast => {
    @codegen.emit_module_wasm_with_options(ast, wasm_emit_options(debug_errors))
  })
}

///|
/// Compile a module to Component Model WASM (for wkg/wa.dev compatibility).
/// Uses Canon lift to properly expose the run function as a component export.
pub fn compile_module_component(
  db : XshDb,
  path : String,
) -> Bytes raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
  let core_wasm = @codegen.emit_module_wasm(bundled) catch {
    e => raise WasmCompileError::Gen(e)
  }
  @codegen.emit_component_wasm_with_lift(core_wasm, "run")
}

///|
pub fn compile_module_component_with_opt_level(
  db : XshDb,
  path : String,
  opt_level? : String? = None,
) -> Bytes raise WasmCompileError {
  let component = compile_module_component(db, path)
  optimize_wasm_bytes_with_opt_level(component, opt_level)
}

///|
/// Generate WIT interface definition for a module.
/// Uses pre-bundling AST to preserve all export declarations.
pub fn generate_module_wit(
  db : XshDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  // Use pre-bundling AST to preserve Export statements and all Let definitions
  @codegen.generate_wit(compiled.ast, package_name, world_name)
}

///|
/// Generate WIT world for component embedding (`wasm-tools component embed/new`).
/// Uses bundled AST so builtins used through imports are reflected in the interface.
pub fn generate_module_component_wit(
  db : XshDb,
  path : String,
  package_name : String,
  world_name : String,
) -> String raise WasmCompileError {
  let compiled = compile_module(db, path) catch {
    e => raise WasmCompileError::Compile(e)
  }
  let bundled = bundle_for_wasm(db, path, compiled.ast)
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
