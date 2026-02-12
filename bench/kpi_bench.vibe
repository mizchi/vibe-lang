let mix1 = (x: Int) -> Int {
  add(mul(x, 3), 11)
}

let mix2 = (x: Int) -> Int {
  add(mul(x, 5), 17)
}

let mix3 = (x: Int) -> Int {
  add(mul(x, 7), 23)
}

let mix4 = (x: Int) -> Int {
  add(mul(x, 11), 29)
}

let mix5 = (x: Int) -> Int {
  add(mul(x, 13), 31)
}

let mix6 = (x: Int) -> Int {
  add(mul(x, 17), 37)
}

let mix7 = (x: Int) -> Int {
  add(mul(x, 19), 41)
}

let mix8 = (x: Int) -> Int {
  add(mul(x, 23), 43)
}

let pipeline = (x: Int) -> Int {
  let a = mix1(x) % 104729
  let b = mix2(a) % 104729
  let c = mix3(b) % 104729
  let d = mix4(c) % 104729
  let e = mix5(d) % 104729
  let f = mix6(e) % 104729
  let g = mix7(f) % 104729
  mix8(g) % 104729
}

let pair_mix = (a: Int, b: Int) -> Int {
  let x = a % b
  let y = add(mul(x, 97), mul(a, 13))
  y % 104729
}

let mut seed_a = 17
let mut seed_b = 123456

bench "pipeline_a" {
  seed_a = pipeline(seed_a)
  let _ = div(1000003, add(1, seed_a % 1000))
}

bench "pipeline_b" {
  seed_b = pipeline(add(seed_b, 97))
  let _ = div(1000003, add(1, seed_b % 1000))
}

bench "pair_mix_ab" {
  seed_a = pair_mix(seed_a, add(seed_b, 1))
  seed_b = pair_mix(seed_b, add(seed_a, 1))
  let _ = div(1000003, add(1, seed_a % 1000))
}

bench "cross_mix" {
  let x = pipeline(add(seed_a, seed_b))
  seed_a = x
  seed_b = pair_mix(seed_b, add(x, 1))
  let _ = div(1000003, add(1, seed_b % 1000))
}
