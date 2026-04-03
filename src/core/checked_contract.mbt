///| Stable contract between checker and codegen.

///|

///| Both `@checker` and `@codegen` depend on `@core` but never on each other.

///| - Checker input: `@core.Module` (AST)

///| - Checker output: `TypeEnv` (stays in checker package)

///| - Codegen input: `@core.Module` (AST) + `ExprTypeIndex` (optional type hints)

///| - Codegen output: `Bytes` (WASM binary)

///|

///| `runtime_compile` orchestrates: parse → type_check → codegen.

///|
/// Minimal checked-data surface consumed by frontend/codegen-adjacent rewrites.
pub struct ExprTypeIndex {
  expr_types : Map[Int64, Type]
} derive(Show, Eq)

///|
pub fn ExprTypeIndex::new(expr_types : Map[Int64, Type]) -> ExprTypeIndex {
  { expr_types, }
}

///|
pub fn ExprTypeIndex::empty() -> ExprTypeIndex {
  { expr_types: {} }
}

///|
fn expr_type_span_key(span : Span) -> Int64 {
  (span.start.to_int64() << 32) | span.end.to_int64()
}

///|
pub fn ExprTypeIndex::get_expr_type(self : ExprTypeIndex, span : Span) -> Type? {
  self.expr_types.get(expr_type_span_key(span))
}
