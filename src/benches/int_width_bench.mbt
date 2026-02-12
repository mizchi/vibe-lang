///|
// Benchmark: Int (i32) vs Int64 (i64) bitwise operations
// Simulates SHA-1-like workload to measure the cost of wider integers.

// --- Int (i32) versions ---

///|
fn sha1_round_i32(
  a : Int,
  b : Int,
  c : Int,
  d : Int,
  e : Int,
  w : Int,
  k : Int,
) -> Int {
  let f = (b & c) ^ (b.lnot() & d)
  let rotl5 = (a << 5) | (a.reinterpret_as_uint() >> 27).reinterpret_as_int()
  (rotl5 + f + e + k + w) & 0x7FFF_FFFF
}

///|
fn i32_schedule_step(w3 : Int, w8 : Int, w14 : Int, w16 : Int) -> Int {
  let x = w3 ^ w8 ^ w14 ^ w16
  ((x << 1) | (x.reinterpret_as_uint() >> 31).reinterpret_as_int()) &
  0x7FFF_FFFF
}

///|
fn i32_bitops_loop(n : Int) -> Int {
  let mut a = 0x6745_2301
  let mut b = 0x7FCD_AB89
  let mut c = 0x18BA_DCFE
  let mut d = 0x1032_5476
  let mut e = 0x43D2_E1F0
  for i = 0; i < n; i = i + 1 {
    let w = i32_schedule_step(a, b, c, d)
    let temp = sha1_round_i32(a, b, c, d, e, w, 0x5A82_7999)
    e = d
    d = c
    c = (b << 30) | (b.reinterpret_as_uint() >> 2).reinterpret_as_int()
    b = a
    a = temp
  }
  a
}

// --- Int64 (i64) versions ---

///|
fn sha1_round_i64(
  a : Int64,
  b : Int64,
  c : Int64,
  d : Int64,
  e : Int64,
  w : Int64,
  k : Int64,
) -> Int64 {
  let f = (b & c) ^ (b.lnot() & d)
  let rotl5 = (a << 5) |
    (a.reinterpret_as_uint64() >> 27).reinterpret_as_int64()
  (rotl5 + f + e + k + w) & 0xFFFF_FFFFL
}

///|
fn i64_schedule_step(w3 : Int64, w8 : Int64, w14 : Int64, w16 : Int64) -> Int64 {
  let x = w3 ^ w8 ^ w14 ^ w16
  ((x << 1) | (x.reinterpret_as_uint64() >> 31).reinterpret_as_int64()) &
  0xFFFF_FFFFL
}

///|
fn i64_bitops_loop(n : Int) -> Int64 {
  let mut a = 0x6745_2301L
  let mut b = 0xEFCD_AB89L
  let mut c = 0x98BA_DCFEL
  let mut d = 0x1032_5476L
  let mut e = 0xC3D2_E1F0L
  for i = 0; i < n; i = i + 1 {
    let w = i64_schedule_step(a, b, c, d)
    let temp = sha1_round_i64(a, b, c, d, e, w, 0x5A82_7999L)
    e = d
    d = c
    c = (b << 30) | (b.reinterpret_as_uint64() >> 2).reinterpret_as_int64()
    b = a
    a = temp
  }
  a
}

// --- Benchmarks ---

///|
test "bench: int_width.i32_sha1_round_80" (b : @bench.T) {
  b.bench(fn() { b.keep(i32_bitops_loop(80)) })
}

///|
test "bench: int_width.i64_sha1_round_80" (b : @bench.T) {
  b.bench(fn() { b.keep(i64_bitops_loop(80)) })
}

///|
test "bench: int_width.i32_sha1_round_800" (b : @bench.T) {
  b.bench(fn() { b.keep(i32_bitops_loop(800)) })
}

///|
test "bench: int_width.i64_sha1_round_800" (b : @bench.T) {
  b.bench(fn() { b.keep(i64_bitops_loop(800)) })
}
