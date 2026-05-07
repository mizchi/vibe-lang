// Tests for ADR-0051 Layer 3: `ObligationSolver`.

///|
test "ObligationSolver::satisfies covers primitive intrinsic Eq" {
  let env = TypeEnv::new()
  let solver = ObligationSolver::of(env)
  assert_true(solver.satisfies(@core.Type::Int, "Eq"))
  assert_true(solver.satisfies(@core.Type::String, "Eq"))
  assert_true(solver.satisfies(@core.Type::Bool, "Eq"))
}

///|
test "ObligationSolver::satisfies covers primitive intrinsic Ord (Bool excluded)" {
  let env = TypeEnv::new()
  let solver = ObligationSolver::of(env)
  assert_true(solver.satisfies(@core.Type::Int, "Ord"))
  assert_true(solver.satisfies(@core.Type::String, "Ord"))
  // Bool has Eq but not Ord.
  assert_false(solver.satisfies(@core.Type::Bool, "Ord"))
}

///|
test "ObligationSolver::satisfies finds direct impl" {
  let env = TypeEnv::new()
  env.set_trait_info("Show", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Show", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Named(name="UserId", args=[]),
  })
  assert_true(
    ObligationSolver::of(env).satisfies(
      @core.Type::Named(name="UserId", args=[]),
      "Show",
    ),
  )
}

///|
test "ObligationSolver::satisfies falls back to subtrait impls" {
  // If `Ord : Eq` and a type has an impl for `Ord`, then asking
  // "does it implement Eq?" must succeed via the subtrait fallback.
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  env.add_trait_impl("Ord", TraitImplDef::{
    type_params: [],
    type_bounds: {},
    target: @core.Type::Named(name="MyKey", args=[]),
  })
  let solver = ObligationSolver::of(env)
  assert_true(
    solver.satisfies(@core.Type::Named(name="MyKey", args=[]), "Ord"),
  )
  assert_true(
    solver.satisfies(@core.Type::Named(name="MyKey", args=[]), "Eq"),
  )
}

///|
test "ObligationSolver::bound_satisfied honours supertrait closure" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  let solver = ObligationSolver::of(env)
  // A type variable bound by Ord also satisfies Eq.
  assert_true(solver.bound_satisfied(["Ord"], "Eq"))
  // A type variable bound only by Eq does not satisfy Ord.
  assert_false(solver.bound_satisfied(["Eq"], "Ord"))
}

///|
test "ObligationSolver::satisfies covers Option[T]: Eq when T: Eq" {
  let env = TypeEnv::new()
  let solver = ObligationSolver::of(env)
  assert_true(
    solver.satisfies(@core.Type::Named(name="Option", args=[@core.Type::Int]), "Eq"),
  )
}
