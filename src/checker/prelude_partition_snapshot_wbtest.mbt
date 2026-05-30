///|
/// #402: re-splitting prelude value stmts by the snapshotted builtin-name set
/// must reproduce the computed partition exactly (same core/builtin split).
test "prelude partition snapshot reconstruction matches computed" {
  let ast = prelude_ast()
  let (core, builtin) = prelude_partition_value_stmts(ast)
  // Encode the builtin names, decode, re-split.
  let bytes = encode_partition_names(builtin_names_of(builtin))
  let names = (try? decode_partition_names(bytes)).unwrap_or([])
  let set : Map[String, Bool] = {}
  for n in names {
    set[n] = true
  }
  let (core2, builtin2) = split_prelude_value_stmts(ast, set)
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
