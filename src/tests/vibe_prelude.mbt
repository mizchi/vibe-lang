///|
pub using @runtime_compile {
  compile_module,
  compile_module_component,
  compile_module_component_with_opt_level,
  compile_module_component_string_lift_auto,
  compile_module_wasm,
  compile_module_wasm_with_coverage,
  compile_module_wasm_gc,
  compile_module_wasm_with_opt_level,
  generate_module_component_wit,
}

///|
pub using @runtime_compile {type CompileError}

///|
pub using @runtime_compile {type CompiledModule}

///|
pub using @runtime {type EvalResult}

///|
pub using @runtime {type Runtime}

///|
pub using @runtime_compile {type WasmCompileError}

///|
pub using @runtime_compile {type WasmCoverageArtifact}

///|
pub using @runtime_compile {type WasmCoveragePoint}

///|
pub using @runtime_compile {type WasmCoveragePointKind}

///|
pub using @runtime {type VibeDb}
