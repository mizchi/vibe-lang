///|
/// #402: static builtin-name snapshot must reproduce the computed partition
/// exactly (same core/builtin split). If `prelude_source` or partition logic
/// changes, update `prelude_static_builtin_value_name` with this test.
test "prelude static partition snapshot matches computed" {
  let ast = prelude_ast()
  let (core, builtin) = _prelude_partition_value_stmts(ast)
  let (core2, builtin2) = split_prelude_value_stmts_by_static_snapshot(ast)
  assert_eq(core2.length(), core.length())
  assert_eq(builtin2.length(), builtin.length())
  // Names must match in order.
  let names_of = fn(stmts : Array[@core.Stmt]) -> Array[String] {
    let r : Array[String] = []
    for s in stmts {
      match prelude_stmt_value_name(s) {
        Some(n) => r.push(n)
        None => ()
      }
    }
    r
  }
  assert_eq(names_of(core2), names_of(core))
  assert_eq(names_of(builtin2), names_of(builtin))
}
