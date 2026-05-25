///|
/// Phase B-0 (#415) sanity tests: the registry skeleton is empty but
/// callable. Migration of namespaces will add real entries plus
/// per-entry tests.

///|
test "builtin_registry: empty skeleton returns no entries" {
  @debug.assert_eq(builtins().length(), 0)
}

///|
test "builtin_registry: find_builtin returns None for unknown" {
  @debug.assert_eq(find_builtin("Array::push").is_empty(), true)
}
