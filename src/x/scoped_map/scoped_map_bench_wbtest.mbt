///|
/// Build a flat ScopedMap with n entries: "k0"..="k{n-1}" → 0..n-1
fn build_flat(n : Int) -> ScopedMap[Int] {
  let m : ScopedMap[Int] = ScopedMap::new()
  for i in 0..<n {
    m["k" + i.to_string()] = i
  }
  m
}

///|
/// Build a chain of depth d, each level adding n entries
fn build_chain(depth : Int, entries_per_level : Int) -> ScopedMap[Int] {
  let mut m : ScopedMap[Int] = ScopedMap::new()
  for d in 0..<depth {
    for i in 0..<entries_per_level {
      m["d" + d.to_string() + "_k" + i.to_string()] = d * entries_per_level + i
    }
    if d < depth - 1 {
      m = m.fork()
    }
  }
  m
}

// --- get: own scope ---

///|
test "bench: scoped_map.get.own.100" (b : @bench.T) {
  let m = build_flat(100)
  b.bench(fn() { b.keep(m.get("k50")) })
}

///|
test "bench: scoped_map.get.own.1000" (b : @bench.T) {
  let m = build_flat(1000)
  b.bench(fn() { b.keep(m.get("k500")) })
}

// --- get: parent chain lookup ---

///|
test "bench: scoped_map.get.parent_depth1" (b : @bench.T) {
  let parent = build_flat(100)
  let child : ScopedMap[Int] = parent.fork()
  child["local"] = 999
  b.bench(fn() {
    // lookup from parent (promoted on first call, then own)
    b.keep(child.get("k50"))
  })
}

///|
test "bench: scoped_map.get.parent_depth5" (b : @bench.T) {
  let m = build_chain(5, 20)
  b.bench(fn() {
    // key at root level
    b.keep(m.get("d0_k10"))
  })
}

///|
test "bench: scoped_map.get.parent_depth10" (b : @bench.T) {
  let m = build_chain(10, 20)
  b.bench(fn() { b.keep(m.get("d0_k10")) })
}

// --- get: miss (not found) ---

///|
test "bench: scoped_map.get.miss.flat" (b : @bench.T) {
  let m = build_flat(100)
  b.bench(fn() { b.keep(m.get("nonexistent")) })
}

///|
test "bench: scoped_map.get.miss.chain5" (b : @bench.T) {
  let m = build_chain(5, 20)
  b.bench(fn() { b.keep(m.get("nonexistent")) })
}

// --- set ---

///|
test "bench: scoped_map.set.100" (b : @bench.T) {
  let m : ScopedMap[Int] = ScopedMap::new()
  let mut i = 0
  b.bench(fn() {
    m["k" + i.to_string()] = i
    i += 1
  })
}

// --- contains ---

///|
test "bench: scoped_map.contains.own" (b : @bench.T) {
  let m = build_flat(100)
  b.bench(fn() { b.keep(m.contains("k50")) })
}

///|
test "bench: scoped_map.contains.parent_depth5" (b : @bench.T) {
  let m = build_chain(5, 20)
  b.bench(fn() { b.keep(m.contains("d0_k10")) })
}

// --- fork ---

///|
test "bench: scoped_map.fork" (b : @bench.T) {
  let m = build_flat(1000)
  b.bench(fn() { b.keep(m.fork()) })
}

// --- copy (flatten) ---

///|
test "bench: scoped_map.copy.flat100" (b : @bench.T) {
  let m = build_flat(100)
  b.bench(fn() { b.keep(m.copy()) })
}

///|
test "bench: scoped_map.copy.chain5x20" (b : @bench.T) {
  let m = build_chain(5, 20)
  b.bench(fn() { b.keep(m.copy()) })
}

///|
test "bench: scoped_map.copy.chain10x20" (b : @bench.T) {
  let m = build_chain(10, 20)
  b.bench(fn() { b.keep(m.copy()) })
}

// --- merge_up ---

///|
test "bench: scoped_map.merge_up.depth3" (b : @bench.T) {
  b.bench(fn() {
    let m = build_chain(3, 20)
    b.keep(m.merge_up_or_self())
  })
}

// --- iter2 ---

///|
test "bench: scoped_map.iter2.flat100" (b : @bench.T) {
  let m = build_flat(100)
  b.bench(fn() {
    let mut count = 0
    for _, _ in m {
      count += 1
    }
    b.keep(count)
  })
}

///|
test "bench: scoped_map.iter2.chain5x20" (b : @bench.T) {
  let m = build_chain(5, 20)
  b.bench(fn() {
    let mut count = 0
    for _, _ in m {
      count += 1
    }
    b.keep(count)
  })
}

// --- realistic: checker-like pattern ---

///|
test "bench: scoped_map.checker_pattern.fork_set_get" (b : @bench.T) {
  // Simulates checker: fork for scope, bind variables, lookup
  let base = build_flat(50)
  b.bench(fn() {
    let scope = base.fork()
    scope["x"] = 1
    scope["y"] = 2
    scope["z"] = 3
    let _ = scope.get("x")
    let _ = scope.get("k25") // from parent
    b.keep(scope.get("k49"))
  })
}

///|
test "bench: scoped_map.checker_pattern.nested_scopes" (b : @bench.T) {
  // Simulates nested let/match scopes
  let base = build_flat(30)
  b.bench(fn() {
    let s1 = base.fork()
    s1["a"] = 1
    let s2 = s1.fork()
    s2["b"] = 2
    let s3 = s2.fork()
    s3["c"] = 3
    let _ = s3.get("a") // 2 levels up
    let _ = s3.get("k15") // from base, 3 levels up
    b.keep(s3.get("c"))
  })
}
