///|
/// Phase B-1 (#415) sanity tests: the registry now owns the codegen
/// parity contract (core-namespace divergences between the linear and
/// wasm-gc backends). The end-to-end gate that cross-checks these entries
/// against the actual backend source lives in
/// `src/tests/codegen_parity_test.mbt`.

///|
test "builtin_registry: declared divergences carry a reason" {
  for decl in builtins() {
    // Every entry currently in the table is a parity divergence, so it
    // must have exactly one backend and a recorded reason.
    @debug.assert_eq(decl.has_linear != decl.has_gc, true)
    @debug.assert_eq(decl.divergence_reason is Some(_), true)
  }
}

///|
test "builtin_registry: String::compare is a linear-only divergence" {
  match find_builtin("String::compare") {
    Some(d) => {
      @debug.assert_eq(d.has_linear, true)
      @debug.assert_eq(d.has_gc, false)
    }
    None => abort("expected String::compare entry")
  }
}

///|
test "builtin_registry: find_builtin returns None for non-divergent builtin" {
  // Array::push is implemented in both backends, so it is not (yet) in the
  // table — the registry only owns divergences for now.
  @debug.assert_eq(find_builtin("Array::push") is None, true)
}
