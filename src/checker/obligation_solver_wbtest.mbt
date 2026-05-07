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

///|
test "ObligationSolver::witness reports NoImpl when none exists" {
  let env = TypeEnv::new()
  env.set_trait_info("Show", TraitDefInfo::defined_here([], false))
  let target = @core.Type::Named(name="UserId", args=[])
  let w = ObligationSolver::of(env).witness(target, "Show")
  assert_false(w.is_satisfied())
  let msg = w.message()
  assert_true(msg.contains("no impl"))
  assert_true(msg.contains("Show"))
  assert_true(msg.contains("UserId"))
}

///|
test "ObligationSolver::witness reports ImplBoundFailed when bounds fail" {
  // Register `Hash`, then `impl Show for Array[T] where T: Hash`. Asking
  // for `Show` on `Array[Int]` should fail because Int does not have a
  // Hash impl in this fresh env.
  let env = TypeEnv::new()
  env.set_trait_info("Show", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Hash", TraitDefInfo::defined_here([], false))
  env.add_trait_impl("Show", TraitImplDef::{
    type_params: ["T"],
    type_bounds: { "T": ["Hash"] },
    target: @core.Type::Array(@core.Type::Param("T")),
  })
  let target = @core.Type::Array(@core.Type::Int)
  let w = ObligationSolver::of(env).witness(target, "Show")
  assert_false(w.is_satisfied())
  match w {
    TraitWitness::ImplBoundFailed(
      trait_name~,
      param_name~,
      required_bound~,
      ..
    ) => {
      assert_eq(trait_name, "Show")
      assert_eq(param_name, "T")
      assert_eq(required_bound, "Hash")
    }
    _ => fail("expected ImplBoundFailed witness")
  }
}

///|
test "ObligationSolver::witness reports VarLacksBound for type variables" {
  let env = TypeEnv::new()
  env.set_trait_info("Eq", TraitDefInfo::defined_here([], false))
  env.set_trait_info("Ord", TraitDefInfo::defined_here(["Eq"], false))
  // Fresh type var with bound `Eq` only.
  let tv = fresh_type_var(env)
  match tv {
    @core.Type::Var(id) => add_var_trait_bounds(env, id, ["Eq"])
    _ => fail("fresh_type_var did not return Var")
  }
  let w = ObligationSolver::of(env).witness(tv, "Ord")
  match w {
    TraitWitness::VarLacksBound(trait_name~, available~) => {
      assert_eq(trait_name, "Ord")
      assert_true(available.contains("Eq"))
    }
    _ => fail("expected VarLacksBound witness")
  }
}
