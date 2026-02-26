///|
fn make_scoped_ref_cache_entry(ty : @core.Type, has_scoped_ref : Bool) -> ScopedRefContainsCacheEntry {
  ScopedRefContainsCacheEntry::{ ty, has_scoped_ref }
}

///|
test "TypeEnv lifecycle: fork_for_check drops derived type caches" {
  let env = TypeEnv::new()
  let source_ty = @core.Type::Named(name="Box", args=[@core.Type::Int])
  let normalized_ty = @core.Type::Named(name="BoxedInt", args=[])
  env.scoped_ref_contains_cache[1] = [make_scoped_ref_cache_entry(source_ty, false)]
  env.normalize_type_cache_expand[1] = [(source_ty, normalized_ty)]
  env.normalize_type_cache_preserve[1] = [(source_ty, source_ty)]
  let forked = env.fork_for_check()
  assert_eq(forked.scoped_ref_contains_cache.length(), 0)
  assert_eq(forked.normalize_type_cache_expand.length(), 0)
  assert_eq(forked.normalize_type_cache_preserve.length(), 0)
}

///|
test "TypeEnv lifecycle: compact_for_eval drops derived type caches" {
  let env = TypeEnv::new()
  let source_ty = @core.Type::Named(name="Wrap", args=[@core.Type::String])
  env.scoped_ref_contains_cache[2] = [make_scoped_ref_cache_entry(source_ty, false)]
  env.normalize_type_cache_expand[2] = [(source_ty, source_ty)]
  let compacted = env.compact_for_eval()
  assert_eq(compacted.scoped_ref_contains_cache.length(), 0)
  assert_eq(compacted.normalize_type_cache_expand.length(), 0)
  assert_eq(compacted.normalize_type_cache_preserve.length(), 0)
}

///|
test "TypeEnv lifecycle: clone drops derived type caches" {
  let env = TypeEnv::new()
  let source_ty = @core.Type::Named(name="Foo", args=[])
  env.scoped_ref_contains_cache[3] = [make_scoped_ref_cache_entry(source_ty, false)]
  env.normalize_type_cache_expand[3] = [(source_ty, source_ty)]
  let cloned = env.clone()
  assert_eq(cloned.scoped_ref_contains_cache.length(), 0)
  assert_eq(cloned.normalize_type_cache_expand.length(), 0)
  assert_eq(cloned.normalize_type_cache_preserve.length(), 0)
}
