///|
/// Phase B-1 (#415) sanity tests: the registry now owns the codegen
/// parity contract (core-namespace divergences between the linear and
/// wasm-gc backends). The end-to-end gate that cross-checks these entries
/// against the actual backend source lives in
/// `src/tests/codegen_parity_test.mbt`.

///|
test "builtin_registry: divergence entries carry a reason, both-entries don't" {
  for decl in builtins() {
    if decl.has_linear != decl.has_gc {
      // A parity divergence must record why.
      @debug.assert_eq(decl.divergence_reason is Some(_), true)
    } else {
      // A both-backends entry (e.g. migrated Char) has no divergence.
      @debug.assert_eq(decl.has_linear && decl.has_gc, true)
      @debug.assert_eq(decl.divergence_reason is None, true)
    }
  }
}

///|
test "builtin_registry: migrated Char dispatch is table-driven" {
  @debug.assert_eq(migrated_builtin("Char::to_int") is Some(_), true)
  @debug.assert_eq(migrated_builtin("Char::from_int") is Some(_), true)
  // Array::slice has only a wasm-gc dispatch arm (no linear arm), so it is
  // not migrated onto the shared table.
  @debug.assert_eq(migrated_builtin("Array::slice") is None, true)
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
test "builtin_registry: find_builtin returns None for an unregistered builtin" {
  // Array::slice has only a wasm-gc dispatch arm (no linear arm and no
  // recorded divergence), so the registry does not own it.
  @debug.assert_eq(find_builtin("Array::slice") is None, true)
}
