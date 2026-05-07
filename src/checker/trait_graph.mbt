// Layer 1 of the 3-layer trait resolution architecture (ADR-0051).
//
// `TraitGraph` is a read-only view over `env.traits`: it answers questions
// about trait definitions, the supertrait closure, and the subtrait relation.
// It is a thin adapter — storage stays on `TypeEnv` for now — so that the
// read path can be migrated independently of the write path.

///|
pub struct TraitGraph {
  env : TypeEnv
}

///|
pub fn TraitGraph::of(env : TypeEnv) -> TraitGraph {
  TraitGraph::{ env, }
}

///|
pub fn TraitGraph::has(self : TraitGraph, name : String) -> Bool {
  self.env.has_trait(name)
}

///|
pub fn TraitGraph::info(self : TraitGraph, name : String) -> TraitDefInfo? {
  self.env.get_trait_info(name)
}

///|
/// Direct (one-hop) supertraits of `name`.
pub fn TraitGraph::supertraits(self : TraitGraph, name : String) -> Array[String] {
  match self.env.get_trait_info(name) {
    Some(info) => info.supertraits_copy()
    None => []
  }
}

///|
/// Transitive supertrait closure of `name`, excluding `name` itself.
/// Cycle-safe: traits already on the visit stack are skipped.
pub fn TraitGraph::super_traitclosure(
  self : TraitGraph,
  name : String,
) -> Array[String] {
  let result : Array[String] = []
  let seen : Map[String, Bool] = {}
  trait_graph_collect_supers(self.env, name, seen, result)
  result
}

///|
fn trait_graph_collect_supers(
  env : TypeEnv,
  name : String,
  seen : Map[String, Bool],
  out : Array[String],
) -> Unit {
  match env.get_trait_info(name) {
    Some(info) =>
      for parent in info.supertraits_copy() {
        if seen.contains(parent) {
          continue
        }
        seen[parent] = true
        out.push(parent)
        trait_graph_collect_supers(env, parent, seen, out)
      }
    None => ()
  }
}

///|
/// True iff `sub == super_trait` or `super_trait` appears in the transitive supertrait
/// closure of `sub`. Cycle-safe.
pub fn TraitGraph::is_subtrait(
  self : TraitGraph,
  sub : String,
  super_trait : String,
) -> Bool {
  if sub == super_trait {
    return true
  }
  trait_graph_is_subtrait_inner(self.env, sub, super_trait, {})
}

///|
fn trait_graph_is_subtrait_inner(
  env : TypeEnv,
  sub : String,
  super_trait : String,
  visiting : Map[String, Bool],
) -> Bool {
  if sub == super_trait {
    return true
  }
  if visiting.contains(sub) {
    return false
  }
  match env.get_trait_info(sub) {
    Some(info) => {
      let next_visiting = visiting.copy()
      next_visiting[sub] = true
      for parent in info.supertraits_copy() {
        if parent == super_trait {
          return true
        }
        if trait_graph_is_subtrait_inner(env, parent, super_trait, next_visiting) {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
/// True if the supertrait chain rooted at `name` contains a cycle.
/// Currently only `import_trait` can introduce cycles (`register_trait_def`
/// rejects self-reference); this helper exists so callers can defensively
/// validate imported trait graphs.
pub fn TraitGraph::has_cycle(self : TraitGraph, name : String) -> Bool {
  trait_graph_cycle_inner(self.env, name, {})
}

///|
fn trait_graph_cycle_inner(
  env : TypeEnv,
  name : String,
  stack : Map[String, Bool],
) -> Bool {
  if stack.contains(name) {
    return true
  }
  match env.get_trait_info(name) {
    Some(info) => {
      let next = stack.copy()
      next[name] = true
      for parent in info.supertraits_copy() {
        if trait_graph_cycle_inner(env, parent, next) {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
/// Iterate over every trait name registered in the underlying environment.
pub fn TraitGraph::trait_names(self : TraitGraph) -> Array[String] {
  self.env.trait_names()
}
