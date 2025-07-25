//! Simplified WASM queries for shell responsiveness
//!
//! This module provides a simpler approach to WASM generation
//! without using Salsa's caching for types that don't implement Eq.

use vibe_compiler::wasm::{CodeGenerator, WasmModule};
use vibe_compiler::{TypeChecker, TypeEnv};
use vibe_language::{Expr, XsError};

/// Generate WASM directly from expression without caching
pub fn generate_wasm_direct(expr: &Expr) -> Result<WasmModule, XsError> {
    // Type check first
    let mut type_checker = TypeChecker::new();
    let mut type_env = TypeEnv::new();
    let _ty = type_checker.check(expr, &mut type_env)
        .map_err(|e| XsError::TypeError(vibe_language::Span::new(0, 0), e))?;
    
    // Convert to IR (simplified - just use untyped IR for now)
    let ir = expr_to_ir(expr)?;
    
    // Generate WASM
    let mut codegen = CodeGenerator::new();
    codegen.generate(&ir)
        .map_err(|e| XsError::RuntimeError(vibe_language::Span::new(0, 0), e.to_string()))
}

/// Simple expression to IR conversion
fn expr_to_ir(expr: &Expr) -> Result<vibe_language::ir::IrExpr, XsError> {
    match expr {
        Expr::Literal(lit, _) => Ok(vibe_language::ir::IrExpr::Literal(lit.clone())),
        
        Expr::Ident(name, _) => Ok(vibe_language::ir::IrExpr::Var(name.0.clone())),
        
        Expr::Let { name, value, .. } => {
            let value_ir = expr_to_ir(value)?;
            // For simplicity, just return the value
            Ok(vibe_language::ir::IrExpr::Let {
                name: name.0.clone(),
                value: Box::new(value_ir),
                body: Box::new(vibe_language::ir::IrExpr::Literal(vibe_language::Literal::Int(0))),
            })
        }
        
        Expr::Lambda { params, body, .. } => {
            let param_names = params.iter().map(|(name, _)| name.0.clone()).collect();
            let body_ir = expr_to_ir(body)?;
            Ok(vibe_language::ir::IrExpr::Lambda {
                params: param_names,
                body: Box::new(body_ir),
            })
        }
        
        Expr::Apply { func, args, .. } => {
            let func_ir = expr_to_ir(func)?;
            let args_ir: Result<Vec<_>, _> = args.iter().map(expr_to_ir).collect();
            Ok(vibe_language::ir::IrExpr::Apply {
                func: Box::new(func_ir),
                args: args_ir?,
            })
        }
        
        Expr::If { cond, then_expr, else_expr, .. } => {
            let cond_ir = expr_to_ir(cond)?;
            let then_ir = expr_to_ir(then_expr)?;
            let else_ir = expr_to_ir(else_expr)?;
            Ok(vibe_language::ir::IrExpr::If {
                cond: Box::new(cond_ir),
                then_expr: Box::new(then_ir),
                else_expr: Box::new(else_ir),
            })
        }
        
        Expr::Block { exprs, .. } => {
            // Convert block to nested let bindings
            if exprs.is_empty() {
                Ok(vibe_language::ir::IrExpr::Literal(vibe_language::Literal::Int(0)))
            } else {
                // Build from the last expression backwards
                let mut iter = exprs.iter().rev();
                let last_expr = iter.next().unwrap();
                let mut body = expr_to_ir(last_expr)?;
                
                // Process remaining expressions in reverse order
                for expr in iter {
                    match expr {
                        Expr::Let { name, value, .. } => {
                            let value_ir = expr_to_ir(value)?;
                            body = vibe_language::ir::IrExpr::Let {
                                name: name.0.clone(),
                                value: Box::new(value_ir),
                                body: Box::new(body),
                            };
                        }
                        Expr::FunctionDef { name, params, body: fn_body, .. } => {
                            let param_names = params.iter().map(|p| p.name.0.clone()).collect();
                            let fn_body_ir = expr_to_ir(fn_body)?;
                            let lambda = vibe_language::ir::IrExpr::Lambda {
                                params: param_names,
                                body: Box::new(fn_body_ir),
                            };
                            body = vibe_language::ir::IrExpr::Let {
                                name: name.0.clone(),
                                value: Box::new(lambda),
                                body: Box::new(body),
                            };
                        }
                        _ => {
                            // Skip other expressions for now
                        }
                    }
                }
                Ok(body)
            }
        }
        
        Expr::FunctionDef { params, body, .. } => {
            let param_names = params.iter().map(|p| p.name.0.clone()).collect();
            let body_ir = expr_to_ir(body)?;
            Ok(vibe_language::ir::IrExpr::Lambda {
                params: param_names,
                body: Box::new(body_ir),
            })
        }
        
        _ => Err(XsError::RuntimeError(
            vibe_language::Span::new(0, 0),
            format!("Expression to IR conversion not implemented for: {:?}", expr),
        )),
    }
}

/// WASM generation result that can be cached
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedWasmResult {
    /// The generated WAT text
    pub wat_text: String,
    /// The binary WASM bytes
    pub wasm_bytes: Vec<u8>,
}

/// Convert WASM module to cacheable result
pub fn wasm_to_cached_result(module: &WasmModule) -> Result<CachedWasmResult, XsError> {
    // Generate simplified WAT
    let mut wat_text = String::new();
    wat_text.push_str("(module\n");
    
    // Add type definitions
    wat_text.push_str("  ;; Type definitions\n");
    
    // Add memory if needed
    if let Some(mem) = &module.memory {
        wat_text.push_str(&format!(
            "  (memory {} {})\n",
            mem.min_pages,
            mem.max_pages.map_or("".to_string(), |m| m.to_string())
        ));
    }
    
    // Add functions
    for (i, func) in module.functions.iter().enumerate() {
        wat_text.push_str(&format!("  ;; Function: {}\n", func.name));
        wat_text.push_str(&format!("  (func ${} (export \"{}\")", i, func.name));
        
        // Add parameters
        for param_ty in &func.params {
            wat_text.push_str(&format!(" (param {})", wasm_type_to_wat(param_ty)));
        }
        
        // Add results
        for result_ty in &func.results {
            wat_text.push_str(&format!(" (result {})", wasm_type_to_wat(result_ty)));
        }
        
        wat_text.push_str("\n");
        
        // Add locals
        for (j, local_ty) in func.locals.iter().enumerate() {
            wat_text.push_str(&format!("    (local ${} {})\n", j, wasm_type_to_wat(local_ty)));
        }
        
        // Add body (simplified)
        wat_text.push_str("    i32.const 42  ;; placeholder\n");
        wat_text.push_str("  )\n");
    }
    
    // Export main if it exists
    if module.functions.iter().any(|f| f.name == "main") {
        wat_text.push_str("  (export \"main\" (func $0))\n");
    }
    
    wat_text.push_str(")\n");
    
    // Parse to binary
    let wasm_bytes = wat::parse_str(&wat_text)
        .map_err(|e| XsError::RuntimeError(vibe_language::Span::new(0, 0), e.to_string()))?;
    
    Ok(CachedWasmResult {
        wat_text,
        wasm_bytes,
    })
}

/// Convert WASM type to WAT string
fn wasm_type_to_wat(ty: &vibe_compiler::wasm::WasmType) -> &'static str {
    use vibe_compiler::wasm::WasmType;
    match ty {
        WasmType::I32 => "i32",
        WasmType::I64 => "i64",
        WasmType::F32 => "f32",
        WasmType::F64 => "f64",
        WasmType::StructRef(_) => "(ref struct)",
        WasmType::ArrayRef(_) => "(ref array)",
        WasmType::FuncRef(_) => "funcref",
        WasmType::AnyRef => "anyref",
        WasmType::Ref(_) => "(ref any)",
    }
}

/// Simple cache for WASM generation
pub struct WasmCache {
    cache: std::collections::HashMap<String, CachedWasmResult>,
}

impl WasmCache {
    pub fn new() -> Self {
        Self {
            cache: std::collections::HashMap::new(),
        }
    }
    
    /// Get or generate WASM for expression
    pub fn get_or_generate(&mut self, key: &str, expr: &Expr) -> Result<CachedWasmResult, XsError> {
        if let Some(cached) = self.cache.get(key) {
            return Ok(cached.clone());
        }
        
        // Generate WASM
        let module = generate_wasm_direct(expr)?;
        let result = wasm_to_cached_result(&module)?;
        
        // Cache it
        self.cache.insert(key.to_string(), result.clone());
        
        Ok(result)
    }
    
    /// Invalidate cache entry
    pub fn invalidate(&mut self, key: &str) {
        self.cache.remove(key);
    }
    
    /// Clear all cache
    pub fn clear(&mut self) {
        self.cache.clear();
    }
}