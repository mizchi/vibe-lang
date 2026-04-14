///|
/// A scoped map with parent chain lookup and lazy promotion.
///
/// `fork()` creates a child scope sharing the parent's entries.
/// `get()` walks the parent chain and promotes found entries to own for O(1) next lookup.
/// `merge_up_or_self()` pushes own entries into the parent (destructive to parent).
pub(all) struct ScopedMap[V] {
  own : Map[String, V]
  parent : ScopedMap[V]?
} derive(Debug, Eq)

///|
pub fn[V] ScopedMap::new() -> ScopedMap[V] {
  { own: {}, parent: None }
}

///|
pub fn[V] ScopedMap::from_map(m : Map[String, V]) -> ScopedMap[V] {
  { own: m, parent: None }
}

///|
/// O(1) fork: create a child scope with empty own map and parent pointer.
pub fn[V] ScopedMap::fork(self : ScopedMap[V]) -> ScopedMap[V] {
  { own: {}, parent: Some(self) }
}

///|
/// Lookup key in own map, then walk parent chain.
/// When found in a parent, promotes the entry to own for O(1) next lookup.
pub fn[V] ScopedMap::get(self : ScopedMap[V], key : String) -> V? {
  match self.own.get(key) {
    Some(v) => Some(v)
    None =>
      match self.parent {
        Some(p) =>
          match p.get(key) {
            Some(v) => {
              self.own[key] = v
              Some(v)
            }
            None => None
          }
        None => None
      }
  }
}

///|
/// Write to own scope.
pub fn[V] ScopedMap::op_set(self : ScopedMap[V], key : String, val : V) -> Unit {
  self.own[key] = val
}

///|
/// Check if key exists in own map or any parent.
/// Promotes to own if found in parent.
pub fn[V] ScopedMap::contains(self : ScopedMap[V], key : String) -> Bool {
  if self.own.contains(key) {
    return true
  }
  match self.parent {
    Some(p) =>
      match p.get(key) {
        Some(v) => {
          self.own[key] = v
          true
        }
        None => false
      }
    None => false
  }
}

///|
/// Remove from own scope only. Does not affect parent.
pub fn[V] ScopedMap::remove(self : ScopedMap[V], key : String) -> Unit {
  self.own.remove(key)
}

///|
/// Iterate all entries (own first, then parent chain).
/// Note: shadowed entries from parent may appear as duplicates.
pub fn[V] ScopedMap::iter2(self : ScopedMap[V]) -> Iter2[String, V] {
  match self.parent {
    None => self.own.iter2()
    Some(p) => Iter2::concat(self.own.iter2(), p.iter2())
  }
}

///|
/// Flatten to a single-layer ScopedMap (no parent).
/// Parent entries are copied first, then own entries overwrite.
pub fn[V] ScopedMap::copy(self : ScopedMap[V]) -> ScopedMap[V] {
  match self.parent {
    None => { own: self.own.copy(), parent: None }
    Some(_) => {
      let flat : Map[String, V] = {}
      flatten(self, flat)
      { own: flat, parent: None }
    }
  }
}

///|
fn[V] flatten(m : ScopedMap[V], target : Map[String, V]) -> Unit {
  match m.parent {
    Some(p) => flatten(p, target)
    None => ()
  }
  for k, v in m.own {
    target[k] = v
  }
}

///|
/// Merge own entries into parent and return the merged result.
/// WARNING: This mutates the parent's own map. If no parent, returns self unchanged.
pub fn[V] ScopedMap::merge_up_or_self(self : ScopedMap[V]) -> ScopedMap[V] {
  match self.parent {
    None => self
    Some(p) => {
      for k, v in self.own {
        p.own[k] = v
      }
      p.merge_up_or_self()
    }
  }
}
