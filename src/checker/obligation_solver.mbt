// Layer 3 of the 3-layer trait resolution architecture (ADR-0051).
//
// `ObligationSolver` answers `type_implements_trait` and `bound_satisfied`
// using `TraitGraph` (subtrait queries) and `ImplIndex` (impl lookup +
// overlap). The solver owns the recursion that walks impl-bound obligations
// and the search across subtraits when a direct impl is missing.

///|
pub struct ObligationSolver {
  env : TypeEnv
  graph : TraitGraph
  index : ImplIndex
}

///|
pub fn ObligationSolver::of(env : TypeEnv) -> ObligationSolver {
  ObligationSolver::{
    env,
    graph: TraitGraph::of(env),
    index: ImplIndex::of(env),
  }
}

///|
/// True if `ty` satisfies `trait_name`, considering:
/// (1) intrinsic primitive impls, (2) Option[T]: Eq when T: Eq,
/// (3) registered impls of `trait_name`, (4) impls of any trait that is a
/// subtrait of `trait_name`. For type variables, the recorded trait bounds
/// are consulted via the supertrait closure.
pub fn ObligationSolver::satisfies(
  self : ObligationSolver,
  ty : @core.Type,
  trait_name : String,
) -> Bool {
  let resolved = resolve_type(self.env, ty)
  match resolved {
    @core.Type::Var(id) =>
      match self.env.var_trait_bounds.get(id) {
        Some(bounds) => self.bound_satisfied(bounds, trait_name)
        None => false
      }
    _ => {
      // Primitive intrinsic impls.
      // (Bool has Eq but not Ord — runtime __lt does not handle booleans.)
      if trait_name == "Eq" && is_eq_primitive(resolved) {
        return true
      }
      if trait_name == "Ord" && is_ord_primitive(resolved) {
        return true
      }
      // Option[T] implements Eq when T: Eq (intrinsic, avoids builtin dep).
      if trait_name == "Eq" {
        match resolved {
          @core.Type::Named(name="Option", args=[inner]) =>
            if self.satisfies(inner, "Eq") {
              return true
            }
          _ => ()
        }
      }
      // Direct impls of `trait_name`.
      if obligation_solver_match_any(self, resolved, self.index.impls_for(
            trait_name,
          )) {
        return true
      }
      // Subtrait impls: any trait T' with T' : trait_name contributes its
      // impls to the search, since T:T' implies T:trait_name.
      for impl_trait_name in self.index.traits_with_impls() {
        if impl_trait_name == trait_name {
          continue
        }
        if not(self.graph.is_subtrait(impl_trait_name, trait_name)) {
          continue
        }
        if obligation_solver_match_any(self, resolved, self.index.impls_for(
              impl_trait_name,
            )) {
          return true
        }
      }
      false
    }
  }
}

///|
/// True if any bound in `available` is `required` or a subtrait of `required`.
pub fn ObligationSolver::bound_satisfied(
  self : ObligationSolver,
  available : Array[String],
  required : String,
) -> Bool {
  for bound in available {
    if self.graph.is_subtrait(bound, required) {
      return true
    }
  }
  false
}

///|
fn obligation_solver_match_any(
  solver : ObligationSolver,
  resolved : @core.Type,
  impls : Array[TraitImplDef],
) -> Bool {
  for impl_def in impls {
    let mapping : Map[String, @core.Type] = {}
    if type_matches_impl_target(solver.env, impl_def.target, resolved, mapping) {
      let mut ok = true
      for param in impl_def.type_params {
        match mapping.get(param) {
          Some(actual_ty) =>
            match impl_def.type_bounds.get(param) {
              Some(bounds) =>
                for bound in bounds {
                  if not(solver.satisfies(actual_ty, bound)) {
                    ok = false
                    break
                  }
                }
              None => ()
            }
          None => ()
        }
        if not(ok) {
          break
        }
      }
      if ok {
        return true
      }
    }
  }
  false
}
