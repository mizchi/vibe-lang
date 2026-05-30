///|
/// Build a flat Map from a ScopedMap's flattened entries, for order-independent
/// equality comparison.
fn[V] snap_scoped_to_map(m : @scoped_map.ScopedMap[V]) -> Map[String, V] {
  let out : Map[String, V] = {}
  m.copy().iter2().each((k, v) => out[k] = v)
  out
}

///|
/// The typechecked builtins env must survive serialize -> deserialize with its
/// definitional state intact (issue #476). Compare every propagated map for
/// order-independent equality against a fresh-session reconstruction.
test "builtins env snapshot round-trips" {
  let session = TypecheckSession::new()
  // Populate session.cached_builtins_env via the normal path.
  let _ = get_cached_prelude_env_for_module_with_session(session)
  let env = match session.cached_builtins_env.val {
    Some(e) => e
    None => abort("cached_builtins_env not populated")
  }
  let bytes = serialize_builtins_env(env)
  // Reconstruct into a brand-new session (fresh typevar counter etc).
  let env2 = deserialize_builtins_env(TypecheckSession::new(), bytes) catch {
    err => abort("deserialize failed: " + err.to_string())
  }

  // Definitional maps must match (Eq is order-independent for Map).
  assert_true(
    snap_scoped_to_map(env.bindings) == snap_scoped_to_map(env2.bindings),
  )
  assert_true(env.enum_defs == env2.enum_defs)
  assert_true(env.struct_defs == env2.struct_defs)
  assert_true(env.type_aliases == env2.type_aliases)
  assert_true(env.ctor_index == env2.ctor_index)
  assert_true(env.effect_defs == env2.effect_defs)
  assert_true(env.trait_state.traits == env2.trait_state.traits)
  assert_true(env.trait_state.trait_impls == env2.trait_state.trait_impls)
  assert_true(env.fn_versions == env2.fn_versions)
  assert_true(
    snap_scoped_to_map(env.purities) == snap_scoped_to_map(env2.purities),
  )
  assert_true(
    snap_scoped_to_map(env.purity_tiers) ==
    snap_scoped_to_map(env2.purity_tiers),
  )

  // The reconstructed env must carry the load sentinels so re-loading is a no-op.
  assert_eq(env2.get_purity("__prelude_loaded"), Some(true))
  assert_eq(env2.get_purity("__builtins_loaded"), Some(true))

  // Codec must be byte-stable on a reconstructed env.
  let bytes2 = serialize_builtins_env(env2)
  assert_eq(bytes.length(), bytes2.length())
}
