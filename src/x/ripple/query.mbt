///|
/// Memo stores a cached query result with its revision metadata.
struct Memo[V] {
  value : V
  /// Revision when this value was last computed/verified
  mut verified_at : Revision
  /// Revision when this value actually changed
  changed_at : Revision
  /// Minimum durability among all dependencies
  durability : Durability
  /// Dependencies recorded during computation (for deep verify)
  edges : Array[QueryEdge]
}

///|
/// Query represents a memoized computation.
/// It caches results and automatically invalidates when dependencies change.
pub struct Query[K, V] {
  /// Unique index for this query
  ingredient_index : Int
  /// The computation function
  compute : (Runtime, K) -> V
  /// Cached results
  memos : @hashmap.HashMap[K, Memo[V]]
}

///|
/// Create a new Query with the given index and computation function.
pub fn[K, V] Query::new(
  ingredient_index : Int,
  compute : (Runtime, K) -> V,
) -> Query[K, V] {
  { ingredient_index, compute, memos: @hashmap.new() }
}

///|
/// Get the ingredient index.
pub fn[K, V] Query::get_index(self : Query[K, V]) -> Int {
  self.ingredient_index
}

///|
/// Register this query's verifier with the runtime.
/// This enables deep verify for queries that depend on this query.
/// Note: For Query, the verifier must ensure the memo is up-to-date
/// before checking if it changed. This requires calling verify_internal.
pub fn[K : Hash + Eq, V : Eq] Query::register(
  self : Query[K, V],
  rt : Runtime,
) -> Unit {
  let query = self
  let runtime = rt
  rt.register_verifier(self.ingredient_index, fn(key_index, revision) {
    query.verify_by_hash(runtime, key_index)
    for entry in query.memos.iter() {
      let (key, memo) = entry
      if key.hash() == key_index {
        return memo.changed_at.is_after(revision)
      }
    }
    true
  })
}

///|
/// Verify a memo by key hash without recording dependencies.
/// Used by the verifier to ensure memo is up to date.
fn[K : Hash + Eq, V : Eq] Query::verify_by_hash(
  self : Query[K, V],
  rt : Runtime,
  key_hash : Int,
) -> Unit {
  // Find the key with matching hash
  for entry in self.memos.iter() {
    let (key, memo) = entry
    if key.hash() == key_hash {
      // Verify this memo if needed
      if memo.verified_at == rt.current_revision() {
        return // Already verified
      }
      // Check durability-based shallow verify
      let last_changed = rt.last_changed_at(memo.durability)
      if not(last_changed.is_after(memo.verified_at)) {
        memo.verified_at = rt.current_revision()
        return // No changes at this durability level
      }
      // Deep verify: check dependencies
      let deps_changed = self.deep_verify(rt, memo)
      if not(deps_changed) {
        memo.verified_at = rt.current_revision()
        return // Dependencies unchanged
      }
      // Need to recompute - call execute
      self.execute(rt, key, key_hash) |> ignore
      return
    }
  }
}

///|
/// Fetch the result for a key, using cache if valid or recomputing if necessary.
pub fn[K : Hash + Eq, V : Eq] Query::fetch(
  self : Query[K, V],
  rt : Runtime,
  key : K,
) -> V {
  let key_hash = key.hash()
  // Check for cycle
  if rt.is_executing(self.ingredient_index, key_hash) {
    // For now, panic on cycle. Future: support fixpoint iteration
    panic()
  }
  // Try to use cached value
  match self.memos.get(key) {
    Some(memo) => {
      // Shallow verify: already verified at current revision?
      if memo.verified_at == rt.current_revision() {
        // Record dependency only if there's an active parent query
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
      // Durability-based shallow verify:
      // If only high-durability inputs changed since last verify,
      // and this query only depends on higher durability, skip deep verify
      let last_changed = rt.last_changed_at(memo.durability)
      if not(last_changed.is_after(memo.verified_at)) {
        // No changes at this durability level - cache is valid
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
      // Deep verify: check if any dependency actually changed
      let deps_changed = self.deep_verify(rt, memo)
      if not(deps_changed) {
        // No dependency changed - cache is still valid
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
      // Dependencies changed - need to recompute
      let new_value = self.execute(rt, key, key_hash)
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
      let value = self.execute(rt, key, key_hash)
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
/// Deep verify: check if any dependency has changed since last verification.
fn[K, V] Query::deep_verify(
  self : Query[K, V],
  rt : Runtime,
  memo : Memo[V],
) -> Bool {
  ignore(self)
  for edge in memo.edges {
    // Check if this dependency's changed_at is after what we recorded
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
/// Execute the computation and store the result.
fn[K : Hash + Eq, V : Eq] Query::execute(
  self : Query[K, V],
  rt : Runtime,
  key : K,
  key_hash : Int,
) -> V {
  // Push onto query stack
  rt.push_query(self.ingredient_index, key_hash)
  // Execute computation
  let value = (self.compute)(rt, key)
  // Pop and get edges, changed_at, and durability
  let (edges, _deps_changed_at, durability) = rt.pop_query().unwrap()
  // Check if we have an old memo to compare against (backdate)
  let old_changed_at = match self.memos.get(key) {
    Some(old_memo) =>
      if old_memo.value == value {
        // Value unchanged - backdate
        old_memo.changed_at
      } else {
        // Value changed
        rt.current_revision()
      }
    None =>
      // New value
      rt.current_revision()
  }
  // Store memo
  let memo : Memo[V] = {
    value,
    verified_at: rt.current_revision(),
    changed_at: old_changed_at,
    durability,
    edges,
  }
  self.memos.set(key, memo)
  value
}

///|
/// Get the changed_at revision for a key (for dependency tracking).
pub fn[K : Hash + Eq, V] Query::changed_at(
  self : Query[K, V],
  key : K,
) -> Revision? {
  match self.memos.get(key) {
    Some(memo) => Some(memo.changed_at)
    None => None
  }
}

///|
/// Get the durability for a key.
pub fn[K : Hash + Eq, V] Query::get_durability(
  self : Query[K, V],
  key : K,
) -> Durability? {
  match self.memos.get(key) {
    Some(memo) => Some(memo.durability)
    None => None
  }
}

///|
/// Check if the query might have changed after a given revision.
pub fn[K : Hash + Eq, V] Query::maybe_changed_after(
  self : Query[K, V],
  key : K,
  revision : Revision,
) -> Bool {
  match self.memos.get(key) {
    Some(memo) => memo.changed_at.is_after(revision)
    None => true // Not computed yet, considered "changed"
  }
}
