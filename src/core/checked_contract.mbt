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
