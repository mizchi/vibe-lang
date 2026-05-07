// Layer 3 of the 3-layer trait resolution architecture (ADR-0051).
//
// `ObligationSolver` answers `type_implements_trait` and `bound_satisfied`
// using `TraitGraph` (subtrait queries) and `ImplIndex` (impl lookup +
// overlap). The solver owns the recursion that walks impl-bound obligations
// and the search across subtraits when a direct impl is missing.
//
// The solver returns a structured `TraitWitness` so the bound-check site
// can explain *why* a type does not satisfy a trait (no impl vs. impl
// found but a parameter bound was unsatisfied vs. type variable lacks the
// bound). `satisfies` is a thin wrapper that just collapses the witness
// to a Bool.

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
/// Result of a single trait-obligation check. Carries enough context for
/// the caller to render a precise diagnostic without re-running the
/// solver. Failure cases are intentionally shallow — when an impl bound
/// recursively fails, we surface the first impl + first failing bound
/// rather than a deep tree.
pub enum TraitWitness {
  Satisfied
  // No registered impl matches `ty`, and no subtrait impl helps.
  NoImpl(trait_name~ : String, ty~ : @core.Type)
  // Found a candidate impl whose target unified with `ty`, but a type
  // parameter bound was not satisfied. Holds enough info for the
  // diagnostic to point at the offending impl + failing bound.
  ImplBoundFailed(
    trait_name~ : String,
    impl_target~ : @core.Type,
    param_name~ : String,
    required_bound~ : String,
    actual_ty~ : @core.Type
  )
  // For `Var(id)`: the recorded bounds do not contain `trait_name`
  // (or any of its subtraits).
  VarLacksBound(trait_name~ : String, available~ : Array[String])
} derive(Debug, Eq)

///|
pub fn TraitWitness::is_satisfied(self : TraitWitness) -> Bool {
  match self {
    TraitWitness::Satisfied => true
    _ => false
  }
}

///|
/// Human-readable explanation suitable for embedding in a diagnostic
/// note or context string. Returns the empty string for `Satisfied` —
/// callers should branch on `is_satisfied` first.
pub fn TraitWitness::message(self : TraitWitness) -> String {
  match self {
    TraitWitness::Satisfied => ""
    TraitWitness::NoImpl(trait_name~, ty~) =>
      "no impl `" + trait_name + "` for `" + ty.to_string() + "`"
    TraitWitness::ImplBoundFailed(
      trait_name~,
      impl_target~,
      param_name~,
      required_bound~,
      actual_ty~,
    ) =>
      "impl `" +
      trait_name +
      "` for `" +
      impl_target.to_string() +
      "` requires `" +
      param_name +
      ": " +
      required_bound +
      "`, but `" +
      actual_ty.to_string() +
      "` does not satisfy it"
    TraitWitness::VarLacksBound(trait_name~, available~) =>
      if available.is_empty() {
        "type variable has no trait bounds; expected `" + trait_name + "`"
      } else {
        "type variable bounds " +
        available.to_string() +
        " do not include `" +
        trait_name +
        "`"
      }
  }
}

///|
/// True if `ty` satisfies `trait_name`. Thin wrapper over `witness`.
pub fn ObligationSolver::satisfies(
  self : ObligationSolver,
  ty : @core.Type,
  trait_name : String,
) -> Bool {
  self.witness(ty, trait_name).is_satisfied()
}

///|
/// Diagnostic-friendly counterpart to `satisfies`. See `TraitWitness` for
/// the failure variants the caller can surface.
pub fn ObligationSolver::witness(
  self : ObligationSolver,
  ty : @core.Type,
  trait_name : String,
) -> TraitWitness {
  let resolved = resolve_type(self.env, ty)
  match resolved {
    @core.Type::Var(id) =>
      match self.env.var_trait_bounds.get(id) {
        Some(bounds) =>
          if self.bound_satisfied(bounds, trait_name) {
            TraitWitness::Satisfied
          } else {
            TraitWitness::VarLacksBound(
              trait_name~,
              available=bounds.copy(),
            )
          }
        None => TraitWitness::VarLacksBound(trait_name~, available=[])
      }
    _ => {
      // Primitive intrinsic impls.
      // (Bool has Eq but not Ord — runtime __lt does not handle booleans.)
      if trait_name == "Eq" && is_eq_primitive(resolved) {
        return TraitWitness::Satisfied
      }
      if trait_name == "Ord" && is_ord_primitive(resolved) {
        return TraitWitness::Satisfied
      }
      // Option[T] implements Eq when T: Eq (intrinsic, avoids builtin dep).
      if trait_name == "Eq" {
        match resolved {
          @core.Type::Named(name="Option", args=[inner]) =>
            if self.satisfies(inner, "Eq") {
              return TraitWitness::Satisfied
            }
          _ => ()
        }
      }
      // Try direct impls of `trait_name`. Track the best near-miss so
      // we can return ImplBoundFailed when no impl ultimately satisfies.
      let mut near_miss : TraitWitness? = None
      match obligation_solver_witness_match_any(
          self,
          resolved,
          trait_name,
          self.index.impls_for(trait_name),
        ) {
        TraitWitness::Satisfied => return TraitWitness::Satisfied
        w =>
          if near_miss is None {
            near_miss = Some(w)
          }
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
        match obligation_solver_witness_match_any(
            self,
            resolved,
            // The user-visible failure is still about `trait_name`
            // (the requested obligation), not the subtrait we tried.
            trait_name,
            self.index.impls_for(impl_trait_name),
          ) {
          TraitWitness::Satisfied => return TraitWitness::Satisfied
          w =>
            if near_miss is None {
              near_miss = Some(w)
            }
        }
      }
      match near_miss {
        Some(TraitWitness::ImplBoundFailed(..) as w) => w
        _ => TraitWitness::NoImpl(trait_name~, ty=resolved)
      }
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
/// Try every impl in `impls` against `resolved`. Returns Satisfied on the
/// first impl whose target unifies and whose bounds all hold; otherwise
/// returns the first ImplBoundFailed (target matched, bound failed) or
/// NoImpl (no target matched). `trait_name` is the user-visible
/// obligation, which may differ from the impl's home trait when the
/// caller reached this impl via the subtrait fallback.
fn obligation_solver_witness_match_any(
  solver : ObligationSolver,
  resolved : @core.Type,
  trait_name : String,
  impls : Array[TraitImplDef],
) -> TraitWitness {
  let mut bound_failure : TraitWitness? = None
  for impl_def in impls {
    let mapping : Map[String, @core.Type] = {}
    if type_matches_impl_target(
        solver.env, impl_def.target, resolved, mapping,
      ) {
      let mut ok = true
      let mut first_failure : TraitWitness? = None
      for param in impl_def.type_params {
        match mapping.get(param) {
          Some(actual_ty) =>
            match impl_def.type_bounds.get(param) {
              Some(bounds) =>
                for bound in bounds {
                  if not(solver.satisfies(actual_ty, bound)) {
                    ok = false
                    if first_failure is None {
                      first_failure = Some(
                        TraitWitness::ImplBoundFailed(
                          trait_name~,
                          impl_target=impl_def.target,
                          param_name=param,
                          required_bound=bound,
                          actual_ty~,
                        ),
                      )
                    }
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
        return TraitWitness::Satisfied
      }
      // Capture the first impl-with-bound-failure so subsequent impls
      // don't overwrite a more informative witness.
      if bound_failure is None {
        bound_failure = first_failure
      }
    }
  }
  match bound_failure {
    Some(w) => w
    None => TraitWitness::NoImpl(trait_name~, ty=resolved)
  }
}
