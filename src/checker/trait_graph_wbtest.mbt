// Tests for ADR-0051 Layer 1: `TraitGraph`.

///|
test "TraitGraph::is_subtrait reflexive and direct" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  let g = TraitGraph::of(env)
  assert_true(g.is_subtrait("Eq", "Eq"))
  assert_true(g.is_subtrait("Ord", "Eq"))
  assert_false(g.is_subtrait("Eq", "Ord"))
}

///|
test "TraitGraph::is_subtrait transitive across deep hierarchy" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  env.set_trait_info("D", TraitDefInfo::defined_here(["C"], false))
  let g = TraitGraph::of(env)
  assert_true(g.is_subtrait("D", "A"))
  assert_true(g.is_subtrait("D", "B"))
  assert_true(g.is_subtrait("D", "C"))
  assert_false(g.is_subtrait("A", "D"))
}

///|
test "TraitGraph::super_closure returns transitive parents only" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  let supers = TraitGraph::of(env).super_closure("C")
  assert_true(supers.contains("B"))
  assert_true(supers.contains("A"))
  assert_false(supers.contains("C"))
}

///|
test "TraitGraph::has_cycle detects cycle introduced via import_trait" {
  // `register_trait_def` rejects self-reference, but `import_trait` rewrites
  // supertraits and can in principle introduce a cycle, so the graph layer
  // is responsible for detecting it.
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  // Force a cycle: A -> B -> A.
  env.set_trait_info("A", TraitDefInfo::imported(["B"], true))
  let g = TraitGraph::of(env)
  assert_true(g.has_cycle("A"))
  assert_true(g.has_cycle("B"))
}

///|
test "TraitGraph::supertraits returns one-hop parents only" {
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("C", TraitDefInfo::defined_here(["B"], false))
  let g = TraitGraph::of(env)
  let parents = g.supertraits("C")
  @debug.assert_eq(parents, ["B"])
}

///|
test "TraitGraph::register_def installs trait + supertrait" {
  let env = TypeEnv::new()
  let g = TraitGraph::of(env)
  let span = @core.Span::empty(0)
  g.register_def("Eq", [], false, true, span)
  g.register_def("Ord", ["Eq"], false, true, span)
  assert_true(g.has("Eq"))
  assert_true(g.is_subtrait("Ord", "Eq"))
}

///|
test "TraitGraph::register_def rejects self-referential supertrait" {
  let env = TypeEnv::new()
  let g = TraitGraph::of(env)
  let span = @core.Span::empty(0)
  let result : Result[Unit, TypeError] = try? g.register_def(
    "Bad",
    ["Bad"],
    false,
    true,
    span,
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected register_def to reject self-reference")
  }
}

///|
test "TraitGraph::register_def rejects unknown supertrait" {
  let env = TypeEnv::new()
  let g = TraitGraph::of(env)
  let span = @core.Span::empty(0)
  let result : Result[Unit, TypeError] = try? g.register_def(
    "Ord",
    ["Eq"],
    false,
    true,
    span,
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected register_def to reject unknown supertrait")
  }
}

///|
test "TraitGraph::register_def rejects open trait without export" {
  let env = TypeEnv::new()
  let g = TraitGraph::of(env)
  let span = @core.Span::empty(0)
  let result : Result[Unit, TypeError] = try? g.register_def(
    "Custom",
    [],
    true,
    false,
    span,
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected register_def to reject `open trait` without export")
  }
}

///|
test "TraitGraph::import_def installs an external trait cleanly" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  let g = TraitGraph::of(env)
  let installed = g.import_def(
    "Ord",
    TraitDefInfo::defined_here(["Eq"], true),
    ["Eq"],
  )
  assert_true(installed)
  assert_true(g.is_subtrait("Ord", "Eq"))
}

///|
test "TraitGraph::import_def rolls back if it would close a cycle" {
  // A : (no parents); B : A. Re-importing A with parent B would close
  // a cycle A -> B -> A. import_def must reject it and restore A.
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  let g = TraitGraph::of(env)
  let installed = g.import_def("A", TraitDefInfo::defined_here([], true), ["B"])
  assert_false(installed)
  // After rollback, A should retain its empty supertrait list.
  @debug.assert_eq(g.supertraits("A"), [])
  assert_false(g.has_cycle("A"))
}

///|
test "TraitGraph::import_def removes new entries on cycle" {
  // If the imported trait was never present, rollback removes it
  // entirely instead of leaving a partial state.
  let env = TypeEnv::new()
  env.set_trait_info("Self", TraitDefInfo::defined_here([], false))
  let g = TraitGraph::of(env)
  // Simulate an upstream that produced a self-referential supertrait list.
  let installed = g.import_def(
    "Recursive",
    TraitDefInfo::defined_here([], true),
    ["Recursive"],
  )
  assert_false(installed)
  assert_false(g.has("Recursive"))
}

///|
test "TraitGraph::cycle_chain returns the offending trait sequence" {
  // A : B; B : A — manually construct via set_trait_info to bypass the
  // self-reference / existence checks that register_def enforces.
  let env = TypeEnv::new()
  env.set_trait_info("A", TraitDefInfo::defined_here([], false))
  env.set_trait_info("B", TraitDefInfo::defined_here(["A"], false))
  env.set_trait_info("A", TraitDefInfo::imported(["B"], true))
  let g = TraitGraph::of(env)
  match g.cycle_chain("A") {
    Some(chain) =>
      // Walk order starts at A, hits B, closes back at A.
      @debug.assert_eq(chain, ["A", "B", "A"])
    None => fail("expected cycle_chain to detect A -> B -> A")
  }
}

///|
test "TraitGraph::cycle_chain returns None when graph is acyclic" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  match TraitGraph::of(env).cycle_chain("Ord") {
    Some(_) => fail("unexpected cycle in acyclic graph")
    None => ()
  }
}

///|
test "TraitGraph::import_def returning false leaves trait absent" {
  // Regression coverage for the runtime DB-loader fix: when import_def
  // rolls back due to a cycle, the caller can rely on `has_trait`
  // returning false to skip subsequent impl installation. (The runtime
  // layer treats this signal as "do not install orphan impls".)
  let env = TypeEnv::new()
  env.set_trait_info("Self", TraitDefInfo::defined_here([], false))
  let g = TraitGraph::of(env)
  let installed = g.import_def(
    "Recursive",
    TraitDefInfo::defined_here([], true),
    ["Recursive"],
  )
  assert_false(installed)
  assert_false(env.has_trait("Recursive"))
}
