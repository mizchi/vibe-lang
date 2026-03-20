///|
/// CycleStrategy defines how to handle cycles in query execution.
pub enum CycleStrategy[K, V] {
  /// Panic when a cycle is detected (default behavior)
  Panic
  /// Return a fixed fallback value when cycle is detected
  Fallback(V)
  /// Call a recovery function when cycle is detected
  Recover((Runtime, K) -> V)
}

///|
/// Maximum iterations for fixpoint computation
pub let max_fixpoint_iterations : Int = 200

///|
/// CycleQuery is a Query that supports cycle recovery.
/// When a cycle is detected, instead of panicking, it uses the configured strategy.
pub struct CycleQuery[K, V] {
  /// Unique index for this query
  ingredient_index : Int
  /// The computation function
  compute : (Runtime, K) -> V
  /// Cached results
  memos : @hashmap.HashMap[K, CycleMemo[V]]
  /// Cycle recovery strategy
  strategy : CycleStrategy[K, V]
}

///|
/// CycleMemo extends Memo with provisional value tracking for fixpoint iteration.
struct CycleMemo[V] {
  value : V
  mut verified_at : Revision
  changed_at : Revision
  durability : Durability
  edges : Array[QueryEdge]
  /// Whether this value is provisional (during fixpoint iteration)
  mut is_provisional : Bool
}

///|
/// Create a new CycleQuery with Panic strategy (same as regular Query).
pub fn[K, V] CycleQuery::new(
  ingredient_index : Int,
  compute : (Runtime, K) -> V,
) -> CycleQuery[K, V] {
  {
    ingredient_index,
    compute,
    memos: @hashmap.new(),
    strategy: CycleStrategy::Panic,
  }
}

///|
/// Create a new CycleQuery with a fallback value for cycle recovery.
pub fn[K, V] CycleQuery::new_with_fallback(
  ingredient_index : Int,
  compute : (Runtime, K) -> V,
  fallback : V,
) -> CycleQuery[K, V] {
  {
    ingredient_index,
    compute,
    memos: @hashmap.new(),
    strategy: CycleStrategy::Fallback(fallback),
  }
}

///|
/// Create a new CycleQuery with a recovery function for cycle recovery.
pub fn[K, V] CycleQuery::new_with_recover(
  ingredient_index : Int,
  compute : (Runtime, K) -> V,
  recover : (Runtime, K) -> V,
) -> CycleQuery[K, V] {
  {
    ingredient_index,
    compute,
    memos: @hashmap.new(),
    strategy: CycleStrategy::Recover(recover),
  }
}

///|
/// Get the ingredient index.
pub fn[K, V] CycleQuery::get_index(self : CycleQuery[K, V]) -> Int {
  self.ingredient_index
}

///|
/// Fetch the result for a key, with cycle recovery support.
pub fn[K : Hash + Eq, V : Eq] CycleQuery::fetch(
  self : CycleQuery[K, V],
  rt : Runtime,
  key : K,
) -> V {
  let key_hash = key.hash()
  // Check for cycle
  if rt.is_executing(self.ingredient_index, key_hash) {
    // Cycle detected! Use recovery strategy
    return self.handle_cycle(rt, key)
  }
  // Try to use cached value
  match self.memos.get(key) {
    Some(memo) => {
      // Skip provisional values - need to recompute
      if memo.is_provisional {
        return self.execute_with_fixpoint(rt, key, key_hash)
      }
      // Shallow verify: already verified at current revision?
      if memo.verified_at == rt.current_revision() {
        if rt.has_active_query() {
          rt.record_dependency(
            self.ingredient_index,
            key_hash,
            memo.changed_at,
            memo.durability,
          )
          |> ignore
        }
        return memo.value
      }
      // Durability-based shallow verify
      let last_changed = rt.last_changed_at(memo.durability)
      if not(last_changed.is_after(memo.verified_at)) {
        memo.verified_at = rt.current_revision()
        if rt.has_active_query() {
          rt.record_dependency(
            self.ingredient_index,
            key_hash,
            memo.changed_at,
            memo.durability,
          )
          |> ignore
        }
        return memo.value
      }
      // Deep verify
      let deps_changed = self.deep_verify(rt, memo)
      if not(deps_changed) {
        memo.verified_at = rt.current_revision()
        if rt.has_active_query() {
          rt.record_dependency(
            self.ingredient_index,
            key_hash,
            memo.changed_at,
            memo.durability,
          )
          |> ignore
        }
        return memo.value
      }
      // Recompute
      let new_value = self.execute_with_fixpoint(rt, key, key_hash)
      if rt.has_active_query() {
        let memo = self.memos.get(key).unwrap()
        rt.record_dependency(
          self.ingredient_index,
          key_hash,
          memo.changed_at,
          memo.durability,
        )
        |> ignore
      }
      new_value
    }
    None => {
      // No cached value, compute fresh
      let value = self.execute_with_fixpoint(rt, key, key_hash)
      if rt.has_active_query() {
        let memo = self.memos.get(key).unwrap()
        rt.record_dependency(
          self.ingredient_index,
          key_hash,
          memo.changed_at,
          memo.durability,
        )
        |> ignore
      }
      value
    }
  }
}

///|
/// Handle a detected cycle using the configured strategy.
/// Records a dependency on this query for the calling query.
fn[K : Hash, V] CycleQuery::handle_cycle(
  self : CycleQuery[K, V],
  rt : Runtime,
  key : K,
) -> V {
  let value = match self.strategy {
    CycleStrategy::Panic => panic()
    CycleStrategy::Fallback(v) => v
    CycleStrategy::Recover(recover) => recover(rt, key)
  }
  // Record dependency for the calling query
  // Use current revision as changed_at since we're returning a provisional value
  if rt.has_active_query() {
    let key_hash = key.hash()
    rt.record_dependency(
      self.ingredient_index,
      key_hash,
      rt.current_revision(), // Provisional value always considered "changed"
      Durability::Low, // Low durability to ensure re-verification
    )
    |> ignore
  }
  value
}

///|
/// Execute with fixpoint iteration support.
/// If a cycle is detected during execution, uses provisional values
/// and iterates until convergence.
fn[K : Hash + Eq, V : Eq] CycleQuery::execute_with_fixpoint(
  self : CycleQuery[K, V],
  rt : Runtime,
  key : K,
  key_hash : Int,
) -> V {
  // First execution
  rt.push_query(self.ingredient_index, key_hash)
  let value = (self.compute)(rt, key)
  let (edges, _deps_changed_at, durability) = rt.pop_query().unwrap()
  // Check for provisional memo (indicates we're in a cycle)
  let has_provisional = match self.memos.get(key) {
    Some(memo) => memo.is_provisional
    None => false
  }
  if has_provisional {
    // We're in a cycle - check if value converged
    let old_value = self.memos.get(key).unwrap().value
    if old_value == value {
      // Converged! Mark as non-provisional
      let memo = self.memos.get(key).unwrap()
      memo.is_provisional = false
      memo.verified_at = rt.current_revision()
      return value
    }
    // Not converged - iterate
    return self.iterate_fixpoint(rt, key, key_hash, value, edges, durability)
  }
  // Normal case: store and return
  let old_changed_at = match self.memos.get(key) {
    Some(old_memo) =>
      if old_memo.value == value {
        old_memo.changed_at
      } else {
        rt.current_revision()
      }
    None => rt.current_revision()
  }
  let memo : CycleMemo[V] = {
    value,
    verified_at: rt.current_revision(),
    changed_at: old_changed_at,
    durability,
    edges,
    is_provisional: false,
  }
  self.memos.set(key, memo)
  value
}

///|
/// Iterate until fixpoint or max iterations.
fn[K : Hash + Eq, V : Eq] CycleQuery::iterate_fixpoint(
  self : CycleQuery[K, V],
  rt : Runtime,
  key : K,
  key_hash : Int,
  initial_value : V,
  initial_edges : Array[QueryEdge],
  durability : Durability,
) -> V {
  let mut current_value = initial_value
  let mut current_edges = initial_edges
  let mut iterations = 0
  while iterations < max_fixpoint_iterations {
    iterations = iterations + 1
    // Store current value as provisional
    let provisional_memo : CycleMemo[V] = {
      value: current_value,
      verified_at: rt.current_revision(),
      changed_at: rt.current_revision(),
      durability,
      edges: current_edges,
      is_provisional: true,
    }
    self.memos.set(key, provisional_memo)
    // Recompute
    rt.push_query(self.ingredient_index, key_hash)
    let new_value = (self.compute)(rt, key)
    let (new_edges, _, new_durability) = rt.pop_query().unwrap()
    // Check convergence
    if new_value == current_value {
      // Converged!
      let final_memo : CycleMemo[V] = {
        value: new_value,
        verified_at: rt.current_revision(),
        changed_at: rt.current_revision(),
        durability: new_durability,
        edges: new_edges,
        is_provisional: false,
      }
      self.memos.set(key, final_memo)
      return new_value
    }
    current_value = new_value
    current_edges = new_edges
  }
  // Max iterations reached - use last value
  let final_memo : CycleMemo[V] = {
    value: current_value,
    verified_at: rt.current_revision(),
    changed_at: rt.current_revision(),
    durability,
    edges: current_edges,
    is_provisional: false,
  }
  self.memos.set(key, final_memo)
  current_value
}

///|
/// Deep verify for CycleQuery.
fn[K, V] CycleQuery::deep_verify(
  self : CycleQuery[K, V],
  rt : Runtime,
  memo : CycleMemo[V],
) -> Bool {
  ignore(self)
  for edge in memo.edges {
    if rt.maybe_changed_after(
        edge.ingredient_index,
        edge.key_index,
        edge.changed_at,
      ) {
      return true
    }
  }
  false
}

///|
/// Register this query's verifier with the runtime.
pub fn[K : Hash + Eq, V : Eq] CycleQuery::register(
  self : CycleQuery[K, V],
  rt : Runtime,
) -> Unit {
  let query = self
  let runtime = rt
  rt.register_verifier(self.ingredient_index, fn(key_index, revision) {
    // First ensure the memo is up to date
    query.verify_by_hash(runtime, key_index)
    // Then check if the specific key's memo changed after the revision
    for entry in query.memos.iter() {
      let (key, memo) = entry
      if key.hash() == key_index {
        return memo.changed_at.is_after(revision)
      }
    }
    true // No memo found, consider it changed
  })
}

///|
/// Verify a memo by key hash.
/// Includes cycle detection to prevent infinite recursion during verification.
fn[K : Hash + Eq, V : Eq] CycleQuery::verify_by_hash(
  self : CycleQuery[K, V],
  rt : Runtime,
  key_hash : Int,
) -> Unit {
  // Check for cycle in verification
  if rt.is_executing(self.ingredient_index, key_hash) {
    return // Already being verified, skip
  }
  for entry in self.memos.iter() {
    let (key, memo) = entry
    if key.hash() == key_hash {
      if memo.verified_at == rt.current_revision() {
        return
      }
      let last_changed = rt.last_changed_at(memo.durability)
      if not(last_changed.is_after(memo.verified_at)) {
        memo.verified_at = rt.current_revision()
        return
      }
      // Use query stack for cycle detection during deep verify
      rt.push_query(self.ingredient_index, key_hash)
      let deps_changed = self.deep_verify(rt, memo)
      rt.pop_query() |> ignore
      if not(deps_changed) {
        memo.verified_at = rt.current_revision()
        return
      }
      self.execute_with_fixpoint(rt, key, key_hash) |> ignore
      return
    }
  }
}

///|
/// Get the changed_at revision for a key.
pub fn[K : Hash + Eq, V] CycleQuery::changed_at(
  self : CycleQuery[K, V],
  key : K,
) -> Revision? {
  match self.memos.get(key) {
    Some(memo) => Some(memo.changed_at)
    None => None
  }
}

///|
/// Get the durability for a key.
pub fn[K : Hash + Eq, V] CycleQuery::get_durability(
  self : CycleQuery[K, V],
  key : K,
) -> Durability? {
  match self.memos.get(key) {
    Some(memo) => Some(memo.durability)
    None => None
  }
}

///|
/// Check if the query might have changed after a given revision.
pub fn[K : Hash + Eq, V] CycleQuery::maybe_changed_after(
  self : CycleQuery[K, V],
  key : K,
  revision : Revision,
) -> Bool {
  match self.memos.get(key) {
    Some(memo) => memo.changed_at.is_after(revision)
    None => true
  }
}
